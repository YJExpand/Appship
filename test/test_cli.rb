# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/appship"

class CLITest < Minitest::Test
  def test_fir_short_options_are_normalized
    args = ["-key", "new-key", "-password", "new-password"]

    Appship::CLI.new.send(:normalize_provider_short_options!, args, "fir")

    assert_equal ["--fir-api-key", "new-key", "--fir-password", "new-password"], args
  end

  def test_pgyer_short_options_are_normalized
    args = ["-key=new-key", "-password=new-password"]

    Appship::CLI.new.send(:normalize_provider_short_options!, args, "pgyer")

    assert_equal ["--api-key=new-key", "--password=new-password"], args
  end
end
