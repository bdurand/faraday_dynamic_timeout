# frozen_string_literal: true

module FaradayDynamicTimeout
  class Middleware < Faraday::Middleware
    def initialize(*)
      super

      @redis_client = option(:redis)
      if @redis_client.nil? && !(options.include?(:redis) || options.include?("redis"))
        @redis_client = Redis.new
      end

      @memoized_buckets = []
      @mutex = Mutex.new
    end

    def call(env)
      buckets = sorted_buckets
      redis = redis_client
      return app.call(env) if !enabled?(env) || buckets.empty? || redis.nil?

      error = nil
      bucket_timeout = nil
      callback = option(:callback)
      start_time = monotonic_time if callback

      count_request(env.url, redis, buckets, callback) do |request_count|
        execute_with_timeout(env.url, buckets, request_count, redis) do |timeout|
          bucket_timeout = timeout
          set_timeout(env, timeout) if timeout

          # Resetting the start time to more accurately reflect the time spent in the request.
          start_time = monotonic_time if callback
          app.call(env)
        end
      rescue => e
        error = e
        raise
      ensure
        if callback
          duration = monotonic_time - start_time
          request_info = RequestInfo.new(env: env, duration: duration, timeout: bucket_timeout, request_count: request_count, error: error)
          callback.call(request_info)
        end
      end
    end

    private

    # Return the valid buckets sorted by timeout.
    # @return [Array<Bucket>] The sorted buckets.
    # @api private
    def sorted_buckets
      config = option(:buckets)
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
      filter = option(:filter)
      if filter
        filter.call(env)
      else
        true
      end
    end

    def execute_with_timeout(uri, buckets, request_count, redis)
      buckets = buckets.dup
      total_requests = 0

      while (bucket = buckets.pop)
        if bucket.no_limit?
          retval = yield(bucket.timeout)
          break
        else
          restrainer = Restrainer.new(restrainer_name(uri, bucket.timeout), limit: bucket.limit, timeout: bucket.timeout, redis: redis)
          begin
            retval = restrainer.throttle { yield(bucket.timeout) }
            break
          rescue Restrainer::ThrottledError
            total_requests += bucket.limit
            if buckets.empty?
              # Since request_count is a snapshot before the request was started it is subject to
              # race conditions, so we'll make sure to report a higher number if we calculated one.
              request_count = [request_count, total_requests + 1].max
              raise ThrottledError.new("Request to #{base_url(uri)} aborted due to #{request_count} concurrent requests", request_count: request_count)
            end
          end
        end
      end

      retval
    end

    def set_timeout(env, timeout)
      request = env.request
      request.timeout = timeout
      request.open_timeout = nil
      request.write_timeout = nil
      request.read_timeout = nil

      option(:before_request)&.call(env, timeout)
    end

    # Track how many requests are currently being executed only if a callback has been configured.
    def count_request(uri, redis, buckets, callback)
      if callback
        ttl = buckets.last.timeout
        ttl = 60 if ttl <= 0
        request_counter = Counter.new(name: request_counter_name(uri), redis: redis, ttl: ttl)
        request_counter.execute do
          yield request_counter.value
        end
      else
        yield 1
      end
    end

    def request_counter_name(uri)
      "#{redis_key_namespace(uri)}.requests"
    end

    def restrainer_name(uri, timeout)
      "#{redis_key_namespace(uri)}.#{timeout}"
    end

    def redis_key_namespace(uri)
      name = option(:name).to_s
      name = base_url(uri) if name.empty?
      "FaradayDynamicTimeout:#{name}"
    end

    def base_url(uri)
      url = "#{uri.scheme}://#{uri.host.downcase}"
      url = "#{url}:#{uri.port}" unless uri.port == uri.default_port
      url
    end

    def redis_client
      redis = option(:redis) || @redis_client
      redis = redis.call if redis.is_a?(Proc)
      redis
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def option(key)
      options[key] || options[key.to_s]
    end
  end
end
