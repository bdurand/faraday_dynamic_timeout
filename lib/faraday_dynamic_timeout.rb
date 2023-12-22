# frozen_string_literal: true

require "faraday"
require "restrainer"
require "socket"

require_relative "faraday_dynamic_timeout/bucket"
require_relative "faraday_dynamic_timeout/counter"
require_relative "faraday_dynamic_timeout/middleware"

module FaradayDynamicTimeout
  VERSION = File.read(File.expand_path("../VERSION", __dir__)).strip
end

Faraday::Request.register_middleware(dynamic_timeout: FaradayDynamicTimeout::Middleware)
