# frozen_string_literal: true

module FaradayDynamicTimeout
  class Counter
    def initialize(name:, redis:, ttl: 60)
      @ttl = ttl.to_f
      @ttl = 60 if @ttl <= 0
      @redis = redis
      @key = "FaradayDynamicTimeout:#{name}"
    end

    def execute
      id = track!
      begin
        yield
      ensure
        release!(id)
      end
    end

    def value
      min_score = Time.now.to_f - @ttl
      active_count, total_count = @redis.multi do |transaction|
        transaction.zcount(@key, min_score, "+inf")
        transaction.zcard(@key)
      end

      if active_count != total_count
        @redis.zremrangebyscore(@key, "-inf", Time.now.to_f - @ttl)
      end

      active_count
    end

    def track!(id = nil)
      id ||= SecureRandom.hex
      @redis.multi do |transaction|
        transaction.zadd(@key, Time.now.to_f, id)
        transaction.pexpire(@key, @ttl * 1000)
      end
      id
    end

    def release!(id)
      @redis.zrem(@key, id)
    end
  end
end
