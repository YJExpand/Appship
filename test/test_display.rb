# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/appship"

class DisplayTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir("appship-display-")
    @original_home = ENV["HOME"]
    ENV["HOME"] = @home
    @message_path = File.join(@home, ".appship", ".default_message")
  end

  def teardown
    ENV["HOME"] = @original_home
    FileUtils.remove_entry(@home)
  end

  def test_first_cli_use_initializes_read_only_default_message
    output, = capture_io { Appship::CLI.new.start(["--version"]) }

    assert_equal "appship #{Appship::VERSION}\n", output
    assert_equal File.read(File.expand_path("../lib/appship/default_message", __dir__)), File.read(@message_path)
    assert_equal 0o444, File.stat(@message_path).mode & 0o777
  end

  def test_default_template_is_updated_from_bundled_version_and_made_read_only
    FileUtils.mkdir_p(File.dirname(@message_path))
    File.write(@message_path, "旧默认模板: %{provider} %{password_label}\n")

    2.times { Appship::Message.initialize_default! }
    output, = capture_io { Appship::Display.upload_result({}, file: "Demo.ipa") }

    assert_equal File.read(File.expand_path("../lib/appship/default_message", __dir__)), File.read(@message_path)
    assert_includes output, "应用名称: Demo\n"
    assert_equal 0o444, File.stat(@message_path).mode & 0o777
  end

  def test_rejects_directory_at_message_path_without_changing_permissions
    FileUtils.mkdir_p(@message_path, mode: 0o700)
    original_mode = File.stat(@message_path).mode

    error = assert_raises(Appship::ConfigurationError) { Appship::Message.initialize_default! }

    assert_includes error.message, "消息模板必须是普通文件"
    assert_equal original_mode, File.stat(@message_path).mode
  end

  def test_rejects_symlink_without_changing_target
    target = File.join(@home, "other-file")
    File.write(target, "keep", perm: 0o600)
    FileUtils.mkdir_p(File.dirname(@message_path))
    File.symlink(target, @message_path)

    assert_raises(Appship::ConfigurationError) { Appship::Message.initialize_default! }

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
    refute_includes File.read(@message_path), "install-secret"
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
