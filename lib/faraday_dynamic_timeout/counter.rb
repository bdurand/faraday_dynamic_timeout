# frozen_string_literal: true

module FaradayDynamicTimeout
  class Counter
    def initialize(name:, redis:, ttl: 60.0)
      @ttl = ttl.to_f
      @ttl = 60.0 if @ttl <= 0.0
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
      total_count, expired_count = @redis.multi do |transaction|
        transaction.zcard(@key)
        transaction.zremrangebyscore(@key, "-inf", Time.now.to_f - @ttl)
      end

      total_count - expired_count
    end

    def track!(id = nil)
      id ||= SecureRandom.hex
      @redis.multi do |transaction|
        transaction.zadd(@key, Time.now.to_f, id)
        transaction.pexpire(@key, (@ttl * 1000).round)
      end
      id
    end

    def release!(id)
      @redis.zrem(@key, id)
    end
  end
end
