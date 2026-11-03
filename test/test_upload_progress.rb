# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/appship"

class UploadProgressTest < Minitest::Test
  class Terminal < StringIO
    def tty?
      true
    end
  end

  class Connection
    attr_reader :body

    def initialize(result)
      @result = result
    end

    def request(request)
      @body = request.body_stream
      if @result.is_a?(Exception)
        @body.read(1024)
        raise @result
      end
      while @body.read(16 * 1024); end
      @result
    end
  end

  def test_progress_does_not_report_success_until_server_acknowledges
    [StringIO.new, Terminal.new].each do |output|
      progress = Appship::UploadProgress.new(100, output: output)
      progress.start
      progress.update(100)
      refute_match(/100%|100 %|上传完成/, output.string)

      progress.finish(success: true)
      assert_includes output.string, "上传完成"
      assert_match(/100%/, output.string)
      completed = output.string.dup
      progress.finish
      assert_equal completed, output.string
    end
  end

  def test_failed_upload_keeps_actual_byte_count_without_fake_completion
    output = Terminal.new
    progress = Appship::UploadProgress.new(100, output: output)
    progress.start
    progress.update(25)
    progress.finish(success: false)

    assert_includes output.string, "上传失败"
    assert_includes output.string, "25B/100B"
    refute_match(/100%|上传完成/, output.string)
  end

  def test_both_platforms_complete_progress_only_on_http_success_and_close_streams
    Dir.mktmpdir do |directory|
      file = File.join(directory, "Demo.ipa")
      File.write(file, "x" * 65_536)
      [Appship::PgyerUploader, Appship::FirUploader].each do |base|
        [200, 403, SocketError.new("network failed")].each do |status|
          result = if status.is_a?(Exception)
                     status
                   else
                     response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status.to_s).new("1.1", status.to_s, "")
                     response.body = "response"
                     response.instance_variable_set(:@read, true)
                     response
                   end
          connection = Connection.new(result)
          klass = Class.new(base) do
            attr_accessor :connection

            private

            def http(_uri)
              connection
            end
          end
          uploader = klass.new(api_key: "key", fir_api_token: "token")
          uploader.connection = connection
          call = if base == Appship::PgyerUploader
                   -> { uploader.send(:upload_to_cos!, file, { endpoint: "https://example.test/upload", key: "key", signature: "signature", security_token: "token" }) }
                 else
                   -> { uploader.send(:multipart_upload!, "https://example.test/upload", { "key" => "key" }, file) }
                 end
          output, = capture_io do
            if status == 200
              assert call.call
            else
              assert_raises(status.is_a?(Exception) ? SocketError : Appship::UploadError) { call.call }
            end
          end

          assert connection.body.instance_variable_get(:@file).closed?
          if status == 200
            assert_includes output, "上传完成"
          else
            assert_includes output, "上传失败"
            refute_match(/100%|上传完成/, output)
          end
        end
      end
    end
  end
end
