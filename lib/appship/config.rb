# frozen_string_literal: true

module Appship
  class Config
    TEMPLATE = <<~YAML
      # appship configuration. Secrets should be supplied through environment variables.
      # Run `appship doctor` to validate the local toolchain.
      workspace: MyApp.xcworkspace
      # project: MyApp.xcodeproj
      scheme: MyApp
      configuration: Debug
      sdk: iphoneos
      output: build/MyApp-Debug.ipa

      # Optional icon badge. Remove or set to null to disable it.
      # badge: DEBUG
      # assets: MyApp/Assets.xcassets
      # app_icon: AppIcon

      upload:
        provider: pgyer
        api_key_env: PGYER_API_KEY
        # fir_api_token_env: FIR_API_TOKEN
        # fir_password_env: FIR_PASSWORD
        install_type: 1
        # password_env: PGYER_INSTALL_PASSWORD
        # channel: internal
    YAML

    attr_reader :path, :data

    def initialize(path = nil, data: nil)
      @path = path && File.expand_path(path)
      @data = if data
                data
              elsif @path && File.file?(@path)
                YAML.safe_load(File.read(@path), permitted_classes: [], aliases: false) || {}
              else
                {}
              end
      raise ConfigurationError, "配置文件必须是 YAML 对象: #{@path}" unless @data.is_a?(Hash)
    rescue Psych::SyntaxError => e
      raise ConfigurationError, "配置文件解析失败: #{e.message}"
    end

    def get(*keys, default: nil)
      value = keys.reduce(@data) do |current, key|
        current.is_a?(Hash) ? current[key.to_s] : nil
      end
      value.nil? ? default : value
    end

    def self.find(path = nil)
      return new(path) if path

      local_path = ProjectConfig.path
      if File.exist?(local_path) || File.symlink?(local_path)
        profile = ProjectConfig.load(ENV.fetch("APPSHIP_ENV_FILE", Cache::DEFAULT_PATH), interactive: false)
                               .resolve(interactive: false, credentials: false)
        profile["scheme"] ||= profile["project_name"]
        unless profile["workspace"] || profile["project"]
          workspace = "#{profile["project_name"]}.xcworkspace"
          project = "#{profile["project_name"]}.xcodeproj"
          profile["workspace"] = workspace if File.directory?(workspace)
          profile["project"] = project if !profile["workspace"] && File.directory?(project)
        end
        return new(local_path, data: profile)
      end

      candidates = [
        File.join(Dir.pwd, ".appship.yml"),
        File.join(Dir.pwd, ".appship.yaml"),
        # Backward compatibility with the first provider-specific prototype.
        File.join(Dir.pwd, ".pgyer.yml"),
        File.join(Dir.pwd, ".pgyer.yaml")
      ]
      new(candidates.find { |candidate| File.file?(candidate) })
    end

    def self.write_template(path, force: false)
      expanded = File.expand_path(path)
      if File.exist?(expanded) && !force
        raise ConfigurationError, "文件已存在: #{expanded}（使用 --force 覆盖）"
      end

      FileUtils.mkdir_p(File.dirname(expanded))
      File.write(expanded, TEMPLATE)
      expanded
    end
  end
end
