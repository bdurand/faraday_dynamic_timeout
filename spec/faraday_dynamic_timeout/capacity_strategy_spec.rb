# frozen_string_literal: true

require_relative "../spec_helper"

describe FaradayDynamicTimeout::CapacityStrategy do
  it "calculates the capacity based on the number of processes counted" do
    strategy = FaradayDynamicTimeout::CapacityStrategy.new(
      buckets: [{timeout: 1, capacity: 0.5}],
      redis: REDIS
    )

    # Stub 5 different process ids
    pid = Process.pid
    expect(strategy.call).to eq([{timeout: 1, limit: 1}])

    allow(Process).to receive(:pid).and_return(pid + 1)
    expect(strategy.call).to eq([{timeout: 1, limit: 1}])

    allow(Process).to receive(:pid).and_return(pid + 2)
    expect(strategy.call).to eq([{timeout: 1, limit: 2}])

    allow(Process).to receive(:pid).and_return(pid + 3)
    expect(strategy.call).to eq([{timeout: 1, limit: 2}])

    allow(Process).to receive(:pid).and_return(pid + 4)
    4.times { expect(strategy.call).to eq([{timeout: 1, limit: 3}]) }
  end

  it "calculates the capacity based on the number of threads per process" do
    strategy = FaradayDynamicTimeout::CapacityStrategy.new(
      buckets: [{timeout: 1, capacity: 0.5}],
      redis: REDIS,
      threads_per_process: 4
    )
    expect(strategy.call).to eq([{timeout: 1, limit: 2}])
  end

  it "uses the limit as a floor if it is greater than the capacity" do
    strategy = FaradayDynamicTimeout::CapacityStrategy.new(
      buckets: [{timeout: 1, capacity: 0.5, limit: 3}],
      redis: REDIS
    )
    expect(strategy.call).to eq([{timeout: 1, limit: 3}])
  end

  it "will choose a limit of -1 over the capacity limit" do
    strategy = FaradayDynamicTimeout::CapacityStrategy.new(
      buckets: [{timeout: 1, capacity: 0.5, limit: -1}],
      redis: REDIS
    )
    expect(strategy.call).to eq([{timeout: 1, limit: -1}])
  end

  it "will set a limit of -1 if the capacity is 1.0 or greater" do
    strategy = FaradayDynamicTimeout::CapacityStrategy.new(
      buckets: [{timeout: 1, limit: 5, capacity: 1.0}],
      redis: REDIS
    )
    expect(strategy.call).to eq([{timeout: 1, limit: -1}])
  end

  it "can pass the bucket config as a proc" do
    strategy = FaradayDynamicTimeout::CapacityStrategy.new(
      buckets: -> { [{timeout: 1, capacity: 0.5}] },
      redis: REDIS
    )
    expect(strategy.call).to eq([{timeout: 1, limit: 1}])
  end

  it "can pass the threads_per_process as a proc" do
    strategy = FaradayDynamicTimeout::CapacityStrategy.new(
      buckets: [{timeout: 1, capacity: 0.5}],
      redis: REDIS,
      threads_per_process: -> { 4 }
    )
    expect(strategy.call).to eq([{timeout: 1, limit: 2}])
  end
end
