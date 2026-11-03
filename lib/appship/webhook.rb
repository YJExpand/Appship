# frozen_string_literal: true

module Appship
  class Webhook
    PLATFORMS = { "wechat" => "企业微信", "dingtalk" => "钉钉" }.freeze

    def self.parse_url!(url)
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty? && !uri.userinfo && !uri.fragment
        raise ConfigurationError, "Webhook 必须是有效的 HTTPS 地址，不能包含用户名、密码或片段标记"
      end
      uri
    rescue URI::InvalidURIError
      raise ConfigurationError, "Webhook 必须是有效的 HTTPS 地址"
    end

    def initialize(options = {})
      @options = options
    end

    def notify(message, failure: false)
      label = failure ? "失败通知" : "发布通知"
      context = failure ? "" : "（应用已发布）"
      PLATFORMS.each do |platform, name|
        url = @options["#{platform}_webhook".to_sym].to_s.strip
        next if url.empty?

        begin
          post!(self.class.parse_url!(url), message)
          puts "✅ #{name}#{label}已发送"
        rescue Error => e
          warn "⚠️ #{name}#{label}失败#{context}: #{e.message}"
        rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError => e
          warn "⚠️ #{name}#{label}失败#{context}: 网络请求失败（#{e.class}）"
        end
      end
    end

    def failure(error)
      message = [
        "❌ Appship 发布流程失败",
        "应用名称: #{@options[:app_name] || @options[:project_name] || "未知"}",
        "分发平台: #{@options[:provider] == "fir" ? "fir.im" : "蒲公英"}",
        "构建配置: #{@options[:configuration] || "未选择"}",
        "错误类型: #{error.class}",
        "错误原因: #{error.message}"
      ].join("\n")
      secrets = @options.values_at(:api_key, :password, :fir_api_token, :fir_password, :wechat_webhook, :dingtalk_webhook)
      env_names = %w[PGYER_API_KEY PGYER_INSTALL_PASSWORD FIR_API_TOKEN FIR_PASSWORD]
      env_names += @options.values_at(:api_key_env, :password_env, :fir_api_token_env, :fir_password_env).compact
      secrets += env_names.map { |name| ENV[name] }
      secrets.compact.map(&:to_s).reject(&:empty?).sort_by { |value| -value.length }.each do |secret|
        message = message.gsub(secret, "[已隐藏]")
      end
      message = message.gsub(%r{(https?://[^\s"'<>?]+)\?[^\s"'<>]+}, '\\1?[已隐藏]')
      notify(message.byteslice(0, 1900).scrub(""), failure: true)
    end

    private

    def post!(uri, message)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json; charset=utf-8"
      request.body = JSON.generate(msgtype: "text", text: { content: message })
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15
      http.write_timeout = 15
      http.max_retries = 0
      response = http.request(request)
      raise CommandError, "机器人返回 HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      code = data.is_a?(Hash) ? data["errcode"] : nil
      raise CommandError, "机器人未返回成功状态（错误码 #{code || "缺失"}）" unless code.to_s == "0"
    rescue JSON::ParserError
      raise CommandError, "机器人返回了无法解析的响应"
    end
  end
end
