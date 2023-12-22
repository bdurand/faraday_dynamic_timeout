# frozen_s

require_relative "../spec_helper"

describe FaradayDynamicTimeout::Counter do
  let(:counter) { FaradayDynamicTimeout::Counter.new(name: "test", redis: Restrainer.redis, ttl: 0.2) }

  it "tracks and releases a request" do
    expect(counter.value).to eq(0)
    id_1 = counter.track!
    expect(counter.value).to eq(1)
    id_2 = counter.track!
    expect(counter.value).to eq(2)
    counter.release!(id_1)
    expect(counter.value).to eq(1)
    counter.release!(id_2)
    expect(counter.value).to eq(0)
  end

  it "tracks and releases a request in an execute block" do
    expect(counter.value).to eq(0)
    counter.execute do
      expect(counter.value).to eq(1)
      counter.execute do
        expect(counter.value).to eq(2)
      end
      expect(counter.value).to eq(1)
    end
    expect(counter.value).to eq(0)
  end

  it "tracks and releases a request with a provided id" do
    expect(counter.value).to eq(0)
    id_1 = counter.track!("id_1")
    expect(counter.value).to eq(1)
    id_2 = counter.track!("id_2")
    expect(counter.value).to eq(2)
    counter.release!(id_1)
    expect(counter.value).to eq(1)
    counter.release!(id_2)
    expect(counter.value).to eq(0)
  end

  it "cleans up expired requests" do
    id_1 = counter.track!
    expect(counter.value).to eq(1)
    sleep(0.1)
    id_2 = counter.track!
    expect(counter.value).to eq(2)
    sleep(0.11)
    expect(counter.value).to eq(1)
    counter.release!(id_2)
    expect(counter.value).to eq(0)
  end
end
