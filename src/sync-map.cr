require "sync/rw_lock"

# A thread-safe map (Hash) that is safe for concurrent use
# by multiple fibers without additional locking or coordination.
#
# The API mirrors Go's `sync.Map` with Crystal-idiomatic aliases.
#
# Uses Sync::RWLock(:unchecked) so read-only operations can proceed concurrently
# while writes stay exclusive. Safe because Sync::Map never upgrades locks and
# always properly pairs read/write lock and unlock operations.
#
# Upstream sources:
# - Go stdlib sync.Map: vendor/go/src/sync/map.go (Go 1.24+, HashTrieMap-backed)
# - xsync.Map: vendor/xsync/map.go (puzpuzpuz/xsync, CLHT-based)
class Sync::Map(K, V)
  include Enumerable({K, V})

  VERSION = "0.1.2"

  # Operations for the `compute` method, matching xsync.ComputeOp.
  enum ComputeOp
    Cancel = 0
    Update = 1
    Delete = 2
  end

  @hash = Hash(K, V).new
  @mu = Sync::RWLock.new(:unchecked)

  # Returns the zero/default value of type V.
  private def default_value : V
    v = uninitialized V
    v
  end

  private def read_sync(& : -> _)
    @mu.read { yield }
  end

  private def write_sync(& : -> _)
    @mu.write { yield }
  end

  def initialize
  end

  # Creates a new map initialized from a standard Hash.
  def self.new(hash : Hash(K, V))
    map = new
    hash.each { |k, v| map.store(k, v) }
    map
  end

  # --- Go sync.Map parity ---

  # Returns the value stored in the map for a key, or zero value if absent.
  # The ok result indicates whether value was found in the map.
  def load(key : K) : {V, Bool}
    read_sync { @hash[key]?.try { |v| {v, true} } || {default_value, false} }
  end

  # Sets the value for a key.
  def store(key : K, value : V) : Nil
    write_sync { @hash[key] = value }
  end

  # Deletes the value for a key. Does nothing if the key is absent.
  def delete(key : K) : Nil
    write_sync { @hash.delete(key) }
  end

  # Deletes all entries, resulting in an empty map.
  def clear : Nil
    write_sync { @hash.clear }
  end

  # Returns the existing value for the key if present.
  # Otherwise, stores and returns the given value.
  # The loaded result is true if the value was loaded, false if stored.
  def load_or_store(key : K, value : V) : {V, Bool}
    write_sync do
      if @hash.has_key?(key)
        {@hash[key], true}
      else
        @hash[key] = value
        {value, false}
      end
    end
  end

  # Deletes the value for a key, returning the previous value if any.
  # The loaded result reports whether the key was present.
  def load_and_delete(key : K) : {V, Bool}
    write_sync do
      if @hash.has_key?(key)
        value = @hash[key]
        @hash.delete(key)
        {value, true}
      else
        {default_value, false}
      end
    end
  end

  # Swaps the value for a key and returns the previous value if any.
  # The loaded result reports whether the key was present.
  # When the key is absent, stores the value and returns loaded=false.
  def swap(key : K, value : V) : {V, Bool}
    write_sync do
      if @hash.has_key?(key)
        previous = @hash[key]
        @hash[key] = value
        {previous, true}
      else
        @hash[key] = value
        {default_value, false}
      end
    end
  end

  # Swaps old and new values for key if the current value equals old.
  def compare_and_swap(key : K, old : V, new : V) : Bool
    write_sync do
      if @hash.has_key?(key) && @hash[key] == old
        @hash[key] = new
        true
      else
        false
      end
    end
  end

  # Deletes the entry for key if its value equals old.
  # If there is no current value for key, returns false.
  def compare_and_delete(key : K, old : V) : Bool
    write_sync do
      if @hash.has_key?(key) && @hash[key] == old
        @hash.delete(key)
        true
      else
        false
      end
    end
  end

  # Returns the number of entries in the map.
  def size : Int32
    read_sync { @hash.size }
  end

  # Returns true if the map is empty.
  def empty? : Bool
    read_sync { @hash.empty? }
  end

  # Returns true if the key is present.
  def has_key?(key : K) : Bool
    read_sync { @hash.has_key?(key) }
  end

  # Returns all keys.
  def keys : Array(K)
    read_sync { @hash.keys }
  end

  # Returns all values.
  def values : Array(V)
    read_sync { @hash.values }
  end

  # --- Crystal Hash parity ---

  # Returns true if the value is present.
  def has_value?(val : V) : Bool
    read_sync { @hash.has_value?(val) }
  end

  # Returns the key for the given value. Raises KeyError if absent.
  def key_for(value : V) : K
    read_sync { @hash.key_for(value) }
  end

  # Returns the key for value, or yields the value to the block if absent.
  def key_for(value : V, & : V -> K) : K
    read_sync { @hash.key_for(value) { |v| yield v } }
  end

  # Returns the key for the given value, or nil if absent.
  def key_for?(value : V) : K?
    read_sync { @hash.key_for?(value) }
  end

  # If the key is absent, stores the value and returns it.
  # If the key is present, returns the existing value.
  def put_if_absent(key : K, value : V) : V
    write_sync do
      if @hash.has_key?(key)
        @hash[key]
      else
        @hash[key] = value
        value
      end
    end
  end

  # If the key is absent, calls the block, stores the result, and returns it.
  # If the key is present, returns the existing value.
  def put_if_absent(key : K, & : K -> V) : V
    write_sync do
      if @hash.has_key?(key)
        @hash[key]
      else
        value = yield(key)
        @hash[key] = value
        value
      end
    end
  end

  # Removes and returns the first key-value pair. Raises IndexError if empty.
  def shift : {K, V}
    write_sync do
      if @hash.empty?
        raise IndexError.new("shift from empty map")
      end
      key = @hash.first_key
      value = @hash[key]
      @hash.delete(key)
      {key, value}
    end
  end

  # Removes and returns the first key-value pair, or nil if empty.
  def shift? : {K, V}?
    write_sync do
      if @hash.empty?
        nil
      else
        key = @hash.first_key
        value = @hash[key]
        @hash.delete(key)
        {key, value}
      end
    end
  end

  # Returns a shallow copy of the map.
  def dup : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each { |k, v| copy.unsafe_store(k, v) }
      copy
    end
  end

  # Merges entries from another Hash into this map, overwriting existing keys.
  def merge!(other : Hash(K, V)) : self
    write_sync do
      other.each { |k, v| @hash[k] = v }
    end
    self
  end

  # Returns a new map with entries for which the block returns true.
  def select(& : K, V -> _) : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, v) if yield(k, v)
      end
      copy
    end
  end

  # Returns a new map with entries for which the block returns false.
  def reject(& : K, V -> _) : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, v) unless yield(k, v)
      end
      copy
    end
  end

  # Returns the first key in the map.
  def first_key : K
    read_sync { @hash.first_key }
  end

  # Returns the first key, or nil if empty.
  def first_key? : K?
    read_sync { @hash.first_key? }
  end

  # Returns the last key in the map.
  def last_key : K
    read_sync { @hash.last_key }
  end

  # Returns the last key, or nil if empty.
  def last_key? : K?
    read_sync { @hash.last_key? }
  end

  # Returns the first value in the map.
  def first_value : V
    read_sync { @hash.first_value }
  end

  # Returns the first value, or nil if empty.
  def first_value? : V?
    read_sync { @hash.first_value? }
  end

  # Returns the last value in the map.
  def last_value : V
    read_sync { @hash.last_value }
  end

  # Returns the last value, or nil if empty.
  def last_value? : V?
    read_sync { @hash.last_value? }
  end

  # --- xsync extended API ---

  # Returns the existing value for the key if present,
  # while setting the new value for the key.
  # Stores the new value and returns the existing one if present.
  # The loaded result is true if the existing value was loaded.
  def load_and_store(key : K, value : V) : {V, Bool}
    write_sync do
      if @hash.has_key?(key)
        old = @hash[key]
        @hash[key] = value
        {old, true}
      else
        @hash[key] = value
        {default_value, false}
      end
    end
  end

  # Returns the existing value for the key if present.
  # Otherwise, computes the value using the provided block and stores it.
  # The block must return a {value, cancel} tuple.
  # If cancel is true, the key is not stored.
  # The loaded result is true if the value was loaded, false if computed.
  def load_or_compute(key : K, & : -> {V, Bool}) : {V, Bool}
    write_sync do
      if @hash.has_key?(key)
        {@hash[key], true}
      else
        value, cancel = yield
        if cancel
          {default_value, false}
        else
          @hash[key] = value
          {value, false}
        end
      end
    end
  end

  # Performs an atomic compute operation on the value for key.
  # The block receives (old_value, loaded) and returns {new_value, op}.
  # op is a ComputeOp: Update to set, Delete to remove, Cancel to do nothing.
  # Returns {actual, ok} where ok indicates the entry is present after the call.
  def compute(key : K, & : V, Bool -> {V, ComputeOp}) : {V, Bool}
    write_sync do
      if @hash.has_key?(key)
        old = @hash[key]
        newv, op = yield(old, true)
        case op
        in ComputeOp::Delete
          @hash.delete(key)
          {old, false}
        in ComputeOp::Update
          @hash[key] = newv
          {newv, true}
        in ComputeOp::Cancel
          {old, true}
        end
      else
        newv, op = yield(default_value, false)
        if op == ComputeOp::Update
          @hash[key] = newv
          {newv, true}
        else
          {default_value, false}
        end
      end
    end
  end

  # Deletes all entries for which the block returns {true, _}.
  # If the block returns {_, true}, iteration stops immediately.
  # Returns the number of deleted entries.
  def delete_matching(& : K, V -> {Bool, Bool}) : Int32
    total = 0
    write_sync do
      to_delete = [] of K
      @hash.each do |key, value|
        del, stop = yield(key, value)
        to_delete << key if del
        total += 1 if del
        break if stop
      end
      to_delete.each { |k| @hash.delete(k) }
    end
    total
  end

  # --- Crystal-idiomatic accessors ---

  # Returns value or raises KeyError.
  def [](key : K) : V
    read_sync { @hash[key] }
  end

  # Returns value or nil.
  def []?(key : K) : V?
    read_sync { @hash[key]? }
  end

  # Stores a value.
  def []=(key : K, value : V) : V
    write_sync { @hash[key] = value }
  end

  # Returns value for key or the given default.
  def fetch(key : K, default : V) : V
    read_sync { @hash.fetch(key, default) }
  end

  # Returns value for key or yields the key to the block if absent.
  def fetch(key : K, & : K -> V) : V
    read_sync { @hash.fetch(key) { |k| yield k } }
  end

  # Updates the existing value for key via the block. Raises KeyError if absent.
  def update(key : K, & : V -> V) : V
    write_sync do
      @hash[key] = yield @hash[key]
    end
  end

  # Traverses nested structures using #dig on each level. Raises on missing key.
  def dig(key : K, *subkeys)
    read_sync do
      if (value = @hash[key]) && value.responds_to?(:dig)
        value.dig(*subkeys)
      else
        raise KeyError.new "Map value not diggable for key: #{key.inspect}"
      end
    end
  end

  # Returns the value at key. Raises on missing key.
  def dig(key : K)
    read_sync { @hash[key] }
  end

  # Traverses nested structures using #dig? on each level. Returns nil on miss.
  def dig?(key : K, *subkeys)
    read_sync do
      if (value = @hash[key]?) && value.responds_to?(:dig?)
        value.dig?(*subkeys)
      end
    end
  end

  # Returns the value at key or nil.
  def dig?(key : K)
    read_sync { @hash[key]? }
  end

  # Unsafe store (no locking) for internal use during locked operations.
  protected def unsafe_store(key : K, value : V) : Nil
    @hash[key] = value
  end

  # --- More Crystal Hash parity ---

  # Iterates all keys.
  # Removes entries for which the block returns false.
  def select!(& : K, V -> _) : self
    write_sync { @hash.select! { |k, v| yield(k, v) } }
    self
  end

  # Removes entries for which the block returns true.
  def reject!(& : K, V -> _) : self
    write_sync { @hash.reject! { |k, v| yield(k, v) } }
    self
  end

  # Returns a new map with transformed keys.
  def transform_keys(& : K, V -> K) : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(yield(k, v), v)
      end
      copy
    end
  end

  # Returns a new map with transformed values.
  def transform_values(& : V, K -> V) : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, yield(v, k))
      end
      copy
    end
  end

  # Returns a new map containing entries from self and other.
  # Entries from other overwrite self's entries for duplicate keys.
  def merge(other : Hash(K, V)) : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each { |k, v| copy.unsafe_store(k, v) }
      other.each { |k, v| copy.unsafe_store(k, v) }
      copy
    end
  end

  # Returns a new map without nil values.
  def compact : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, v) unless v.nil?
      end
      copy
    end
  end

  # Removes nil values in place.
  def compact! : self
    write_sync { @hash.compact! }
    self
  end

  # Returns an Array of {K, V} tuples.
  def to_a : Array({K, V})
    read_sync { @hash.to_a }
  end

  # --- More Crystal Hash parity 2 ---

  # Returns a new map containing only the given keys.
  def select(keys : Enumerable(K)) : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      keys.each do |k|
        copy.unsafe_store(k, @hash[k]) if @hash.has_key?(k)
      end
      copy
    end
  end

  # Returns a new map containing only the given keys (varargs).
  def select(*keys : K) : Sync::Map(K, V)
    keys_set = keys.to_set
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, v) if keys_set.includes?(k)
      end
      copy
    end
  end

  # Returns a new map excluding the given keys.
  def reject(keys : Enumerable(K)) : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, v) unless keys.any? { |reject_key| reject_key == k }
      end
      copy
    end
  end

  # Returns a new map excluding the given keys (varargs).
  def reject(*keys : K) : Sync::Map(K, V)
    keys_set = keys.to_set
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, v) unless keys_set.includes?(k)
      end
      copy
    end
  end

  # Returns a new map with entries from self and other.
  # The block resolves conflicts: |key, old_val, new_val| -> resolved_val.
  def merge(other : Hash(K, V), & : K, V, V -> V) : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each { |k, v| copy.unsafe_store(k, v) }
      other.each do |k, v|
        if copy.has_key?(k)
          copy.unsafe_store(k, yield(k, copy.unsafe_fetch(k), v))
        else
          copy.unsafe_store(k, v)
        end
      end
      copy
    end
  end

  # Merges entries from other into self, with optional conflict resolution.
  def merge!(other : Hash(K, V), & : K, V, V -> V) : self
    write_sync do
      other.each do |k, v|
        if @hash.has_key?(k)
          @hash[k] = yield(k, @hash[k], v)
        else
          @hash[k] = v
        end
      end
    end
    self
  end

  # Transforms keys in place.
  def transform_keys!(& : K, V -> K) : self
    write_sync do
      new_entries = @hash.map { |k, v| {yield(k, v), v} }
      @hash.clear
      new_entries.each { |k, v| @hash[k] = v }
    end
    self
  end

  # Transforms values in place.
  def transform_values!(& : V, K -> V) : self
    write_sync do
      @hash.each do |k, v|
        @hash[k] = yield(v, k)
      end
    end
    self
  end

  # Returns a new map with keys and values swapped.
  def invert : Sync::Map(V, K)
    read_sync do
      copy = Sync::Map(V, K).new
      @hash.each do |k, v|
        if copy.has_key?(v)
          raise KeyError.new("Duplicate value in invert: #{v}")
        end
        copy.unsafe_store(v, k)
      end
      copy
    end
  end

  # Returns an array of values for the given keys. Raises KeyError on missing key.
  def values_at(*keys : K) : Array(V)
    read_sync { keys.map { |k| @hash[k] }.to_a }
  end

  # Returns a deep copy (clones values too).
  def clone : Sync::Map(K, V)
    read_sync do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, v.clone)
      end
      copy
    end
  end

  # Returns the underlying Hash representation (snapshot).
  def to_h : Hash(K, V)
    read_sync { @hash.dup }
  end

  # Unsafe fetch (no locking) for internal use during locked operations.
  protected def unsafe_fetch(key : K) : V
    @hash[key]
  end

  # --- Stats ---

  # Statistics for diagnostic purposes.
  struct Stats
    getter size : Int32
    getter capacity : Int32

    def initialize(@size : Int32, @capacity : Int32)
    end
  end

  # Returns statistics about the map. O(N) operation, for diagnostics only.
  def stats : Stats
    read_sync do
      Stats.new(@hash.size, @hash.size) # capacity = size for simple hash
    end
  end

  # --- Block-less iterators ---

  # Yields each key-value pair as {K, V} tuple (Enumerable contract).
  def each(& : {K, V} -> _) : Nil
    snapshot = read_sync { @hash.to_a }
    snapshot.each { |pair| yield pair }
  end

  # Without block, returns a snapshot iterator.
  def each : Iterator({K, V})
    entries = read_sync { @hash.to_a }
    entries.each
  end

  # Go sync.Map Range semantics: iterates entries, stops when block returns falsey.
  def range(& : K, V -> _) : Nil
    snapshot = read_sync { @hash.to_a }
    snapshot.each do |key, value|
      break unless yield(key, value)
    end
  end

  # Iterates all keys (snapshot-based).
  def each_key(& : K -> _) : Nil
    snapshot = read_sync { @hash.keys }
    snapshot.each { |k| yield k }
  end

  # Without block, returns an iterator over snapshot keys.
  def each_key : Iterator(K)
    keys = read_sync { @hash.keys }
    keys.each
  end

  # Iterates all values (snapshot-based).
  def each_value(& : V -> _) : Nil
    snapshot = read_sync { @hash.values }
    snapshot.each { |v| yield v }
  end

  # Without block, returns an iterator over snapshot values.
  def each_value : Iterator(V)
    vals = read_sync { @hash.values }
    vals.each
  end

  # --- In-place key-based filtering ---

  # Removes all entries except those with the given keys.
  def select!(*keys : K) : self
    keys_set = keys.to_set
    write_sync { @hash.select! { |k, _v| keys_set.includes?(k) } }
    self
  end

  # Removes entries with the given keys.
  def reject!(*keys : K) : self
    keys_set = keys.to_set
    write_sync { @hash.reject! { |k, _v| keys_set.includes?(k) } }
    self
  end
end
