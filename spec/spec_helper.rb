# frozen_string_literal: true

require "webmock/rspec"

require_relative "../lib/faraday_dynamic_timeout"

WebMock.disable_net_connect!(allow_localhost: false)

REDIS = Redis.new(url: ENV["REDIS_URL"])

RSpec.configure do |config|
  config.run_all_when_everything_filtered = true
  config.filter_run :focus

  config.order = "random"

  config.before(:suite) do
    REDIS.flushdb
  end

  config.after(:each) do
    REDIS.flushdb
  end
end
