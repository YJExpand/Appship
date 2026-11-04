# frozen_string_literal: true

module Appship
  module Message
    VARIABLES = %w[name build_type_name version_info configuration build_size_mb build_updated description password url].freeze
    PLACEHOLDER = /%\{([^}]*)\}/
    CONTENT_FIELDS = %w[
      cli_content
      wechat_webhook_success_content dingtalk_webhook_success_content feishu_webhook_success_content
      wechat_webhook_content dingtalk_webhook_content feishu_webhook_content
    ].freeze
    FAILURE_FIELDS = %w[wechat_webhook_failure_content dingtalk_webhook_failure_content feishu_webhook_failure_content].freeze
    FAILURE_VARIABLES = %w[name provider configuration error_type error_message].freeze
    FORMATS = {
      "wechat_webhook_format" => %w[text markdown].freeze,
      "feishu_webhook_format" => %w[text post].freeze
    }.freeze
    INSTRUCTIONS = <<~TEXT.freeze
      # Appship 发布消息模板
      # 复制为 appship/message.yml 后编辑。用 | 开始多行文本，正文缩进两个空格。
      # 成功文案留空则沿用 cli_content；失败文案留空则使用内置失败文案。
      # 失败文案可用变量：name、provider、configuration、error_type、error_message。
      # %{变量名} 会替换为实际数据。缺少可选数据时，会省略对应行。
      #
      # 可用变量：
      # name            : 应用名称
      # build_type_name : 应用类型，例如 iOS、Android
      # version_info    : 版本信息，例如 1.0.0(42)
      # configuration   : 构建配置，例如 Debug、Release
      # build_size_mb   : 应用大小，例如 39.5MB
      # build_updated   : 更新时间
      # description     : 本次更新内容
      # password        : 安装密码或密码设置状态
      # url             : 应用下载链接
    TEXT

    module_function

    def path(project_dir = Dir.pwd)
      File.join(File.expand_path(project_dir), "appship", "message.yml")
    end

    def default_path
      File.join(__dir__, "default_message")
    end

    def init!(project_dir: Dir.pwd)
      content = INSTRUCTIONS + <<~YAML

        # 自定义终端文案时，去掉下面整段每行前的 "# "，保留正文缩进。
        # cli_content: |
        #   🚀 %{name} 发布成功
        #   版本：%{version_info}
        #   更新内容：%{description}
        #   下载地址：%{url}

        # wechat_webhook_success_content: ""    # 企微成功文案
        # wechat_webhook_failure_content: ""    # 企微失败文案

        # dingtalk_webhook_success_content: ""  # 钉钉成功文案
        # dingtalk_webhook_failure_content: ""  # 钉钉失败文案

        # feishu_webhook_success_content: ""    # 飞书成功文案
        # feishu_webhook_failure_content: ""    # 飞书失败文案

        # 默认发送纯文本；成功通知可按平台切换消息格式。
        # wechat_webhook_format: markdown  # 企微：text 或 markdown
        # feishu_webhook_format: post      # 飞书：text 或 post（富文本）
      YAML
      selected = "#{path(project_dir)}.sample"
      FileUtils.mkdir_p(File.dirname(selected), mode: 0o700)
      File.open(selected, "wx", 0o600) { |file| file.write(content) }
      selected
    rescue Errno::EEXIST
      regular_file!(selected)
      selected
    rescue SystemCallError => e
      raise ConfigurationError, "消息模板初始化失败: #{e.message}"
    end

    def template
      templates.fetch("cli_content")
    end

    def templates
      selected = path
      unless File.exist?(selected) || File.symlink?(selected)
        legacy = File.join(File.dirname(selected), "message")
        selected = File.exist?(legacy) || File.symlink?(legacy) ? legacy : default_path
        regular_file!(selected)
        return { "cli_content" => parse(File.read(selected, encoding: "UTF-8"), selected, legacy: true) }
      end

      data = load_yaml(selected)
      unless (data.keys - CONTENT_FIELDS - FAILURE_FIELDS - FORMATS.keys).empty?
        raise ConfigurationError, "消息模板包含未知字段: #{selected}"
      end

      data = data.slice(*CONTENT_FIELDS, *FORMATS.keys).reject do |key, value|
        next true if value.nil?
        raise ConfigurationError, "消息模板 #{key} 必须是字符串: #{selected}" unless value.is_a?(String)

        value.strip.empty?
      end
      FORMATS.each do |key, formats|
        next unless data.key?(key) && !formats.include?(data[key])

        raise ConfigurationError, "#{key} 仅支持 #{formats.join(" 或 ")}: #{selected}"
      end
      data["cli_content"] ||= File.read(default_path, encoding: "UTF-8")
      CONTENT_FIELDS.each do |key|
        parse(data[key], "#{selected} (#{key})") if data.key?(key)
      end
      data
    rescue SystemCallError => e
      raise ConfigurationError, "消息模板读取失败: #{e.message}"
    end

    def failure_templates(project_dir: Dir.pwd)
      selected = path(project_dir)
      return {} unless File.exist?(selected) || File.symlink?(selected)

      load_yaml(selected).slice(*FAILURE_FIELDS).each_with_object({}) do |(key, body), templates|
        next if body.nil? || (body.is_a?(String) && body.strip.empty?)
        raise ConfigurationError unless body.is_a?(String)

        templates[key] = parse(body, selected, variables: FAILURE_VARIABLES)
      rescue ConfigurationError
        warn "⚠️ #{key} 无效，使用内置失败文案"
      end
    rescue ConfigurationError
      warn "⚠️ 无法读取失败消息模板，使用内置失败文案"
      {}
    end

    def load_yaml(selected)
      regular_file!(selected)
      content = File.read(selected, encoding: "UTF-8")
      raise ConfigurationError, "消息模板必须使用 UTF-8 编码: #{selected}" unless content.valid_encoding?

      data = YAML.safe_load(content, permitted_classes: [], aliases: false)
      return {} if data.nil?
      raise ConfigurationError, "消息模板必须是 YAML 对象: #{selected}" unless data.is_a?(Hash)

      data
    rescue Psych::Exception
      raise ConfigurationError, "消息模板 YAML 格式无效: #{selected}"
    rescue SystemCallError => e
      raise ConfigurationError, "消息模板读取失败: #{e.message}"
    end

    def parse(content, source, legacy: false, variables: VARIABLES)
      raise ConfigurationError, "消息模板必须使用 UTF-8 编码: #{source}" unless content.valid_encoding?

      body = content.delete_prefix("\uFEFF")
      if legacy && body.lstrip.start_with?("/*")
        comment_end = body.index("*/")
        raise ConfigurationError, "消息模板备注缺少 */: #{source}" unless comment_end

        body = body[(comment_end + 2)..].sub(/\A[ \t]*\r?\n/, "")
      end
      raise ConfigurationError, "消息模板正文不能为空: #{source}" if body.strip.empty?

      unknown = body.scan(PLACEHOLDER).flatten.uniq - variables
      unless unknown.empty?
        raise ConfigurationError, "消息模板包含未知变量 #{unknown.join(", ")}: #{source}\n可用变量: #{variables.join(", ")}"
      end
      if body.gsub(PLACEHOLDER, "").include?("%{")
        raise ConfigurationError, "消息模板变量缺少右花括号 }: #{source}"
      end
      body
    end

    def render(values)
      render_text(template, values)
    end

    def render_text(body, values)
      body.lines.filter_map do |line|
        keys = line.scan(PLACEHOLDER).flatten
        next if keys.any? { |key| values.fetch(key.to_sym).nil? }

        line.gsub(PLACEHOLDER) { values.fetch(Regexp.last_match(1).to_sym).to_s }
      end.join
    end

    def regular_file!(file)
      unless File.file?(file) && !File.symlink?(file)
        raise ConfigurationError, "消息模板必须是普通文件: #{file}"
      end
    end
  end
end
