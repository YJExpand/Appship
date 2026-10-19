# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/appship"

class CLITest < Minitest::Test
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
