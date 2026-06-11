require "mutex"

# A thread-safe map (Hash) that is safe for concurrent use
# by multiple fibers without additional locking or coordination.
#
# The API mirrors Go's `sync.Map` with Crystal-idiomatic aliases.
#
# Upstream sources:
# - Go stdlib sync.Map: vendor/go/src/sync/map.go (Go 1.24+, HashTrieMap-backed)
# - xsync.Map: vendor/xsync/map.go (puzpuzpuz/xsync, CLHT-based)
class Sync::Map(K, V)
  VERSION = "0.1.0"

  # Operations for the `compute` method, matching xsync.ComputeOp.
  enum ComputeOp
    Cancel = 0
    Update = 1
    Delete = 2
  end

  @hash = Hash(K, V).new
  @mu = ::Mutex.new

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
    @mu.synchronize { @hash[key]?.try { |v| {v, true} } || {V.zero, false} }
  end

  # Sets the value for a key.
  def store(key : K, value : V) : Nil
    @mu.synchronize { @hash[key] = value }
  end

  # Deletes the value for a key. Does nothing if the key is absent.
  def delete(key : K) : Nil
    @mu.synchronize { @hash.delete(key) }
  end

  # Deletes all entries, resulting in an empty map.
  def clear : Nil
    @mu.synchronize { @hash.clear }
  end

  # Returns the existing value for the key if present.
  # Otherwise, stores and returns the given value.
  # The loaded result is true if the value was loaded, false if stored.
  def load_or_store(key : K, value : V) : {V, Bool}
    @mu.synchronize do
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
    @mu.synchronize do
      if @hash.has_key?(key)
        value = @hash[key]
        @hash.delete(key)
        {value, true}
      else
        {V.zero, false}
      end
    end
  end

  # Swaps the value for a key and returns the previous value if any.
  # The loaded result reports whether the key was present.
  # When the key is absent, stores the value and returns loaded=false.
  def swap(key : K, value : V) : {V, Bool}
    @mu.synchronize do
      if @hash.has_key?(key)
        previous = @hash[key]
        @hash[key] = value
        {previous, true}
      else
        @hash[key] = value
        {V.zero, false}
      end
    end
  end

  # Swaps old and new values for key if the current value equals old.
  def compare_and_swap(key : K, old : V, new : V) : Bool
    @mu.synchronize do
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
    @mu.synchronize do
      if @hash.has_key?(key) && @hash[key] == old
        @hash.delete(key)
        true
      else
        false
      end
    end
  end

  # Calls the block for each key and value present in the map.
  # If the block returns a falsey value, the iteration stops.
  def each(& : K, V -> _) : Nil
    @mu.synchronize do
      @hash.each do |key, value|
        break unless yield(key, value)
      end
    end
  end

  # Returns the number of entries in the map.
  def size : Int32
    @mu.synchronize { @hash.size }
  end

  # Returns true if the map is empty.
  def empty? : Bool
    @mu.synchronize { @hash.empty? }
  end

  # Returns true if the key is present.
  def has_key?(key : K) : Bool
    @mu.synchronize { @hash.has_key?(key) }
  end

  # Returns all keys.
  def keys : Array(K)
    @mu.synchronize { @hash.keys }
  end

  # Returns all values.
  def values : Array(V)
    @mu.synchronize { @hash.values }
  end

  # --- Crystal Hash parity ---

  # Returns true if the value is present.
  def has_value?(val : V) : Bool
    @mu.synchronize { @hash.has_value?(val) }
  end

  # Returns the key for the given value. Raises KeyError if absent.
  def key_for(value : V) : K
    @mu.synchronize { @hash.key_for(value) }
  end

  # Returns the key for the given value, or nil if absent.
  def key_for?(value : V) : K?
    @mu.synchronize { @hash.key_for?(value) }
  end

  # If the key is absent, stores the value and returns it.
  # If the key is present, returns the existing value.
  def put_if_absent(key : K, value : V) : V
    @mu.synchronize do
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
    @mu.synchronize do
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
    @mu.synchronize do
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
    @mu.synchronize do
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
    @mu.synchronize do
      copy = Sync::Map(K, V).new
      @hash.each { |k, v| copy.unsafe_store(k, v) }
      copy
    end
  end

  # Merges entries from another Hash into this map, overwriting existing keys.
  def merge!(other : Hash(K, V)) : self
    @mu.synchronize do
      other.each { |k, v| @hash[k] = v }
    end
    self
  end

  # Returns a new map with entries for which the block returns true.
  def select(& : K, V -> _) : Sync::Map(K, V)
    @mu.synchronize do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, v) if yield(k, v)
      end
      copy
    end
  end

  # Returns a new map with entries for which the block returns false.
  def reject(& : K, V -> _) : Sync::Map(K, V)
    @mu.synchronize do
      copy = Sync::Map(K, V).new
      @hash.each do |k, v|
        copy.unsafe_store(k, v) unless yield(k, v)
      end
      copy
    end
  end

  # Returns the first key in the map.
  def first_key : K
    @mu.synchronize { @hash.first_key }
  end

  # Returns the first key, or nil if empty.
  def first_key? : K?
    @mu.synchronize { @hash.first_key? }
  end

  # Returns the last key in the map.
  def last_key : K
    @mu.synchronize { @hash.last_key }
  end

  # Returns the last key, or nil if empty.
  def last_key? : K?
    @mu.synchronize { @hash.last_key? }
  end

  # Returns the first value in the map.
  def first_value : V
    @mu.synchronize { @hash.first_value }
  end

  # Returns the first value, or nil if empty.
  def first_value? : V?
    @mu.synchronize { @hash.first_value? }
  end

  # Returns the last value in the map.
  def last_value : V
    @mu.synchronize { @hash.last_value }
  end

  # Returns the last value, or nil if empty.
  def last_value? : V?
    @mu.synchronize { @hash.last_value? }
  end

  # --- xsync extended API ---

  # Returns the existing value for the key if present,
  # while setting the new value for the key.
  # Stores the new value and returns the existing one if present.
  # The loaded result is true if the existing value was loaded.
  def load_and_store(key : K, value : V) : {V, Bool}
    @mu.synchronize do
      if @hash.has_key?(key)
        old = @hash[key]
        @hash[key] = value
        {old, true}
      else
        @hash[key] = value
        {V.zero, false}
      end
    end
  end

  # Returns the existing value for the key if present.
  # Otherwise, computes the value using the provided block and stores it.
  # The block must return a {value, cancel} tuple.
  # If cancel is true, the key is not stored.
  # The loaded result is true if the value was loaded, false if computed.
  def load_or_compute(key : K, & : -> {V, Bool}) : {V, Bool}
    @mu.synchronize do
      if @hash.has_key?(key)
        {@hash[key], true}
      else
        value, cancel = yield
        if cancel
          {V.zero, false}
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
    @mu.synchronize do
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
        newv, op = yield(V.zero, false)
        if op == ComputeOp::Update
          @hash[key] = newv
          {newv, true}
        else
          {V.zero, false}
        end
      end
    end
  end

  # Deletes all entries for which the block returns {true, _}.
  # If the block returns {_, true}, iteration stops immediately.
  # Returns the number of deleted entries.
  def delete_matching(& : K, V -> {Bool, Bool}) : Int32
    total = 0
    @mu.synchronize do
      @hash.each do |key, value|
        del, stop = yield(key, value)
        if del
          @hash.delete(key)
          total += 1
        end
        break if stop
      end
    end
    total
  end

  # --- Crystal-idiomatic accessors ---

  # Returns value or raises KeyError.
  def [](key : K) : V
    @mu.synchronize { @hash[key] }
  end

  # Returns value or nil.
  def []?(key : K) : V?
    @mu.synchronize { @hash[key]? }
  end

  # Stores a value.
  def []=(key : K, value : V) : V
    @mu.synchronize { @hash[key] = value }
  end

  # Returns value for key or the given default.
  def fetch(key : K, default : V) : V
    @mu.synchronize { @hash.fetch(key, default) }
  end

  # Unsafe store (no locking) for internal use during locked operations.
  protected def unsafe_store(key : K, value : V) : Nil
    @hash[key] = value
  end
end
