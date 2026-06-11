require "./spec_helper"
require "../src/sync-map/hash_trie_map"

describe Sync::HashTrieMap do
  describe "#load" do
    it "returns false for missing key" do
      m = Sync::HashTrieMap(String, Int32).new
      _, ok = m.load("foo")
      ok.should be_false
    end

    it "returns value for stored key" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      v, ok = m.load("foo")
      ok.should be_true
      v.should eq(42)
    end
  end

  describe "#store and #swap" do
    it "store sets value" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      v, _ = m.load("foo")
      v.should eq(42)
    end

    it "store overwrites" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      m.store("foo", 99)
      v, _ = m.load("foo")
      v.should eq(99)
    end

    it "swap returns old value" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      old, loaded = m.swap("foo", 99)
      loaded.should be_true
      old.should eq(42)
      v, _ = m.load("foo")
      v.should eq(99)
    end

    it "swap on new key stores and returns false" do
      m = Sync::HashTrieMap(String, Int32).new
      _, loaded = m.swap("foo", 99)
      loaded.should be_false
      v, _ = m.load("foo")
      v.should eq(99)
    end
  end

  describe "#load_or_store" do
    it "stores and returns given value when key missing" do
      m = Sync::HashTrieMap(String, Int32).new
      v, loaded = m.load_or_store("foo", 42)
      loaded.should be_false
      v.should eq(42)
    end

    it "returns existing value when key present" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      v, loaded = m.load_or_store("foo", 99)
      loaded.should be_true
      v.should eq(42)
    end

    it "many keys" do
      m = Sync::HashTrieMap(String, Int32).new
      data = (0..99).map { |i| {"key_#{i}", i} }
      data.each do |k, v|
        m.load(k)[1].should be_false
        _, loaded = m.load_or_store(k, v)
        loaded.should be_false
        v2, ok = m.load(k)
        ok.should be_true
        v2.should eq(v)
        _, loaded2 = m.load_or_store(k, 0)
        loaded2.should be_true
      end
      data.each do |k, v|
        v2, ok = m.load(k)
        ok.should be_true
        v2.should eq(v)
        _, loaded = m.load_or_store(k, 0)
        loaded.should be_true
      end
    end
  end

  describe "#delete and #load_and_delete" do
    it "delete removes key" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      m.delete("foo")
      _, ok = m.load("foo")
      ok.should be_false
    end

    it "delete missing key is no-op" do
      m = Sync::HashTrieMap(String, Int32).new
      m.delete("missing")
      _, ok = m.load("missing")
      ok.should be_false
    end

    it "load_and_delete returns old value" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      v, loaded = m.load_and_delete("foo")
      loaded.should be_true
      v.should eq(42)
      _, ok = m.load("foo")
      ok.should be_false
    end

    it "load_and_delete missing key" do
      m = Sync::HashTrieMap(String, Int32).new
      _, loaded = m.load_and_delete("missing")
      loaded.should be_false
    end
  end

  describe "#compare_and_swap" do
    it "swaps when old matches" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      m.compare_and_swap("foo", 42, 99).should be_true
      v, _ = m.load("foo")
      v.should eq(99)
    end

    it "fails when old differs" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      m.compare_and_swap("foo", 77, 99).should be_false
      v, _ = m.load("foo")
      v.should eq(42)
    end

    it "fails on missing key" do
      m = Sync::HashTrieMap(String, Int32).new
      m.compare_and_swap("foo", 0, 42).should be_false
    end
  end

  describe "#compare_and_delete" do
    it "deletes when old matches" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      m.compare_and_delete("foo", 42).should be_true
      _, ok = m.load("foo")
      ok.should be_false
    end

    it "fails when old differs" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("foo", 42)
      m.compare_and_delete("foo", 77).should be_false
      _, ok = m.load("foo")
      ok.should be_true
    end

    it "fails on missing key" do
      m = Sync::HashTrieMap(String, Int32).new
      m.compare_and_delete("missing", 0).should be_false
    end
  end

  describe "#clear" do
    it "removes all entries" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      m.clear
      _, ok = m.load("a")
      ok.should be_false
      _, ok = m.load("b")
      ok.should be_false
    end

    it "allows re-insert after clear" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("a", 1)
      m.clear
      m.store("a", 42)
      v, _ = m.load("a")
      v.should eq(42)
    end
  end

  describe "#each" do
    it "iterates all entries" do
      m = Sync::HashTrieMap(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      seen = {} of String => Int32
      m.each { |k, v| seen[k] = v }
      seen.size.should eq(3)
      seen["a"].should eq(1)
    end

    it "empty map iterates nothing" do
      m = Sync::HashTrieMap(String, Int32).new
      count = 0
      m.each { |_, _| count += 1 }
      count.should eq(0)
    end
  end

  describe "hash collisions" do
    it "handles same-hash keys via overflow chain" do
      m = Sync::HashTrieMap(String, Int32).new
      # Store many keys — some will collide
      100.times do |i|
        m.store("key_#{i}", i)
      end
      100.times do |i|
        v, ok = m.load("key_#{i}")
        ok.should be_true
        v.should eq(i)
      end
    end

    it "delete from collision chain" do
      m = Sync::HashTrieMap(String, Int32).new
      50.times { |i| m.store("key_#{i}", i) }
      m.delete("key_25")
      _, ok = m.load("key_25")
      ok.should be_false
      # Other keys still present
      v, ok = m.load("key_24")
      ok.should be_true
      v.should eq(24)
    end
  end

  describe "concurrency" do
    it "concurrent stores and loads" do
      m = Sync::HashTrieMap(Int32, Int32).new
      done = Channel(Nil).new
      10.times do |t|
        spawn do
          100.times { |i| m.store(t * 100 + i, t * 100 + i) }
          done.send(nil)
        end
      end
      10.times { done.receive }
      1000.times { |i| v, _ = m.load(i); v.should eq(i) }
    end

    it "concurrent load_or_store" do
      m = Sync::HashTrieMap(Int32, Int32).new
      done = Channel(Nil).new
      10.times do |t|
        spawn do
          100.times { |i| m.load_or_store(t * 100 + i, i) }
          done.send(nil)
        end
      end
      10.times { done.receive }
      1000.times { |i| _, ok = m.load(i); ok.should be_true }
    end

    it "clear is safe with concurrent reads" do
      m = Sync::HashTrieMap(Int32, Int32).new
      (1..100).each { |i| m.store(i, i) }
      done = Channel(Nil).new
      5.times do
        spawn do
          50.times { m.load(rand(1..100)) }
          done.send(nil)
        end
      end
      5.times do
        spawn do
          m.clear
          done.send(nil)
        end
      end
      10.times { done.receive }
    end
  end
end
