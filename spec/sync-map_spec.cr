require "./spec_helper"

describe Sync::Map do
  describe "#new" do
    it "creates an empty map" do
      m = Sync::Map(String, Int32).new
      m.size.should eq(0)
      m.empty?.should be_true
    end
  end

  describe "#store and #load" do
    it "stores and loads a value" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      value, ok = m.load("foo")
      ok.should be_true
      value.should eq(42)
      m.size.should eq(1)
      m.empty?.should be_false
    end

    it "loads nil for missing key" do
      m = Sync::Map(String, Int32).new
      value, ok = m.load("missing")
      ok.should be_false
      value.should eq(0)
    end

    it "overwrites existing key" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      m.store("foo", 99)
      value, ok = m.load("foo")
      ok.should be_true
      value.should eq(99)
      m.size.should eq(1)
    end
  end

  describe "#[] and #[]=" do
    it "provides idiomatic access" do
      m = Sync::Map(String, Int32).new
      m["foo"] = 42
      m["foo"].should eq(42)
    end

    it "returns nil for missing key with #[]?" do
      m = Sync::Map(String, Int32).new
      m["missing"]?.should be_nil
    end

    it "raises on missing key with #[]" do
      m = Sync::Map(String, Int32).new
      expect_raises(KeyError) { m["missing"] }
    end

    it "fetch with default works" do
      m = Sync::Map(String, Int32).new
      m.fetch("missing", 99).should eq(99)
    end
  end

  describe "#delete" do
    it "deletes existing key" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      m.has_key?("foo").should be_true
      m.delete("foo")
      m.has_key?("foo").should be_false
      _, ok = m.load("foo")
      ok.should be_false
      m.size.should eq(0)
    end

    it "is no-op for missing key" do
      m = Sync::Map(String, Int32).new
      m.delete("missing")
      m.size.should eq(0)
    end
  end

  describe "#has_key?" do
    it "returns true for present key" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      m.has_key?("foo").should be_true
    end

    it "returns false for missing key" do
      m = Sync::Map(String, Int32).new
      m.has_key?("bar").should be_false
    end
  end

  describe "#clear" do
    it "removes all entries" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      m.size.should eq(3)
      m.clear
      m.size.should eq(0)
      m.empty?.should be_true
    end
  end

  describe "#load_or_store" do
    it "stores and returns new value when key missing" do
      m = Sync::Map(String, Int32).new
      actual, loaded = m.load_or_store("foo", 42)
      loaded.should be_false
      actual.should eq(42)
      m.size.should eq(1)
    end

    it "returns existing value when key present" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      actual, loaded = m.load_or_store("foo", 99)
      loaded.should be_true
      actual.should eq(42)
      m.size.should eq(1)
    end
  end

  describe "#load_and_delete" do
    it "deletes and returns value for existing key" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      value, loaded = m.load_and_delete("foo")
      loaded.should be_true
      value.should eq(42)
      m.has_key?("foo").should be_false
      m.size.should eq(0)
    end

    it "returns false for missing key" do
      m = Sync::Map(String, Int32).new
      _, loaded = m.load_and_delete("missing")
      loaded.should be_false
    end
  end

  describe "#swap" do
    it "swaps and returns old value" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      previous, loaded = m.swap("foo", 99)
      loaded.should be_true
      previous.should eq(42)
      v, _ = m.load("foo")
      v.should eq(99)
    end

    it "returns false and stores for missing key" do
      m = Sync::Map(String, Int32).new
      _, loaded = m.swap("foo", 99)
      loaded.should be_false
      v, _ = m.load("foo")
      v.should eq(99)
    end
  end

  describe "#compare_and_swap" do
    it "swaps when old value matches" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      swapped = m.compare_and_swap("foo", 42, 99)
      swapped.should be_true
      v, _ = m.load("foo")
      v.should eq(99)
    end

    it "does not swap when old value differs" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      swapped = m.compare_and_swap("foo", 77, 99)
      swapped.should be_false
      v, _ = m.load("foo")
      v.should eq(42)
    end

    it "fails on non-existing key per Go spec" do
      m = Sync::Map(String, Int32).new
      swapped = m.compare_and_swap("foo", 0, 42)
      swapped.should be_false
    end
  end

  describe "#compare_and_delete" do
    it "deletes when old value matches" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      deleted = m.compare_and_delete("foo", 42)
      deleted.should be_true
      m.has_key?("foo").should be_false
    end

    it "does not delete when old value differs" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      deleted = m.compare_and_delete("foo", 77)
      deleted.should be_false
      m.has_key?("foo").should be_true
    end

    it "fails on non-existing key" do
      m = Sync::Map(String, Int32).new
      deleted = m.compare_and_delete("missing", 0)
      deleted.should be_false
    end
  end

  describe "#each" do
    it "iterates all entries" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      seen = {} of String => Int32
      m.each do |k, v|
        seen[k] = v
      end
      seen.size.should eq(3)
      seen["a"].should eq(1)
      seen["b"].should eq(2)
      seen["c"].should eq(3)
    end

    it "stops when block returns false (Range semantics)" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      count = 0
      m.each do |_, _|
        count += 1
        false
      end
      count.should eq(1)
    end
  end

  describe "#keys and #values" do
    it "returns all keys" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      keys = m.keys
      keys.sort.should eq(["a", "b"])
    end

    it "returns all values" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      values = m.values
      values.sort.should eq([1, 2])
    end
  end

  describe "#size and #empty?" do
    it "tracks size correctly through mutations" do
      m = Sync::Map(String, Int32).new
      m.empty?.should be_true
      m.size.should eq(0)

      m.store("a", 1)
      m.size.should eq(1)
      m.empty?.should be_false

      m.store("b", 2)
      m.size.should eq(2)

      m.delete("a")
      m.size.should eq(1)

      m.clear
      m.size.should eq(0)
      m.empty?.should be_true
    end
  end
end
