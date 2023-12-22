# frozen_string_literal: true

require "webmock/rspec"

require_relative "../lib/faraday_dynamic_timeout"

# This can be changed by setting the REDIS_URL environment variable.
Restrainer.redis = Redis.new

WebMock.disable_net_connect!(allow_localhost: false)

RSpec.configure do |config|
  config.run_all_when_everything_filtered = true
  config.filter_run :focus

  config.order = "random"

  config.before(:suite) do
    Restrainer.redis.flushdb
  end

  config.after(:each) do
    Restrainer.redis.flushdb
  end
end
