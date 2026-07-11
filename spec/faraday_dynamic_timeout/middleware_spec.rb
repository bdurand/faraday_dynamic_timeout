# frozen_string_literal: true

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

    it "does not treat a throttle error raised from within the request as a full bucket" do
      error = Restrainer::ThrottledError.new("downstream throttle")
      stub_request(:get, url).to_raise(error)

      expect { connection(buckets: buckets).get(url) }.to raise_error(Restrainer::ThrottledError, "downstream throttle")
      expect(a_request(:get, url)).to have_been_made.once
    end

    it "pads the restrainer timeout so slots are not expired while requests are in flight" do
      stub_request(:get, url)

      expect(Restrainer).to receive(:new).with(anything, hash_including(timeout: 60)).and_call_original
      connection(buckets: [{timeout: 0.3, limit: 1}]).get(url)

      expect(Restrainer).to receive(:new).with(anything, hash_including(timeout: 90)).and_call_original
      connection(buckets: [{timeout: 30, limit: 1}]).get(url)
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

  describe "redis outage" do
    it "makes the request with the highest timeout if the throttle cannot reach redis" do
      stub_request(:get, url)
      allow_any_instance_of(Restrainer).to receive(:lock!).and_raise(Redis::CannotConnectError.new("down"))

      response = connection(buckets: buckets).get(url)
      expect(response.status).to eq(200)
      expect(response.env.request.timeout).to eq(0.3)
      expect(a_request(:get, url)).to have_been_made.once
    end

    it "fails open on a redis command error, not just connection errors" do
      stub_request(:get, url)
      allow_any_instance_of(Restrainer).to receive(:lock!).and_raise(Redis::CommandError.new("OOM"))

      response = connection(buckets: buckets).get(url)
      expect(response.status).to eq(200)
      expect(response.env.request.timeout).to eq(0.3)
      expect(a_request(:get, url)).to have_been_made.once
    end

    it "makes the request and reports a count of 1 if the counter cannot reach redis" do
      stub_request(:get, url)
      allow_any_instance_of(FaradayDynamicTimeout::Counter).to receive(:track!).and_raise(Redis::CannotConnectError.new("down"))
      allow_any_instance_of(FaradayDynamicTimeout::Counter).to receive(:value).and_raise(Redis::CannotConnectError.new("down"))

      request_info = nil
      response = connection(buckets: buckets, callback: ->(info) { request_info = info }).get(url)
      expect(response.status).to eq(200)
      expect(a_request(:get, url)).to have_been_made.once
      expect(request_info.request_count).to eq(1)
    end

    it "passes the request through if building the bucket config cannot reach redis" do
      stub_request(:get, url)
      buckets_proc = -> { raise Redis::CannotConnectError.new("down") }

      response = connection(buckets: buckets_proc).get(url)
      expect(response.status).to eq(200)
      expect(response.env.request.timeout).to eq(default_timeouts[:timeout])
      expect(a_request(:get, url)).to have_been_made.once
    end

    it "does not let a redis failure while releasing the slot mask a successful response" do
      stub_request(:get, url)
      allow_any_instance_of(Restrainer).to receive(:release!).and_raise(Redis::CannotConnectError.new("down"))

      response = connection(buckets: buckets).get(url)
      expect(response.status).to eq(200)
      expect(a_request(:get, url)).to have_been_made.once
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

  describe "before_request" do
    it "calls the before_request proc before making the request" do
      stub_request(:post, url).with(query: {timeout: "0.3"})
      before_request_proc = ->(env, timeout) do
        env.request_headers["X-Test"] = timeout.to_s
        json = JSON.parse(env.body)
        json["timeout"] = timeout
        env.body = JSON.dump(json)
        query_params = Faraday::Utils.parse_query(env.url.query) || {}
        query_params["timeout"] = timeout
        env.url.query = Faraday::Utils.build_query(query_params)
      end
      response = connection(buckets: buckets, before_request: before_request_proc).post(url, JSON.generate(timeout: 5, foo: "bar"))
      expect(response.env.request_headers["X-Test"]).to eq("0.3")
      expect(JSON.parse(response.env.request_body)).to eq("timeout" => 0.3, "foo" => "bar")
      expect(response.env.url.query).to eq("timeout=0.3")
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

    it "pads the request counter ttl so in flight requests are not expired" do
      stub_request(:get, url)
      expect(FaradayDynamicTimeout::Counter).to receive(:new).with(hash_including(ttl: 60)).and_call_original
      connection(buckets: buckets, callback: ->(info) {}).get(url)
    end

    it "calls the callback with the request info on throttle error" do
      error = Restrainer::ThrottledError.new
      allow_any_instance_of(Restrainer).to receive(:lock!).and_raise(error)

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
