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
    ENV["HOME"] = @webhook_home
  end

  def teardown
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
    File.write(Appship::Message.path, "发布成功\n应用: %{name}\n下载: %{url}\n")
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
