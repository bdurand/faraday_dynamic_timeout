# frozen_s

require_relative "../spec_helper"

describe FaradayDynamicTimeout::RequestInfo do
  let(:uri) { URI("https://example.com") }
  let(:env) { double(Faraday::Env, method: :get, url: uri, status: 200) }
  let(:error) { nil }
  let(:request_info) { FaradayDynamicTimeout::RequestInfo.new(env: env, duration: 0.5, timeout: 1.5, request_count: 4, error: error) }

  describe "attributes" do
    it "has attributes" do
      expect(request_info.env).to eq(env)
      expect(request_info.duration).to eq(0.5)
      expect(request_info.timeout).to eq(1.5)
    end
  end

  describe "http_method" do
    it "gets the HTTP method" do
      expect(request_info.http_method).to eq(:get)
    end
  end

  describe "uri" do
    it "gets the URI" do
      expect(request_info.uri).to eq(uri)
    end
  end

  describe "status" do
    it "gets the response status code" do
      expect(request_info.status).to eq(200)
    end
  end

  context "where there is no error" do
    it "gets the request count from the attribute" do
      expect(request_info.request_count).to eq(4)
    end

    it "does not have an error" do
      expect(request_info.error?).to be(false)
    end

    it "is not throttled" do
      expect(request_info.throttled?).to be(false)
    end

    it "is not timed out" do
      expect(request_info.timed_out?).to be(false)
    end
  end

  context "when the request was throttled" do
    let(:error) { FaradayDynamicTimeout::ThrottledError.new("throttled", request_count: 5) }

    it "gets the request count from the error" do
      expect(request_info.request_count).to eq(5)
    end

    it "has an error" do
      expect(request_info.error?).to be(true)
    end

    it "is throttled" do
      expect(request_info.throttled?).to be(true)
    end

    it "is not timed out" do
      expect(request_info.timed_out?).to be(false)
    end
  end

  context "when the request timed out" do
    let(:error) { Faraday::TimeoutError.new("timed out") }

    it "gets the request count from the attribute" do
      expect(request_info.request_count).to eq(4)
    end

    it "has an error" do
      expect(request_info.error?).to be(true)
    end

    it "is not throttled" do
      expect(request_info.throttled?).to be(false)
    end

    it "is timed out" do
      expect(request_info.timed_out?).to be(true)
    end
  end
end
