# Concurrent hash-trie map. Unified-node design from lucaong/immutable.
# 32-way branching, lock-free reads, per-node mutex writes.
# Levels INCREASE with depth: 0=root, leaf at max depth where entries live.
# A leaf holds entries whose hashes share the same bits at all levels above.
require "sync/mutex"

class Sync::HashTrieMap(K, V)
  BITS = 5_u32; SIZE = 32; MASK      = SIZE - 1
  MAX_DEPTH =  2

  private class EntriesBox(K, V)
    getter entries : Array({K, V})

    def initialize(@entries : Array({K, V}))
    end
  end

  private class Node(K, V)
    getter mu = Sync::Mutex.new(:unchecked)
    @children : StaticArray(Atomic(Pointer(Void)), SIZE)
    property levels : Int32 # depth from root: 0=root, 1=child, ... MAX_DEPTH=leaf
    @entries : Atomic(Pointer(Void))

    def initialize(@levels : Int32)
      @children = StaticArray(Atomic(Pointer(Void)), SIZE).new { Atomic(Pointer(Void)).new(Pointer(Void).null) }
      @entries = Atomic(Pointer(Void)).new(EntriesBox(K, V).new([] of {K, V}).as(Void*))
    end

    def leaf?
      @levels >= MAX_DEPTH
    end

    def load_child(idx : Int32) : Pointer(Void)
      @children[idx].get(:acquire)
    end

    def store_child(idx : Int32, ptr : Pointer(Void))
      @children[idx] = Atomic(Pointer(Void)).new(ptr)
    end

    def load_entries : Array({K, V})
      @entries.get(:acquire).as(EntriesBox(K, V)).entries
    end

    def store_entries(entries : Array({K, V}))
      @entries.set(EntriesBox(K, V).new(entries).as(Void*), :release)
    end
  end

  @root : Atomic(Pointer(Void))
  @seed : UInt64

  def initialize
    @root = Atomic(Pointer(Void)).new(Pointer(Void).null)
    @seed = Random::Secure.rand(UInt64)
    @root.set(Node(K, V).new(0).as(Void*), :release)
  end

  private def hash(key : K) : UInt64
    key.hash.to_u64 ^ @seed
  end

  private def as_node(p : Pointer(Void)) : Node(K, V)
    p.as(Node(K, V))
  end

  # Descend from node to leaf for hash h, creating children as needed.
  # Returns the leaf node (locked).
  private def descend(node : Node(K, V), h : UInt64) : Node(K, V)
    cur = node
    while !cur.leaf?
      shift = ((MAX_DEPTH - cur.levels) * BITS).to_u32
      idx = ((h >> (shift - BITS)) & MASK).to_i
      child = cur.load_child(idx)
      if child.address == 0
        cur.mu.lock
        child = cur.load_child(idx)
        if child.address == 0
          new_child = Node(K, V).new(cur.levels + 1)
          cur.store_child(idx, new_child.as(Void*))
          cur.mu.unlock
          cur = new_child
          next
        end
        cur.mu.unlock
      end
      cur = as_node(child)
    end
    cur.mu.lock
    cur
  end

  # --- API ---

  def load(key : K) : {V?, Bool}
    h = hash(key)
    # Hot path specialized for MAX_DEPTH=2: root -> internal -> leaf.
    root = as_node(@root.get(:acquire))
    child = root.load_child(((h >> BITS) & MASK).to_i)
    return {nil, false} if child.address == 0

    leaf = as_node(child).load_child((h & MASK).to_i)
    return {nil, false} if leaf.address == 0

    as_node(leaf).load_entries.each { |(k, v)| return {v, true} if k == key }
    {nil, false}
  end

  def store(key : K, value : V) : Nil
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    begin
      entries = leaf.load_entries.dup
      entries.each_with_index do |(k, _), i|
        if k == key
          entries[i] = {key, value}
          leaf.store_entries(entries)
          return
        end
      end
      entries << {key, value}
      leaf.store_entries(entries)
    ensure
      leaf.mu.unlock
    end
  end

  def swap(key : K, nv : V) : {V?, Bool}
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    begin
      entries = leaf.load_entries.dup
      entries.each_with_index do |(k, _), i|
        if k == key
          old = entries[i][1]
          entries[i] = {key, nv}
          leaf.store_entries(entries)
          return {old, true}
        end
      end
      entries << {key, nv}
      leaf.store_entries(entries)
      {nil, false}
    ensure
      leaf.mu.unlock
    end
  end

  def delete(key : K) : Nil
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    begin
      entries = leaf.load_entries.dup
      entries.each_with_index do |(k, _), i|
        if k == key
          entries.delete_at(i)
          leaf.store_entries(entries)
          return
        end
      end
    ensure
      leaf.mu.unlock
    end
  end

  def load_or_store(key : K, value : V) : {V?, Bool}
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    begin
      entries = leaf.load_entries.dup
      entries.each_with_index do |(k, _), i|
        if k == key
          return {entries[i][1], true}
        end
      end
      entries << {key, value}
      leaf.store_entries(entries)
      {nil, false}
    ensure
      leaf.mu.unlock
    end
  end

  def load_and_delete(key : K) : {V?, Bool}
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    begin
      entries = leaf.load_entries.dup
      entries.each_with_index do |(k, _), i|
        if k == key
          v = entries[i][1]
          entries.delete_at(i)
          leaf.store_entries(entries)
          return {v, true}
        end
      end
      {nil, false}
    ensure
      leaf.mu.unlock
    end
  end

  def compare_and_swap(key : K, ov : V, nv : V) : Bool
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    begin
      entries = leaf.load_entries.dup
      entries.each_with_index do |(k, v), i|
        if k == key && v == ov
          entries[i] = {key, nv}
          leaf.store_entries(entries)
          return true
        end
      end
      false
    ensure
      leaf.mu.unlock
    end
  end

  def compare_and_delete(key : K, ov : V) : Bool
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    begin
      entries = leaf.load_entries.dup
      entries.each_with_index do |(k, v), i|
        if k == key && v == ov
          entries.delete_at(i)
          leaf.store_entries(entries)
          return true
        end
      end
      false
    ensure
      leaf.mu.unlock
    end
  end

  def clear : Nil
    @root.set(Node(K, V).new(0).as(Void*), :release)
  end

  def each(& : K, V -> _) : Nil
    stack = [as_node(@root.get(:acquire))]
    while n = stack.pop?
      if n.leaf?
        n.load_entries.each { |(k, v)| yield(k, v) }
      else
        SIZE.times { |j| c = n.load_child(j); stack.push(as_node(c)) if c.address != 0 }
      end
    end
  end

  def size : Int32
    count = 0; each { |_, _| count += 1 }; count
  end

  def [](key : K) : V
    v, ok = load(key)
    raise KeyError.new("Missing hash key: #{key.inspect}") unless ok
    v.not_nil!
  end

  def []?(key : K) : V?
    v, ok = load(key)
    ok ? v : nil
  end

  def []=(key : K, value : V) : V
    store(key, value)
    value
  end

  def has_key?(key : K) : Bool
    _, ok = load(key)
    ok
  end

  def keys : Array(K)
    a = [] of K
    each { |k, _| a << k }
    a
  end

  def values : Array(V)
    a = [] of V
    each { |_, v| a << v }
    a
  end

  def empty? : Bool
    size == 0
  end
end
