# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/appship"

class FirUploaderTest < Minitest::Test
  def test_requests_credentials_and_uploads_binary_with_fir_fields
    uploader_class = Class.new(Appship::FirUploader) do
      attr_reader :credential_request, :binary_upload, :password_update

      private

      def post_json!(url, payload)
        @credential_request = [url, payload]
        {
          "id" => "app-id",
          "short" => "demo",
          "cert" => {
            "binary" => {
              "key" => "binary-key",
              "token" => "binary-token",
              "upload_url" => "https://upload.example.test/binary"
            }
          }
        }
      end

      def multipart_upload!(url, fields, file)
        @binary_upload = [url, fields, file]
        true
      end

      def update_access_password!(app_id, password)
        @password_update = [app_id, password]
        true
      end
    end

    Tempfile.create(["demo", ".ipa"]) do |file|
      file.write("ipa-data")
      file.flush
      uploader = uploader_class.new(
        fir_api_token: "fir-secret",
        bundle_id: "com.example.demo",
        app_name: "Demo",
        app_version: "1.2.3",
        build_number: "42",
        release_type: "Inhouse",
        fir_password: "install-secret",
        description: "first build"
      )

      result = uploader.upload!(file.path)

      assert_equal "https://api.appmeta.cn/apps", uploader.credential_request.first
      assert_equal({
        "type" => "ios",
        "bundle_id" => "com.example.demo",
        "api_token" => "fir-secret"
      }, uploader.credential_request.last)
      assert_equal "https://upload.example.test/binary", uploader.binary_upload.first
      assert_equal "binary-key", uploader.binary_upload[1]["key"]
      assert_equal "binary-token", uploader.binary_upload[1]["token"]
      assert_equal "Demo", uploader.binary_upload[1]["x:name"]
      assert_equal "1.2.3", uploader.binary_upload[1]["x:version"]
      assert_equal "42", uploader.binary_upload[1]["x:build"]
      assert_equal "Inhouse", uploader.binary_upload[1]["x:release_type"]
      assert_equal "first build", uploader.binary_upload[1]["x:changelog"]
      assert_equal ["app-id", "install-secret"], uploader.password_update
      assert_equal "https://fir.im/demo", result["url"]
      assert_equal "fir", result["provider"]
      assert result["data"]["password_protected"]
    end
  end

  def test_uploader_selects_fir_provider
    uploader = Appship::Uploader.new(provider: "fir", fir_api_token: "secret")

    assert_instance_of Appship::FirUploader, uploader.instance_variable_get(:@delegate)
  end

  def test_requires_bundle_id_when_ipa_metadata_is_unavailable
    Tempfile.create(["invalid", ".ipa"]) do |file|
      file.write("not-an-ipa")
      file.flush
      uploader = Appship::FirUploader.new(fir_api_token: "secret")

      error = assert_raises(Appship::ConfigurationError) { uploader.upload!(file.path) }
      assert_includes error.message, "--bundle-id"
    end
  end
end
