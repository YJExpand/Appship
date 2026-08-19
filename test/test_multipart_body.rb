# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/appship"

class MultipartBodyTest < Minitest::Test
  def test_streams_file_and_form_fields
    Tempfile.create("pgyer-upload-test") do |file|
      file.write("ipa-data")
      file.flush
      progress = []
      body = Appship::MultipartBody.new(
        { "key" => "abc" },
        file.path,
        "boundary",
        progress: ->(current, total) { progress << [current, total] }
      )
      chunks = +""
      while (chunk = body.read(3))
        chunks << chunk
      end

      assert_includes chunks, 'name="key"'
      assert_includes chunks, "abc"
      assert_includes chunks, 'filename="pgyer-upload-test'
      assert_includes chunks, "ipa-data"
      assert_includes chunks, "--boundary--"
      assert_equal body.length, chunks.bytesize
      assert_equal [8, 8], progress.last
    end
  end
end
