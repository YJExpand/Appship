# frozen_string_literal: true

module Appship
  class Uploader
    SUPPORTED_PROVIDERS = %w[pgyer fir].freeze

    def initialize(options = {})
      provider = (options[:provider] || "pgyer").to_s.downcase
      provider = "fir" if provider == "fir.im"
      unless SUPPORTED_PROVIDERS.include?(provider)
        raise ConfigurationError, "不支持的分发平台: #{options[:provider]}（可选 pgyer 或 fir）"
      end

      @delegate = provider == "fir" ? FirUploader.new(options) : PgyerUploader.new(options)
    end

    def upload!(file)
      @delegate.upload!(file)
    end
  end

  class PgyerUploader
    PGYER_HOST = "www.pgyer.com"

    def initialize(options = {})
      @options = options
      @api_key = options[:api_key] || ENV[options[:api_key_env] || "PGYER_API_KEY"]
      raise ConfigurationError, "缺少蒲公英 API Key，请使用 --api-key 或 PGYER_API_KEY" if @api_key.to_s.empty?
    end

    def upload!(file)
      raise ConfigurationError, "IPA/APK 文件不存在: #{file}" unless File.file?(file)

      puts "☁️ 获取蒲公英上传凭证..."
      token = request_token(file)
      puts "☁️ 上传 #{File.basename(file)}（#{format_size(File.size(file))}）..."
      upload_to_cos!(file, token)
      puts "☁️ 等待蒲公英处理..."
      poll_build_info!(token.fetch(:build_key))
    end

    private

    def request_token(file)
      fields = {
        "_api_key" => @api_key,
        "buildType" => File.extname(file).delete_prefix(".").downcase,
        "buildInstallType" => (@options[:install_type] || 1).to_s
      }
      add_field(fields, "buildPassword", @options[:password] || env_value(@options[:password_env]))
      add_field(fields, "buildUpdateDescription", @options[:description])
      add_field(fields, "buildInstallDate", @options[:install_date])
      add_field(fields, "buildInstallStartDate", @options[:start_date])
      add_field(fields, "buildInstallEndDate", @options[:end_date])
      add_field(fields, "buildChannelShortcut", @options[:channel])

      response = form_post!("https://#{PGYER_HOST}/apiv2/app/getCOSToken", fields)
      data = response["data"].is_a?(Hash) ? response["data"] : response
      endpoint = deep_find(data, "endpoint")
      key = deep_find(data, "key")
      signature = deep_find(data, "signature")
      security_token = deep_find(data, "x-cos-security-token")
      unless [endpoint, key, signature, security_token].all? { |value| value && !value.to_s.empty? }
        raise UploadError, "获取蒲公英上传凭证失败: #{response}"
      end

      { endpoint: endpoint, key: key, signature: signature, security_token: security_token, build_key: key }
    end

    def upload_to_cos!(file, token)
      fields = {
        "key" => token[:key],
        "signature" => token[:signature],
        "x-cos-security-token" => token[:security_token],
        "x-cos-meta-file-name" => File.basename(file)
      }
      uri = URI.parse(token[:endpoint])
      boundary = "----AppshipUpload#{SecureRandom.hex(12)}"
      progress = UploadProgress.new(File.size(file))
      progress.start
      body = MultipartBody.new(fields, file, boundary, progress: progress.method(:update))
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request["Content-Length"] = body.length.to_s
      request.body_stream = body
      response = http(uri).request(request)
      return true if response.code.to_i == 204 || response.is_a?(Net::HTTPSuccess)

      raise UploadError, "蒲公英文件上传失败（HTTP #{response.code}）: #{response.body}"
    ensure
      progress&.finish
    end

    def poll_build_info!(build_key)
      attempts = (@options[:poll_attempts] || 60).to_i
      attempts = 1 if attempts < 1
      attempts.times do |index|
        query = URI.encode_www_form("_api_key" => @api_key, "buildKey" => build_key)
        uri = URI.parse("https://#{PGYER_HOST}/apiv2/app/buildInfo?#{query}")
        response = http(uri).request(Net::HTTP::Get.new(uri))
        json = parse_json!(response)
        return json if json["code"].to_i == 0

        sleep 1 if index < attempts - 1
      end
      raise UploadError, "文件已上传，但 #{attempts} 秒内未查询到构建结果；请稍后到蒲公英后台确认"
    end

    def form_post!(url, fields)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(fields)
      parse_json!(http(uri).request(request))
    end

    def parse_json!(response)
      json = JSON.parse(response.body)
      return json if response.is_a?(Net::HTTPSuccess) || json["code"].to_i == 0

      raise UploadError, "蒲公英 API 请求失败（HTTP #{response.code}）: #{json}"
    rescue JSON::ParserError
      raise UploadError, "蒲公英 API 返回了无法解析的响应（HTTP #{response.code}）: #{response.body}"
    end

    def http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = (@options[:open_timeout] || 30).to_i
      http.read_timeout = (@options[:read_timeout] || 600).to_i
      http
    end

    def env_value(name)
      name && ENV[name]
    end

    def add_field(hash, key, value)
      hash[key] = value.to_s unless value.nil? || value.to_s.empty?
    end

    def format_size(bytes)
      return "#{bytes}B" if bytes < 1024
      return format("%.1fKB", bytes / 1024.0) if bytes < 1024 * 1024
      return format("%.1fMB", bytes / 1024.0 / 1024.0) if bytes < 1024 * 1024 * 1024

      format("%.1fGB", bytes / 1024.0 / 1024.0 / 1024.0)
    end

    def deep_find(value, wanted_key)
      return nil unless value.is_a?(Hash) || value.is_a?(Array)
      return value[wanted_key] if value.is_a?(Hash) && value.key?(wanted_key)

      (value.is_a?(Hash) ? value.values : value).each do |child|
        found = deep_find(child, wanted_key)
        return found unless found.nil?
      end
      nil
    end
  end

  class FirUploader
    FIR_API_HOST = "api.appmeta.cn"

    def initialize(options = {})
      @options = options
      @api_token = options[:fir_api_token] || options[:api_token]
      @api_token ||= ENV[options[:fir_api_token_env] || options[:api_token_env] || "FIR_API_TOKEN"]
      @password = options[:fir_password] || options[:password]
      @password ||= ENV[options[:fir_password_env] || options[:password_env] || "FIR_PASSWORD"]
      if @api_token.to_s.empty?
        raise ConfigurationError, "缺少 fir.im API Token，请使用 --fir-api-token 或 FIR_API_TOKEN"
      end
    end

    def upload!(file)
      raise ConfigurationError, "IPA/APK 文件不存在: #{file}" unless File.file?(file)

      type = package_type(file)
      metadata = package_metadata(file)
      bundle_id = metadata[:bundle_id]
      if bundle_id.to_s.empty?
        raise ConfigurationError, "缺少应用 Bundle ID，请使用 --bundle-id 指定（fir.im 上传凭证需要该参数）"
      end

      puts "☁️ 获取 fir.im 上传凭证..."
      app = request_credentials(type, bundle_id)
      binary = app.dig("cert", "binary") || {}
      unless [binary["key"], binary["token"], binary["upload_url"]].all? { |value| !value.to_s.empty? }
        raise UploadError, "获取 fir.im 上传凭证失败: #{app}"
      end

      puts "☁️ 上传 #{File.basename(file)}（#{format_size(File.size(file))}）到 fir.im..."
      upload_binary!(file, binary, metadata, type)

      icon = @options[:icon]
      upload_icon!(icon, app.dig("cert", "icon")) if icon
      update_access_password!(app["id"], @password) unless @password.to_s.empty?

      short = app["short"]
      {
        "provider" => "fir",
        "data" => {
          "id" => app["id"],
          "short" => short,
          "name" => metadata[:app_name],
          "bundle_id" => bundle_id,
          "version" => metadata[:version],
          "build" => metadata[:build],
          "password_protected" => !@password.to_s.empty?,
          "type" => type
        },
        "url" => short.to_s.empty? ? "https://fir.im/" : "https://fir.im/#{short}"
      }
    end

    private

    def package_type(file)
      case File.extname(file).downcase
      when ".ipa" then "ios"
      when ".apk" then "android"
      else
        raise ConfigurationError, "fir.im 只支持 .ipa 或 .apk 文件: #{file}"
      end
    end

    def package_metadata(file)
      info = File.extname(file).casecmp(".ipa").zero? ? ipa_info(file) : {}
      {
        bundle_id: @options[:bundle_id] || info["CFBundleIdentifier"],
        app_name: @options[:app_name] || info["CFBundleDisplayName"] || info["CFBundleName"] || File.basename(file, File.extname(file)),
        version: @options[:app_version] || info["CFBundleShortVersionString"] || "1.0",
        build: @options[:build_number] || info["CFBundleVersion"] || "1"
      }
    end

    def ipa_info(file)
      return {} unless Runner.which("unzip") && Runner.which("plutil")

      entries, _, status = Open3.capture3("unzip", "-Z1", file)
      return {} unless status.success?

      plist_entry = entries.lines.map(&:strip).find { |entry| entry.match?(%r{\APayload/[^/]+\.app/Info\.plist\z}) }
      return {} unless plist_entry

      plist_data, _, plist_status = Open3.capture3("unzip", "-p", file, plist_entry)
      return {} unless plist_status.success?

      Tempfile.create(["appship-fir-info", ".plist"]) do |plist|
        plist.binmode
        plist.write(plist_data)
        plist.flush
        json, _, json_status = Open3.capture3("plutil", "-convert", "json", "-o", "-", plist.path)
        return JSON.parse(json) if json_status.success?
      end
      {}
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def request_credentials(type, bundle_id)
      response = post_json!("https://#{FIR_API_HOST}/apps", {
        "type" => type,
        "bundle_id" => bundle_id,
        "api_token" => @api_token
      })
      response["data"].is_a?(Hash) ? response["data"] : response
    end

    def upload_binary!(file, certificate, metadata, type)
      fields = {
        "key" => certificate["key"],
        "token" => certificate["token"],
        "x:name" => metadata[:app_name],
        "x:version" => metadata[:version],
        "x:build" => metadata[:build]
      }
      if type == "ios"
        fields["x:release_type"] = @options[:release_type] || "Adhoc"
      end
      add_field(fields, "x:changelog", @options[:description])
      multipart_upload!(certificate["upload_url"], fields, file)
    end

    def upload_icon!(icon, certificate)
      raise ConfigurationError, "fir.im 图标文件不存在: #{icon}" unless File.file?(icon)
      unless certificate.is_a?(Hash) && [certificate["key"], certificate["token"], certificate["upload_url"]].all? { |value| !value.to_s.empty? }
        raise UploadError, "获取 fir.im 图标上传凭证失败"
      end

      puts "☁️ 上传 fir.im 应用图标..."
      multipart_upload!(certificate["upload_url"], {
        "key" => certificate["key"],
        "token" => certificate["token"]
      }, icon)
    end

    def update_access_password!(app_id, password)
      if app_id.to_s.empty?
        raise UploadError, "fir.im 返回结果缺少应用 ID，无法设置访问密码"
      end

      puts "🔒 设置 fir.im 访客密码..."
      uri = URI.parse("https://#{FIR_API_HOST}/apps/#{URI.encode_www_form_component(app_id)}")
      request = Net::HTTP::Put.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form("api_token" => @api_token, "passwd" => password)
      response = http(uri).request(request)
      json = JSON.parse(response.body)
      return json if response.is_a?(Net::HTTPSuccess)

      raise UploadError, "fir.im 访问密码设置失败（HTTP #{response.code}）: #{json}"
    rescue JSON::ParserError
      raise UploadError, "fir.im 访问密码设置失败（HTTP #{response&.code}）: #{response&.body}"
    end

    def post_json!(url, payload)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      response = http(uri).request(request)
      json = JSON.parse(response.body)
      return json if response.is_a?(Net::HTTPSuccess)

      raise UploadError, "fir.im API 请求失败（HTTP #{response.code}）: #{json}"
    rescue JSON::ParserError
      raise UploadError, "fir.im API 返回了无法解析的响应（HTTP #{response&.code}）: #{response&.body}"
    end

    def multipart_upload!(url, fields, file)
      uri = URI.parse(url)
      boundary = "----AppshipFirUpload#{SecureRandom.hex(12)}"
      progress = UploadProgress.new(File.size(file))
      progress.start
      body = MultipartBody.new(fields, file, boundary, progress: progress.method(:update))
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request["Content-Length"] = body.length.to_s
      request.body_stream = body
      response = http(uri).request(request)
      return true if response.is_a?(Net::HTTPSuccess)

      raise UploadError, "fir.im 文件上传失败（HTTP #{response.code}）: #{response.body}"
    ensure
      progress&.finish
    end

    def http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = (@options[:open_timeout] || 30).to_i
      http.read_timeout = (@options[:read_timeout] || 600).to_i
      http
    end

    def add_field(hash, key, value)
      hash[key] = value.to_s unless value.nil? || value.to_s.empty?
    end

    def format_size(bytes)
      return "#{bytes}B" if bytes < 1024
      return format("%.1fKB", bytes / 1024.0) if bytes < 1024 * 1024
      return format("%.1fMB", bytes / 1024.0 / 1024.0) if bytes < 1024 * 1024 * 1024

      format("%.1fGB", bytes / 1024.0 / 1024.0 / 1024.0)
    end
  end

  class UploadProgress
    BAR_WIDTH = 24

    def initialize(total, output: $stdout)
      @total = [total.to_i, 1].max
      @output = output
      @interactive = output.tty?
      @last_percent = -1
      @started = false
    end

    def start
      @started = true
      render(0)
    end

    def update(current, total = @total)
      @total = [total.to_i, 1].max
      percent = [[(current.to_i * 100.0 / @total).floor, 0].max, 100].min
      return if percent == @last_percent

      render(percent, current.to_i)
    end

    def finish
      return unless @started

      render(100, @total)
      if @interactive
        @output.print "\r\e[2K"
        @output.puts "☁️ 上传完成（#{format_size(@total)}）"
      end
      @output.flush
    end

    private

    def render(percent, current = 0)
      @last_percent = percent
      if @interactive
        filled = (BAR_WIDTH * percent / 100.0).round
        bar = "█" * filled + "░" * (BAR_WIDTH - filled)
        @output.print "\r☁️ 上传中 [#{bar}] #{format("%3d", percent)}% (#{format_size(current)}/#{format_size(@total)})"
      elsif percent.zero? || percent == 100 || (percent % 5).zero?
        @output.puts "☁️ 上传进度: #{percent}% (#{format_size(current)}/#{format_size(@total)})"
      end
      @output.flush
    end

    def format_size(bytes)
      return "#{bytes}B" if bytes < 1024
      return format("%.1fKB", bytes / 1024.0) if bytes < 1024 * 1024
      return format("%.1fMB", bytes / 1024.0 / 1024.0) if bytes < 1024 * 1024 * 1024

      format("%.1fGB", bytes / 1024.0 / 1024.0 / 1024.0)
    end
  end

  class MultipartBody
    def initialize(fields, file, boundary, progress: nil)
      @progress = progress
      @file_size = File.size(file)
      @segments = []
      fields.each do |name, value|
        @segments << "--#{boundary}\r\n"
        @segments << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
        @segments << value.to_s
        @segments << "\r\n"
      end
      @segments << "--#{boundary}\r\n"
      @segments << "Content-Disposition: form-data; name=\"file\"; filename=\"#{File.basename(file)}\"\r\n"
      @segments << "Content-Type: application/octet-stream\r\n\r\n"
      @file = File.open(file, "rb")
      @segments << @file
      @segments << "\r\n--#{boundary}--\r\n"
      @index = 0
      @offset = 0
      @length = @segments.sum { |segment| segment.respond_to?(:read) ? segment.size : segment.bytesize }
    end

    def length
      @length
    end

    def read(length = nil, out_buffer = nil)
      requested = length || 16 * 1024
      result = out_buffer || +""
      result.clear
      while result.bytesize < requested && @index < @segments.length
        segment = @segments[@index]
        if segment.respond_to?(:read)
          chunk = segment.read(requested - result.bytesize)
          if chunk.nil? || chunk.empty?
            segment.close unless segment.closed?
            @index += 1
          else
            result << chunk
            if segment.equal?(@file)
              @progress&.call(@file.tell, @file_size)
            end
          end
        else
          remaining = segment.byteslice(@offset, requested - result.bytesize)
          if remaining.nil? || remaining.empty?
            @index += 1
            @offset = 0
          else
            result << remaining
            @offset += remaining.bytesize
            if @offset >= segment.bytesize
              @index += 1
              @offset = 0
            end
          end
        end
      end
      result.empty? ? nil : result
    end
  end
end
