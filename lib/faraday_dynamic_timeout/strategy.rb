# frozen_string_literal: true

module FaradayDynamicTimeout
  class Strategy
    def initialize(buckets:, options: {})
      @config = buckets
      @options = options
    end
  end
end
