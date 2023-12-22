# frozen_string_literal: true

module FaradayDynamicTimeout
  # Internal class for storing bucket configuration.
  # @api private
  class Bucket
    attr_reader :timeout, :limit, :capacity

    class << self
      def from_hashes(hashes)
        all_buckets = hashes.collect { |hash| new(timeout: hash[:timeout], limit: hash[:limit], capacity: hash[:capacity]) }
        grouped_buckets = all_buckets.select(&:valid?).group_by(&:timeout).values
        return [] if grouped_buckets.empty?

        unique_buckets = grouped_buckets.map do |buckets|
          buckets.reduce do |merged, bucket|
            merged.nil? ? bucket : merged.merge(bucket)
          end
        end

        unique_buckets.sort_by(&:timeout)
      end
    end

    # @param timeout [Float] The timeout in seconds.
    # @param limit [Integer] The limit.
    # @param capacity [Float] The capacity.
    def initialize(timeout:, limit: 0, capacity: 0.0)
      @timeout = timeout.to_f.round(3)
      @limit = limit.to_i
      @capacity = capacity.to_f
    end

    # Return true if the bucket has no limit. A bucket has no limit if the limit
    # is negative or the capacity is negative or greater than or equal to 1.0.
    # @return [Boolean] True if the bucket has no limit.
    def no_limit?
      limit < 0 || capacity < 0 || capacity >= 1.0
    end

    # Return true if the bucket is valid. A bucket is valid if the timeout is
    # positive and the limit or capacity is non-zero.
    def valid?
      timeout.positive? && !(limit.zero? && capacity.zero?)
    end

    def ==(other)
      return false unless other.is_a?(self.class)

      timeout == other.timeout && limit == other.limit && capacity == other.capacity
    end

    def merge(bucket)
      combined_limit = if no_limit?
        limit
      elsif bucket.no_limit?
        bucket.limit
      else
        limit + bucket.limit
      end

      combined_capacity = if no_limit?
        capacity
      elsif bucket.no_limit?
        bucket.capacity
      else
        capacity + bucket.capacity
      end

      combined_timeout = [timeout, bucket.timeout].max

      self.class.new(timeout: combined_timeout, limit: combined_limit, capacity: combined_capacity)
    end
  end
end
