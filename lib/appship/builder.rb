# frozen_string_literal: true

module Appship
  class Builder
    attr_reader :runner

    def initialize(runner: Runner.new)
      @runner = runner
    end

    def build!(options)
      target = target_options(options)
      scheme = required!(options[:scheme], "--scheme 或配置 scheme")
      configuration = options[:configuration] || "Debug"
      sdk = options[:sdk] || "iphoneos"
      output = File.expand_path(options[:output] || File.join("build", "#{scheme}-#{configuration}.ipa"))
      temp_root = nil
      managed_paths = []

      if options[:archive_path]
        archive_path = File.expand_path(options[:archive_path])
      else
        temp_root = Dir.mktmpdir("appship-")
        archive_path = File.join(temp_root, "#{scheme}.xcarchive")
        managed_paths << archive_path
      end

      if options[:export_path]
        export_path = File.expand_path(options[:export_path])
      else
        temp_root ||= Dir.mktmpdir("appship-")
        export_path = File.join(temp_root, "export")
        managed_paths << export_path
      end

      begin
        runner.require_command!("xcodebuild", "需要安装 Xcode 命令行工具")
        FileUtils.rm_rf(archive_path) if File.exist?(archive_path) && options.fetch(:clean, true)
        FileUtils.rm_rf(export_path) if File.exist?(export_path) && options.fetch(:clean, true)
        FileUtils.mkdir_p(File.dirname(archive_path))
        FileUtils.mkdir_p(export_path)

        archive!(target, scheme, configuration, sdk, archive_path, options)
        export!(archive_path, export_path, options)

        ipa = Dir[File.join(export_path, "*.ipa")].first
        raise CommandError, "导出完成但未找到 IPA: #{export_path}" unless ipa

        final_ipa = File.expand_path(ipa)
        if options[:badge]
          Ipa.apply_badge!(final_ipa, assets: options[:assets], app_icon: options[:app_icon], text: options[:badge], runner: runner)
        end

        FileUtils.mkdir_p(File.dirname(output))
        unless File.expand_path(output) == final_ipa
          FileUtils.rm_f(output) if File.exist?(output)
          FileUtils.mv(final_ipa, output)
        end
        puts "✅ IPA 已生成: #{output}"

        upload_if_requested!(output, options)
        output
      ensure
        FileUtils.rm_rf(temp_root) if temp_root && !options[:keep_temporary]
      end
    end

    def find_cached_app!(options)
      target = target_options(options)
      scheme = required!(options[:scheme], "--scheme 或缓存中的 project_name")
      sdk = options[:sdk] || "iphoneos"
      app_name = required!(options[:app_name], "缓存中的 app_name 或 --app-name")

      runner.require_command!("xcodebuild", "需要安装 Xcode 命令行工具")
      target_flag = target.keys.first == :workspace ? "-workspace" : "-project"
      configurations = [options[:configuration], "Debug", "Release"].compact.uniq
      configurations.each do |configuration|
        begin
          settings = runner.capture!(["xcodebuild", target_flag, target.values.first, "-scheme", scheme,
                                      "-configuration", configuration, "-sdk", sdk, "-showBuildSettings"])
        rescue CommandError
          next
        end
        products_dir = settings.lines.filter_map do |line|
          next unless line.include?("BUILT_PRODUCTS_DIR") && line.include?("=")

          line.split("=", 2).last.strip
        end.first
        next if products_dir.to_s.empty?

        app_path = File.join(products_dir, "#{app_name}.app")
        next unless File.directory?(app_path)

        options[:configuration] = configuration
        return app_path
      end

      raise CommandError, "未找到缓存 App（已检查配置: #{configurations.join(", ")}）"
    end

    def package!(options)
      app = File.expand_path(required!(options[:app], "--app"))
      raise ConfigurationError, ".app 不存在: #{app}" unless File.directory?(app)

      output = File.expand_path(options[:output] || File.join(Dir.pwd, "#{File.basename(app, ".app")}.ipa"))
      runner.require_command!("zip", "macOS 通常自带 zip")
      runner.require_command!("unzip", "macOS 通常自带 unzip") if options[:badge]
      Ipa.package!(app, output: output, badge: options[:badge], assets: options[:assets], app_icon: options[:app_icon], runner: runner)
      puts "✅ IPA 已生成: #{output}"
      upload_if_requested!(output, options)
      output
    end

    def upload!(options)
      file = File.expand_path(required!(options[:file], "IPA 文件路径"))
      raise ConfigurationError, "文件不存在: #{file}" unless File.file?(file)

      result = Uploader.new(options).upload!(file)
      Display.upload_result(result, file: file, options: options)
      result
    end

    private

    def target_options(options)
      workspace = options[:workspace]
      project = options[:project]
      if workspace && project
        raise ConfigurationError, "--workspace 和 --project 不能同时指定"
      end
      if workspace.nil? && project.nil?
        raise ConfigurationError, "请指定 --workspace 或 --project"
      end

      key = workspace ? :workspace : :project
      path = File.expand_path(options[key])
      raise ConfigurationError, "工程文件不存在: #{path}" unless File.exist?(path)
      { key => path }
    end

    def archive!(target, scheme, configuration, sdk, archive_path, options)
      argv = ["xcodebuild", "archive", target.keys.first == :workspace ? "-workspace" : "-project", target.values.first,
              "-scheme", scheme, "-configuration", configuration, "-sdk", sdk,
              "-destination", "generic/platform=iOS", "-archivePath", archive_path]
      argv += ["-allowProvisioningUpdates"] if options.fetch(:allow_provisioning_updates, true)
      argv += ["-skipPackagePluginValidation"] if options.fetch(:skip_package_plugin_validation, true)
      argv += ["-skipMacroValidation"] if options.fetch(:skip_macro_validation, true)
      argv << "BUILD_ACTIVE_RESOURCES_ONLY=NO"
      puts "🔨 开始归档 #{scheme} (#{configuration})..."
      runner.run!(argv)
    end

    def export!(archive_path, export_path, options)
      plist_path = options[:export_options_plist]
      temporary_plist = nil
      unless plist_path
        temporary_plist = Tempfile.new(["appship-export-options", ".plist"])
        temporary_plist.write(export_options_plist(options))
        temporary_plist.close
        plist_path = temporary_plist.path
      end

      argv = ["xcodebuild", "-exportArchive", "-archivePath", archive_path, "-exportPath", export_path,
              "-exportOptionsPlist", File.expand_path(plist_path)]
      argv << "-allowProvisioningUpdates" if options.fetch(:allow_provisioning_updates, true)
      puts "📦 导出 IPA..."
      runner.run!(argv)
    ensure
      temporary_plist&.unlink
    end

    def export_options_plist(options)
      method = options[:export_method] || "development"
      team_id = options[:team_id]
      team_xml = team_id ? "\n\t<key>teamID</key>\n\t<string>#{xml_escape(team_id)}</string>" : ""
      <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>method</key>
        \t<string>#{xml_escape(method)}</string>
        \t<key>signingStyle</key>
        \t<string>#{options[:signing_style] || "automatic"}</string>
        \t<key>compileBitcode</key>
        \t<false/>
        \t<key>thinning</key>
        \t<string>&lt;none&gt;</string>#{team_xml}
        </dict>
        </plist>
      PLIST
    end

    def upload_if_requested!(file, options)
      return unless options[:upload]

      result = Uploader.new(options).upload!(file)
      Display.upload_result(result, file: file, options: options)
    end

    def required!(value, name)
      return value unless value.nil? || value.to_s.empty?

      raise ConfigurationError, "缺少参数: #{name}"
    end

    def xml_escape(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&apos;")
    end
  end

  module Display
    module_function

    def upload_result(result, file:, options: {})
      if result.is_a?(Hash) && result["provider"] == "fir"
        fir_upload_result(result, file: file, options: options)
        return
      end

      data = result.is_a?(Hash) ? (result["data"] || result) : {}
      key = deep_find(data, "buildKey")
      name = deep_find(data, "buildName") || options[:app_name] || File.basename(file, File.extname(file))
      build_type = deep_find(data, "buildType") || File.extname(file).delete_prefix(".").downcase
      build_type_name = %w[2 apk android].include?(build_type.to_s.downcase) ? "Android" : "iOS"
      version = deep_find(data, "buildVersion")
      build_version = deep_find(data, "buildBuildVersion")
      version_info = if version && !version.to_s.empty?
                       build_version && !build_version.to_s.empty? ? "#{version}(#{build_version})" : version.to_s
                     end
      build_file_size = deep_find(data, "buildFileSize")
      build_size_mb = if build_file_size && !build_file_size.to_s.empty?
                        format("%.1fMB", build_file_size.to_f / 1_048_576)
                      end
      build_updated = deep_find(data, "buildUpdated")
      configuration = options[:configuration] || "未知"
      description = options[:interactive_content] || options[:description] || ""
      password = options[:password]
      password ||= ENV[options[:password_env]] if options[:password_env]
      password ||= "未设置"
      url = key ? "https://www.pgyer.com/#{key}" : "https://www.pgyer.com/"

      puts ""
      puts "======================================================="
      puts "                   🎉 发布完成 🎉                      "
      puts "======================================================="
      puts "应用名称: #{name}"
      puts "应用类型: #{build_type_name}"
      puts "版本信息: #{version_info}" if version_info
      puts "构建模式: #{configuration}"
      puts "应用大小: #{build_size_mb}" if build_size_mb
      puts "更新时间: #{build_updated}" if build_updated && !build_updated.to_s.empty?
      puts "更新描述: #{description}"
      puts "安装密码: #{password}"
      puts "下载链接: #{url}"
      puts "======================================================="
    end

    def fir_upload_result(result, file:, options: {})
      data = result["data"].is_a?(Hash) ? result["data"] : result
      name = data["name"] || options[:app_name] || File.basename(file, File.extname(file))
      type = data["type"].to_s == "android" ? "Android" : "iOS"
      version = data["version"]
      build = data["build"]
      version_info = if version && !version.to_s.empty?
                       build && !build.to_s.empty? ? "#{version}(#{build})" : version.to_s
                     end

      puts ""
      puts "======================================================="
      puts "                   🎉 发布完成 🎉                      "
      puts "======================================================="
      puts "分发平台: fir.im"
      puts "应用名称: #{name}"
      puts "应用类型: #{type}"
      puts "版本信息: #{version_info}" if version_info
      puts "更新描述: #{options[:description] || ""}"
      puts "下载链接: #{result["url"]}"
      puts "======================================================="
    end

    def deep_find(value, wanted_key)
      return nil unless value.is_a?(Hash) || value.is_a?(Array)
      return value[wanted_key] if value.is_a?(Hash) && value.key?(wanted_key)

      enum = value.is_a?(Hash) ? value.values : value
      enum.each do |child|
        found = deep_find(child, wanted_key)
        return found unless found.nil?
      end
      nil
    end
  end
end
