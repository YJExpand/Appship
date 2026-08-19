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
        api_key_env: PGYER_API_KEY
        install_type: 1
        # password_env: PGYER_INSTALL_PASSWORD
        # channel: internal
    YAML

    attr_reader :path, :data

    def initialize(path = nil)
      @path = path && File.expand_path(path)
      @data = if @path && File.file?(@path)
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
