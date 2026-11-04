# frozen_string_literal: true

module Appship
  class ProjectConfig < Cache
    def self.path(project_dir = Dir.pwd)
      File.join(File.expand_path(project_dir), "appship", "config.yml")
    end

    def self.load(global_path = DEFAULT_PATH, project_dir: Dir.pwd, interactive: true, provider: "pgyer")
      local_path = path(project_dir)
      unless File.exist?(local_path) || File.symlink?(local_path)
        return Cache.load(global_path, project_dir: project_dir, interactive: interactive, provider: provider)
      end
      unless File.file?(local_path) && !File.symlink?(local_path)
        raise ConfigurationError, "项目配置必须是普通文件: #{local_path}"
      end

      new(global_path, project_dir: project_dir)
    end

    def self.init!(project_dir: Dir.pwd)
      config_path = "#{path(project_dir)}.sample"
      if File.exist?(config_path) || File.symlink?(config_path)
        unless File.file?(config_path) && !File.symlink?(config_path)
          raise ConfigurationError, "项目配置必须是普通文件: #{config_path}"
        end
      else
        name = Cache.infer_project_name!(project_dir)
        FileUtils.mkdir_p(File.dirname(config_path), mode: 0o700)
        File.open(config_path, "wx", 0o600) do |file|
          file.write(<<~YAML)
            # 按需取消注释并填写；未配置的字段继承全局配置。
            # 密码或 Webhook 填 "" 表示关闭对应设置。

            #{YAML.dump("project_name" => name).delete_prefix("---\n").chomp}

            # app_name: app-name                # ipa 名字

            # 蒲公英 API Key（登录后查看）：https://www.pgyer.com/account/api
            # pgyer_api_key: "your-pgyer-api-key"
            # pgyer_password: "your-pgyer-password"

            # fir.im API Token（登录后查看）：https://www.betaqr.com.cn/apps/apitoken
            # fir_api_key: "your-fir-api-key"
            # fir_password: "your-fir-password"

            # 机器人配置
            # wechat_webhook: ""                # 企微机器人
            # dingtalk_webhook: ""              # 钉钉机器人
            # feishu_webhook: ""                # 飞书机器人
            # feishu_webhook_secret: ""         # 飞书签名密钥，仅开启签名校验时填写

            # App Icon 角标
            # app_icon_badge: true              # 是否启用角标
            # app_icon_badge_environment: true  # 显示 DEBUG / RELEASE
            # app_icon_badge_version: false     # 预留，暂不绘制版本号
          YAML
        end
      end
      [config_path, Message.init!(project_dir: project_dir)]
    end

    def initialize(global_path, project_dir: Dir.pwd)
      @path = self.class.path(project_dir)
      @global_path = File.expand_path(global_path)
      @project_dir = File.expand_path(project_dir)
      @project_data = Config.new(@path).data
      @entries = []
    end

    def resolve(project_name: nil, project_dir: @project_dir, provider: "pgyer", interactive: true, credential_overrides: {}, credentials: true)
      name = project_name.to_s.strip
      name = @project_data["project_name"].to_s.strip if name.empty?
      name = Cache.infer_project_name!(project_dir) if name.empty?
      global_entries = if File.file?(@global_path) && !File.read(@global_path).strip.empty?
                         Cache.new(@global_path).entries
                       else
                         []
                       end
      matches = global_entries.select { |entry| entry["project_name"] == name }
      raise ConfigurationError, "全局配置中 project_name 重复: #{name}" if matches.length > 1

      entry = (matches.first || {}).merge(@project_data).merge("project_name" => name)
      @entries = [entry]
      @baseline = entry.dup
      if credentials && entry["app_name"].to_s.empty?
        unless interactive && $stdin.tty?
          raise ConfigurationError, "项目配置缺少 app_name: #{@path}"
        end
        update_profile!(entry, "app_name" => Cache.prompt_required("app_name"))
      end
      super(project_name: name, project_dir: project_dir, provider: provider, interactive: interactive,
            credential_overrides: credential_overrides, credentials: credentials)
    end

    def update_profile!(entry, values)
      values = values.transform_keys(&:to_s).reject { |_key, value| value.nil? }
      @project_data.merge!(values)
      entry.merge!(values)
      persist!
      entry
    end

    private

    def persist!
      entry = @entries.first
      @project_data.merge!(entry.reject { |key, value| @baseline.key?(key) && @baseline[key] == value })
      @project_data["project_name"] ||= entry["project_name"]
      File.write(@path, YAML.dump(@project_data))
      File.chmod(0o600, @path)
      @baseline = entry.dup
    end
  end
end
