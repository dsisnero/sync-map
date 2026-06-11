require "./spec_helper"
require "../src/sync-map/hash_trie_map"

describe Sync::HashTrieMap do
  it "loads missing key" do
    m = Sync::HashTrieMap(String, Int32).new
    _, ok = m.load("foo")
    ok.should be_false
  end

  it "stores and loads" do
    m = Sync::HashTrieMap(String, Int32).new
    m.store("foo", 42)
    v, ok = m.load("foo")
    ok.should be_true
    v.should eq(42)
  end

  it "overwrites" do
    m = Sync::HashTrieMap(String, Int32).new
    m.store("foo", 42)
    m.store("foo", 99)
    v, _ = m.load("foo")
    v.should eq(99)
  end

  it "deletes" do
    m = Sync::HashTrieMap(String, Int32).new
    m.store("foo", 42)
    m.delete("foo")
    _, ok = m.load("foo")
    ok.should be_false
  end

  it "load_and_delete" do
    m = Sync::HashTrieMap(String, Int32).new
    m.store("foo", 42)
    v, loaded = m.load_and_delete("foo")
    loaded.should be_true
    v.should eq(42)
    _, ok = m.load("foo")
    ok.should be_false
  end

  it "swap" do
    m = Sync::HashTrieMap(String, Int32).new
    m.store("foo", 42)
    old, loaded = m.swap("foo", 99)
    loaded.should be_true
    old.should eq(42)
    v, _ = m.load("foo")
    v.should eq(99)
  end

  it "compare_and_swap" do
    m = Sync::HashTrieMap(String, Int32).new
    m.store("foo", 42)
    m.compare_and_swap("foo", 42, 99).should be_true
    v, _ = m.load("foo")
    v.should eq(99)
    m.compare_and_swap("foo", 42, 100).should be_false
  end

  it "compare_and_delete" do
    m = Sync::HashTrieMap(String, Int32).new
    m.store("foo", 42)
    m.compare_and_delete("foo", 42).should be_true
    _, ok = m.load("foo")
    ok.should be_false
  end

  it "clear" do
    m = Sync::HashTrieMap(String, Int32).new
    m.store("a", 1)
    m.store("b", 2)
    m.clear
    _, ok = m.load("a")
    ok.should be_false
  end

  it "each" do
    m = Sync::HashTrieMap(String, Int32).new
    m.store("a", 1)
    m.store("b", 2)
    seen = {} of String => Int32
    m.each { |k, v| seen[k] = v }
    seen.size.should eq(2)
  end

  it "many keys" do
    m = Sync::HashTrieMap(Int32, Int32).new
    100.times { |i| m.store(i, i * 10) }
    100.times { |i| v, _ = m.load(i); v.should eq(i * 10) }
  end
end
