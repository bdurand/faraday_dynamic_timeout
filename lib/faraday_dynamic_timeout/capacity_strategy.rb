# frozen_string_literal: true

module FaradayDynamicTimeout
  class CapacityStrategy
    def initialize(buckets:, redis:, name: nil, threads_per_process: 1)
      @config = buckets
      @redis = redis
      @name = (name || "default").to_s
      @threads_per_process = threads_per_process
    end

    def call
      process_count = count_processes
      threads_count = total_threads(process_count)

      buckets_config.collect do |bucket|
        timeout = fetch_indifferent_key(bucket, :timeout)&.to_f
        limit = fetch_indifferent_key(bucket, :limit)&.to_i
        capacity = fetch_indifferent_key(bucket, :capacity)&.to_f
        {timeout: timeout, limit: capacity_limit(capacity, limit, threads_count)}
      end
    end

    private

    def capacity_limit(capacity, limit, threads_count)
      if capacity && (limit.nil? || limit >= 0)
        if capacity < 0 || capacity >= 1.0
          limit = -1
        else
          capacity_limit = (capacity * threads_count).ceil
          limit = [limit, capacity_limit].compact.max
        end
      end

      limit
    end

    def count_processes
      process_counter = Counter.new(name: process_counter_name, redis: redis_client, ttl: 60)
      process_counter.track!(process_id)
      process_counter.value
    end

    def buckets_config
      if @config.respond_to?(:call)
        @config.call
      else
        @config
      end
    end

    def redis_client
      if @redis.is_a?(Proc)
        @redis.call
      else
        @redis
      end
    end

    def total_threads(process_count)
      threads_per_process = (@threads_per_process.respond_to?(:call) ? @threads_per_process.call : @threads_per_process).to_i
      threads_per_process = 1 if threads_per_process <= 0
      [process_count, 1].max * threads_per_process
    end

    def process_id
      "#{Socket.gethostname}:#{Process.pid}"
    end

    def process_counter_name
      "#{self.class.name}:#{@name}.processes"
    end

    def fetch_indifferent_key(hash, key)
      hash[key] || hash[key.to_s]
    end
  end
end
