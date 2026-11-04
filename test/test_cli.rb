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
    attr_reader :calls, :options

    def initialize(error)
      @error = error
      @calls = []
    end

    def find_cached_app!(_options)
      @calls << :find_cached_app
      raise @error
    end

    def build!(options)
      @options = options
      @calls << :build
      raise @error
    end

    def package!(options)
      @options = options
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

  def test_both_release_commands_use_partial_project_config_and_persist_credentials_locally
    %w[pgyer fir].each do |provider|
      args = configured_release_args(provider) + ["--rebuild", "-key", "local-key", "-password", ""]
      local_path = Appship::ProjectConfig.path(@project_dir)
      FileUtils.mkdir_p(File.dirname(local_path))
      File.write(local_path, YAML.dump("project_name" => "Demo", "app_name" => "LocalApp", "configuration" => "Release",
                                       "app_icon_badge" => true, "badge" => "QA"))
      global_content = File.read(@cache_path)

      with_release_fakes(Appship::CommandError.new("stop before archive")) do |builder, messages|
        capture_io { assert_raises(Appship::CommandError) { Appship::CLI.new.start(args) } }

        assert_equal [:build], builder.calls
        assert_equal "LocalApp", builder.options[:app_name]
        assert_equal "Release", builder.options[:configuration]
        assert_nil builder.options[:badge]
        assert_equal "local-key", builder.options[provider == "fir" ? :fir_api_token : :api_key]
        assert_equal "", builder.options[provider == "fir" ? :fir_password : :password]
        assert_equal @profiles.first["wechat_webhook"], builder.options[:wechat_webhook]
        assert_equal 1, messages.length
        assert_includes messages.first[:message], "LocalApp"
      end
      saved = YAML.safe_load_file(local_path)
      assert_equal "local-key", saved["#{provider}_api_key"]
      assert_equal "", saved["#{provider}_password"]
      refute saved.key?(provider == "fir" ? "pgyer_api_key" : "fir_api_key")
      assert_equal global_content, File.read(@cache_path)
    end
  end

  def test_app_icon_badge_settings_override_automatic_choices
    cli = Appship::CLI.new
    cases = [
      [{ "app_icon_badge" => false, "app_icon_badge_environment" => true, "badge" => "QA" }, nil],
      [{ "app_icon_badge" => true }, "RELEASE"],
      [{ "app_icon_badge_environment" => true }, "RELEASE"],
      [{ "app_icon_badge" => true, "app_icon_badge_environment" => false, "app_icon_badge_version" => true }, nil],
      [{ "app_icon_badge_environment" => false, "badge" => "QA" }, "QA"]
    ]
    cases.each do |profile, expected|
      options = { configuration: "Release" }
      cli.send(:apply_badge_config!, options, profile) { flunk "should not prompt for a badge" }
      expected ? assert_equal(expected, options[:badge]) : assert_nil(options[:badge])
    end
    assert_raises(Appship::ConfigurationError) do
      cli.send(:apply_badge_config!, {}, { "app_icon_badge" => "false" })
    end
  end

  def test_cache_badge_uses_configuration_of_the_package_found
    cli = Appship::CLI.new
    builder = Object.new
    builder.define_singleton_method(:find_cached_app!) do |options|
      options[:configuration] = "Release"
      "Demo.app"
    end
    options = { build_mode: "cache", build_mode_explicit: true, configuration: "Debug", description: "test" }

    capture_io { cli.send(:prepare_pgyer_flow!, options, builder, { "app_icon_badge" => true }) }

    assert_equal "Demo.app", options[:app]
    assert_equal "RELEASE", options[:badge]
  end

  def test_build_and_package_resolve_badges_after_cli_options
    path = File.join(@cli_home, "config.yml")
    File.write(path, YAML.dump("configuration" => "Debug", "app_icon_badge" => true))

    [
      [%w[build --configuration Release], "RELEASE"],
      [%w[package --no-badge], nil],
      [%w[package], "DEBUG"],
      [%w[package --badge QA], "QA"]
    ].each do |command, expected|
      with_release_fakes(Appship::CommandError.new("stop before build")) do |builder, _messages|
        capture_io { assert_raises(Appship::CommandError) { Appship::CLI.new.start(["--config", path, *command]) } }
        expected ? assert_equal(expected, builder.options[:badge]) : assert_nil(builder.options[:badge])
      end
    end
  end

  def test_missing_credentials_can_notify_from_local_only_profile
    args = ["pgyer", "--project-dir", @project_dir, "--env-file", File.join(@cli_home, "missing.config"), "--rebuild"]
    local_path = Appship::ProjectConfig.path(@project_dir)
    FileUtils.mkdir_p(File.dirname(local_path))
    File.write(local_path, JSON.generate("project_name" => "Demo", "app_name" => "LocalApp", "feishu_webhook" => "https://example.test/local"))

    with_release_fakes(Appship::CommandError.new("must not build")) do |builder, messages|
      capture_io { assert_raises(Appship::ConfigurationError) { Appship::CLI.new.start(args) } }

      assert_empty builder.calls
      assert_equal 1, messages.length
      assert_includes messages.first[:message], "缺少 pgyer_api_key"
      assert_includes messages.first[:message], "LocalApp"
    end
    refute File.exist?(File.join(@cli_home, "missing.config"))
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
      "dingtalk" => "https://oapi.dingtalk.com/robot/send?access_token=test-token",
      "feishu" => "https://open.feishu.cn/open-apis/bot/v2/hook/test-token"
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
                "wechat_webhook" => "https://example.test/wechat", "dingtalk_webhook" => "https://example.test/dingtalk",
                "feishu_webhook" => "https://example.test/feishu", "feishu_webhook_secret" => "signing-secret" }

    capture_io { Appship::CLI.new.send(:apply_cached_profile!, options, profile) }

    assert_equal "key", options[:api_key]
    assert_equal "", options[:password]
    assert_equal 1, options[:install_type]
    assert_equal profile["wechat_webhook"], options[:wechat_webhook]
    assert_equal profile["dingtalk_webhook"], options[:dingtalk_webhook]
    assert_equal profile["feishu_webhook"], options[:feishu_webhook]
    assert_equal profile["feishu_webhook_secret"], options[:feishu_webhook_secret]
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
