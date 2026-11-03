# frozen_string_literal: true

module Appship
  module Message
    VARIABLES = %w[name build_type_name version_info configuration build_size_mb build_updated description password url].freeze
    PLACEHOLDER = /%\{([^}]*)\}/
    INSTRUCTIONS = <<~TEXT.freeze
      /*
      Appship 发布消息模板

      使用方法：
      修改下方正文中的文字、顺序或换行。
      %{变量名} 会在发布时自动替换为实际数据。

      可用变量：
      name            : App 应用名称
      build_type_name : 应用类型，例如 iOS、Android
      version_info    : 版本信息，例如 1.0.0(42)
      configuration   : 构建配置，例如 Debug、Release
      build_size_mb   : 应用大小，例如 39.5MB
      build_updated   : 更新时间
      description     : 本次更新内容
      password        : 安装密码或密码设置状态
      url             : 应用下载链接

      部分字段取决于平台，未获取到数据时会省略对应行。
      建议将可选字段单独放在一行。

      ↓↓↓↓案例↓↓↓↓

      🚀 %{name} 发布成功
      版本：%{version_info}

      更新内容：
      %{description}

      下载地址：%{url}

      相关命令：
      appship message -e
        编辑当前模板。

      appship message -o <filePath>
        使用指定文件覆盖当前模板。
      */
    TEXT

    module_function

    def path
      File.expand_path("~/.appship/message.txt")
    end

    def initialize_default!
      default_path = File.expand_path("~/.appship/.default_message")
      content = File.read(File.join(__dir__, "default_message"), encoding: "UTF-8")
      if File.exist?(default_path) || File.symlink?(default_path)
        regular_file!(default_path)
        if File.read(default_path, encoding: "UTF-8") == content
          File.chmod(0o444, default_path)
          return default_path
        end
      end
      write!(default_path, content, mode: 0o444)
    rescue SystemCallError => e
      raise ConfigurationError, "默认消息模板初始化失败: #{e.message}"
    end

    def init!
      content = INSTRUCTIONS + "\n" + File.read(initialize_default!, encoding: "UTF-8")
      File.open(path, "wx", 0o600) { |file| file.write(content) }
      path
    rescue Errno::EEXIST
      regular_file!(path)
      path
    rescue SystemCallError => e
      raise ConfigurationError, "消息模板初始化失败: #{e.message}"
    end

    def overwrite!(source)
      source = File.expand_path(source)
      content = File.read(source, encoding: "UTF-8")
      parse(content, source)
      write!(path, content, mode: 0o600)
    rescue SystemCallError => e
      raise ConfigurationError, "消息模板覆盖失败: #{e.message}"
    end

    def template
      selected = File.exist?(path) || File.symlink?(path) ? path : initialize_default!
      regular_file!(selected)
      parse(File.read(selected, encoding: "UTF-8"), selected)
    rescue SystemCallError => e
      raise ConfigurationError, "消息模板读取失败: #{e.message}"
    end

    def parse(content, source)
      raise ConfigurationError, "消息模板必须使用 UTF-8 编码: #{source}" unless content.valid_encoding?

      body = content.delete_prefix("\uFEFF")
      if body.lstrip.start_with?("/*")
        comment_end = body.index("*/")
        raise ConfigurationError, "消息模板备注缺少 */: #{source}" unless comment_end

        body = body[(comment_end + 2)..].sub(/\A[ \t]*\r?\n/, "")
      end
      raise ConfigurationError, "消息模板正文不能为空: #{source}" if body.strip.empty?

      unknown = body.scan(PLACEHOLDER).flatten.uniq - VARIABLES
      unless unknown.empty?
        raise ConfigurationError, "消息模板包含未知变量 #{unknown.join(", ")}: #{source}\n可用变量: #{VARIABLES.join(", ")}"
      end
      if body.gsub(PLACEHOLDER, "").include?("%{")
        raise ConfigurationError, "消息模板变量缺少右花括号 }: #{source}"
      end
      body
    end

    def render(values)
      template.lines.filter_map do |line|
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

    def write!(destination, content, mode:)
      regular_file!(destination) if File.exist?(destination) || File.symlink?(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      Tempfile.create([".appship-message-", ".tmp"], File.dirname(destination)) do |file|
        file.write(content)
        file.flush
        file.chmod(mode)
        File.rename(file.path, destination)
      end
      destination
    end
  end
end
