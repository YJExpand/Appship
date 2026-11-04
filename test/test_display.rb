# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/appship"

class DisplayTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir("appship-display-")
    @original_home = ENV["HOME"]
    @original_directory = Dir.pwd
    ENV["HOME"] = @home
    Dir.chdir(@home)
    @message_path = Appship::Message.path
  end

  def teardown
    Dir.chdir(@original_directory)
    ENV["HOME"] = @original_home
    FileUtils.remove_entry(@home)
  end

  def test_version_does_not_create_message_files
    output, = capture_io { Appship::CLI.new.start(["--version"]) }

    assert_equal "appship #{Appship::VERSION}\n", output
    refute File.exist?(@message_path)
    refute File.exist?(File.join(@home, ".appship"))
  end

  def test_missing_project_template_uses_bundle_without_reading_or_writing_global_messages
    legacy_path = File.join(@home, ".appship", "message.txt")
    FileUtils.mkdir_p(File.dirname(legacy_path))
    File.write(legacy_path, "旧全局模板\n")
    output, = capture_io { Appship::Display.upload_result({}, file: "Demo.ipa") }

    assert_equal File.read(File.expand_path("../lib/appship/default_message", __dir__)), Appship::Message.template
    assert_includes output, "应用名称: Demo\n"
    assert_equal "旧全局模板\n", File.read(legacy_path)
    refute File.exist?(File.join(@home, ".appship", ".default_message"))
    refute File.exist?(@message_path)
  end

  def test_rejects_directory_at_message_path_without_changing_permissions
    FileUtils.mkdir_p(@message_path, mode: 0o700)
    original_mode = File.stat(@message_path).mode

    error = assert_raises(Appship::ConfigurationError) { Appship::Message.template }

    assert_includes error.message, "消息模板必须是普通文件"
    assert_equal original_mode, File.stat(@message_path).mode
  end

  def test_rejects_symlink_without_changing_target
    target = File.join(@home, "other-file")
    File.write(target, "keep", perm: 0o600)
    FileUtils.mkdir_p(File.dirname(@message_path))
    File.symlink(target, @message_path)

    assert_raises(Appship::ConfigurationError) { Appship::Message.template }

    assert_equal "keep", File.read(target)
    assert_equal 0o600, File.stat(target).mode & 0o777
  end

  def test_pgyer_output_renders_template_with_upload_data
    result = { "data" => {
      "buildName" => "Demo",
      "buildType" => "1",
      "buildVersion" => "1.2.3",
      "buildBuildVersion" => "42",
      "buildFileSize" => "1572864",
      "buildUpdated" => "2026-10-26 10:00:00",
      "buildKey" => "demo"
    } }
    options = { configuration: "Release", interactive_content: "完成 100% %{url}", password: "install-secret" }

    output, = capture_io { Appship::Display.upload_result(result, file: "Demo.ipa", options: options) }

    assert_includes output, "应用名称: Demo\n应用类型: iOS\n版本信息: 1.2.3(42)\n"
    assert_includes output, "构建模式: Release\n应用大小: 1.5MB\n更新时间: 2026-10-26 10:00:00\n"
    assert_includes output, "更新描述: 完成 100% %{url}\n安装密码: install-secret\n下载链接: https://www.pgyer.com/demo\n"
    refute_includes output, "分发平台:"
    refute_includes Appship::Message.template, "install-secret"
  end

  def test_pgyer_output_omits_missing_optional_fields
    output, = capture_io do
      Appship::Display.upload_result({ "buildUpdated" => "" }, file: "Demo.apk")
    end

    assert_includes output, "应用名称: Demo\n应用类型: Android\n构建模式: 未知\n"
    assert_includes output, "安装密码: 未设置\n下载链接: https://www.pgyer.com/\n"
    refute_match(/版本信息:|应用大小:|更新时间:|分发平台:/, output)
  end

  def test_fir_output_preserves_password_status
    result = {
      "provider" => "fir",
      "data" => { "name" => "Demo", "type" => "ios", "version" => "1.2.3", "build" => "42", "password_protected" => true },
      "url" => "https://fir.im/demo"
    }

    output, = capture_io do
      Appship::Display.upload_result(result, file: "Demo.ipa", options: { description: "首次发布", fir_password: "install-secret" })
    end

    assert_includes output, "应用名称: Demo\n应用类型: iOS\n版本信息: 1.2.3(42)\n"
    assert_includes output, "更新描述: 首次发布\n安装密码: 已设置\n下载链接: https://fir.im/demo\n"
    refute_match(/分发平台:|构建模式:|应用大小:|更新时间:|install-secret/, output)
  end

  def test_fir_output_handles_missing_version_and_no_password
    result = { "provider" => "fir", "data" => { "type" => "android" }, "url" => "https://fir.im/demo" }

    output, = capture_io { Appship::Display.upload_result(result, file: "Demo.apk") }

    assert_includes output, "应用名称: Demo\n应用类型: Android\n更新描述: \n安装密码: 未设置\n"
    refute_includes output, "版本信息:"
  end
end
