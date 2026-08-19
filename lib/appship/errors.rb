# frozen_string_literal: true

module Appship
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class CommandError < Error; end
  class UploadError < Error; end
end
