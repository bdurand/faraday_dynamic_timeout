# frozen_string_literal: true

module FaradayDynamicTimeout
  class RequestInfo
    attr_reader :env, :duration, :timeout, :error

    def initialize(env:, duration:, timeout:, request_count:, error: nil)
      @env = env
      @duration = duration
      @timeout = timeout
      @request_count = request_count
      @error = error
    end

    def http_method
      env.method
    end

    def uri
      env.url
    end

    def status
      env.status
    end

    def request_count
      throttled? ? error.request_count : @request_count
    end

    def throttled?
      @error.is_a?(ThrottledError)
    end

    def timed_out?
      @error.is_a?(Faraday::TimeoutError)
    end

    def error?
      !!@error
    end
  end
end
