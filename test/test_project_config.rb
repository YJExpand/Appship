# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/appship"

class ProjectConfigTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("appship-project-config-")
    @original_directory = Dir.pwd
    @original_env_file = ENV["APPSHIP_ENV_FILE"]
    @original_stdin = $stdin
    @project_dir = File.join(@directory, "project")
    FileUtils.mkdir_p(File.join(@project_dir, "Demo.xcodeproj"))
    Dir.chdir(@project_dir)
    @local_path = Appship::ProjectConfig.path
    @global_path = File.join(@directory, "global.config")
    ENV["APPSHIP_ENV_FILE"] = @global_path
    $stdin = StringIO.new
    @profile = {
      "project_name" => "Demo", "app_name" => "GlobalApp",
      "pgyer_api_key" => "pgyer-key", "pgyer_password" => "global-password",
      "fir_api_key" => "fir-key", "fir_password" => "fir-password",
      "wechat_webhook" => "https://example.test/wechat", "configuration" => "Release"
    }
    @global_content = JSON.pretty_generate([@profile, { "project_name" => "Other", "custom" => "keep" }])
    File.write(@global_path, @global_content)
  end

  def teardown
    Dir.chdir(@original_directory)
    ENV["APPSHIP_ENV_FILE"] = @original_env_file
    $stdin = @original_stdin
    FileUtils.remove_entry(@directory)
  end

  def write_local(data)
    FileUtils.mkdir_p(File.dirname(@local_path))
    File.write(@local_path, YAML.dump(data))
  end

  def resolve(**options)
    Appship::ProjectConfig.load(@global_path).resolve(interactive: false, **options)
  end

  def test_partial_project_config_inherits_only_the_matching_global_profile
    local = { "app_name" => "LocalApp", "configuration" => "Debug" }
    write_local(local)

    %w[pgyer fir].each do |provider|
      profile = resolve(provider: provider)
      assert_equal @profile.merge(local), profile
      refute profile.key?("custom")
    end
    assert_equal local, YAML.safe_load_file(@local_path)
    assert_equal @global_content, File.read(@global_path)
  end

  def test_explicit_empty_values_override_global_passwords_and_webhooks
    local = {
      "pgyer_api_key" => "local-pgyer-key", "pgyer_password" => "",
      "fir_api_key" => "local-fir-key", "fir_password" => "",
      "wechat_webhook" => "", "dingtalk_webhook" => "https://example.test/dingtalk"
    }
    write_local(local)
    profile = resolve
    options = {}
    capture_io { Appship::CLI.new.send(:apply_cached_profile!, options, profile) }

    assert_equal "local-pgyer-key", options[:api_key]
    assert_equal "", options[:password]
    assert_equal 1, options[:install_type]
    assert_equal "", options[:wechat_webhook]
    assert_equal "https://example.test/dingtalk", options[:dingtalk_webhook]
    assert_equal local, resolve(provider: "fir").slice(*local.keys)
    assert_equal @global_content, File.read(@global_path)
  end

  def test_complete_project_config_does_not_create_global_cache
    write_local(@profile)
    missing = File.join(@directory, "missing", ".config")

    profile = Appship::ProjectConfig.load(missing).resolve(interactive: false)

    assert_equal @profile, profile
    refute File.exist?(File.dirname(missing))
  end

  def test_other_projects_credentials_are_never_used_as_fallback
    File.write(@global_path, JSON.generate([@profile.merge("project_name" => "Other")]))
    write_local("app_name" => "LocalApp")

    error = assert_raises(Appship::ConfigurationError) { resolve }

    assert_includes error.message, "缺少 pgyer_api_key"
    refute_includes File.read(@local_path), "pgyer-key"
  end

  def test_missing_values_are_prompted_into_local_config_and_can_resume
    write_local("project_name" => "Demo")
    missing = File.join(@directory, "missing.config")
    input = StringIO.new("LocalApp\n")
    input.define_singleton_method(:tty?) { true }
    $stdin = input

    capture_io do
      assert_raises(Appship::ConfigurationError) do
        Appship::ProjectConfig.load(missing).resolve
      end
    end
    assert_equal "LocalApp", YAML.safe_load_file(@local_path)["app_name"]
    $stdin = StringIO.new("new-key\n\n")
    $stdin.define_singleton_method(:tty?) { true }
    capture_io { Appship::ProjectConfig.load(missing).resolve }

    assert_equal({ "project_name" => "Demo", "app_name" => "LocalApp", "pgyer_api_key" => "new-key", "pgyer_password" => "" }, YAML.safe_load_file(@local_path))
    refute File.exist?(missing)
    assert_equal @global_content, File.read(@global_path)
  end

  def test_credential_overrides_only_persist_locally_and_keep_other_platforms
    write_local("project_name" => "Demo", "custom" => "keep")

    profile = resolve(credential_overrides: { "pgyer_api_key" => "local-key", "pgyer_password" => "" })

    assert_equal "local-key", profile["pgyer_api_key"]
    assert_equal "fir-key", profile["fir_api_key"]
    assert_equal({ "project_name" => "Demo", "custom" => "keep", "pgyer_api_key" => "local-key", "pgyer_password" => "" }, YAML.safe_load_file(@local_path))
    assert_equal @global_content, File.read(@global_path)
    assert_equal 0o600, File.stat(@local_path).mode & 0o777
  end

  def test_setting_a_value_equal_to_global_still_saves_an_explicit_local_override
    write_local("project_name" => "Demo")
    cache = Appship::ProjectConfig.load(@global_path)
    profile = cache.resolve(interactive: false)
    cache.update_profile!(profile, "pgyer_password" => @profile["pgyer_password"])

    assert_equal @profile["pgyer_password"], YAML.safe_load_file(@local_path)["pgyer_password"]
    assert_equal @global_content, File.read(@global_path)
  end

  def test_webhook_command_writes_project_config_without_copying_global_secrets
    write_local("project_name" => "Demo")
    capture_io { Appship::CLI.new.start(["webhook", "wechat", ""]) }

    assert_equal({ "project_name" => "Demo", "wechat_webhook" => "" }, YAML.safe_load_file(@local_path))
    assert_equal @global_content, File.read(@global_path)
  end

  def test_without_local_config_the_existing_global_cache_is_used
    cache = Appship::ProjectConfig.load(@global_path)
    assert_instance_of Appship::Cache, cache
    profile = cache.resolve(interactive: false)
    cache.update_profile!(profile, "pgyer_password" => "")

    assert_equal "", JSON.parse(File.read(@global_path)).first["pgyer_password"]
    refute File.exist?(@local_path)
  end

  def test_generic_commands_also_receive_merged_build_and_upload_defaults
    write_local("app_name" => "LocalApp", "pgyer_password" => "", "wechat_webhook" => "")
    config = Appship::Config.find
    cli = Appship::CLI.new
    build = cli.send(:build_options, config)
    upload = cli.send(:upload_options, config)

    assert_equal @local_path, config.path
    assert_equal "Demo", build[:scheme]
    assert_equal "Demo.xcodeproj", build[:project]
    assert_equal "Release", build[:configuration]
    assert_equal "pgyer-key", upload[:api_key]
    assert_equal "LocalApp", upload[:app_name]
    assert_equal "", upload[:password]
    assert_equal 1, upload[:install_type]
    assert_equal "", upload[:wechat_webhook]
  end

  def test_invalid_project_config_does_not_silently_use_global_config
    write_local([])
    assert_raises(Appship::ConfigurationError) { resolve }
    File.write(@local_path, "{broken")
    assert_raises(Appship::ConfigurationError) { resolve }
  end

  def test_duplicate_global_project_names_are_rejected
    write_local("app_name" => "LocalApp")
    File.write(@global_path, JSON.generate([@profile, @profile]))

    error = assert_raises(Appship::ConfigurationError) { resolve }

    assert_includes error.message, "project_name 重复"
  end

  def test_symlinked_project_config_is_rejected_without_changing_target
    FileUtils.mkdir_p(File.dirname(@local_path))
    File.symlink(@global_path, @local_path)

    assert_raises(Appship::ConfigurationError) { Appship::ProjectConfig.load(@global_path) }
    assert_equal @global_content, File.read(@global_path)
  end

  def test_samples_are_not_loaded_as_active_configuration_or_message
    Appship::ProjectConfig.init!
    File.write("#{@local_path}.sample", JSON.generate("app_name" => "MustNotUse"))
    File.write("#{Appship::Message.path}.sample", "MustNotUse %{name}\n")

    assert_equal "GlobalApp", resolve["app_name"]
    refute_includes Appship::Message.template, "MustNotUse"
    refute File.exist?(@local_path)
    refute File.exist?(Appship::Message.path)
  end

  def test_init_rejects_symlinked_sample_without_changing_target
    FileUtils.mkdir_p(File.dirname(@local_path))
    File.symlink(@global_path, "#{@local_path}.sample")

    assert_raises(Appship::ConfigurationError) { Appship::ProjectConfig.init! }
    assert_equal @global_content, File.read(@global_path)
  end
end
