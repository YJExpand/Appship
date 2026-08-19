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
end
