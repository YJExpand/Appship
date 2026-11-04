# frozen_string_literal: true

module Appship
  class Webhook
    PLATFORMS = { "wechat" => "企业微信", "dingtalk" => "钉钉", "feishu" => "飞书" }.freeze
    URL_FIELDS = PLATFORMS.keys.map { |platform| :"#{platform}_webhook" }.freeze
    OPTION_FIELDS = (URL_FIELDS + [:feishu_webhook_secret]).freeze

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

    def notify(message, failure: false, formats: {})
      label = failure ? "失败通知" : "发布通知"
      context = failure ? "" : "（应用已发布）"
      PLATFORMS.each do |platform, name|
        url = @options["#{platform}_webhook".to_sym].to_s.strip
        next if url.empty?

        content = content_for(message, platform, failure)
        next if content.to_s.strip.empty?

        begin
          format = failure ? nil : formats["#{platform}_webhook_format"]
          post!(self.class.parse_url!(url), platform, content, format)
          puts "✅ #{name}#{label}已发送"
        rescue Error => e
          warn "⚠️ #{name}#{label}失败#{context}: #{e.message}"
        rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError => e
          warn "⚠️ #{name}#{label}失败#{context}: 网络请求失败（#{e.class}）"
        end
      end
    end

    def failure(error)
      return unless @options.values_at(*URL_FIELDS).any? { |url| !url.to_s.strip.empty? }

      values = {
        name: @options[:app_name] || @options[:project_name] || "未知",
        provider: @options[:provider] == "fir" ? "fir.im" : "蒲公英",
        configuration: @options[:configuration] || "未选择",
        error_type: error.class.to_s,
        error_message: error.message
      }
      message = [
        "❌ Appship 发布流程失败",
        "应用名称: #{values[:name]}",
        "分发平台: #{values[:provider]}",
        "构建配置: #{values[:configuration]}",
        "错误类型: #{values[:error_type]}",
        "错误原因: #{values[:error_message]}"
      ].join("\n")
      templates = Message.failure_templates(project_dir: @options[:project_dir] || Dir.pwd)
      if templates.empty?
        notify(safe_failure_content(message), failure: true)
      else
        messages = templates.transform_values { |body| Message.render_text(body, values) }
        messages["default"] = message
        notify(messages.transform_values { |body| safe_failure_content(body) }, failure: true)
      end
    end

    private

    def content_for(message, platform, failure)
      return message unless message.is_a?(Hash)
      return message.fetch("#{platform}_webhook_failure_content", message["default"]) if failure

      message.fetch("#{platform}_webhook_success_content") do
        message.fetch("#{platform}_webhook_content", message["cli_content"])
      end
    end

    def safe_failure_content(message)
      secrets = @options.values_at(:api_key, :password, :fir_api_token, :fir_password, *OPTION_FIELDS)
      secrets << @options[:feishu_webhook].to_s[%r{/open-apis/bot/v2/hook/([^/?#]+)}, 1]
      env_names = %w[PGYER_API_KEY PGYER_INSTALL_PASSWORD FIR_API_TOKEN FIR_PASSWORD]
      env_names += @options.values_at(:api_key_env, :password_env, :fir_api_token_env, :fir_password_env).compact
      secrets += env_names.map { |name| ENV[name] }
      secrets.compact.map(&:to_s).reject(&:empty?).sort_by { |value| -value.length }.each do |secret|
        message = message.gsub(secret, "[已隐藏]")
      end
      message = message.gsub(%r{(https?://[^\s"'<>?]+)\?[^\s"'<>]+}, '\\1?[已隐藏]')
      message.byteslice(0, 1900).scrub("")
    end

    def post!(uri, platform, message, format)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json; charset=utf-8"
      request.body = JSON.generate(payload(platform, message, format))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15
      http.write_timeout = 15
      http.max_retries = 0
      response = http.request(request)
      raise CommandError, "机器人返回 HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      code = if data.is_a?(Hash)
               platform == "feishu" ? data.fetch("code", data["StatusCode"]) : data["errcode"]
             end
      raise CommandError, "机器人未返回成功状态（错误码 #{code || "缺失"}）" unless code.to_s == "0"
    rescue JSON::ParserError
      raise CommandError, "机器人返回了无法解析的响应"
    end

    def payload(platform, message, format)
      if platform == "feishu"
        body = if format == "post"
                 paragraphs = message.lines.filter_map do |line|
                   next if line.strip.empty?

                   line.chomp.split(%r{(https?://[^\s<>"，。]+)}).reject(&:empty?).map do |part|
                     if part.start_with?("http://", "https://")
                       { tag: "a", text: part, href: part }
                     else
                       { tag: "text", text: part }
                     end
                   end
                 end
                 { msg_type: "post", content: { post: { zh_cn: { title: "Appship 发布通知", content: paragraphs } } } }
               else
                 { msg_type: "text", content: { text: message } }
               end
        secret = @options[:feishu_webhook_secret].to_s
        unless secret.empty?
          timestamp = Time.now.to_i.to_s
          body[:timestamp] = timestamp
          body[:sign] = [OpenSSL::HMAC.digest("SHA256", "#{timestamp}\n#{secret}", "")].pack("m0")
        end
        body
      elsif platform == "wechat" && format == "markdown"
        { msgtype: "markdown", markdown: { content: message } }
      else
        { msgtype: "text", text: { content: message } }
      end
    end
  end
end
