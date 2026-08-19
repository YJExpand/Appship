# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/appship"

class ConfigTest < Minitest::Test
  def test_reads_nested_values
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".appship.yml")
      File.write(path, <<~YAML)
        workspace: Demo.xcworkspace
        upload:
          api_key_env: DEMO_API_KEY
      YAML

      config = Appship::Config.new(path)
      assert_equal "Demo.xcworkspace", config.get("workspace")
      assert_equal "DEMO_API_KEY", config.get("upload", "api_key_env")
      assert_equal "fallback", config.get("missing", default: "fallback")
    end
  end
end
