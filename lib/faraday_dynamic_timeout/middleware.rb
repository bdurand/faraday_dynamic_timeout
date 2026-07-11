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
    end

    def call(env)
      # A Redis outage must never take down HTTP traffic, so if building the bucket
      # configuration touches Redis (e.g. a capacity based strategy) and it is
      # unavailable, fail open and let the request through with no dynamic timeout.
      buckets = safe_redis { sorted_buckets }
      redis = redis_client
      return app.call(env) if !enabled?(env) || buckets.nil? || buckets.empty? || redis.nil?

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
      return memoized_buckets if config == memoized_config

      # Duplicate the config before storing it so a caller mutating the array or its
      # hashes cannot change the memoized snapshot out from under us. The memo is
      # published with a single assignment; concurrent threads may redundantly rebuild
      # it, which is harmless.
      config = config.collect(&:dup)
      buckets = Bucket.from_hashes(config)
      @memoized_buckets = [config, buckets]
      buckets
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
          restrainer = Restrainer.new(restrainer_name(uri, bucket.timeout), limit: bucket.limit, timeout: slot_ttl(bucket.timeout), redis: redis)
          begin
            # Acquire the slot explicitly rather than using Restrainer#throttle so that a
            # ThrottledError raised from within the request itself (e.g. from a nested
            # middleware) is not mistaken for this bucket being full, which would retry
            # the request on the next bucket and execute it a second time.
            process_id = restrainer.lock!
          rescue Restrainer::ThrottledError
            total_requests += bucket.limit
            if buckets.empty?
              # Since request_count is a snapshot before the request was started it is subject to
              # race conditions, so we'll make sure to report a higher number if we calculated one.
              request_count = [request_count, total_requests + 1].max
              raise ThrottledError.new("Request to #{base_url(uri)} aborted due to #{request_count} concurrent requests", request_count: request_count)
            end
          rescue Redis::BaseError
            # Redis is unavailable, so throttling cannot be enforced. Fail open using the
            # current (highest available) timeout rather than failing the request.
            retval = yield(bucket.timeout)
            break
          else
            begin
              retval = yield(bucket.timeout)
            ensure
              # Releasing the slot is best effort; if Redis is unavailable the slot will
              # expire on its own via the TTL. A cleanup failure must not mask the result
              # of a request that has already been made.
              safe_redis { restrainer.release!(process_id) }
            end
            break
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

    # The TTL used to clean up orphaned slot and counter entries in Redis. The bucket
    # timeout only bounds each phase of the request (open/read/write), not its total
    # wall time, so the TTL is padded to avoid expiring entries for requests that are
    # still legitimately in flight.
    def slot_ttl(timeout)
      [timeout * 3, 60].max
    end

    # Track how many requests are currently being executed only if a callback has been configured.
    #
    # Each Redis operation is guarded so that a Redis outage degrades to a pass through
    # (reporting a request count of 1) rather than blocking the request. The counter entry
    # is released on the way out, but only when it was successfully added.
    def count_request(uri, redis, buckets, callback)
      return yield(1) unless callback

      # The counter entry is added before a bucket has been selected, so the TTL must
      # conservatively cover the highest timeout (the last bucket); a shorter TTL could
      # expire entries for requests still legitimately in flight. The TTL only comes
      # into play for orphaned entries since entries are normally removed when the
      # request finishes.
      ttl = slot_ttl(buckets.last.timeout)
      request_counter = Counter.new(name: request_counter_name(uri), redis: redis, ttl: ttl)
      id = safe_redis { request_counter.track! }
      begin
        yield(safe_redis { request_counter.value } || 1)
      ensure
        safe_redis { request_counter.release!(id) } if id
      end
    end

    # Run a block that talks to Redis, returning nil instead of raising if the Redis
    # call fails for any reason. Used to keep Redis problems from taking down HTTP
    # traffic.
    def safe_redis
      yield
    rescue Redis::BaseError
      nil
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
