# frozen_string_literal: true

module Appship
  module Ipa
    module_function

    def package!(app, output:, badge: nil, assets: nil, app_icon: nil, runner: Runner.new)
      runner.require_command!("zip", "macOS 通常自带 zip")
      root = Dir.mktmpdir("appship-ipa-")
      begin
        payload = File.join(root, "Payload")
        FileUtils.mkdir_p(payload)
        FileUtils.cp_r(app, File.join(payload, File.basename(app)))
        if badge
          Badger.apply!(File.join(payload, File.basename(app)), assets: assets, app_icon: app_icon, text: badge, runner: runner)
        end
        zip_directory!(root, output, runner)
      ensure
        FileUtils.rm_rf(root)
      end
      output
    end

    def apply_badge!(ipa_path, assets:, app_icon:, text:, runner: Runner.new)
      runner.require_command!("unzip", "macOS 通常自带 unzip")
      runner.require_command!("zip", "macOS 通常自带 zip")
      root = Dir.mktmpdir("appship-badge-")
      begin
        runner.run!(["unzip", "-q", ipa_path, "-d", root])
        app = Dir[File.join(root, "Payload", "*.app")].first
        raise ConfigurationError, "IPA 内没有找到 Payload/*.app" unless app

        Badger.apply!(app, assets: assets, app_icon: app_icon, text: text, runner: runner)
        replacement = File.join(root, "rebuilt.ipa")
        zip_directory!(root, replacement, runner, exclude: [File.basename(replacement)])
        FileUtils.mv(replacement, ipa_path, force: true)
      ensure
        FileUtils.rm_rf(root)
      end
      ipa_path
    end

    def zip_directory!(root, output, runner, exclude: [])
      FileUtils.mkdir_p(File.dirname(output))
      entries = Dir.children(root).reject { |entry| exclude.include?(entry) }
      raise CommandError, "没有可打包的 IPA 内容" if entries.empty?

      runner.run!(["zip", "-qr", output, *entries], chdir: root)
    end
  end
end
