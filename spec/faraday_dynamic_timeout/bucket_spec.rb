# frozen_string_literal: true

require_relative "../spec_helper"

describe FaradayDynamicTimeout::Bucket do
  describe "no_limit?" do
    it "has a limit if the limit is not negative" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: 1)
      expect(bucket.no_limit?).to be(false)
    end

    it "has a limit if the capacity is not negative" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, capacity: 0.5)
      expect(bucket.no_limit?).to be(false)
    end

    it "has no limit if the limit is negative" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: -1, capacity: 1)
      expect(bucket).to be_no_limit
    end

    it "has no limit if the capacity is negative" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: 1, capacity: -1)
      expect(bucket).to be_no_limit
    end

    it "has no limit if the capacity is greater than or equal to 1.0" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: 1, capacity: 1.0)
      expect(bucket).to be_no_limit
    end
  end

  describe "valid?" do
    it "is valid if the timeout is positive and the limit is positive" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: 1)
      expect(bucket).to be_valid
    end

    it "is valid if the timeout is positive and the limit is negative" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: -1)
      expect(bucket).to be_valid
    end

    it "is valid if the timeout is positive and the capacity is positive" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, capacity: 0.5)
      expect(bucket).to be_valid
    end

    it "is valid if the timeout is positive and the capacity is negative" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, capacity: -1)
      expect(bucket).to be_valid
    end

    it "is not valid if the timeout is not positive" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 0, limit: 1)
      expect(bucket).not_to be_valid
    end

    it "is not valid if the limit and capacity are both zero" do
      bucket = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: 0, capacity: 0)
      expect(bucket).not_to be_valid
    end
  end

  describe "merge" do
    it "inherits a no limit limit if either bucket has no limit" do
      bucket_1 = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: 1)
      bucket_2 = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: -1)
      expect(bucket_1.merge(bucket_2)).to be_no_limit
      expect(bucket_2.merge(bucket_1)).to be_no_limit
    end

    it "inherits a no limit capacity if either bucket has no limit" do
      bucket_1 = FaradayDynamicTimeout::Bucket.new(timeout: 1, capacity: 0.5)
      bucket_2 = FaradayDynamicTimeout::Bucket.new(timeout: 1, capacity: -1)
      expect(bucket_1.merge(bucket_2)).to be_no_limit
      expect(bucket_2.merge(bucket_1)).to be_no_limit
    end

    it "combines the limits if both buckets have a limit" do
      bucket_1 = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: 1)
      bucket_2 = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: 2)
      expect(bucket_1.merge(bucket_2).limit).to eq(3)
      expect(bucket_2.merge(bucket_1).limit).to eq(3)
    end

    it "combines the capacities if both buckets have a capacity" do
      bucket_1 = FaradayDynamicTimeout::Bucket.new(timeout: 1, capacity: 0.5)
      bucket_2 = FaradayDynamicTimeout::Bucket.new(timeout: 1, capacity: 0.4)
      expect(bucket_1.merge(bucket_2).capacity).to eq(0.9)
      expect(bucket_2.merge(bucket_1).capacity).to eq(0.9)
    end

    it "uses the larger timeout" do
      bucket_1 = FaradayDynamicTimeout::Bucket.new(timeout: 1, limit: 1)
      bucket_2 = FaradayDynamicTimeout::Bucket.new(timeout: 2, limit: 1)
      expect(bucket_1.merge(bucket_2).timeout).to eq(2)
      expect(bucket_2.merge(bucket_1).timeout).to eq(2)
    end
  end

  describe "from_hashes" do
    it "returns buckets in sorted order by timeout" do
      hashes = [{timeout: 2, limit: 1}, {timeout: 0.5, limit: 1}, {timeout: 1, limit: 1}]
      buckets = FaradayDynamicTimeout::Bucket.from_hashes(hashes)
      expect(buckets.map(&:timeout)).to eq([0.5, 1, 2])
    end

    it "will not use a bucket if the limit and capacity are both zero" do
      buckets = FaradayDynamicTimeout::Bucket.from_hashes([{timeout: 1, limit: 0, capacity: 0}])
      expect(buckets).to eq([])
    end

    it "ignores buckets with a non-positive timeout" do
      buckets = FaradayDynamicTimeout::Bucket.from_hashes([{timeout: 0, limit: 1}])
      expect(buckets).to eq([])
    end

    it "merges buckets with the same timeout" do
      hashes = [{timeout: 1, limit: 1}, {timeout: 1, limit: 2}, {timeout: 2, limit: 4}]
      buckets = FaradayDynamicTimeout::Bucket.from_hashes(hashes)
      expect(buckets.collect { |b| [b.timeout, b.limit] }).to eq([[1, 3], [2, 4]])
    end
  end
end
