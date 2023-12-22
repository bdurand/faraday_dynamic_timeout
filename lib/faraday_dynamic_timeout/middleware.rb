# frozen_string_literal: true

module FaradayDynamicTimeout
  class Middleware < Faraday::Middleware
    def initialize(*)
      super
      @memoized_buckets = []
      @mutex = Mutex.new
    end

    def call(env)
      buckets = sorted_buckets
      redis = redis_client
      return app.call(env) if !enabled?(env) || buckets.empty? || redis.nil?

      process_count = count_processes(env.url, redis, buckets)
      threads_count = total_threads(process_count)

      execute_with_timeout(env.url, buckets, threads_count, redis) do |timeout|
        set_timeout(env.request, timeout) if timeout
        app.call(env)
      end
    end

    # Estimate the total number of threads available to all of the processes.
    # @param process_count [Integer] The number of processes.
    # @return [Integer] The total number of threads.
    # @api private
    def total_threads(process_count)
      process_count * options.fetch(:threads_per_process, 1).to_i
    end

    private

    # Return the valid buckets sorted by timeout.
    # @return [Array<Bucket>] The sorted buckets.
    # @api private
    def sorted_buckets
      config = options[:buckets]
      config = config.call if config.respond_to?(:call)
      config = Array(config)
      memoized_config, memoized_buckets = @memoized_buckets

      if config == memoized_config
        memoized_buckets
      else
        duplicated_config = @mutex.synchronize { config.collect(&:dup) }
        buckets = Bucket.from_hashes(duplicated_config)
        @memoized_buckets = [duplicated_config, buckets]
        buckets
      end
    end

    def enabled?(env)
      filter = options[:filter]
      if filter
        filter.call(env)
      else
        true
      end
    end

    def execute_with_timeout(uri, buckets, threads_count, redis)
      buckets = buckets.dup
      while (bucket = buckets.pop)
        if bucket.no_limit?
          retval = yield(bucket.timeout)
          break
        else
          limit = [bucket.limit, (bucket.capacity * threads_count).round].max
          restrainer = Restrainer.new(restrainer_name(uri, bucket.timeout), limit: limit, timeout: bucket.timeout, redis: redis)
          begin
            retval = restrainer.throttle { yield(bucket.timeout) }
            break
          rescue Restrainer::ThrottledError
            raise if buckets.empty?
          end
        end
      end

      retval
    end

    def set_timeout(request, timeout)
      request.timeout = timeout
      request.open_timeout = nil
      request.write_timeout = nil
      request.read_timeout = nil
    end

    def count_processes(uri, redis, buckets)
      process_ttl = buckets.last.timeout
      process_ttl = 60 if process_ttl <= 0
      process_counter = Counter.new(name: process_counter_name(uri), redis: redis, ttl: process_ttl)
      process_counter.track!(process_id)
      process_counter.value
    end

    def process_counter_name(uri)
      "#{redis_key_namespace(uri)}.processes"
    end

    def restrainer_name(uri, timeout)
      "#{redis_key_namespace(uri)}.#{timeout}"
    end

    def redis_key_namespace(uri)
      name = options[:name].to_s
      if name.empty?
        name = uri.host.downcase
        name = "#{name}:#{uri.port}" if uri.port != uri.default_port
      end
      "FaradayDynamicTimeout:#{name}"
    end

    def process_id
      "#{Socket.gethostname}:#{Process.pid}"
    end

    def redis_client
      redis = options[:redis]
      redis = redis.call if redis.is_a?(Proc)
      if redis.nil? && !options.include?(:redis)
        redis = Restrainer.redis
      end
      redis
    end
  end
end
