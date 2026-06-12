# Concurrent hash-trie map. Unified-node design from lucaong/immutable.
# 32-way branching, lock-free reads, per-node mutex writes.
# Levels INCREASE with depth: 0=root, leaf at max depth where entries live.
# A leaf holds entries whose hashes share the same bits at all levels above.
require "sync/mutex"

class Sync::HashTrieMap(K, V)
  BITS = 5_u32; SIZE = 32; MASK = SIZE - 1
  MAX_DEPTH = 2

  private class Node(K, V)
    getter mu = Sync::Mutex.new(:unchecked)
    @children : StaticArray(Atomic(Pointer(Void)), SIZE)
    property entries : Array({K, V}) = [] of {K, V}
    property levels : Int32  # depth from root: 0=root, 1=child, ... MAX_DEPTH=leaf

    def initialize(@levels : Int32)
      @children = StaticArray(Atomic(Pointer(Void)), SIZE).new { Atomic(Pointer(Void)).new(Pointer(Void).null) }
    end

    def leaf?; @levels >= MAX_DEPTH; end

    def load_child(idx : Int32) : Pointer(Void)
      @children[idx].get(:acquire)
    end

    def store_child(idx : Int32, ptr : Pointer(Void))
      @children[idx] = Atomic(Pointer(Void)).new(ptr)
    end
  end

  @root : Atomic(Pointer(Void))
  @seed : UInt64

  def initialize
    @root = Atomic(Pointer(Void)).new(Pointer(Void).null)
    @seed = Random::Secure.rand(UInt64)
    @root.set(Node(K, V).new(0).as(Void*), :release)
  end

  private def hash(key : K) : UInt64; key.hash.to_u64 ^ @seed; end
  private def as_node(p : Pointer(Void)) : Node(K, V); p.as(Node(K, V)); end

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
    node = as_node(@root.get(:acquire))
    while !node.leaf?
      shift = ((MAX_DEPTH - node.levels) * BITS).to_u32
      idx = ((h >> (shift - BITS)) & MASK).to_i
      child = node.load_child(idx)
      return {nil, false} if child.address == 0
      node = as_node(child)
    end
    node.entries.each { |(k, v)| return {v, true} if k == key }
    {nil, false}
  end

  def store(key : K, value : V) : Nil
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    leaf.entries.each_with_index { |(k, _), i| if k == key; leaf.entries[i] = {key, value}; leaf.mu.unlock; return; end }
    leaf.entries << {key, value}
    leaf.mu.unlock
  end

  def swap(key : K, nv : V) : {V?, Bool}
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    leaf.entries.each_with_index { |(k, _), i| if k == key; old = leaf.entries[i][1]; leaf.entries[i] = {key, nv}; leaf.mu.unlock; return {old, true}; end }
    leaf.entries << {key, nv}
    leaf.mu.unlock; {nil, false}
  end

  def delete(key : K) : Nil
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    leaf.mu.lock
    leaf.entries.each_with_index { |(k, _), i| if k == key; leaf.entries.delete_at(i); leaf.mu.unlock; return; end }
    leaf.mu.unlock
  end

  def load_or_store(key : K, value : V) : {V?, Bool}
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    leaf.entries.each_with_index { |(k, _), i| if k == key; v = leaf.entries[i][1]; leaf.mu.unlock; return {v, true}; end }
    leaf.entries << {key, value}
    leaf.mu.unlock; {nil, false}
  end

  def load_and_delete(key : K) : {V?, Bool}
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    leaf.mu.lock
    leaf.entries.each_with_index { |(k, _), i| if k == key; v = leaf.entries[i][1]; leaf.entries.delete_at(i); leaf.mu.unlock; return {v, true}; end }
    leaf.mu.unlock; {nil, false}
  end

  def compare_and_swap(key : K, ov : V, nv : V) : Bool
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    leaf.entries.each_with_index { |(k, v), i| if k == key && v == ov; leaf.entries[i] = {key, nv}; leaf.mu.unlock; return true; end }
    leaf.mu.unlock; false
  end

  def compare_and_delete(key : K, ov : V) : Bool
    h = hash(key)
    leaf = descend(as_node(@root.get(:acquire)), h)
    leaf.entries.each_with_index { |(k, v), i| if k == key && v == ov; leaf.entries.delete_at(i); leaf.mu.unlock; return true; end }
    leaf.mu.unlock; false
  end

  def clear : Nil
    @root.set(Node(K, V).new(0).as(Void*), :release)
  end

  def each(& : K, V -> _) : Nil
    stack = [as_node(@root.get(:acquire))]
    while n = stack.pop?
      if n.leaf?
        n.entries.each { |(k, v)| return unless yield(k, v) }
      else
        SIZE.times { |j| c = n.load_child(j); stack.push(as_node(c)) if c.address != 0 }
      end
    end
  end

  def size : Int32
    count = 0; each { |_, _| count += 1 }; count
  end
end
