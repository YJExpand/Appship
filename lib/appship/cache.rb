# frozen_string_literal: true

module Appship
  class Cache
    DEFAULT_PATH = File.expand_path("~/.appship/.config")
    DEFAULT_BUILD_DIR = File.expand_path("~/.appship/build")
    LEGACY_PATH = File.expand_path("~/.appship/.env")

    attr_reader :path, :entries

    def self.load(path = DEFAULT_PATH, project_dir: Dir.pwd, interactive: true, provider: "pgyer")
      expanded = File.expand_path(path)
      # 兼容早期版本的 ~/.appship/.env；发现旧缓存时迁移到新的 .config。
      if expanded == DEFAULT_PATH && !File.file?(expanded) && File.file?(LEGACY_PATH)
        FileUtils.mkdir_p(File.dirname(expanded))
        FileUtils.cp(LEGACY_PATH, expanded)
        File.chmod(0o600, expanded)
      end

      unless File.file?(expanded)
        create_file!(expanded)
        return collect_interactively!(expanded, project_dir: project_dir, provider: provider) if interactive && $stdin.tty?

        raise ConfigurationError, missing_credentials_message(expanded, provider, created: true)
      end

      if File.read(expanded).strip.empty?
        return collect_interactively!(expanded, project_dir: project_dir, provider: provider) if interactive && $stdin.tty?

        raise ConfigurationError, missing_credentials_message(expanded, provider, empty: true)
      end

      new(expanded)
    end

    def self.create_file!(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.chmod(0o700, File.dirname(path)) if File.directory?(File.dirname(path))
      File.write(path, "[]\n") unless File.exist?(path)
      File.chmod(0o600, path)
      path
    end

    def self.collect_interactively!(path, project_dir: Dir.pwd, provider: "pgyer", entries: [], project_name: nil, credential_overrides: {})
      project_name ||= infer_project_name!(project_dir)
      unless [".xcodeproj", ".xcworkspace"].any? { |extension| File.directory?(File.join(project_dir, "#{project_name}#{extension}")) }
        raise ConfigurationError, "当前目录找不到 #{project_name}.xcodeproj 或 #{project_name}.xcworkspace，无法新增项目配置: #{File.expand_path(project_dir)}"
      end
      provider_name = provider.to_s == "fir" ? "fir.im" : "pgyer"
      credential_key = credential_key_for(provider)
      puts ""
      puts "首次使用当前项目的 appship #{provider_name}，请填写本机项目缓存。"
      puts "缓存文件: #{path}"
      puts ""
      puts "✅ 已识别 project_name: #{project_name}"
      app_name = prompt_required("app_name")
      data = {
        "project_name" => project_name,
        "app_name" => app_name,
        credential_key => credential_overrides[credential_key] || prompt_required(credential_key)
      }
      password_key = provider.to_s == "fir" ? "fir_password" : "pgyer_password"
      data[password_key] = credential_overrides.fetch(password_key) { prompt_optional(password_key) }
      File.write(path, JSON.pretty_generate(entries + [data]) + "\n")
      File.chmod(0o600, path)
      puts ""
      puts "✅ 本机缓存已保存: #{path}"
      new(path)
    end

    def self.infer_project_name!(project_dir)
      xcodeprojects = Dir[File.join(File.expand_path(project_dir), "*.xcodeproj")]
      if xcodeprojects.empty?
        raise ConfigurationError, "当前目录找不到 .xcodeproj，无法自动设置 project_name: #{File.expand_path(project_dir)}"
      end
      if xcodeprojects.length > 1
        names = xcodeprojects.map { |path| File.basename(path, ".xcodeproj") }.join(", ")
        raise ConfigurationError, "当前目录找到多个 .xcodeproj，无法确定 project_name: #{names}"
      end

      File.basename(xcodeprojects.first, ".xcodeproj")
    end

    def self.prompt_required(name)
      print "请输入 #{name}: "
      value = $stdin.gets&.strip
      raise ConfigurationError, "#{name} 不能为空" if value.to_s.empty?

      value
    end

    def self.prompt_optional(name)
      print "请输入 #{name}（可为空，直接回车表示不设置密码）: "
      $stdin.gets.to_s.strip
    end

    def initialize(path = DEFAULT_PATH)
      @path = File.expand_path(path)
      raise ConfigurationError, "本机缓存文件不存在: #{@path}\n请使用 --env-file 指定路径" unless File.file?(@path)

      @entries = parse(File.read(@path))
      raise ConfigurationError, "缓存文件必须是字典数组: #{@path}" unless @entries.is_a?(Array)
      @entries = @entries.map { |entry| normalize(entry) }
      raise ConfigurationError, "缓存文件中没有有效项目: #{@path}" if @entries.empty?
    rescue Psych::SyntaxError => e
      raise ConfigurationError, "缓存文件解析失败: #{e.message}"
    end

    def resolve(project_name: nil, project_dir: Dir.pwd, provider: "pgyer", interactive: true, credential_overrides: {})
      candidate_names = [project_name.to_s.strip].reject(&:empty?)
      if candidate_names.empty?
        directory = File.expand_path(project_dir)
        candidate_names = Dir[File.join(directory, "*.xcodeproj"), File.join(directory, "*.xcworkspace")]
                          .select { |path| File.directory?(path) }
                          .map { |path| File.basename(path, File.extname(path)) }.uniq
        if candidate_names.empty? && @entries.length > 1
          directory_name = File.basename(directory)
          candidate_names = [directory_name] if @entries.any? { |entry| entry["project_name"] == directory_name }
        end
      end

      matches = if candidate_names.empty?
                  @entries
                else
                  @entries.select { |entry| candidate_names.include?(entry["project_name"]) }
      end
      if matches.length == 1
        update_profile!(matches.first, credential_overrides) unless credential_overrides.empty?
        ensure_provider_credential!(matches.first, provider, interactive: interactive)
        return matches.first
      end
      if matches.empty?
        if interactive && $stdin.tty?
          puts "ℹ️ 当前项目没有匹配的 project_name，将引导新增项目配置。"
          cache = self.class.collect_interactively!(
            @path,
            project_dir: project_dir,
            provider: provider,
            entries: @entries,
            project_name: candidate_names.one? ? candidate_names.first : nil,
            credential_overrides: credential_overrides
          )
          @entries = cache.entries
          return @entries.last
        end

        available = @entries.filter_map { |entry| entry["project_name"] }.join(", ")
        key = self.class.send(:credential_key_for, provider)
        raise ConfigurationError, "当前项目没有匹配的 project_name: #{candidate_names.join(", ")}\n" \
                                  "请在 #{@path} 的配置数组中增加当前项目配置，保留已有项目。\n" \
                                  "project_name 应填写: #{candidate_names.join(" 或 ")}（不含 .xcodeproj/.xcworkspace 后缀）\n" \
                                  "同时填写 app_name、#{key}；安装密码可为空。\n" \
                                  "已有项目: #{available}"
      end

      names = matches.filter_map { |entry| entry["project_name"] }.join(", ")
      raise ConfigurationError, "本机缓存包含多个项目，请使用 --project-name 指定: #{names}"
    end

    def update_profile!(entry, values)
      values.each { |key, value| entry[key.to_s] = value unless value.nil? }
      persist!
      entry
    end

    private

    def self.credential_key_for(provider)
      provider.to_s == "fir" ? "fir_api_key" : "pgyer_api_key"
    end

    def self.missing_credentials_message(path, provider, created: false, empty: false)
      prefix = if created
                 "已创建本机缓存文件: #{path}"
               elsif empty
                 "本机缓存文件为空: #{path}"
               else
                 "本机缓存文件无效: #{path}"
               end
      key = credential_key_for(provider)
      password_key = key == "pgyer_api_key" ? "pgyer_password" : "fir_password"
      suffix = "；#{password_key} 可为空"
      "#{prefix}\n请填写 project_name、app_name、#{key}#{suffix}"
    end

    def parse(content)
      JSON.parse(content)
    rescue JSON::ParserError
      YAML.safe_load(content, permitted_classes: [], aliases: false)
    end

    def normalize(entry)
      raise ConfigurationError, "缓存数组中的每一项必须是字典" unless entry.is_a?(Hash)

      entry.transform_keys(&:to_s)
    end

    def ensure_provider_credential!(entry, provider, interactive:)
      key = self.class.send(:credential_key_for, provider)
      if key == "fir_api_key" && entry[key].to_s.empty? && !entry["fir_api_token"].to_s.empty?
        entry[key] = entry["fir_api_token"]
        persist!
      end
      unless entry[key].to_s.empty?
        ensure_provider_password!(entry, provider, interactive: interactive)
        return entry
      end

      unless interactive && $stdin.tty?
        raise ConfigurationError, "缓存缺少 #{key}: #{@path}\n请填写 #{key} 后重试"
      end

      entry[key] = self.class.prompt_required(key)
      persist!
      puts "✅ 已补充 #{key}: #{@path}"
      ensure_provider_password!(entry, provider, interactive: interactive)
      entry
    end

    def ensure_provider_password!(entry, provider, interactive:)
      password_key = provider.to_s == "fir" ? "fir_password" : "pgyer_password"
      return if entry.key?(password_key)
      return unless interactive && $stdin.tty?

      entry[password_key] = self.class.prompt_optional(password_key)
      persist!
      puts "✅ 已补充 #{password_key}: #{@path}"
    end

    def persist!
      File.write(@path, JSON.pretty_generate(@entries) + "\n")
      File.chmod(0o600, @path)
    end
  end
end
