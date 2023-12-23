# frozen_string_literal: true

require "faraday"
require "restrainer"
require "socket"

require_relative "faraday_dynamic_timeout/bucket"
require_relative "faraday_dynamic_timeout/capacity_strategy"
require_relative "faraday_dynamic_timeout/counter"
require_relative "faraday_dynamic_timeout/middleware"
require_relative "faraday_dynamic_timeout/request_info"

module FaradayDynamicTimeout
  VERSION = File.read(File.expand_path("../VERSION", __dir__)).strip

  # Error raised when a request is not executed due to too many concurrent requests.
  class ThrottledError < Restrainer::ThrottledError
    attr_reader :request_count

    def initialize(message, request_count:)
      super(message)
      @request_count = request_count
    end
  end
end

Faraday::Middleware.register_middleware(dynamic_timeout: FaradayDynamicTimeout::Middleware)
