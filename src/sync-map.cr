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

  @hash = Hash(K, V).new
  @mu = ::Mutex.new

  # Creates a new empty Sync::Map.
  def initialize
  end

  # Returns the value stored in the map for a key, or nil if no
  # value is present. The ok result indicates whether value was found.
  def load(key : K) : {V, Bool}
    @mu.synchronize { @hash[key]?.try { |v| {v, true} } || {V.zero, false} }
  end

  # Sets the value for a key.
  def store(key : K, value : V) : Nil
    @mu.synchronize { @hash[key] = value }
  end

  # Deletes the value for a key. If the key is not in the map, does nothing.
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

  # Swaps old and new values for key if the value stored in the map is equal to old.
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

  # Crystal-idiomatic access: returns value or raises KeyError.
  def [](key : K) : V
    @mu.synchronize { @hash[key] }
  end

  # Crystal-idiomatic access: returns value or nil.
  def []?(key : K) : V?
    @mu.synchronize { @hash[key]? }
  end

  # Crystal-idiomatic store.
  def []=(key : K, value : V) : V
    @mu.synchronize { @hash[key] = value }
  end

  # Returns value for key or the given default.
  def fetch(key : K, default : V) : V
    @mu.synchronize { @hash.fetch(key, default) }
  end
end
