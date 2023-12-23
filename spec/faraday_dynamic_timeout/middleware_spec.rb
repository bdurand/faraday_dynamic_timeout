# frozen_s

require_relative "../spec_helper"

describe FaradayDynamicTimeout::Middleware do
  let(:default_timeouts) do
    {
      timeout: 5,
      open_timeout: 2,
      read_timeout: 3,
      write_timeout: 4
    }
  end

  let(:buckets) do
    [
      {timeout: 0.3, limit: 1},
      {timeout: 0.2, limit: 2}
    ].shuffle
  end

  def connection(options = {})
    Faraday.new do |faraday|
      faraday.options.timeout = default_timeouts[:timeout]
      faraday.options.open_timeout = default_timeouts[:open_timeout]
      faraday.options.read_timeout = default_timeouts[:read_timeout]
      faraday.options.write_timeout = default_timeouts[:write_timeout]
      faraday.use :dynamic_timeout, {redis: REDIS}.merge(options)
    end
  end

  let(:url) { "https://example.com/foobar" }

  describe "call" do
    it "gets the highest timeout by default" do
      stub_request(:get, url)
      2.times do
        response = connection(buckets: buckets).get(url)
        request = response.env.request
        expect(request.timeout).to eq(0.3)
        expect(request.open_timeout).to be_nil
        expect(request.read_timeout).to be_nil
        expect(request.write_timeout).to be_nil
      end
    end

    it "falls back to the next highest timeout if the highest one is throttled" do
      stub_request(:get, url)
        .to_return do
          sleep 0.2
          {status: 200}
        end
        .to_return(status: 200)

      thread = Thread.new { connection(buckets: buckets).get(url) }
      sleep 0.1

      response = connection(buckets: buckets).get(url)
      request = response.env.request
      expect(request.timeout).to eq(0.2)

      thread.value
    end

    it "raises an error if all buckets are throttled" do
      stub_request(:get, url)
        .to_return do
          sleep 0.2
          {status: 200}
        end.times(3)
        .to_return(status: 200)

      faraday = connection(buckets: buckets)

      threads = 3.times.collect do
        Thread.new { faraday.get(url) }
      end
      sleep(0.1)

      expect { faraday.get(url) }.to raise_error(Restrainer::ThrottledError)

      threads.each(&:value)
    end

    it "can use a proc that returns the bucket configuration" do
      stub_request(:get, url)
      response = connection(buckets: -> { buckets }).get(url)
      request = response.env.request
      expect(request.timeout).to eq(0.3)
    end

    it "will always use a timeout if the bucket has a negative limit" do
      stub_request(:get, url)
      response = connection(buckets: [{timeout: 1, limit: -1}]).get(url)
      request = response.env.request
      expect(request.timeout).to eq(1)
    end

    it "does not set a timeout if there are no buckets" do
      stub_request(:get, url)
      response = connection(buckets: []).get(url)
      request = response.env.request
      expect(request.timeout).to eq(default_timeouts[:timeout])
      expect(request.open_timeout).to eq(default_timeouts[:open_timeout])
      expect(request.read_timeout).to eq(default_timeouts[:read_timeout])
      expect(request.write_timeout).to eq(default_timeouts[:write_timeout])
    end

    it "sets a timeout if the filter returns true" do
      stub_request(:get, url)
      filter_proc = ->(env) { env.url.path.start_with?("/foo") }
      response = connection(buckets: buckets, filter: filter_proc).get(url)
      request = response.env.request
      expect(request.timeout).to eq(0.3)
    end

    it "does not set a timeout if the filter returns false" do
      stub_request(:get, url)
      filter_proc = ->(env) { env.url.path.start_with?("/timeout") }
      response = connection(buckets: buckets, filter: filter_proc).get(url)
      request = response.env.request
      expect(request.timeout).to eq(default_timeouts[:timeout])
    end

    it "uses a default redis connection if none is provided" do
      stub_request(:get, url)
      connection = Faraday.new { |faraday| faraday.use :dynamic_timeout, {buckets: buckets} }
      response = connection.get(url)
      request = response.env.request
      expect(request.timeout).to eq(0.3)
    end

    it "can pass the redis connection as a proc" do
      proc_called = false
      redis_proc = lambda do
        proc_called = true
        REDIS
      end
      stub_request(:get, url)
      response = connection(buckets: buckets, redis: redis_proc).get(url)
      request = response.env.request
      expect(request.timeout).to eq(0.3)
      expect(proc_called).to be(true)
    end

    it "does not set a timeout if the redis client is explicitly nil" do
      stub_request(:get, url)
      response = connection(buckets: buckets, redis: nil).get(url)
      request = response.env.request
      expect(request.timeout).to eq(default_timeouts[:timeout])
    end
  end

  describe "memoized buckets" do
    it "memoizes the buckets" do
      buckets = [{timeout: 0.2, limit: 1}]
      middleware = FaradayDynamicTimeout::Middleware.new(nil, buckets: buckets)
      sorted_buckets = middleware.send(:sorted_buckets)
      expect(middleware.send(:sorted_buckets).object_id).to eq(sorted_buckets.object_id)
      buckets << {timeout: 0.1, limit: 1}
      new_sorted_buckets = middleware.send(:sorted_buckets)
      expect(new_sorted_buckets.object_id).to_not eq(sorted_buckets.object_id)
      expect(new_sorted_buckets.last).to eq(sorted_buckets.last)
    end
  end

  describe "callback" do
    it "calls the callback with the request info on success" do
      stub_request(:get, url)

      request_info = nil
      callback_proc = ->(info) { request_info = info }
      connection(buckets: buckets, callback: callback_proc).get(url)

      expect(request_info).to be_a(FaradayDynamicTimeout::RequestInfo)
      expect(request_info.env.url.to_s).to eq(url)
      expect(request_info.duration).to be_a(Float)
      expect(request_info.timeout).to eq(0.3)
      expect(request_info.request_count).to eq(1)
      expect(request_info.error).to be_nil
    end

    it "calls the callback with the request info on failure" do
      error = StandardError.new("boom")
      stub_request(:get, url).to_raise(error)

      request_info = nil
      callback_proc = ->(info) { request_info = info }
      expect { connection(buckets: buckets, callback: callback_proc).get(url) }.to raise_error(error)

      expect(request_info).to be_a(FaradayDynamicTimeout::RequestInfo)
      expect(request_info.env.url.to_s).to eq(url)
      expect(request_info.duration).to be_a(Float)
      expect(request_info.timeout).to eq(0.3)
      expect(request_info.request_count).to eq(1)
      expect(request_info.error).to eq(error)
    end

    it "calls the callback with the request info on throttle error" do
      error = Restrainer::ThrottledError.new
      allow_any_instance_of(Restrainer).to receive(:throttle).and_raise(error)

      request_info = nil
      callback_proc = ->(info) { request_info = info }
      expect { connection(buckets: buckets, callback: callback_proc).get(url) }.to raise_error(FaradayDynamicTimeout::ThrottledError)

      expect(request_info).to be_a(FaradayDynamicTimeout::RequestInfo)
      expect(request_info.env.url.to_s).to eq(url)
      expect(request_info.duration).to be_a(Float)
      expect(request_info.timeout).to be_nil
      expect(request_info.error).to be_a(FaradayDynamicTimeout::ThrottledError)
      expect(request_info.error.request_count).to eq(buckets.sum { |b| b[:limit] } + 1)
    end
  end
end
