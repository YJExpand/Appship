# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/appship"

class WebhookTest < Minitest::Test
  class FakeHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def request(request)
      @requests << request
      response = @responses.shift
      raise response if response.is_a?(Exception)
      raise "Unexpected request" unless response

      response
    end
  end

  FakeUploader = Struct.new(:result) do
    def upload!(_file)
      raise result if result.is_a?(Exception)

      result
    end
  end

  def setup
    @webhook_home = Dir.mktmpdir("appship-webhook-")
    @original_home = ENV["HOME"]
    @original_directory = Dir.pwd
    ENV["HOME"] = @webhook_home
    Dir.chdir(@webhook_home)
  end

  def teardown
    Dir.chdir(@original_directory)
    ENV["HOME"] = @original_home
    FileUtils.remove_entry(@webhook_home)
  end

  def response(body = '{"errcode":0,"errmsg":"ok"}', status: "200")
    result = Net::HTTPResponse::CODE_TO_OBJ.fetch(status).new("1.1", status, "")
    result.body = body
    result.instance_variable_set(:@read, true)
    result
  end

  def with_constructor(klass, object)
    original = klass.method(:new)
    klass.define_singleton_method(:new) { |*| object }
    yield
  ensure
    klass.define_singleton_method(:new, original)
  end

  def test_posts_release_message_as_utf8_text_to_both_robots
    http = FakeHTTP.new(response, response)
    message = "应用名称: Demo\n更新描述: 完成 100%\n"
    options = {
      wechat_webhook: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key",
      dingtalk_webhook: "https://oapi.dingtalk.com/robot/send?access_token=test-token"
    }

    output, errors = capture_io do
      with_constructor(Net::HTTP, http) { Appship::Webhook.new(options).notify(message) }
    end

    assert_equal 2, http.requests.length
    http.requests.each do |request|
      assert_equal "POST", request.method
      assert_equal "application/json; charset=utf-8", request["Content-Type"]
      assert_equal({ "msgtype" => "text", "text" => { "content" => message } }, JSON.parse(request.body))
    end
    assert http.use_ssl
    assert_equal 0, http.max_retries
    assert_includes output, "企业微信发布通知已发送"
    assert_includes output, "钉钉发布通知已发送"
    assert_empty errors
    refute_includes output, "test-key"
    refute_includes output, "test-token"
  end

  def test_unset_webhooks_do_not_make_requests
    http = FakeHTTP.new
    output, errors = capture_io do
      with_constructor(Net::HTTP, http) do
        Appship::Webhook.new(wechat_webhook: "", dingtalk_webhook: nil).notify("message")
      end
    end

    assert_empty output
    assert_empty errors
    assert_empty http.requests
  end

  def test_failure_notification_contains_context_but_hides_credentials
    url = "https://example.test/send?key=webhook-token"
    http = FakeHTTP.new(response)
    webhook = Appship::Webhook.new(
      app_name: "Demo", provider: "fir", configuration: "Release",
      api_key: "api-secret", password: 123456, fir_api_token: "fir-secret",
      wechat_webhook: url
    )
    error = Appship::UploadError.new("failed api-secret 123456 fir-secret #{url} https://upload.test/path?signature=upload-secret")
    output, errors = capture_io do
      with_constructor(Net::HTTP, http) { webhook.failure(error) }
    end

    content = JSON.parse(http.requests.first.body).dig("text", "content")
    assert_includes content, "发布流程失败"
    assert_includes content, "应用名称: Demo"
    assert_includes content, "分发平台: fir.im"
    assert_includes content, "构建配置: Release"
    %w[api-secret 123456 fir-secret webhook-token upload-secret].each { |secret| refute_includes content, secret }
    assert_includes output, "企业微信失败通知已发送"
    assert_empty errors
  end

  def test_failure_notification_error_does_not_claim_the_app_was_published
    http = FakeHTTP.new(SocketError.new("network failed"))
    output, errors = capture_io do
      with_constructor(Net::HTTP, http) do
        Appship::Webhook.new(wechat_webhook: "https://example.test/send").failure(Appship::CommandError.new("archive failed"))
      end
    end

    assert_equal 1, http.requests.length
    assert_empty output
    assert_includes errors, "失败通知失败"
    refute_includes errors, "应用已发布"
  end

  def test_failed_robot_does_not_prevent_other_robot_from_receiving_message
    http = FakeHTTP.new(response('{"errcode":310000,"errmsg":"keyword missing"}'), response)
    output, errors = capture_io do
      with_constructor(Net::HTTP, http) do
        Appship::Webhook.new(
          wechat_webhook: "https://example.test/wechat?key=secret",
          dingtalk_webhook: "https://example.test/dingtalk?access_token=secret"
        ).notify("发布消息")
      end
    end

    assert_equal 2, http.requests.length
    assert_includes errors, "310000"
    assert_includes errors, "应用已发布"
    refute_includes errors, "secret"
    assert_includes output, "钉钉发布通知已发送"
  end

  def test_http_parse_and_network_failures_are_warnings
    [
      response("secret-body", status: "403"),
      response("not-json"),
      response("{}"),
      Net::ReadTimeout.new
    ].each do |failure|
      http = FakeHTTP.new(failure)
      output, errors = capture_io do
        with_constructor(Net::HTTP, http) do
          Appship::Webhook.new(wechat_webhook: "https://example.test/send?key=secret-token").notify("message")
        end
      end

      assert_empty output
      assert_includes errors, "通知失败"
      refute_includes errors, "secret"
    end
  end

  def test_successful_uploads_send_the_exact_rendered_message
    FileUtils.mkdir_p(File.dirname(Appship::Message.path))
    File.write(Appship::Message.path, YAML.dump("cli_content" => "发布成功\n应用: %{name}\n下载: %{url}\n"))
    file = File.join(@webhook_home, "Demo.ipa")
    File.write(file, "ipa-data")
    results = [
      { "data" => { "buildName" => "Demo", "buildKey" => "demo" } },
      { "provider" => "fir", "data" => { "name" => "Demo" }, "url" => "https://fir.im/demo" }
    ]

    results.each do |result|
      [:direct, :after_build].each do |flow|
        options = { file: file, upload: true, wechat_webhook: "https://example.test/send" }
        http = FakeHTTP.new(response)
        output, errors = capture_io do
          with_constructor(Net::HTTP, http) do
            with_constructor(Appship::Uploader, FakeUploader.new(result)) do
              builder = Appship::Builder.new
              if flow == :direct
                assert_equal result, builder.upload!(options)
              else
                builder.send(:upload_if_requested!, file, options)
              end
            end
          end
        end

        assert_equal 1, http.requests.length
        content = JSON.parse(http.requests.first.body).fetch("text").fetch("content")
        assert_equal content + "✅ 企业微信发布通知已发送\n", output
        assert_includes content, "应用: Demo"
        assert_includes content, result["provider"] == "fir" ? "https://fir.im/demo" : "https://www.pgyer.com/demo"
        assert_empty errors
      end
    end
  end

  def test_successful_upload_uses_each_channel_template_and_approved_format
    FileUtils.mkdir_p(File.dirname(Appship::Message.path))
    File.write(Appship::Message.path, <<~YAML)
      cli_content: |
        终端: %{name}
      wechat_webhook_success_content: |
        **企微: %{name}**
      wechat_webhook_content: 旧版企微文案
      wechat_webhook_failure_content: "%{password}"
      wechat_webhook_format: markdown
      dingtalk_webhook_content: |
        钉钉: %{name}
      feishu_webhook_success_content: |
        飞书: %{name}
        下载: %{url}
      feishu_webhook_format: post
    YAML
    file = File.join(@webhook_home, "Demo.ipa")
    File.write(file, "ipa-data")
    options = {
      file: file,
      wechat_webhook: "https://example.test/wechat",
      dingtalk_webhook: "https://example.test/dingtalk",
      feishu_webhook: "https://example.test/feishu",
      feishu_webhook_secret: "feishu-signing-secret"
    }
    result = { "provider" => "fir", "data" => { "name" => "Demo" }, "url" => "https://fir.im/demo" }
    http = FakeHTTP.new(response, response, response('{"code":0,"msg":"success"}'))
    output, errors = capture_io do
      with_constructor(Net::HTTP, http) do
        with_constructor(Appship::Uploader, FakeUploader.new(result)) { Appship::Builder.new.upload!(options) }
      end
    end

    wechat, dingtalk, feishu = http.requests.map { |request| JSON.parse(request.body) }
    assert_includes output, "终端: Demo\n"
    refute_includes output, "企微: Demo"
    refute_includes output, "feishu-signing-secret"
    assert_empty errors
    assert_equal({ "msgtype" => "markdown", "markdown" => { "content" => "**企微: Demo**\n" } }, wechat)
    assert_equal "钉钉: Demo\n", dingtalk.dig("text", "content")
    assert_equal "post", feishu["msg_type"]
    paragraphs = feishu.dig("content", "post", "zh_cn", "content")
    assert_equal({ "tag" => "text", "text" => "飞书: Demo" }, paragraphs.first.first)
    assert_equal({ "tag" => "a", "text" => "https://fir.im/demo", "href" => "https://fir.im/demo" }, paragraphs.last.last)
    expected_signature = OpenSSL::HMAC.digest("SHA256", "#{feishu.fetch("timestamp")}\nfeishu-signing-secret", "")
    assert_equal expected_signature, feishu.fetch("sign").unpack1("m0")
  end

  def test_custom_failure_messages_use_project_directory_and_keep_redaction
    project = File.join(@webhook_home, "project")
    path = Appship::Message.path(project)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~YAML)
      cli_content: "成功文案"
      wechat_webhook_success_content: "企微成功"
      wechat_webhook_failure_content: |
        企微失败：%{name} / %{provider} / %{configuration}
        %{error_type}：%{error_message}
      wechat_webhook_format: markdown
      dingtalk_webhook_failure_content: "%{password}"
      feishu_webhook_failure_content: "飞书失败：%{error_message}"
      feishu_webhook_format: post
    YAML
    options = {
      project_dir: project, app_name: "Demo", provider: "fir", configuration: "Release",
      wechat_webhook: "https://example.test/wechat?key=wechat-secret",
      dingtalk_webhook: "https://example.test/dingtalk",
      feishu_webhook: "https://open.feishu.cn/open-apis/bot/v2/hook/feishu-token",
      feishu_webhook_secret: "signing-secret", api_key: "api-secret"
    }
    error = Appship::CommandError.new("归档失败 api-secret feishu-token signing-secret https://upload.test/path?token=query-secret")
    http = FakeHTTP.new(response, response, response('{"code":0}'))
    _output, warnings = capture_io do
      with_constructor(Net::HTTP, http) { Appship::Webhook.new(options).failure(error) }
    end

    wechat, dingtalk, feishu = http.requests.map { |request| JSON.parse(request.body) }
    assert_equal "text", wechat["msgtype"]
    assert_equal "text", feishu["msg_type"]
    assert feishu.key?("sign")
    assert_includes wechat.dig("text", "content"), "企微失败：Demo / fir.im / Release"
    assert_includes wechat.dig("text", "content"), "Appship::CommandError"
    assert_includes dingtalk.dig("text", "content"), "Appship 发布流程失败"
    assert_includes feishu.dig("content", "text"), "飞书失败：归档失败"
    assert_includes warnings, "dingtalk_webhook_failure_content 无效"
    refute_match(/api-secret|feishu-token|signing-secret|query-secret|企微成功/, http.requests.map(&:body).join)
  end

  def test_invalid_message_yaml_does_not_prevent_builtin_failure_notification
    path = Appship::Message.path
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "cli_content: [")
    http = FakeHTTP.new(response)
    _output, warnings = capture_io do
      with_constructor(Net::HTTP, http) do
        Appship::Webhook.new(wechat_webhook: "https://example.test/send").failure(Appship::CommandError.new("上传失败"))
      end
    end

    assert_includes JSON.parse(http.requests.first.body).dig("text", "content"), "上传失败"
    assert_includes warnings, "无法读取失败消息模板"
  end

  def test_feishu_uses_text_without_signature_by_default_and_hides_secrets_on_failure
    url = "https://open.feishu.cn/open-apis/bot/v2/hook/feishu-token"
    http = FakeHTTP.new(response('{"code":0}'), response('{"code":0}'))
    capture_io do
      with_constructor(Net::HTTP, http) do
        Appship::Webhook.new(feishu_webhook: url).notify("发布成功")
        Appship::Webhook.new(feishu_webhook: url, feishu_webhook_secret: "signing-secret")
                        .failure(Appship::CommandError.new("error #{url} feishu-token signing-secret"))
      end
    end

    text, failure = http.requests.map { |request| JSON.parse(request.body) }
    assert_equal({ "msg_type" => "text", "content" => { "text" => "发布成功" } }, text)
    assert_equal "text", failure["msg_type"]
    assert failure.key?("sign")
    assert_includes failure.dig("content", "text"), "发布流程失败"
    refute_match(/feishu-token|signing-secret/, failure.dig("content", "text"))
  end

  def test_upload_failure_never_sends_success_notification
    file = File.join(@webhook_home, "Demo.ipa")
    File.write(file, "ipa-data")
    options = { file: file, upload: true, wechat_webhook: "https://example.test/send" }

    http = FakeHTTP.new
    with_constructor(Net::HTTP, http) do
      with_constructor(Appship::Uploader, FakeUploader.new(Appship::UploadError.new("upload failed"))) do
        assert_raises(Appship::UploadError) { Appship::Builder.new.upload!(options) }
        assert_raises(Appship::UploadError) { Appship::Builder.new.send(:upload_if_requested!, file, options) }
      end
    end
    assert_empty http.requests
  end
end
