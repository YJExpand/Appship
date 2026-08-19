# frozen_string_literal: true

module Appship
  class Uploader
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
      @length = @segments.sum { |segment| segment.respond_to?(:size) ? segment.size : 0 }
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
