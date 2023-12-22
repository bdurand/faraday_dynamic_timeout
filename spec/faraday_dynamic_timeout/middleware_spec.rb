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
      faraday.request :dynamic_timeout, {redis: Restrainer.redis}.merge(options)
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

    it "picks the higher of limit or capacity" do
      stub_request(:get, url)
        .to_return do
          sleep 0.2
          {status: 200}
        end
        .to_return(status: 200)

      buckets = [
        {timeout: 0.3, limit: 1, capacity: 0.1},
        {timeout: 0.2, limit: 2, capacity: 0.2}
      ]
      thread = Thread.new { connection(buckets: buckets).get(url) }
      sleep 0.1

      response = connection(buckets: buckets).get(url)
      request = response.env.request
      expect(request.timeout).to eq(0.2)

      thread.value
    end

    it "falls back based on total thread capacity" do
      stub_request(:get, url)
        .to_return(status: 200)
        .to_return do
          sleep 0.2
          {status: 200}
        end
        .to_return(status: 200)

      buckets = [
        {timeout: 0.3, capacity: 0.5},
        {timeout: 0.2, capacity: 0.5}
      ]
      faraday = connection(buckets: buckets)

      faraday.get(url)

      allow(Process).to receive(:pid).and_return(0)
      thread = Thread.new { faraday.get(url) }
      sleep 0.1

      response = faraday.get(url)
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

    it "will always use a timeout if the bucket has a 100% capacity" do
      stub_request(:get, url)
      response = connection(buckets: [{timeout: 1, capacity: 1.0}]).get(url)
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

    it "can pass the redis connection as a proc" do
      proc_called = false
      redis_proc = lambda do
        proc_called = true
        Restrainer.redis
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

  describe "total_threads" do
    it "will assume there is only one thread per process" do
      middleware = FaradayDynamicTimeout::Middleware.new(nil)
      expect(middleware.total_threads(10)).to eq(10)
    end

    it "will scale out the capacity based on the number of threads per process" do
      middleware = FaradayDynamicTimeout::Middleware.new(nil, threads_per_process: 2)
      expect(middleware.total_threads(10)).to eq(20)
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
end
