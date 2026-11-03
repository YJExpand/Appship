# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/appship"

class CLITest < Minitest::Test
  def setup
    @cli_home = Dir.mktmpdir("appship-cli-")
    @original_home = ENV["HOME"]
    ENV["HOME"] = @cli_home
    @project_dir = File.join(@cli_home, "project")
    FileUtils.mkdir_p(File.join(@project_dir, "Demo.xcodeproj"))
    @cache_path = File.join(@cli_home, ".config")
    @profiles = [
      { "project_name" => "Demo", "app_name" => "DemoApp" },
      { "project_name" => "Other", "custom" => "keep" }
    ]
    File.write(@cache_path, JSON.generate(@profiles))
    @original_stdin = $stdin
    $stdin = StringIO.new
  end

  def teardown
    $stdin = @original_stdin
    ENV["HOME"] = @original_home
    FileUtils.remove_entry(@cli_home)
  end

  class FailingBuilder
    attr_reader :calls

    def initialize(error)
      @error = error
      @calls = []
    end

    def find_cached_app!(_options)
      @calls << :find_cached_app
      raise @error
    end

    def build!(_options)
      @calls << :build
      raise @error
    end

    def package!(_options)
      @calls << :package
      raise @error
    end
  end

  def with_release_fakes(error, notification_error: nil)
    original_builder = Appship::Builder.method(:new)
    original_webhook = Appship::Webhook.method(:new)
    builder = FailingBuilder.new(error)
    messages = []
    Appship::Builder.define_singleton_method(:new) { |*| builder }
    Appship::Webhook.define_singleton_method(:new) do |options|
      webhook = original_webhook.call(options)
      webhook.define_singleton_method(:notify) do |message, failure: false|
        messages << { message: message, failure: failure }
        raise notification_error if notification_error
      end
      webhook
    end
    yield builder, messages
  ensure
    Appship::Builder.define_singleton_method(:new, original_builder)
    Appship::Webhook.define_singleton_method(:new, original_webhook)
  end

  def configured_release_args(provider = "pgyer")
    @profiles.first.merge!(
      "pgyer_api_key" => "pgyer-test-key", "pgyer_password" => "",
      "fir_api_key" => "fir-test-key", "fir_password" => "",
      "wechat_webhook" => "https://example.test/send?key=test-key"
    )
    File.write(@cache_path, JSON.generate(@profiles))
    [provider, "--project-dir", @project_dir, "--env-file", @cache_path, "--description", "test", "--no-badge"]
  end

  def test_missing_cache_stops_both_platforms_and_sends_one_failure_notification
    %w[pgyer fir].each do |provider|
      args = configured_release_args(provider) + ["--cache"]
      error = Appship::CommandError.new("未找到缓存 App")
      with_release_fakes(error) do |builder, messages|
        capture_io do
          actual = assert_raises(Appship::CommandError) { Appship::CLI.new.start(args) }
          assert_same error, actual
        end

        assert_equal [:find_cached_app], builder.calls
        assert_equal 1, messages.length
        assert messages.first[:failure]
        assert_includes messages.first[:message], "未找到缓存 App"
        assert_includes messages.first[:message], "DemoApp"
      end
    end
  end

  def test_missing_credentials_can_notify_using_the_matching_project_webhook
    args = configured_release_args + ["--rebuild"]
    @profiles.first.delete("pgyer_api_key")
    File.write(@cache_path, JSON.generate(@profiles))
    with_release_fakes(Appship::CommandError.new("must not build")) do |builder, messages|
      capture_io do
        assert_raises(Appship::ConfigurationError) { Appship::CLI.new.start(args) }
      end

      assert_empty builder.calls
      assert_equal 1, messages.length
      assert_includes messages.first[:message], "缓存缺少 pgyer_api_key"
      assert_includes messages.first[:message], "DemoApp"
    end
  end

  def test_unexpected_exception_and_user_interruption_notify_and_keep_original_error
    [RuntimeError.new("unexpected failure"), Interrupt.new("cancelled")].each do |error|
      args = configured_release_args + ["--rebuild", "--configuration", "Release"]
      with_release_fakes(error) do |builder, messages|
        capture_io do
          actual = assert_raises(error.class) { Appship::CLI.new.start(args) }
          assert_same error, actual
        end

        assert_equal [:build], builder.calls
        assert_equal 1, messages.length
        assert messages.first[:failure]
        assert_includes messages.first[:message], error.message
      end
    end
  end

  def test_failure_notification_error_never_replaces_the_release_error
    args = configured_release_args + ["--cache"]
    error = Appship::CommandError.new("cache failed")
    with_release_fakes(error, notification_error: IOError.new("webhook failed")) do |_builder, messages|
      _output, warnings = capture_io do
        actual = assert_raises(Appship::CommandError) { Appship::CLI.new.start(args) }
        assert_same error, actual
      end

      assert_equal 1, messages.length
      assert_includes warnings, "保留原始错误"
    end
  end

  def test_failed_project_matching_does_not_notify_other_projects
    args = configured_release_args + ["--cache"]
    @profiles = [{ "project_name" => "Other", "wechat_webhook" => "https://example.test/other" }]
    File.write(@cache_path, JSON.generate(@profiles))

    with_release_fakes(Appship::CommandError.new("must not build")) do |builder, messages|
      capture_io { assert_raises(Appship::ConfigurationError) { Appship::CLI.new.start(args) } }

      assert_empty messages
      assert_empty builder.calls
    end
  end

  def test_webhook_settings_save_without_credentials_or_exposing_urls
    {
      "wechat" => "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key",
      "dingtalk" => "https://oapi.dingtalk.com/robot/send?access_token=test-token"
    }.each do |platform, url|
      output, errors = capture_io do
        Appship::CLI.new.start(["webhook", platform, url, "--project-dir", @project_dir, "--env-file", @cache_path])
      end

      saved = JSON.parse(File.read(@cache_path))
      assert_equal url, saved.first["#{platform}_webhook"]
      assert_equal @profiles.last, saved.last
      assert_equal 0o600, File.stat(@cache_path).mode & 0o777
      assert_includes output, "已保存"
      refute_includes output + errors, url
      refute_includes output, "请输入"
    end
  end

  def test_webhook_empty_url_disables_only_the_selected_project
    @profiles.first["wechat_webhook"] = "https://example.test/old"
    File.write(@cache_path, JSON.generate(@profiles))

    capture_io do
      Appship::CLI.new.start(["webhook", "wechat", "", "--project-name", "Demo", "--env-file", @cache_path])
    end

    saved = JSON.parse(File.read(@cache_path))
    assert_equal "", saved.first["wechat_webhook"]
    assert_equal @profiles.last, saved.last
  end

  def test_invalid_webhook_settings_do_not_modify_cache
    [
      ["wechat"],
      ["unknown", "https://example.test"],
      ["wechat", "http://example.test"],
      ["wechat", "https://user:password@example.test"],
      ["wechat", "https://example.test/#secret"],
      ["wechat", "not a url"]
    ].each do |args|
      original = File.read(@cache_path)
      capture_io do
        assert_raises(Appship::ConfigurationError) do
          Appship::CLI.new.start(["webhook", *args, "--env-file", @cache_path])
        end
      end
      assert_equal original, File.read(@cache_path)
    end
  end

  def test_pgyer_profile_passes_own_credentials_and_webhooks_to_upload_options
    options = {}
    profile = { "project_name" => "Demo", "app_name" => "DemoApp", "pgyer_api_key" => "key", "pgyer_password" => "",
                "fir_api_key" => "fir-key", "fir_password" => "fir-password",
                "wechat_webhook" => "https://example.test/wechat", "dingtalk_webhook" => "https://example.test/dingtalk" }

    capture_io { Appship::CLI.new.send(:apply_cached_profile!, options, profile) }

    assert_equal "key", options[:api_key]
    assert_equal "", options[:password]
    assert_equal 1, options[:install_type]
    assert_equal profile["wechat_webhook"], options[:wechat_webhook]
    assert_equal profile["dingtalk_webhook"], options[:dingtalk_webhook]
  end

  def test_unmatched_target_prompts_for_project_configuration
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, "Demo.xcodeproj"))
      config_path = File.join(directory, "custom.config")
      Dir.chdir(directory) do
        error = assert_raises(Appship::ConfigurationError) do
          Appship::CLI.new.send(:infer_pgyer_target!, { project_name: "WMApp", env_file: config_path })
        end

        assert_includes error.message, config_path
        assert_includes error.message, "增加当前项目配置"
        assert_includes error.message, "project_name: Demo"
      end
    end
  end

  def test_missing_target_prompts_for_project_directory
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        error = assert_raises(Appship::ConfigurationError) do
          Appship::CLI.new.send(:infer_pgyer_target!, { project_name: "WMApp" })
        end

        assert_includes error.message, "project_name"
        assert_includes error.message, "--project-dir"
        assert_includes error.message, directory
      end
    end
  end

  def test_fir_short_options_are_normalized
    args = ["-key", "new-key", "-password", "new-password"]

    Appship::CLI.new.send(:normalize_provider_short_options!, args, "fir")

    assert_equal ["--fir-api-key", "new-key", "--fir-password", "new-password"], args
  end

  def test_pgyer_short_options_are_normalized
    args = ["-key=new-key", "-password=new-password"]

    Appship::CLI.new.send(:normalize_provider_short_options!, args, "pgyer")

    assert_equal ["--api-key=new-key", "--password=new-password"], args
  end
end
