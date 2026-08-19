# frozen_string_literal: true

module Appship
  module Badger
    module_function

    def apply!(app, assets:, app_icon:, text:, runner: Runner.new)
      raise ConfigurationError, ".app 不存在: #{app}" unless File.directory?(app)

      magick = Runner.which("magick") || Runner.which("convert")
      unless magick
        raise ConfigurationError, "添加图标角标需要 ImageMagick（brew install imagemagick）"
      end
      runner.require_command!("xcrun", "需要安装 Xcode")

      font = resolve_font
      raise ConfigurationError, "未找到可用字体文件，无法生成图标角标" unless font

      label = text.to_s.strip
      raise ConfigurationError, "角标文字不能为空" if label.empty?

      modified = regenerate_assets_car!(app, assets, app_icon || "AppIcon", label, magick, font, runner)
      modified ||= badge_loose_icons!(app, label, magick, font, runner)
      raise Error, "未能修改 AppIcon" unless modified

      resign!(app, runner)
      puts "✅ 已添加 #{label} 图标角标并重新签名"
      true
    end

    def regenerate_assets_car!(app, assets, app_icon, text, magick, font, runner)
      return false unless assets && File.directory?(assets) && File.file?(File.join(app, "Assets.car"))
      runner.capture!(["xcrun", "--find", "actool"])

      root = Dir.mktmpdir("appship-assets-")
      begin
        catalog_name = File.basename(File.expand_path(assets))
        copied_catalog = File.join(root, catalog_name)
        FileUtils.cp_r(File.expand_path(assets), copied_catalog)
        icon_set = locate_icon_set(copied_catalog, app_icon)
        return false unless icon_set

        count = 0
        Dir[File.join(icon_set, "*.png")].each do |png|
          count += 1 if badge_png!(png, text, magick, font, root)
        end
        return false if count.zero?

        compiled = File.join(root, "compiled")
        FileUtils.mkdir_p(compiled)
        partial = File.join(root, "partial.plist")
        runner.run!(["xcrun", "actool", "--output-format", "human-readable-text", "--app-icon", app_icon,
                     "--compile", compiled, "--platform", "iphoneos", "--minimum-deployment-target", "13.0",
                     "--target-device", "iphone", "--target-device", "ipad", "--compress-pngs",
                     "--output-partial-info-plist", partial, copied_catalog])
        return false unless File.file?(File.join(compiled, "Assets.car"))

        FileUtils.cp(File.join(compiled, "Assets.car"), File.join(app, "Assets.car"))
        Dir[File.join(compiled, "AppIcon*.png")].each do |png|
          FileUtils.cp(png, app)
        end
        puts "   ✅ Assets.car 已重新编译（#{count} 个图标尺寸）"
        true
      rescue CommandError
        puts "   ⚠️ Assets.car 重编失败，将尝试处理 IPA 内的松散图标"
        false
      ensure
        FileUtils.rm_rf(root)
      end
    end

    def badge_loose_icons!(app, text, magick, font, runner)
      work = Dir.mktmpdir("appship-icon-")
      count = 0
      Dir[File.join(app, "**", "AppIcon*.png")].each do |png|
        count += 1 if badge_png!(png, text, magick, font, work)
      end
      puts "   ℹ️ 已处理 #{count} 个松散 AppIcon PNG" if count.positive?
      count.positive?
    ensure
      FileUtils.rm_rf(work) if work
    end

    def locate_icon_set(catalog, app_icon)
      candidate = File.join(catalog, "#{app_icon}.appiconset")
      return candidate if File.directory?(candidate)

      Dir[File.join(catalog, "**", "*.appiconset")].first
    end

    def badge_png!(png, text, magick, font, work)
      FileUtils.mkdir_p(work)
      normalized = File.join(work, "normalized-#{Process.pid}-#{File.basename(png)}")
      label = File.join(work, "label-#{Process.pid}-#{File.basename(png)}")
      rotated = File.join(work, "rotated-#{Process.pid}-#{File.basename(png)}")

      # pngcrush 不是所有 Xcode 环境都提供；ImageMagick 可直接处理普通 PNG。
      FileUtils.cp(png, normalized)
      dimension_output, dimension_status = Open3.capture2(magick, "-format", "%w %h", normalized, "info:")
      return false unless dimension_status.success?
      dimensions = dimension_output.split.map(&:to_i)
      image_width = dimensions[0]
      return false unless image_width && image_width.positive?

      band_width = [(image_width * 0.60).to_i, 1].max
      band_height = [(image_width * 0.16).to_i, 1].max
      point_size = [(image_width * 0.10).to_i, 8].max
      debug_x = (image_width * 0.60).to_i
      debug_y = -(band_height * 0.8).to_i

      unless system(magick, "-background", "#4CAF50", "-size", "#{band_width}x#{band_height}", "-pointsize", point_size.to_s,
                    "-fill", "white", "-font", font, "-gravity", "center", "caption:#{text}", label,
                    out: File::NULL, err: File::NULL)
        return false
      end
      unless system(magick, "-background", "none", label, "-rotate", "45", rotated,
                    out: File::NULL, err: File::NULL)
        return false
      end
      unless system(magick, normalized, rotated, "-geometry", "+#{debug_x}+#{debug_y}", "-composite", "-alpha", "remove", png,
                    out: File::NULL, err: File::NULL)
        return false
      end
      true
    ensure
      [normalized, label, rotated].compact.each { |file| FileUtils.rm_f(file) }
    end

    def resolve_font
      candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNS.ttf",
        "/Library/Fonts/Arial.ttf"
      ]
      candidates.find { |file| File.file?(file) }
    end

    def resign!(app, runner)
      codesign_stdout, codesign_stderr, codesign_status = Open3.capture3("codesign", "-dvv", app)
      unless codesign_status.success?
        raise CommandError, "无法读取 App 签名信息: #{codesign_stderr}"
      end
      authority = (codesign_stdout + codesign_stderr).lines.find { |line| line.start_with?("Authority=") }&.split("=", 2)&.last&.strip
      identities = runner.capture!(["security", "find-identity", "-v", "-p", "codesigning"]).lines.filter_map do |line|
        match = line.match(/([0-9A-F]{40})\s+"([^"]+)"/)
        match && { sha: match[1], name: match[2] }
      end
      identity = identities.find { |item| authority && item[:name].include?(authority) } || identities.first
      raise ConfigurationError, "找不到可用的代码签名身份，无法重新签名" unless identity

      puts "   🔏 重新签名: #{identity[:name]}"
      entitlements = File.join(Dir.mktmpdir("appship-entitlements-"), "entitlements.plist")
      begin
        stdout, _stderr, status = Open3.capture3("codesign", "-d", "--entitlements", ":-", app)
        File.write(entitlements, stdout) if status.success? && !stdout.strip.empty?

        nested = Dir[File.join(app, "Frameworks", "*")] + Dir[File.join(app, "PlugIns", "*")]
        nested.select! { |path| File.file?(path) || File.directory?(path) }
        nested.sort_by { |path| -path.count(File::SEPARATOR) }.each do |path|
          runner.run!(["codesign", "--force", "--sign", identity[:sha], "--timestamp=none", path])
        end

        args = ["codesign", "--force", "--sign", identity[:sha], "--timestamp=none"]
        args += ["--entitlements", entitlements] if File.file?(entitlements) && !File.zero?(entitlements)
        args << app
        runner.run!(args)
        runner.run!(["codesign", "--verify", "--deep", "--strict", app])
      ensure
        FileUtils.rm_rf(File.dirname(entitlements))
      end
    end
  end
end
