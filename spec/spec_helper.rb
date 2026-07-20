# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" if File.exist?(ENV["BUNDLE_GEMFILE"])

begin
  require "simplecov"
  SimpleCov.start do
    add_filter ["/spec/"]
  end
rescue LoadError
end

Bundler.require(:default, :test)

require "webmock/rspec"

require_relative "../lib/faraday_dynamic_timeout"

WebMock.disable_net_connect!(allow_localhost: false)

REDIS = Redis.new(url: ENV["REDIS_URL"])

RSpec.configure do |config|
  config.warnings = true
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed

  config.before(:suite) do
    REDIS.flushdb
  end

  config.after(:each) do
    REDIS.flushdb
  end
end
