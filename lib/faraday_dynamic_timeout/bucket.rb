# frozen_string_literal: true

module FaradayDynamicTimeout
  # Internal class for storing bucket configuration.
  # @api private
  class Bucket
    attr_reader :timeout, :limit

    class << self
      def from_hashes(hashes)
        all_buckets = hashes.collect { |hash| new(timeout: fetch_indifferent_key(hash, :timeout), limit: fetch_indifferent_key(hash, :limit)) }
        grouped_buckets = all_buckets.select(&:valid?).group_by(&:timeout).values
        return [] if grouped_buckets.empty?

        unique_buckets = grouped_buckets.collect do |buckets|
          buckets.reduce do |merged, bucket|
            merged.nil? ? bucket : merged.merge(bucket)
          end
        end

        unique_buckets.sort_by(&:timeout)
      end

      private

      def fetch_indifferent_key(hash, key)
        hash[key] || hash[key.to_s]
      end
    end

    # @param timeout [Float] The timeout in seconds.
    # @param limit [Integer] The limit.
    def initialize(timeout:, limit: 0)
      @timeout = timeout.to_f.round(3)
      @limit = limit.to_i
    end

    # Return true if the bucket has no limit. A bucket has no limit if the limit is negative.
    # @return [Boolean] True if the bucket has no limit.
    def no_limit?
      limit < 0
    end

    # Return true if the bucket is valid. A bucket is valid if the timeout is positive and
    # the limit is non-zero.
    def valid?
      timeout.positive? && limit != 0
    end

    def ==(other)
      return false unless other.is_a?(self.class)

      timeout == other.timeout && limit == other.limit
    end

    def merge(bucket)
      combined_limit = if no_limit?
        limit
      elsif bucket.no_limit?
        bucket.limit
      else
        limit + bucket.limit
      end

      combined_timeout = [timeout, bucket.timeout].max

      self.class.new(timeout: combined_timeout, limit: combined_limit)
    end
  end
end
