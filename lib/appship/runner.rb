# frozen_string_literal: true

module Appship
  class Runner
    attr_reader :verbose

    def initialize(verbose: false)
      @verbose = verbose
    end

    def self.which(command)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
        candidate = File.join(directory, command)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    def require_command!(command, explanation = nil)
      return Runner.which(command) if Runner.which(command)

      message = "找不到命令: #{command}"
      message += "（#{explanation}）" if explanation
      raise ConfigurationError, message
    end

    def run!(argv, chdir: nil, env: {})
      puts "$ #{Shellwords.join(argv)}" if verbose
      status = nil
      spawn_options = {}
      spawn_options[:chdir] = chdir if chdir
      Open3.popen2e(env, *argv, **spawn_options) do |_stdin, output, wait_thread|
        output.each_line { |line| print line }
        status = wait_thread.value
      end
      return true if status&.success?

      raise CommandError, "命令执行失败（退出码 #{status&.exitstatus || "unknown"}）: #{argv.first}"
    rescue Errno::ENOENT
      raise ConfigurationError, "找不到命令: #{argv.first}"
    end

    def capture!(argv, chdir: nil, env: {})
      spawn_options = {}
      spawn_options[:chdir] = chdir if chdir
      stdout, stderr, status = Open3.capture3(env, *argv, **spawn_options)
      return stdout if status.success?

      detail = [stdout, stderr].reject(&:empty?).join("\n")
      raise CommandError, "命令执行失败: #{Shellwords.join(argv)}\n#{detail}"
    rescue Errno::ENOENT
      raise ConfigurationError, "找不到命令: #{argv.first}"
    end
  end
end
