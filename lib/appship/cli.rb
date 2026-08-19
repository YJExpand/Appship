# frozen_string_literal: true

module Appship
  class CLI
    def self.start(argv)
      new.start(argv)
    rescue Error => e
      warn "❌ #{e.message}"
      exit 1
    rescue OptionParser::ParseError => e
      warn "❌ #{e.message}"
      exit 2
    end

    def start(argv)
      args = argv.dup
      global = extract_global_options!(args)
      command = args.shift

      case command
      when "init"
        init(args)
      when "doctor"
        doctor
      when "build"
        build(args, global)
      when "package"
        package(args, global)
      when "upload"
        upload(args, global)
      when "pgyer"
        pgyer(args, global)
      when "fir"
        fir(args, global)
      when "version", "--version", "-v"
        puts "appship #{VERSION}"
      when nil, "help", "--help", "-h"
        puts help
      else
        raise ConfigurationError, "未知命令: #{command}\n\n#{help}"
      end
    end

    private

    def extract_global_options!(args)
      config_path = nil
      verbose = false
      loop do
        case args.first
        when "--verbose"
          verbose = true
          args.shift
        when "--config"
          args.shift
          config_path = args.shift || raise(OptionParser::MissingArgument, "--config")
        when ->(value) { value&.start_with?("--config=") }
          config_path = args.shift.split("=", 2).last
        else
          break
        end
      end
      { config_path: config_path, verbose: verbose }
    end

    def init(args)
      path = File.join(Dir.pwd, ".appship.yml")
      force = false
      parser = OptionParser.new do |opts|
        opts.banner = "用法: appship init [选项]"
        opts.on("--path PATH", "配置文件路径（默认 .appship.yml）") { |value| path = value }
        opts.on("--force", "覆盖已有配置文件") { force = true }
        opts.on("-h", "--help", "显示帮助") { puts opts; exit 0 }
      end
      parser.parse!(args)
      puts "✅ 已创建配置文件: #{Config.write_template(path, force: force)}"
    end

    def doctor
      checks = {
        "ruby" => "运行 CLI",
        "xcodebuild" => "归档和导出",
        "xcrun" => "actool 和代码工具",
        "codesign" => "重签名角标后的 App",
        "security" => "读取代码签名身份",
        "zip" => "生成 IPA",
        "unzip" => "修改已有 IPA",
        "magick/convert" => "生成图标角标"
      }
      puts "appship doctor"
      checks.each do |command, purpose|
        available = if command == "magick/convert"
                      Runner.which("magick") || Runner.which("convert")
                    else
                      Runner.which(command)
                    end
        puts "#{available ? "✅" : "⚠️"} #{command.ljust(16)} #{available || "未安装"} - #{purpose}"
      end
      config = Config.find
      puts "#{config.path ? "✅" : "ℹ️"} 配置文件       #{config.path || "当前目录没有 .appship.yml"}"
    end

    def build(args, global)
      config = Config.find(global[:config_path])
      options = build_options(config)
      parser = build_parser(options)
      parser.parse!(args)
      Builder.new(runner: Runner.new(verbose: global[:verbose])).build!(options)
    end

    def package(args, global)
      config = Config.find(global[:config_path])
      options = upload_options(config).merge(
        app: nil,
        output: nil,
        badge: config.get("badge"),
        assets: config.get("assets"),
        app_icon: config.get("app_icon", default: "AppIcon")
      )
      parser = package_parser(options)
      parser.parse!(args)
      Builder.new(runner: Runner.new(verbose: global[:verbose])).package!(options)
    end

    def upload(args, global)
      config = Config.find(global[:config_path])
      options = upload_options(config).merge(file: nil)
      parser = upload_parser(options)
      parser.parse!(args)
      options[:file] ||= args.shift
      raise ConfigurationError, "请指定 IPA/APK 文件路径" unless options[:file]
      raise ConfigurationError, "upload 不接受多余参数: #{args.join(" ")}" unless args.empty?

      Builder.new(runner: Runner.new(verbose: global[:verbose])).upload!(options)
    end

    def pgyer(args, global)
      options = {
        project_dir: Dir.pwd,
        env_file: ENV.fetch("APPSHIP_ENV_FILE", Cache::DEFAULT_PATH),
        project_name: nil,
        app_name: nil,
        workspace: nil,
        project: nil,
        scheme: nil,
        configuration: nil,
        configuration_explicit: false,
        sdk: "iphoneos",
        output: nil,
        archive_path: nil,
        export_path: nil,
        export_options_plist: nil,
        export_method: "development",
        signing_style: "automatic",
        team_id: nil,
        build_mode: "rebuild",
        build_mode_explicit: false,
        badge: nil,
        badge_explicit: false,
        assets: nil,
        app_icon: "AppIcon",
        upload: true,
        api_key: nil,
        api_key_env: "PGYER_API_KEY",
        install_type: nil,
        password: nil,
        password_env: nil,
        description: nil,
        description_explicit: false,
        channel: nil,
        poll_attempts: 60,
        clean: true,
        keep_temporary: false,
        allow_provisioning_updates: true,
        skip_package_plugin_validation: true,
        skip_macro_validation: true
      }
      parser = pgyer_parser(options)
      parser.parse!(args)
      raise ConfigurationError, "pgyer 不接受多余参数: #{args.join(" ")}" unless args.empty?

      project_dir = File.expand_path(options[:project_dir])
      raise ConfigurationError, "项目目录不存在: #{project_dir}" unless File.directory?(project_dir)
      env_file = File.expand_path(options[:env_file], Dir.pwd)

      Dir.chdir(project_dir) do
        profile = Cache.load(env_file, project_dir: project_dir, interactive: true, provider: "pgyer").resolve(project_name: options[:project_name], project_dir: project_dir, provider: "pgyer")
        apply_cached_profile!(options, profile, provider: "pgyer")
        infer_pgyer_target!(options)
        options[:output] ||= File.join(Cache::DEFAULT_BUILD_DIR, "#{options[:app_name]}.ipa")

        runner = Runner.new(verbose: global[:verbose])
        builder = Builder.new(runner: runner)
        prepare_pgyer_flow!(options, builder)
        if options[:build_mode] == "cache"
          options[:app] ||= builder.find_cached_app!(options)
          builder.package!(options)
        else
          builder.build!(options)
        end
      end
    end

    def fir(args, global)
      options = {
        project_dir: Dir.pwd,
        env_file: ENV.fetch("APPSHIP_ENV_FILE", Cache::DEFAULT_PATH),
        project_name: nil,
        app_name: nil,
        workspace: nil,
        project: nil,
        scheme: nil,
        configuration: nil,
        configuration_explicit: false,
        sdk: "iphoneos",
        output: nil,
        archive_path: nil,
        export_path: nil,
        export_options_plist: nil,
        export_method: "adhoc",
        signing_style: "automatic",
        team_id: nil,
        build_mode: "rebuild",
        build_mode_explicit: false,
        badge: nil,
        badge_explicit: false,
        assets: nil,
        app_icon: "AppIcon",
        upload: true,
        provider: "fir",
        fir_api_token: nil,
        fir_api_token_env: "FIR_API_TOKEN",
        bundle_id: nil,
        app_version: nil,
        build_number: nil,
        release_type: "Adhoc",
        icon: nil,
        description: nil,
        description_explicit: false,
        clean: true,
        keep_temporary: false,
        allow_provisioning_updates: true,
        skip_package_plugin_validation: true,
        skip_macro_validation: true
      }
      parser = fir_parser(options)
      parser.parse!(args)
      raise ConfigurationError, "fir 不接受多余参数: #{args.join(" ")}" unless args.empty?

      project_dir = File.expand_path(options[:project_dir])
      raise ConfigurationError, "项目目录不存在: #{project_dir}" unless File.directory?(project_dir)
      env_file = File.expand_path(options[:env_file], Dir.pwd)

      Dir.chdir(project_dir) do
        profile = Cache.load(env_file, project_dir: project_dir, interactive: true, provider: "fir").resolve(project_name: options[:project_name], project_dir: project_dir, provider: "fir")
        apply_cached_profile!(options, profile, provider: "fir")
        infer_pgyer_target!(options)
        options[:output] ||= File.join(Cache::DEFAULT_BUILD_DIR, "#{options[:app_name]}.ipa")

        runner = Runner.new(verbose: global[:verbose])
        builder = Builder.new(runner: runner)
        prepare_pgyer_flow!(options, builder)
        if options[:build_mode] == "cache"
          options[:app] ||= builder.find_cached_app!(options)
          builder.package!(options)
        else
          builder.build!(options)
        end
      end
    end

    def apply_cached_profile!(options, profile, provider: "pgyer")
      options[:project_name] ||= profile["project_name"]
      options[:app_name] ||= profile["app_name"]
      if provider.to_s == "fir"
        options[:fir_api_token] ||= profile["fir_api_key"] || profile["fir_api_token"]
        options[:bundle_id] ||= profile["bundle_id"]
        options[:app_version] ||= profile["app_version"]
        options[:build_number] ||= profile["build_number"]
        options[:release_type] ||= profile["fir_release_type"] || "Adhoc"
        options[:description] ||= profile["fir_update_description"]
      else
        options[:api_key] ||= profile["pgyer_api_key"]
      end
      options[:workspace] ||= profile["workspace"]
      options[:project] ||= profile["project"]
      options[:scheme] ||= profile["scheme"] || options[:project_name]
      options[:configuration] ||= profile["configuration"] || "Debug"
      options[:assets] ||= profile["assets"]
      options[:app_icon] ||= profile["app_icon"] || "AppIcon"
      options[:badge] ||= profile["badge"]
      if provider.to_s != "fir"
        options[:password_env] ||= profile["pgyer_password_env"]
        options[:password] ||= profile["pgyer_password"]
        options[:password] ||= ENV[options[:password_env]] if options[:password_env]
        options[:password] ||= ENV["PGYER_INSTALL_PASSWORD"]
        options[:install_type] ||= profile["pgyer_install_type"] || 2
        if options[:password].to_s.empty? && options[:install_type].to_i == 2
          options[:install_type] = 1
          puts "ℹ️ pgyer_password 为空，将使用公开安装模式（不设置密码）"
        end
        options[:description] ||= profile["pgyer_update_description"]
      end

      raise ConfigurationError, "缓存缺少 project_name" if options[:project_name].to_s.empty?
      raise ConfigurationError, "缓存缺少 app_name" if options[:app_name].to_s.empty?
    end

    def infer_pgyer_target!(options)
      return if options[:workspace] || options[:project]

      workspace = "#{options[:project_name]}.xcworkspace"
      project = "#{options[:project_name]}.xcodeproj"
      if File.exist?(workspace)
        options[:workspace] = workspace
      elsif File.exist?(project)
        options[:project] = project
      else
        candidates = Dir["*.xcworkspace", "*.xcodeproj"]
        if candidates.length == 1
          options[File.extname(candidates.first) == ".xcworkspace" ? :workspace : :project] = candidates.first
        else
          raise ConfigurationError, "找不到 #{options[:project_name]}.xcworkspace 或 #{options[:project_name]}.xcodeproj"
        end
      end

      if options[:assets].to_s.empty?
        icon_set = Dir["**/AppIcon.appiconset"].reject { |path| path.include?("Pods/") || path.include?("build/") || path.include?("DerivedData/") }.first
        options[:assets] = File.dirname(icon_set) if icon_set
      end
    end

    def default_description(options)
      branch = git_value(["git", "rev-parse", "--abbrev-ref", "HEAD"], "unknown")
      user = git_value(["git", "config", "user.name"], "unknown")
      content = options[:interactive_content].to_s
      "自动编译打包 | 分支：#{branch} | 构建人：#{user} | 配置：#{options[:configuration]} | 更新内容：#{content}"
    end

    def prepare_pgyer_flow!(options, builder)
      interactive = $stdin.tty? && $stdout.tty?
      unless options[:build_mode_explicit]
        options[:build_mode] = choose_build_mode if interactive
      end

      if options[:build_mode] == "rebuild" && !options[:configuration_explicit] && interactive
        options[:configuration] = choose_configuration
      end

      if options[:build_mode] == "cache"
        options[:badge] ||= badge_text(options[:configuration]) unless options[:badge_explicit]
      elsif !options[:badge_explicit] && interactive
        options[:badge] = choose_badge ? badge_text(options[:configuration]) : nil
      end

      unless options[:description_explicit] || !interactive
        print "请输入更新内容（输入完回车）："
        options[:interactive_content] = $stdin.gets.to_s.chomp
        puts "✅ 更新内容: #{options[:interactive_content]}"
      end

      if options[:build_mode] == "cache"
        begin
          puts ""
          puts "📦 使用缓存模式"
          options[:app] ||= with_spinner("正在查找编译缓存中的 .app 文件") do
            builder.find_cached_app!(options)
          end
          puts "✅ 找到缓存 App: #{options[:app]}"
        rescue CommandError => e
          puts "⚠️ #{e.message}，将切换到重新构建模式"
          options[:build_mode] = "rebuild"
          options[:app] = nil
        end
      end

      options[:description] ||= default_description(options)
    end

    def with_spinner(message)
      return yield unless $stdout.tty?

      frames = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏]
      finished = false
      spinner = Thread.new do
        index = 0
        until finished
          print "\r#{frames[index % frames.length]} #{message}"
          $stdout.flush
          index += 1
          sleep 0.12
        end
      end

      yield
    ensure
      finished = true
      spinner&.join
      if $stdout.tty?
        print "\r\e[2K"
        $stdout.flush
      end
    end

    def choose_build_mode
      choices = [
        "使用缓存（从 DerivedData 读取已有的 .app，快速打包）",
        "重新构建（archive + export 导出已签名 IPA）"
      ]
      selected = gum_choose("请选择构建方式：", choices)
      if selected == choices[0]
        puts "✅ 已选择构建方式: 使用缓存"
        return "cache"
      end
      if selected == choices[1]
        puts "✅ 已选择构建方式: 重新构建"
        return "rebuild"
      end

      puts ""
      puts "请选择构建方式："
      puts "1) #{choices[0]}"
      puts "2) #{choices[1]}"
      print "请输入选项 [1/2，默认 2]: "
      answer = $stdin.gets.to_s.strip
      result = answer == "1" ? "cache" : "rebuild"
      puts "✅ 已选择构建方式: #{result == "cache" ? "使用缓存" : "重新构建"}"
      result
    end

    def choose_badge
      choices = [
        "添加 Badge（显示环境标记）",
        "不添加 Badge（使用原始图标）"
      ]
      selected = gum_choose("请选择是否在 App Icon 上添加 Badge：", choices)
      if selected == choices[0]
        puts "✅ 已选择 Badge: 添加 Badge"
        return true
      end
      if selected == choices[1]
        puts "✅ 已选择 Badge: 不添加 Badge"
        return false
      end

      puts ""
      puts "请选择是否在 App Icon 上添加 Badge："
      puts "1) #{choices[0]}"
      puts "2) #{choices[1]}"
      print "请输入选项 [1/2，默认 2]: "
      result = $stdin.gets.to_s.strip == "1"
      puts "✅ 已选择 Badge: #{result ? "添加 Badge" : "不添加 Badge"}"
      result
    end

    def choose_configuration
      choices = ["Debug", "Release"]
      selected = gum_choose("请选择构建配置：", choices)
      if choices.include?(selected)
        puts "✅ 已选择构建配置: #{selected}"
        return selected
      end

      puts ""
      puts "请选择构建配置："
      puts "1) Debug"
      puts "2) Release"
      print "请输入选项 [1/2，默认 1]: "
      result = $stdin.gets.to_s.strip == "2" ? "Release" : "Debug"
      puts "✅ 已选择构建配置: #{result}"
      result
    end

    def gum_choose(header, choices)
      gum = ensure_gum
      return nil unless gum

      puts ""
      output = IO.popen([gum, "choose", "--header", header, *choices], "r", &:read)
      selected = output.to_s.strip
      selected unless selected.empty?
    rescue Errno::ENOENT
      warn "⚠️ gum 不可用，将使用普通终端选择"
      nil
    end

    def ensure_gum
      existing = Runner.which("gum")
      return existing if existing

      brew = Runner.which("brew")
      unless brew
        warn "⚠️ 未找到 Homebrew，无法自动安装 gum，将使用普通终端选择"
        return nil
      end

      puts "⚙️ gum 未安装，正在通过 Homebrew 安装..."
      Runner.new.run!([brew, "install", "gum"])
      installed = Runner.which("gum")
      return installed if installed

      warn "⚠️ gum 安装命令已完成，但仍找不到 gum，将使用普通终端选择"
      nil
    rescue Error => e
      warn "⚠️ gum 安装失败：#{e.message}"
      nil
    end

    def badge_text(configuration)
      configuration.to_s.casecmp("release").zero? ? "RELEASE" : "DEBUG"
    end

    def git_value(argv, fallback)
      output, status = Open3.capture2(*argv)
      status.success? && !output.strip.empty? ? output.strip : fallback
    end

    def build_options(config)
      upload_options(config).merge(
        workspace: config.get("workspace"),
        project: config.get("project"),
        scheme: config.get("scheme"),
        configuration: config.get("configuration", default: "Debug"),
        sdk: config.get("sdk", default: "iphoneos"),
        output: config.get("output"),
        archive_path: config.get("archive_path"),
        export_path: config.get("export_path"),
        export_options_plist: config.get("export_options_plist"),
        export_method: config.get("export_method", default: "development"),
        signing_style: config.get("signing_style", default: "automatic"),
        team_id: config.get("team_id"),
        badge: config.get("badge"),
        assets: config.get("assets"),
        app_icon: config.get("app_icon", default: "AppIcon"),
        upload: false,
        clean: true,
        keep_temporary: false,
        allow_provisioning_updates: true,
        skip_package_plugin_validation: true,
        skip_macro_validation: true
      )
    end

    def upload_options(config)
      {
        provider: config.get("upload", "provider", default: "pgyer"),
        api_key: nil,
        api_key_env: config.get("upload", "api_key_env", default: "PGYER_API_KEY"),
        fir_api_token: nil,
        fir_api_token_env: config.get("upload", "fir_api_token_env", default: "FIR_API_TOKEN"),
        bundle_id: config.get("upload", "bundle_id"),
        app_name: config.get("upload", "app_name"),
        app_version: config.get("upload", "app_version"),
        build_number: config.get("upload", "build_number"),
        release_type: config.get("upload", "release_type"),
        icon: config.get("upload", "icon"),
        install_type: config.get("upload", "install_type", default: 1),
        password: nil,
        password_env: config.get("upload", "password_env"),
        description: config.get("upload", "description"),
        install_date: config.get("upload", "install_date"),
        start_date: config.get("upload", "start_date"),
        end_date: config.get("upload", "end_date"),
        channel: config.get("upload", "channel"),
        poll_attempts: config.get("upload", "poll_attempts", default: 60),
        upload: false
      }
    end

    def build_parser(options)
      OptionParser.new do |opts|
        opts.banner = "用法: appship [--config FILE] build [选项]"
        opts.separator ""
        opts.separator "工程与构建"
        opts.on("--workspace PATH", "Xcode workspace 路径") { |value| options[:workspace] = value }
        opts.on("--project PATH", "Xcode project 路径") { |value| options[:project] = value }
        opts.on("--scheme NAME", "Scheme 名称") { |value| options[:scheme] = value }
        opts.on("--configuration NAME", "构建配置（默认 Debug）") { |value| options[:configuration] = value }
        opts.on("--sdk NAME", "SDK（默认 iphoneos）") { |value| options[:sdk] = value }
        opts.on("--output PATH", "最终 IPA 路径") { |value| options[:output] = value }
        opts.on("--archive-path PATH", "自定义 xcarchive 路径") { |value| options[:archive_path] = value }
        opts.on("--export-path PATH", "自定义 export 目录") { |value| options[:export_path] = value }
        opts.on("--export-options-plist PATH", "使用已有 ExportOptions.plist") { |value| options[:export_options_plist] = value }
        opts.on("--export-method NAME", "development/adhoc/app-store 等") { |value| options[:export_method] = value }
        opts.on("--team-id ID", "签名 Team ID") { |value| options[:team_id] = value }
        opts.on("--no-clean", "不清理已有 archive/export 路径") { options[:clean] = false }
        opts.on("--keep-temporary", "保留工具生成的临时目录") { options[:keep_temporary] = true }
        opts.on("--no-allow-provisioning-updates", "不允许 xcodebuild 自动更新签名") { options[:allow_provisioning_updates] = false }
        opts.separator ""
        opts.separator "图标角标"
        opts.on("--badge TEXT", "添加角标，例如 DEBUG 或 RELEASE") { |value| options[:badge] = value }
        opts.on("--no-badge", "禁用配置文件里的角标") { options[:badge] = nil }
        opts.on("--assets PATH", "Assets.xcassets 路径") { |value| options[:assets] = value }
        opts.on("--app-icon NAME", "AppIcon 名称（默认 AppIcon）") { |value| options[:app_icon] = value }
        opts.separator ""
        add_upload_options(opts, options)
        opts.on("-h", "--help", "显示帮助") { puts opts; exit 0 }
      end
    end

    def package_parser(options)
      OptionParser.new do |opts|
        opts.banner = "用法: appship [--config FILE] package [选项]"
        opts.on("--app PATH", "已编译 .app 路径") { |value| options[:app] = value }
        opts.on("--output PATH", "最终 IPA 路径") { |value| options[:output] = value }
        opts.on("--badge TEXT", "添加角标") { |value| options[:badge] = value }
        opts.on("--no-badge", "禁用角标") { options[:badge] = nil }
        opts.on("--assets PATH", "Assets.xcassets 路径") { |value| options[:assets] = value }
        opts.on("--app-icon NAME", "AppIcon 名称") { |value| options[:app_icon] = value }
        add_upload_options(opts, options)
        opts.on("-h", "--help", "显示帮助") { puts opts; exit 0 }
      end
    end

    def upload_parser(options)
      OptionParser.new do |opts|
        opts.banner = "用法: appship [--config FILE] upload IPA_OR_APK [选项]"
        opts.on("--file PATH", "IPA/APK 路径，也可作为位置参数传入") { |value| options[:file] = value }
        add_upload_options(opts, options)
        opts.on("-h", "--help", "显示帮助") { puts opts; exit 0 }
      end
    end

    def pgyer_parser(options)
      OptionParser.new do |opts|
        opts.banner = "用法: appship pgyer [选项]"
        opts.separator ""
        opts.separator "项目与缓存"
        opts.on("--project-dir PATH", "项目目录（默认当前目录）") { |value| options[:project_dir] = value }
        opts.on("--env-file PATH", "本机缓存文件（默认 ~/.appship/.config）") { |value| options[:env_file] = value }
        opts.on("--project-name NAME", "缓存中的 project_name") { |value| options[:project_name] = value }
        opts.on("--app-name NAME", "缓存中的 app_name") { |value| options[:app_name] = value }
        opts.on("--workspace PATH", "Xcode workspace 路径") { |value| options[:workspace] = value }
        opts.on("--project PATH", "Xcode project 路径") { |value| options[:project] = value }
        opts.on("--scheme NAME", "Scheme 名称") { |value| options[:scheme] = value }
        opts.on("--configuration NAME", "构建配置（Debug/Release）") { |value| options[:configuration] = value; options[:configuration_explicit] = true }
        opts.on("--output PATH", "最终 IPA 路径") { |value| options[:output] = value }
        opts.on("--cache", "复用 DerivedData 中已有的 .app") { options[:build_mode] = "cache"; options[:build_mode_explicit] = true }
        opts.on("--rebuild", "重新 archive/export 构建（默认）") { options[:build_mode] = "rebuild"; options[:build_mode_explicit] = true }
        opts.separator ""
        opts.separator "角标与导出"
        opts.on("--badge TEXT", "添加图标角标，例如 DEBUG") { |value| options[:badge] = value; options[:badge_explicit] = true }
        opts.on("--no-badge", "不添加图标角标") { options[:badge] = nil; options[:badge_explicit] = true }
        opts.on("--assets PATH", "Assets.xcassets 路径") { |value| options[:assets] = value }
        opts.on("--app-icon NAME", "AppIcon 名称") { |value| options[:app_icon] = value }
        opts.on("--export-method NAME", "development/adhoc/app-store 等") { |value| options[:export_method] = value }
        opts.on("--team-id ID", "签名 Team ID") { |value| options[:team_id] = value }
        opts.on("--no-allow-provisioning-updates", "不允许自动更新签名") { options[:allow_provisioning_updates] = false }
        opts.separator ""
        opts.separator "蒲公英"
        opts.on("--api-key KEY", "覆盖缓存中的 pgyer_api_key") { |value| options[:api_key] = value }
        opts.on("--install-type N", Integer, "1=公开，2=密码，3=邀请") { |value| options[:install_type] = value }
        opts.on("--password PASSWORD", "安装密码") { |value| options[:password] = value }
        opts.on("--password-env NAME", "安装密码环境变量名") { |value| options[:password_env] = value }
        opts.on("--description TEXT", "更新描述") { |value| options[:description] = value; options[:description_explicit] = true }
        opts.on("--channel NAME", "渠道短链接") { |value| options[:channel] = value }
        opts.on("--poll-attempts N", Integer, "轮询次数，默认 60") { |value| options[:poll_attempts] = value }
        opts.on("-h", "--help", "显示帮助") { puts opts; exit 0 }
      end
    end

    def fir_parser(options)
      OptionParser.new do |opts|
        opts.banner = "用法: appship fir [选项]"
        opts.separator ""
        opts.separator "项目与缓存"
        opts.on("--project-dir PATH", "项目目录（默认当前目录）") { |value| options[:project_dir] = value }
        opts.on("--env-file PATH", "本机缓存文件（默认 ~/.appship/.config）") { |value| options[:env_file] = value }
        opts.on("--project-name NAME", "缓存中的 project_name") { |value| options[:project_name] = value }
        opts.on("--app-name NAME", "fir.im 应用名称") { |value| options[:app_name] = value }
        opts.on("--workspace PATH", "Xcode workspace 路径") { |value| options[:workspace] = value }
        opts.on("--project PATH", "Xcode project 路径") { |value| options[:project] = value }
        opts.on("--scheme NAME", "Scheme 名称") { |value| options[:scheme] = value }
        opts.on("--configuration NAME", "构建配置（Debug/Release）") { |value| options[:configuration] = value; options[:configuration_explicit] = true }
        opts.on("--output PATH", "最终 IPA 路径") { |value| options[:output] = value }
        opts.on("--cache", "复用 DerivedData 中已有的 .app") { options[:build_mode] = "cache"; options[:build_mode_explicit] = true }
        opts.on("--rebuild", "重新 archive/export 构建（默认）") { options[:build_mode] = "rebuild"; options[:build_mode_explicit] = true }
        opts.separator ""
        opts.separator "角标与导出"
        opts.on("--badge TEXT", "添加图标角标，例如 DEBUG") { |value| options[:badge] = value; options[:badge_explicit] = true }
        opts.on("--no-badge", "不添加角标") { options[:badge] = nil; options[:badge_explicit] = true }
        opts.on("--assets PATH", "Assets.xcassets 路径") { |value| options[:assets] = value }
        opts.on("--app-icon NAME", "AppIcon 名称") { |value| options[:app_icon] = value }
        opts.on("--export-method NAME", "adhoc/inhouse 等") { |value| options[:export_method] = value }
        opts.on("--team-id ID", "签名 Team ID") { |value| options[:team_id] = value }
        opts.on("--no-allow-provisioning-updates", "不允许自动更新签名") { options[:allow_provisioning_updates] = false }
        opts.separator ""
        opts.separator "fir.im"
        opts.on("--fir-api-key KEY", "覆盖缓存中的 fir_api_key") { |value| options[:fir_api_token] = value }
        opts.on("--fir-api-token TOKEN", "fir.im API Token（不建议写入配置文件）") { |value| options[:fir_api_token] = value }
        opts.on("--fir-api-token-env NAME", "fir.im API Token 环境变量名") { |value| options[:fir_api_token_env] = value }
        opts.on("--bundle-id ID", "应用 Bundle ID（IPA 可自动读取）") { |value| options[:bundle_id] = value }
        opts.on("--app-version VERSION", "应用版本号") { |value| options[:app_version] = value }
        opts.on("--build-number NUMBER", "Build 号") { |value| options[:build_number] = value }
        opts.on("--release-type TYPE", "iOS 打包类型（Adhoc 或 Inhouse）") { |value| options[:release_type] = value }
        opts.on("--icon PATH", "应用图标路径（可选）") { |value| options[:icon] = value }
        opts.on("--description TEXT", "更新描述") { |value| options[:description] = value; options[:description_explicit] = true }
        opts.on("--no-clean", "不清理已有 archive/export 路径") { options[:clean] = false }
        opts.on("--keep-temporary", "保留工具生成的临时目录") { options[:keep_temporary] = true }
        opts.on("-h", "--help", "显示帮助") { puts opts; exit 0 }
      end
    end

    def add_upload_options(opts, options)
      opts.separator ""
      opts.separator "分发平台"
      opts.on("--provider NAME", "分发平台（pgyer 或 fir，默认 pgyer）") { |value| options[:provider] = value }
      opts.separator "蒲公英上传"
      opts.on("--upload", "构建/打包后上传到所选分发平台") { options[:upload] = true }
      opts.on("--api-key KEY", "蒲公英 API Key（不建议写入配置文件）") { |value| options[:api_key] = value }
      opts.on("--api-key-env NAME", "API Key 环境变量名") { |value| options[:api_key_env] = value }
      opts.on("--install-type N", Integer, "1=公开，2=密码，3=邀请") { |value| options[:install_type] = value }
      opts.on("--password PASSWORD", "安装密码（建议使用 --password-env）") { |value| options[:password] = value }
      opts.on("--password-env NAME", "安装密码环境变量名") { |value| options[:password_env] = value }
      opts.on("--description TEXT", "更新描述") { |value| options[:description] = value }
      opts.on("--channel NAME", "渠道短链接") { |value| options[:channel] = value }
      opts.on("--poll-attempts N", Integer, "轮询次数，默认 60") { |value| options[:poll_attempts] = value }
      opts.separator ""
      opts.separator "fir.im 上传"
      opts.on("--fir-api-token TOKEN", "fir.im API Token（不建议写入配置文件）") { |value| options[:fir_api_token] = value }
      opts.on("--fir-api-token-env NAME", "fir.im API Token 环境变量名") { |value| options[:fir_api_token_env] = value }
      opts.on("--bundle-id ID", "fir.im 应用 Bundle ID（IPA 可自动读取）") { |value| options[:bundle_id] = value }
      opts.on("--app-name NAME", "fir.im 应用名称") { |value| options[:app_name] = value }
      opts.on("--app-version VERSION", "fir.im 应用版本号") { |value| options[:app_version] = value }
      opts.on("--build-number NUMBER", "fir.im Build 号") { |value| options[:build_number] = value }
      opts.on("--release-type TYPE", "iOS 打包类型（Adhoc 或 Inhouse）") { |value| options[:release_type] = value }
      opts.on("--icon PATH", "fir.im 应用图标路径（可选）") { |value| options[:icon] = value }
    end

    def help
      <<~HELP
        appship #{VERSION} - 通用移动应用构建、打包和分发工具

        用法:
          appship init [--path .appship.yml]
          appship doctor
          appship pgyer
          appship fir
          appship build [选项]
          appship package --app path/to/App.app [选项]
          appship upload path/to/App.ipa [选项]

        常用示例:
          appship init
          cd /path/to/project && appship pgyer
          FIR_API_TOKEN=xxx appship fir --workspace MyApp.xcworkspace --scheme MyApp
          appship build --workspace MyApp.xcworkspace --scheme MyApp --configuration Debug
          appship build --project MyApp.xcodeproj --scheme MyApp --badge DEBUG --upload
          appship package --app build/Debug-iphoneos/MyApp.app --output build/MyApp.ipa
          PGYER_API_KEY=xxx appship upload build/MyApp.ipa --install-type 2 --password-env PGYER_INSTALL_PASSWORD
          FIR_API_TOKEN=xxx appship upload build/MyApp.ipa --provider fir --bundle-id com.example.MyApp

        全局选项必须放在命令前:
          --config FILE       使用指定配置文件
          --verbose           输出执行的底层命令
      HELP
    end
  end
end
