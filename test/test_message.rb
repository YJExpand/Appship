# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/appship"

class MessageTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir("appship-messages-")
    @original_home = ENV["HOME"]
    @original_env_file = ENV["APPSHIP_ENV_FILE"]
    @original_directory = Dir.pwd
    ENV["HOME"] = @home
    ENV["APPSHIP_ENV_FILE"] = File.join(@home, "global.config")
    @project_dir = File.join(@home, "project")
    FileUtils.mkdir_p(File.join(@project_dir, "Demo.xcodeproj"))
    Dir.chdir(@project_dir)
    @path = Appship::Message.path
  end

  def teardown
    Dir.chdir(@original_directory)
    ENV["HOME"] = @original_home
    ENV["APPSHIP_ENV_FILE"] = @original_env_file
    FileUtils.remove_entry(@home)
  end

  def test_init_creates_only_project_samples_without_global_files
    output, = capture_io { Appship::CLI.new.start(["init"]) }

    assert_equal %w[config.yml.sample message.yml.sample], Dir.children("appship").sort
    config_sample = File.read("appship/config.yml.sample")
    assert_equal({ "project_name" => "Demo" }, YAML.safe_load(config_sample))
    assert_includes config_sample, "# app_name: app-name"
    assert_includes config_sample, "# 机器人配置"
    %w[pgyer_api_key pgyer_password fir_api_key fir_password wechat_webhook dingtalk_webhook feishu_webhook].each do |key|
      assert_match(/^# #{key}: "/, config_sample)
    end
    assert_match(/^# app_icon_badge: true/, config_sample)
    assert_match(/^# app_icon_badge_environment: true/, config_sample)
    assert_match(/^# app_icon_badge_version: false/, config_sample)
    assert_equal 0o600, File.stat("#{Appship::ProjectConfig.path}.sample").mode & 0o777
    assert_equal 0o600, File.stat("#{@path}.sample").mode & 0o777
    message_sample = File.read("#{@path}.sample")
    assert_includes message_sample, "可用变量"
    assert_nil YAML.safe_load(message_sample)
    %w[wechat dingtalk feishu].product(%w[success failure]).each do |platform, status|
      assert_match(/^# #{platform}_webhook_#{status}_content: ""/, message_sample)
    end
    cli_example = message_sample.lines.drop_while { |line| line != "# cli_content: |\n" }
                                .take_while { |line| line.start_with?("# ") }.map { |line| line.delete_prefix("# ") }.join
    assert_includes YAML.safe_load(cli_example).fetch("cli_content"), "发布成功\n版本："
    assert_includes output, "#{@path}.sample"
    refute_includes Appship::Message.template, "可用变量"
    refute File.exist?(File.join(@home, ".appship"))
    refute File.exist?(".appship.yml")
    refute File.exist?(@path)
    refute File.exist?(Appship::ProjectConfig.path)
    File.write(@path, message_sample)
    assert_equal File.read(Appship::Message.default_path), Appship::Message.template
  end

  def test_init_preserves_samples_and_active_files
    capture_io { Appship::CLI.new.start(["init"]) }
    config = "{\"project_name\":\"Demo\",\"app_name\":\"Custom\"}\n"
    File.write(Appship::ProjectConfig.path, config)
    File.write(@path, "自定义 %{name}\n")
    File.write("#{Appship::ProjectConfig.path}.sample", config)
    File.write("#{@path}.sample", "自定义示例 %{name}\n")

    capture_io { 2.times { Appship::CLI.new.start(["init"]) } }

    assert_equal config, File.read(Appship::ProjectConfig.path)
    assert_equal "自定义 %{name}\n", File.read(@path)
    assert_equal config, File.read("#{Appship::ProjectConfig.path}.sample")
    assert_equal "自定义示例 %{name}\n", File.read("#{@path}.sample")
  end

  def test_init_can_target_another_project_directory
    other = File.join(@home, "other")
    FileUtils.mkdir_p(File.join(other, "Other.xcodeproj"))

    capture_io { Appship::CLI.new.start(["init", "--project-dir", other]) }

    assert_equal "Other", YAML.safe_load_file("#{Appship::ProjectConfig.path(other)}.sample")["project_name"]
    assert File.file?("#{Appship::Message.path(other)}.sample")
    refute File.exist?(@path)
  end

  def test_custom_template_preserves_literal_percent_and_body_comments
    Appship::Message.init!
    File.write(File.join(File.dirname(@path), "message"), "/* 备注 */\n%{name} 100%\n/* 正文 */\n%{description}\n")

    assert_equal "Demo 100%\n/* 正文 */\n更新 %{url}\n", Appship::Message.render(name: "Demo", description: "更新 %{url}")
    File.write(@path, YAML.dump("cli_content" => "YAML %{name}\n"))
    assert_equal "YAML Demo\n", Appship::Message.render(name: "Demo")
  end

  def test_invalid_variables_are_reported_before_building_or_uploading
    Appship::Message.init!
    File.write(@path, YAML.dump("feishu_webhook_content" => "未知 %{unknown}\n"))

    [["build", "--upload"], ["package", "--app", "missing.app", "--upload"], ["upload", "missing.ipa"]].each do |args|
      error = assert_raises(Appship::ConfigurationError) { Appship::CLI.new.start(args) }
      assert_includes error.message, "未知变量 unknown"
      assert_includes error.message, @path
    end
  end

  def test_invalid_template_syntax_is_rejected
    Appship::Message.init!
    ["cli_content: [", "cli_content: true", "cli_content: '应用 %{name'",
     "wechat_webhook_format: image", "feishu_webhook_format: interactive", "unknown: text"].each do |content|
      File.write(@path, content)
      assert_raises(Appship::ConfigurationError) { Appship::Message.template }
    end
  end

  def test_messages_are_isolated_by_project_directory
    Appship::Message.init!
    File.write(@path, YAML.dump("cli_content" => "第一个 %{name}\n"))
    other = File.join(@home, "other")
    Appship::Message.init!(project_dir: other)
    File.write(Appship::Message.path(other), YAML.dump("cli_content" => "第二个 %{name}\n"))

    assert_equal "第一个 Demo\n", Appship::Message.render(name: "Demo")
    Dir.chdir(other) { assert_equal "第二个 Demo\n", Appship::Message.render(name: "Demo") }
  end

  def test_entire_message_command_group_is_removed
    [[], ["init"], ["-e"], ["-o", "file.txt"]].each do |args|
      error = assert_raises(Appship::ConfigurationError) { Appship::CLI.new.start(["message", *args]) }
      assert_includes error.message, "未知命令: message"
    end
    output, = capture_io { Appship::CLI.new.start(["--help"]) }
    refute_includes output, "appship message"
    refute File.exist?(@path)
  end
end
