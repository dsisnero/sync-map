require "./spec_helper"
require "../src/sync-map/hash_trie_map"
require "../src/sync-map/xmap"

macro shared_contract(name, type)
  describe {{name}} do
    it "stores, overwrites, and deletes values" do
      m = {{type}}.new

      _, ok = m.load(7)
      ok.should be_false

      m.store(7, 11)
      value, ok = m.load(7)
      ok.should be_true
      value.should eq(11)

      m.store(7, 13)
      value, ok = m.load(7)
      ok.should be_true
      value.should eq(13)

      value, ok = m.load_and_delete(7)
      ok.should be_true
      value.should eq(13)

      _, ok = m.load(7)
      ok.should be_false
      m.size.should eq(0)
    end

    it "clears all entries" do
      m = {{type}}.new
      32.times { |i| m.store(i, i * 2) }

      m.clear

      m.size.should eq(0)
      32.times do |i|
        _, ok = m.load(i)
        ok.should be_false
      end
    end

    it "stores distinct keys concurrently" do
      m = {{type}}.new
      workers = 8
      per_worker = 128
      total = workers * per_worker
      done = Channel(Nil).new

      workers.times do |worker|
        spawn do
          base = worker * per_worker
          per_worker.times do |offset|
            key = base + offset
            m.store(key, key)
          end
          done.send(nil)
        end
      end

      workers.times { done.receive }

      m.size.should eq(total)
      total.times do |i|
        value, ok = m.load(i)
        ok.should be_true
        value.should eq(i)
      end
    end

    it "overwrites a hot key set concurrently" do
      m = {{type}}.new
      workers = 8
      hot_keys = 32
      updates_per_worker = 256
      done = Channel(Nil).new

      hot_keys.times { |key| m.store(key, -1) }

      workers.times do |worker|
        spawn do
          updates_per_worker.times do |i|
            key = i % hot_keys
            m.store(key, worker)
          end
          done.send(nil)
        end
      end

      workers.times { done.receive }

      m.size.should eq(hot_keys)
      hot_keys.times do |key|
        value, ok = m.load(key)
        ok.should be_true
        actual = value.as(Int32)
        actual.should be >= 0
        actual.should be < workers
      end
    end
  end
end

shared_contract "Sync::Map shared contract", Sync::Map(Int32, Int32)
shared_contract "Sync::HashTrieMap shared contract", Sync::HashTrieMap(Int32, Int32)
shared_contract "Sync::XMap shared contract", Sync::XMap(Int32, Int32)

macro shared_hash_sugar(name, type)
  describe {{name}} do
    it "[]= and []" do
      m = {{type}}.new
      m[1] = 10
      m[2] = 20
      m[1].should eq(10)
      m[2].should eq(20)
    end

    it "[]? returns nil for missing key" do
      m = {{type}}.new
      m[1] = 10
      m[1]?.should eq(10)
      m[2]?.should be_nil
    end

    it "has_key?" do
      m = {{type}}.new
      m[1] = 10
      m.has_key?(1).should be_true
      m.has_key?(2).should be_false
    end

    it "keys" do
      m = {{type}}.new
      m[1] = 10
      m[2] = 20
      ks = m.keys.sort
      ks.should eq([1, 2])
    end

    it "values" do
      m = {{type}}.new
      m[1] = 10
      m[2] = 20
      vs = m.values.sort
      vs.should eq([10, 20])
    end

    it "empty?" do
      m = {{type}}.new
      m.empty?.should be_true
      m[1] = 10
      m.empty?.should be_false
    end

    it "overwrites with []=" do
      m = {{type}}.new
      m[1] = 10
      m[1] = 99
      m[1].should eq(99)
    end

    it "[] raises KeyError on missing key" do
      m = {{type}}.new
      expect_raises(KeyError, "Missing hash key: 1") do
        m[1]
      end
    end
  end
end

shared_hash_sugar "Sync::Map hash sugar", Sync::Map(Int32, Int32)
shared_hash_sugar "Sync::HashTrieMap hash sugar", Sync::HashTrieMap(Int32, Int32)
shared_hash_sugar "Sync::XMap hash sugar", Sync::XMap(Int32, Int32)
