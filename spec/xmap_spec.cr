require "./spec_helper"
require "../src/sync-map/xmap"

describe Sync::XMap do
  it "loads missing key" do
    m = Sync::XMap(String, Int32).new
    _, ok = m.load("foo")
    ok.should be_false
  end

  it "stores and loads" do
    m = Sync::XMap(String, Int32).new
    m.store("foo", 42)
    v, ok = m.load("foo")
    ok.should be_true
    v.should eq(42)
  end

  it "overwrites existing key" do
    m = Sync::XMap(String, Int32).new
    m.store("foo", 42)
    m.store("foo", 99)
    v, _ = m.load("foo")
    v.should eq(99)
  end

  it "deletes" do
    m = Sync::XMap(String, Int32).new
    m.store("foo", 42)
    m.delete("foo")
    _, ok = m.load("foo")
    ok.should be_false
  end

  it "load_and_delete" do
    m = Sync::XMap(String, Int32).new
    m.store("foo", 42)
    v, loaded = m.load_and_delete("foo")
    loaded.should be_true
    v.should eq(42)
    _, ok = m.load("foo")
    ok.should be_false
  end

  it "clear" do
    m = Sync::XMap(String, Int32).new
    m.store("a", 1)
    m.store("b", 2)
    m.clear
    _, ok = m.load("a")
    ok.should be_false
    m.size.should eq(0)
  end

  it "tracks size" do
    m = Sync::XMap(String, Int32).new
    m.size.should eq(0)
    m.store("a", 1)
    m.size.should eq(1)
    m.store("b", 2)
    m.size.should eq(2)
    m.delete("a")
    m.size.should eq(1)
  end

  it "handles empty string key" do
    m = Sync::XMap(String, String).new
    m.store("", "foobar")
    v, ok = m.load("")
    ok.should be_true
    v.should eq("foobar")
  end

  it "each" do
    m = Sync::XMap(String, Int32).new
    m.store("a", 1)
    m.store("b", 2)
    seen = {} of String => Int32
    m.each { |k, v| seen[k] = v }
    seen.size.should eq(2)
    seen["a"].should eq(1)
  end

  it "many keys" do
    m = Sync::XMap(Int32, Int32).new
    500.times { |i| m.store(i, i * 10) }
    500.times { |i| v, _ = m.load(i); v.should eq(i * 10) }
  end

  it "handles deletes under load" do
    m = Sync::XMap(Int32, Int32).new
    200.times { |i| m.store(i, i) }
    50.times { |i| m.delete(i * 2) }
    200.times { |i|
      v, ok = m.load(i)
      if i.even? && i < 100
        ok.should be_false
      else
        ok.should be_true
        v.should eq(i)
      end
    }
  end
end
