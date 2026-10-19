# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/appship"

class CacheTest < Minitest::Test
  class InteractiveInput
    def initialize(values)
      @values = values
    end

    def tty?
      true
    end

    def gets
      "#{@values.shift}\n"
    end
  end

  def test_resolves_json_dictionary_array
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".env")
      File.write(path, <<~JSON)
        [
          {"project_name":"Demo","app_name":"DemoApp","pgyer_api_key":"secret"}
        ]
      JSON

      profile = Appship::Cache.new(path).resolve(project_name: "Demo", project_dir: directory)
      assert_equal "DemoApp", profile["app_name"]
      assert_equal "secret", profile["pgyer_api_key"]
    end
  end

  def test_resolves_yaml_dictionary_array
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".env")
      File.write(path, <<~YAML)
        - project_name: Demo
          app_name: DemoApp
          pgyer_api_key: secret
      YAML

      profile = Appship::Cache.new(path).resolve(project_name: "Demo", project_dir: directory)
      assert_equal "Demo", profile["project_name"]
    end
  end

  def test_creates_missing_cache_file
    Dir.mktmpdir do |directory|
      path = File.join(directory, "nested", ".config")
      error = assert_raises(Appship::ConfigurationError) do
        Appship::Cache.load(path, interactive: false)
      end

      assert_includes error.message, "请填写 project_name、app_name、pgyer_api_key；pgyer_password 可为空"
      assert File.file?(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_matches_project_files_instead_of_directory_name
    Dir.mktmpdir("iosBuild-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "Demo.xcodeproj"))
      FileUtils.mkdir_p(File.join(directory, "Demo.xcworkspace"))
      path = File.join(directory, ".config")
      File.write(path, JSON.generate([
        { "project_name" => "WMApp", "pgyer_api_key" => "other-key" },
        { "project_name" => "Demo", "pgyer_api_key" => "demo-key" }
      ]))

      profile = Appship::Cache.new(path).resolve(project_dir: directory, interactive: false)

      assert_equal "Demo", profile["project_name"]
      assert_equal "demo-key", profile["pgyer_api_key"]
    end
  end

  def test_unmatched_project_prompts_for_configuration_without_changing_other_projects
    Dir.mktmpdir("iosBuild-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "Demo.xcodeproj"))
      path = File.join(directory, ".config")
      original = JSON.generate([{ "project_name" => "WMApp", "pgyer_api_key" => "other-key" }])
      File.write(path, original)

      error = assert_raises(Appship::ConfigurationError) do
        Appship::Cache.new(path).resolve(
          project_dir: directory,
          interactive: false,
          credential_overrides: { "pgyer_api_key" => "demo-key" }
        )
      end

      assert_includes error.message, "增加当前项目配置"
      assert_includes error.message, path
      assert_includes error.message, "project_name 应填写: Demo"
      assert_equal original, File.read(path)
    end
  end

  def test_guides_new_project_setup_and_preserves_existing_profiles
    %w[pgyer fir].each do |provider|
      Dir.mktmpdir("iosBuild-") do |directory|
        FileUtils.mkdir_p(File.join(directory, "Demo.xcodeproj"))
        FileUtils.mkdir_p(File.join(directory, "Demo.xcworkspace"))
        path = File.join(directory, ".config")
        existing = { "project_name" => "WMApp", "app_name" => "ExistingApp", "pgyer_api_key" => "old-key", "custom" => "keep" }
        File.write(path, JSON.generate([existing]))
        original_stdin = $stdin
        $stdin = InteractiveInput.new(["DemoApp", "new-key", ""])
        cache = Appship::Cache.new(path)
        profile = nil

        output, = capture_io do
          profile = cache.resolve(project_dir: directory, provider: provider)
        end

        assert_includes output, "请输入 app_name"
        assert_includes output, "请输入 #{provider}_api_key"
        assert_includes output, "请输入 #{provider}_password"
        assert_equal "Demo", profile["project_name"]
        assert_equal "DemoApp", profile["app_name"]
        assert_equal "new-key", profile["#{provider}_api_key"]
        assert_equal "", profile["#{provider}_password"]
        assert_equal [existing, profile], JSON.parse(File.read(path))
        assert_equal 0o600, File.stat(path).mode & 0o777
        assert_equal profile, cache.resolve(project_dir: directory, provider: provider, interactive: false)
        assert_equal 2, cache.entries.length
      ensure
        $stdin = original_stdin
      end
    end
  end

  def test_new_project_setup_uses_credential_overrides
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, "Demo.xcworkspace"))
      path = File.join(directory, ".config")
      File.write(path, JSON.generate([{ "project_name" => "WMApp" }]))
      original_stdin = $stdin
      $stdin = InteractiveInput.new(["DemoApp"])
      profile = nil

      output, = capture_io do
        profile = Appship::Cache.new(path).resolve(
          project_dir: directory,
          credential_overrides: { "pgyer_api_key" => "cli-key", "pgyer_password" => "" }
        )
      end

      assert_equal "cli-key", profile["pgyer_api_key"]
      assert_equal "", profile["pgyer_password"]
      refute_includes output, "请输入 pgyer_api_key"
      refute_includes output, "请输入 pgyer_password"
    ensure
      $stdin = original_stdin
    end
  end

  def test_incomplete_new_project_setup_keeps_cache_unchanged
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, "Demo.xcodeproj"))
      path = File.join(directory, ".config")
      original = JSON.generate([{ "project_name" => "WMApp", "pgyer_api_key" => "old-key" }])
      File.write(path, original)
      original_stdin = $stdin
      $stdin = InteractiveInput.new(["DemoApp", ""])

      capture_io do
        assert_raises(Appship::ConfigurationError) do
          Appship::Cache.new(path).resolve(project_dir: directory)
        end
      end

      assert_equal original, File.read(path)
    ensure
      $stdin = original_stdin
    end
  end

  def test_missing_explicit_project_names_the_configured_cache_file
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".config")
      File.write(path, JSON.generate([{ "project_name" => "WMApp", "fir_api_key" => "other-key" }]))
      error = assert_raises(Appship::ConfigurationError) do
        Appship::Cache.new(path).resolve(project_name: "Demo", provider: "fir", interactive: false)
      end

      assert_includes error.message, path
      assert_includes error.message, "project_name 应填写: Demo"
      assert_includes error.message, "fir_api_key"
    end
  end

  def test_guides_first_time_setup
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".config")
      FileUtils.mkdir_p(File.join(directory, "Demo.xcodeproj"))
      original_stdin = $stdin
      $stdin = InteractiveInput.new(%w[DemoApp secret qiahao])
      profile = Appship::Cache.load(path, project_dir: directory, interactive: true).resolve(project_name: "Demo")
      assert_equal "Demo", profile["project_name"]
      assert_equal "DemoApp", profile["app_name"]
      assert_equal "qiahao", profile["pgyer_password"]
      assert_includes File.read(path), "pgyer_api_key"
    ensure
      $stdin = original_stdin
    end
  end

  def test_guides_fir_api_key_when_cache_entry_is_missing_it
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".config")
      File.write(path, JSON.generate([{ "project_name" => "Demo", "app_name" => "DemoApp" }]))
      original_stdin = $stdin
      $stdin = InteractiveInput.new(["fir-secret"])

      profile = Appship::Cache.load(path, provider: "fir").resolve(project_name: "Demo", provider: "fir")

      assert_equal "fir-secret", profile["fir_api_key"]
      assert_includes File.read(path), "fir_api_key"
    ensure
      $stdin = original_stdin
    end
  end

  def test_guides_fir_credentials_on_first_use
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".config")
      FileUtils.mkdir_p(File.join(directory, "Demo.xcodeproj"))
      original_stdin = $stdin
      $stdin = InteractiveInput.new(%w[DemoApp fir-secret install-secret])

      profile = Appship::Cache.load(path, project_dir: directory, provider: "fir").resolve(project_name: "Demo", provider: "fir")

      assert_equal "fir-secret", profile["fir_api_key"]
      assert_equal "install-secret", profile["fir_password"]
    ensure
      $stdin = original_stdin
    end
  end

  def test_guides_pgyer_api_key_when_cache_entry_is_missing_it
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".config")
      File.write(path, JSON.generate([{ "project_name" => "Demo", "app_name" => "DemoApp" }]))
      original_stdin = $stdin
      $stdin = InteractiveInput.new(["pgyer-secret"])

      profile = Appship::Cache.load(path).resolve(project_name: "Demo")

      assert_equal "pgyer-secret", profile["pgyer_api_key"]
      assert_includes File.read(path), "pgyer_api_key"
    ensure
      $stdin = original_stdin
    end
  end

  def test_credential_overrides_are_persisted
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".config")
      File.write(path, JSON.generate([{ "project_name" => "Demo", "app_name" => "DemoApp", "fir_api_key" => "old-key", "fir_password" => "old-password" }]))

      cache = Appship::Cache.load(path, provider: "fir", interactive: false)
      cache.resolve(
        project_name: "Demo",
        provider: "fir",
        interactive: false,
        credential_overrides: { "fir_api_key" => "new-key", "fir_password" => "new-password" }
      )

      saved = JSON.parse(File.read(path)).first
      assert_equal "new-key", saved["fir_api_key"]
      assert_equal "new-password", saved["fir_password"]
    end
  end
end
