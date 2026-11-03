# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/appship"

class MessageTest < Minitest::Test
  class RecordingCLI < Appship::CLI
    attr_reader :editor_command
    attr_accessor :editor_result

    def system(*args)
      @editor_command = args
      @editor_result != false
    end
  end

  def setup
    @home = Dir.mktmpdir("appship messages-")
    @original_env = ENV.to_h.slice("HOME", "VISUAL", "EDITOR")
    ENV["HOME"] = @home
    ENV.delete("VISUAL")
    ENV.delete("EDITOR")
    @path = File.join(@home, ".appship", "message.txt")
  end

  def teardown
    %w[HOME VISUAL EDITOR].each { |key| ENV[key] = @original_env[key] }
    FileUtils.remove_entry(@home)
  end

  def test_init_creates_editable_template_and_prints_instructions_once
    output, = capture_io { Appship::CLI.new.start(["message", "init"]) }

    assert File.file?(@path)
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert File.read(@path).start_with?(Appship::Message::INSTRUCTIONS)
    assert_equal 1, output.scan("Appship 发布消息模板").length
    assert_includes output, "↓↓↓↓案例↓↓↓↓"
    assert_includes output, "appship message -o <filePath>"
    refute_match(/provider|password_label/, File.read(@path))
    assert_equal 0o444, File.stat(File.join(@home, ".appship", ".default_message")).mode & 0o777

    rendered, = capture_io { Appship::Display.upload_result({}, file: "Demo.ipa") }
    assert_includes rendered, "应用名称: Demo\n"
    refute_match(/Appship 发布消息模板|相关命令|\/\*|\*\//, rendered)
  end

  def test_init_does_not_overwrite_existing_user_template
    Appship::Message.init!
    File.write(@path, "自定义 %{name}\n")

    output, = capture_io { Appship::CLI.new.start(["message", "init"]) }

    assert_equal "自定义 %{name}\n", File.read(@path)
    assert_includes output, "已有文件不会覆盖"
    assert_equal 1, output.scan("Appship 发布消息模板").length
  end

  def test_custom_template_takes_priority_and_preserves_literal_percent_and_body_comments
    Appship::Message.init!
    File.write(@path, "/*\n备注中允许 %{unknown}\n*/\n🚀 %{name} 发布成功，完成 100%\n/* 正文 */\n%{description}\n")
    options = { description: '100% %{name} #{raise "must not run"}' }

    output, = capture_io { Appship::Display.upload_result({}, file: "Demo.ipa", options: options) }

    assert_equal "🚀 Demo 发布成功，完成 100%\n/* 正文 */\n100% %{name} \#{raise \"must not run\"}\n", output
  end

  def test_overwrite_copies_valid_file_and_preserves_default_template
    Appship::Message.init!
    default_path = Appship::Message.initialize_default!
    default_content = File.read(default_path)
    source = File.join(@home, "replacement message.txt")
    content = "/* 备注不会输出 */\n新版 %{name}，完成 100%\n"
    File.write(source, content)

    output, = capture_io { Appship::CLI.new.start(["message", "-o", source]) }

    assert_equal content, File.read(@path)
    assert_equal default_content, File.read(default_path)
    assert_equal 0o444, File.stat(default_path).mode & 0o777
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_includes output, "消息模板已覆盖"
    assert_equal "新版 Demo，完成 100%\n", Appship::Message.render(name: "Demo")
  end

  def test_invalid_overwrite_keeps_existing_template
    Appship::Message.init!
    original = File.read(@path)
    source = File.join(@home, "invalid.txt")
    invalid = ["%{provider}", "%{password_label}", "%{unknown}", "%{name", "/* 未闭合", "/* 只有备注 */", "\xFF".b]

    invalid.each do |content|
      File.write(source, content)
      error = assert_raises(Appship::ConfigurationError) { Appship::Message.overwrite!(source) }

      assert_includes error.message, source
      assert_equal original, File.read(@path)
    end
  end

  def test_missing_overwrite_source_keeps_existing_template
    Appship::Message.init!
    original = File.read(@path)

    assert_raises(Appship::ConfigurationError) do
      Appship::CLI.new.start(["message", "-o", File.join(@home, "missing.txt")])
    end

    assert_equal original, File.read(@path)
  end

  def test_invalid_variables_are_reported_before_building_or_uploading
    Appship::Message.init!
    File.write(@path, "%{unknown}\n")

    %i[build! package! upload!].each do |action|
      error = assert_raises(Appship::ConfigurationError) do
        Appship::Builder.new.public_send(action, { upload: true })
      end

      assert_includes error.message, "未知变量 unknown"
      assert_includes error.message, @path
    end
  end

  def test_edit_uses_visual_editor_with_arguments_without_a_shell
    Appship::Message.init!
    ENV["VISUAL"] = 'my-editor --wait "some option"'
    ENV["EDITOR"] = "other-editor"
    cli = RecordingCLI.new

    cli.start(["message", "-e"])

    assert_equal ["my-editor", "--wait", "some option", @path], cli.editor_command
  end

  def test_edit_defaults_to_macos_text_editor
    Appship::Message.init!
    cli = RecordingCLI.new

    cli.start(["message", "-e"])

    assert_equal ["open", "-t", @path], cli.editor_command
  end

  def test_edit_reports_missing_template_and_editor_errors
    error = assert_raises(Appship::ConfigurationError) { RecordingCLI.new.start(["message", "-e"]) }
    assert_includes error.message, "appship message init"

    Appship::Message.init!
    ENV["EDITOR"] = "'unclosed"
    assert_raises(Appship::ConfigurationError) { RecordingCLI.new.start(["message", "-e"]) }

    ENV["EDITOR"] = "missing-editor"
    cli = RecordingCLI.new
    cli.editor_result = false
    assert_raises(Appship::CommandError) { cli.start(["message", "-e"]) }
  end

  def test_message_rejects_combined_actions_and_extra_arguments
    [["init", "-e"], ["-e", "-o", "file.txt"], ["init", "extra"]].each do |args|
      assert_raises(Appship::ConfigurationError) { RecordingCLI.new.start(["message", *args]) }
    end

    refute File.exist?(@path)
  end
end
