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

  # --- Cycle 2a: Crystal Hash parity methods ---

  describe "#has_value?" do
    it "returns true when value exists" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      m.has_value?(42).should be_true
    end

    it "returns false for missing value" do
      m = Sync::Map(String, Int32).new
      m.has_value?(99).should be_false
    end
  end

  describe "#key_for" do
    it "returns key for existing value" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      m.key_for(42).should eq("foo")
    end

    it "raises on missing value" do
      m = Sync::Map(String, Int32).new
      expect_raises(KeyError) { m.key_for(99) }
    end
  end

  describe "#key_for?" do
    it "returns key for existing value" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      m.key_for?(42).should eq("foo")
    end

    it "returns nil for missing value" do
      m = Sync::Map(String, Int32).new
      m.key_for?(99).should be_nil
    end
  end

  describe "#put_if_absent" do
    it "stores when key missing" do
      m = Sync::Map(String, Int32).new
      m.put_if_absent("foo", 42).should eq(42)
      v, _ = m.load("foo")
      v.should eq(42)
    end

    it "returns existing value when key present" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      m.put_if_absent("foo", 99).should eq(42)
    end

    it "accepts a block for lazy default" do
      m = Sync::Map(String, Int32).new
      result = m.put_if_absent("foo") { 99 }
      result.should eq(99)
      v, _ = m.load("foo")
      v.should eq(99)
    end
  end

  describe "#shift" do
    it "removes and returns first key-value pair" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.shift
      m.size.should eq(1)
    end

    it "raises on empty map" do
      m = Sync::Map(String, Int32).new
      expect_raises(IndexError) { m.shift }
    end
  end

  describe "#shift?" do
    it "returns nil for empty map" do
      m = Sync::Map(String, Int32).new
      m.shift?.should be_nil
    end
  end

  describe "#dup" do
    it "creates a shallow copy" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      copy = m.dup
      copy.size.should eq(1)
      v, ok = copy.load("foo")
      ok.should be_true
      v.should eq(42)
    end

    it "is independent of original" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      copy = m.dup
      copy.store("bar", 99)
      copy.size.should eq(2)
      m.size.should eq(1)
    end
  end

  describe "#merge!" do
    it "merges another hash into the map" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.merge!({"b" => 2, "c" => 3})
      m.size.should eq(3)
      v, _ = m.load("b")
      v.should eq(2)
    end

    it "overwrites existing keys" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.merge!({"a" => 99})
      v, _ = m.load("a")
      v.should eq(99)
    end
  end

  describe "#select" do
    it "returns new map with matching entries" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      filtered = m.select { |_k, v| v > 1 }
      filtered.size.should eq(2)
    end
  end

  describe "#reject" do
    it "returns new map without matching entries" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      filtered = m.reject { |_k, v| v > 1 }
      filtered.size.should eq(1)
      v, ok = filtered.load("a")
      ok.should be_true
      v.should eq(1)
    end
  end

  describe "#first_key and #last_key" do
    it "returns first key" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.first_key.should be_a(String)
    end

    it "first_key? returns nil for empty" do
      m = Sync::Map(String, Int32).new
      m.first_key?.should be_nil
    end

    it "last_key works" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.last_key.should be_a(String)
    end

    it "last_key? returns nil for empty" do
      m = Sync::Map(String, Int32).new
      m.last_key?.should be_nil
    end
  end

  describe "#first_value and #last_value" do
    it "returns first value" do
      m = Sync::Map(String, Int32).new
      m.store("a", 42)
      m.first_value.should eq(42)
    end

    it "first_value? returns nil for empty" do
      m = Sync::Map(String, Int32).new
      m.first_value?.should be_nil
    end

    it "last_value works" do
      m = Sync::Map(String, Int32).new
      m.store("z", 99)
      m.last_value.should eq(99)
    end

    it "last_value? returns nil for empty" do
      m = Sync::Map(String, Int32).new
      m.last_value?.should be_nil
    end
  end

  # --- Cycle 2b: xsync extended API ---

  describe "#load_and_store" do
    it "stores and returns old value for existing key" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      actual, loaded = m.load_and_store("foo", 99)
      loaded.should be_true
      actual.should eq(42)
      v, _ = m.load("foo")
      v.should eq(99)
    end

    it "stores and returns false for new key" do
      m = Sync::Map(String, Int32).new
      _, loaded = m.load_and_store("foo", 99)
      loaded.should be_false
      v, _ = m.load("foo")
      v.should eq(99)
    end
  end

  describe "#load_or_compute" do
    it "returns existing value when present" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      value, loaded = m.load_or_compute("foo") { {99, false} }
      loaded.should be_true
      value.should eq(42)
    end

    it "computes and stores when absent" do
      m = Sync::Map(String, Int32).new
      value, loaded = m.load_or_compute("foo") { {42, false} }
      loaded.should be_false
      value.should eq(42)
      v, _ = m.load("foo")
      v.should eq(42)
    end

    it "cancels when block returns cancel=true" do
      m = Sync::Map(String, Int32).new
      value, loaded = m.load_or_compute("foo") { {0, true} }
      loaded.should be_false
      value.should eq(0)
      m.has_key?("foo").should be_false
    end
  end

  describe "#compute" do
    it "updates existing value" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      actual, ok = m.compute("foo") { |old, _loaded| {old * 2, Sync::Map::ComputeOp::Update} }
      ok.should be_true
      actual.should eq(84)
    end

    it "deletes when DeleteOp returned" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      _, ok = m.compute("foo") { |old, _loaded| {old, Sync::Map::ComputeOp::Delete} }
      ok.should be_false
      m.has_key?("foo").should be_false
    end

    it "cancels when CancelOp returned for absent key" do
      m = Sync::Map(String, Int32).new
      _, ok = m.compute("foo") { |_, _| {42, Sync::Map::ComputeOp::Cancel} }
      ok.should be_false
      m.has_key?("foo").should be_false
    end

    it "cancels when CancelOp returned for present key" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      actual, ok = m.compute("foo") { |old, _loaded| {old, Sync::Map::ComputeOp::Cancel} }
      ok.should be_true
      actual.should eq(42)
    end
  end

  describe "#delete_matching" do
    it "deletes matching entries and returns count" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      deleted = m.delete_matching { |_k, v| v > 1 ? {true, false} : {false, false} }
      deleted.should eq(2)
      m.size.should eq(1)
      m.has_key?("a").should be_true
      m.has_key?("b").should be_false
      m.has_key?("c").should be_false
    end

    it "stops when block returns stop=true" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      deleted = m.delete_matching { |_k, v| v >= 2 ? {true, true} : {false, false} }
      deleted.should eq(1)
    end
  end

  # --- Cycle 2c: Concurrency ---

  describe "concurrency" do
    it "handles concurrent stores and loads" do
      m = Sync::Map(Int32, Int32).new
      done = Channel(Nil).new

      10.times do |i|
        spawn do
          100.times { |j| m.store(i * 100 + j, i * 100 + j) }
          done.send(nil)
        end
      end
      10.times { done.receive }
      m.size.should eq(1000)
    end

    it "handles concurrent reads and writes" do
      m = Sync::Map(Int32, Int32).new
      (1..100).each { |i| m.store(i, i) }
      done = Channel(Nil).new

      10.times do
        spawn do
          100.times do
            m.store(rand(1..1000), rand(1..1000))
            _, _ = m.load(rand(1..1000))
            m.delete(rand(1..100))
          end
          done.send(nil)
        end
      end
      10.times { done.receive }
    end

    it "clear is safe with concurrent reads" do
      m = Sync::Map(Int32, Int32).new
      (1..100).each { |i| m.store(i, i) }
      done = Channel(Nil).new

      5.times do
        spawn do
          50.times { _, _ = m.load(rand(1..100)) }
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

    it "each is safe with concurrent modifications" do
      m = Sync::Map(Int32, Int32).new
      (1..1000).each { |i| m.store(i, i) }
      done = Channel(Nil).new

      spawn do
        m.each { |_k, _v| Fiber.yield }
        done.send(nil)
      end
      5.times do
        spawn do
          100.times { |i| m.store(i, i * 2) }
          done.send(nil)
        end
      end
      6.times { done.receive }
    end

    it "delete_matching is safe with concurrent stores" do
      m = Sync::Map(Int32, Int32).new
      (1..500).each { |i| m.store(i, i) }
      done = Channel(Nil).new

      spawn do
        m.delete_matching { |k, _v| k.even? ? {true, false} : {false, false} }
        done.send(nil)
      end
      5.times do
        spawn do
          100.times { |i| m.store(1000 + i, i) }
          done.send(nil)
        end
      end
      6.times { done.receive }
    end

    it "each_key/each_value iterate correctly under contention" do
      m = Sync::Map(Int32, Int32).new
      (1..100).each { |i| m.store(i, i) }
      done = Channel(Nil).new
      keys_ch = Channel(Array(Int32)).new

      spawn do
        keys = [] of Int32
        m.each_key { |k| keys << k }
        keys_ch.send(keys)
        done.send(nil)
      end
      spawn do
        50.times { m.delete(rand(1..100)) }
        50.times { m.store(rand(200..300), 42) }
        done.send(nil)
      end
      keys = keys_ch.receive
      done.receive
      keys.size.should be >= 50
    end
  end

  # --- Cycle 3: More Crystal Hash parity ---

  describe "#each_key and #each_value" do
    it "iterates all keys" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      keys = [] of String
      m.each_key { |k| keys << k }
      keys.sort.should eq(["a", "b"])
    end

    it "iterates all values" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      values = [] of Int32
      m.each_value { |v| values << v }
      values.sort.should eq([1, 2])
    end
  end

  describe "#select!" do
    it "keeps matching entries in place" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      m.select! { |_k, v| v > 1 }
      m.size.should eq(2)
      m.has_key?("a").should be_false
      m.has_key?("b").should be_true
    end
  end

  describe "#reject!" do
    it "removes matching entries in place" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      m.reject! { |_k, v| v > 1 }
      m.size.should eq(1)
      m.has_key?("a").should be_true
    end
  end

  describe "#transform_keys" do
    it "returns new map with transformed keys" do
      m = Sync::Map(String, Int32).new
      m.store("hello", 1)
      m.store("world", 2)
      result = m.transform_keys { |k, _v| k.upcase }
      result.has_key?("HELLO").should be_true
      result.has_key?("WORLD").should be_true
      result.size.should eq(2)
    end
  end

  describe "#transform_values" do
    it "returns new map with transformed values" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      result = m.transform_values { |v, _k| v * 10 }
      v, _ = result.load("a")
      v.should eq(10)
    end
  end

  describe "#merge" do
    it "returns new map with merged entries" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      result = m.merge({"b" => 2, "c" => 3})
      result.size.should eq(3)
      v, _ = result.load("a")
      v.should eq(1)
    end

    it "does not mutate original" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.merge({"b" => 2})
      m.size.should eq(1)
    end
  end

  describe "#compact" do
    it "returns new map without nil values" do
      m = Sync::Map(String, Int32?).new
      m.store("a", 1)
      m.store("b", nil)
      m.store("c", 3)
      result = m.compact
      result.size.should eq(2)
      result.has_key?("b").should be_false
    end
  end

  describe "#compact!" do
    it "removes nil values in place" do
      m = Sync::Map(String, Int32?).new
      m.store("a", 1)
      m.store("b", nil)
      m.compact!
      m.size.should eq(1)
      m.has_key?("b").should be_false
    end
  end

  describe "#to_a" do
    it "returns array of key-value tuples" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      arr = m.to_a
      arr.size.should eq(2)
      arr.should be_a(Array({String, Int32}))
    end
  end

  # --- Cycle 5: Remaining Crystal Hash parity ---

  describe "#select with keys" do
    it "returns new map with only given keys" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      result = m.select(["a", "c"])
      result.size.should eq(2)
      result.has_key?("a").should be_true
      result.has_key?("b").should be_false
      result.has_key?("c").should be_true
    end

    it "accepts varargs keys" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      result = m.select("a")
      result.size.should eq(1)
    end
  end

  describe "#reject with keys" do
    it "returns new map without given keys" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      result = m.reject(["a", "c"])
      result.size.should eq(1)
      result.has_key?("b").should be_true
    end
  end

  describe "#merge with block" do
    it "resolves conflicts via block" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      result = m.merge({"b" => 20, "c" => 30}) { |_k, v1, v2| v1 + v2 }
      v, _ = result.load("b")
      v.should eq(22)
    end
  end

  describe "#merge! with block" do
    it "resolves conflicts in place via block" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.merge!({"b" => 20, "c" => 30}) { |_k, v1, v2| v1 * v2 }
      v, _ = m.load("b")
      v.should eq(40)
      m.size.should eq(3)
    end

    it "works without block" do
      m = Sync::Map(String, Int32).new
      m.merge!({"a" => 1})
      m.size.should eq(1)
    end
  end

  describe "#transform_keys!" do
    it "transforms keys in place" do
      m = Sync::Map(String, Int32).new
      m.store("hello", 1)
      m.store("world", 2)
      m.transform_keys! { |k, _v| k.upcase }
      m.has_key?("HELLO").should be_true
      m.has_key?("hello").should be_false
    end
  end

  describe "#transform_values!" do
    it "transforms values in place" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.transform_values! { |v, _k| v * 10 }
      v, _ = m.load("a")
      v.should eq(10)
    end
  end

  describe "#invert" do
    it "swaps keys and values" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      result = m.invert
      result.size.should eq(2)
      v, _ = result.load(1)
      v.should eq("a")
    end

    it "raises on duplicate values" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 1)
      expect_raises(KeyError) { m.invert }
    end
  end

  describe "#values_at" do
    it "returns tuple of values for given keys" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      result = m.values_at("a", "c")
      result.should eq([1, 3])
    end

    it "raises on missing key" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      expect_raises(KeyError) { m.values_at("b") }
    end
  end

  describe "#clone" do
    it "creates a deep copy (values cloned too)" do
      m = Sync::Map(String, String).new
      m.store("foo", "bar")
      copy = m.clone
      copy.size.should eq(1)
      v, _ = copy.load("foo")
      v.should eq("bar")
      # Modifying copy does not affect original
      copy.store("foo", "baz")
      orig_v, _ = m.load("foo")
      orig_v.should eq("bar")
    end
  end

  describe "#to_h" do
    it "returns underlying hash representation" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      h = m.to_h
      h.should be_a(Hash(String, Int32))
      h["a"].should eq(1)
    end
  end

  # --- Cycle 6: Stats + block-less iterators ---

  describe "#stats" do
    it "returns statistics about the map" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      m.store("c", 3)
      stats = m.stats
      stats.size.should eq(3)
    end

    it "stats on empty map" do
      m = Sync::Map(String, Int32).new
      stats = m.stats
      stats.size.should eq(0)
    end
  end

  describe "block-less each returns Iterator" do
    it "each returns an iterator" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      m.store("b", 2)
      iter = m.each
      entries = iter.to_a
      entries.size.should eq(2)
    end

    it "each_key returns an iterator" do
      m = Sync::Map(String, Int32).new
      m.store("x", 1)
      iter = m.each_key
      iter.to_a.sort.should eq(["x"])
    end

    it "each_value returns an iterator" do
      m = Sync::Map(String, Int32).new
      m.store("x", 1)
      iter = m.each_value
      iter.to_a.should eq([1])
    end
  end

  # --- Cycle 7: fetch+block, update, dig, key_for+block ---

  describe "#fetch with block" do
    it "yields key when missing" do
      m = Sync::Map(String, Int32).new
      result = m.fetch("missing", &.size)
      result.should eq(7)
    end

    it "does not yield when key present" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      result = m.fetch("foo", &.size)
      result.should eq(42)
    end
  end

  describe "#update" do
    it "updates existing value via block" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      m.update("foo") { |v| v * 2 }
      val, _ = m.load("foo")
      val.should eq(84)
    end

    it "raises on missing key" do
      m = Sync::Map(String, Int32).new
      expect_raises(KeyError) { m.update("foo") { |v| v * 2 } }
    end
  end

  describe "#dig" do
    it "traverses nested maps" do
      inner = Sync::Map(String, Int32).new
      inner.store("b", 2)
      outer = Sync::Map(String, Sync::Map(String, Int32)).new
      outer.store("a", inner)
      outer.dig("a", "b").should eq(2)
    end

    it "raises on missing key in path" do
      m = Sync::Map(String, Int32).new
      m.store("a", 1)
      expect_raises(KeyError) { m.dig("b") }
    end
  end

  describe "#dig?" do
    it "returns value through nested path" do
      inner = Sync::Map(String, Int32).new
      inner.store("b", 2)
      outer = Sync::Map(String, Sync::Map(String, Int32)).new
      outer.store("a", inner)
      outer.dig?("a", "b").should eq(2)
    end

    it "returns nil on missing key in path" do
      m = Sync::Map(String, Int32).new
      m.dig?("missing").should be_nil
    end
  end

  describe "#key_for with block" do
    it "yields value when missing" do
      m = Sync::Map(String, Int32).new
      result = m.key_for(42) { |v| "default_for_#{v}" }
      result.should eq("default_for_42")
    end

    it "does not yield when value found" do
      m = Sync::Map(String, Int32).new
      m.store("foo", 42)
      m.key_for(42).should eq("foo")
    end
  end
end
