# Concurrent hash-trie map. Unified-node design from lucaong/immutable.
# 32-way branching, lock-free reads, per-node mutex writes.
# Minimal API — only essential concurrent map operations.
require "sync/mutex"

class Sync::HashTrieMap(K, V)
  BITS = 5_u32; SIZE = 32_u32; MASK = SIZE - 1

  private class Node(K, V)
    getter mu = Sync::Mutex.new(:unchecked)
    property parent : Node(K, V)?
    @dead = Atomic(Bool).new(false)
    @children : Pointer(Atomic(Pointer(Void)))
    property bitmap : UInt32 = 0
    property entries : Array({K, V}) = [] of {K, V}
    property levels : Int32

    def initialize(@parent : Node(K, V)?, @levels : Int32)
      @children = Pointer(Atomic(Pointer(Void))).null
    end

    def dead?
      @dead.get(:acquire)
    end

    def mark_dead
      @dead.set(true, :release)
    end

    def leaf?
      @levels == 0
    end

    def empty?
      @bitmap == 0 && @entries.empty?
    end

    def load_child(idx : Int32) : Pointer(Void)
      return Pointer(Void).null if @children.null?
      @children[idx].get(:acquire)
    end

    def store_child(idx : Int32, ptr : Pointer(Void))
      if @children.null?
        @children = Pointer(Atomic(Pointer(Void))).malloc(SIZE)
        SIZE.times { |i| @children[i] = Atomic(Pointer(Void)).new(Pointer(Void).null) }
      end
      @children[idx].set(ptr, :release)
    end
  end

  @root : Atomic(Pointer(Void))
  @seed : UInt64

  def initialize
    @root = Atomic(Pointer(Void)).new(Pointer(Void).null)
    @seed = Random::Secure.rand(UInt64)
    @root.set(Node(K, V).new(nil, 0).as(Void*), :release)
  end

  private def hash(key : K) : UInt64
    key.hash.to_u64 ^ @seed
  end

  private def as_node(p : Pointer(Void)) : Node(K, V)
    p.as(Node(K, V))
  end

  # Walk from node toward leaf using hash bits. Returns leaf node.
  private def walk_to_leaf(node : Node(K, V), h : UInt64) : Node(K, V)
    cur = node
    while cur.levels > 0
      shift = (cur.levels * BITS).to_u32
      idx = ((h >> (shift - BITS)) & MASK).to_i
      child = cur.load_child(idx)
      break if child.address == 0
      cur = as_node(child)
    end
    cur
  end

  # --- API: 11 methods ---

  def load(key : K) : {V?, Bool}
    leaf = walk_to_leaf(as_node(@root.get(:acquire)), hash(key))
    leaf.entries.each { |(k, v)| return {v, true} if k == key }
    {nil, false}
  end

  def store(key : K, value : V) : Nil
    leaf = walk_to_leaf(as_node(@root.get(:acquire)), hash(key))
    leaf.mu.lock
    leaf.entries.each_with_index { |(k, _), i| if k == key
      leaf.entries[i] = {key, value}; leaf.mu.unlock; return
    end }
    leaf.entries << {key, value}
    leaf.mu.unlock
  end

  def swap(key : K, nv : V) : {V?, Bool}
    leaf = walk_to_leaf(as_node(@root.get(:acquire)), hash(key))
    leaf.mu.lock
    leaf.entries.each_with_index { |(k, _), i| if k == key
      old = leaf.entries[i][1]; leaf.entries[i] = {key, nv}; leaf.mu.unlock; return {old, true}
    end }
    leaf.entries << {key, nv}
    leaf.mu.unlock; {nil, false}
  end

  def delete(key : K) : Nil
    leaf = walk_to_leaf(as_node(@root.get(:acquire)), hash(key))
    leaf.mu.lock
    leaf.entries.each_with_index { |(k, _), i| if k == key
      leaf.entries.delete_at(i); leaf.mu.unlock; return
    end }
    leaf.mu.unlock
  end

  def load_or_store(key : K, value : V) : {V?, Bool}
    leaf = walk_to_leaf(as_node(@root.get(:acquire)), hash(key))
    leaf.mu.lock
    leaf.entries.each_with_index { |(k, _), i| if k == key
      v = leaf.entries[i][1]; leaf.mu.unlock; return {v, true}
    end }
    leaf.entries << {key, value}
    leaf.mu.unlock; {nil, false}
  end

  def load_and_delete(key : K) : {V?, Bool}
    leaf = walk_to_leaf(as_node(@root.get(:acquire)), hash(key))
    leaf.mu.lock
    leaf.entries.each_with_index { |(k, _), i| if k == key
      v = leaf.entries[i][1]; leaf.entries.delete_at(i); leaf.mu.unlock; return {v, true}
    end }
    leaf.mu.unlock; {nil, false}
  end

  def compare_and_swap(key : K, ov : V, nv : V) : Bool
    leaf = walk_to_leaf(as_node(@root.get(:acquire)), hash(key))
    leaf.mu.lock
    leaf.entries.each_with_index { |(k, v), i| if k == key && v == ov
      leaf.entries[i] = {key, nv}; leaf.mu.unlock; return true
    end }
    leaf.mu.unlock; false
  end

  def compare_and_delete(key : K, ov : V) : Bool
    leaf = walk_to_leaf(as_node(@root.get(:acquire)), hash(key))
    leaf.mu.lock
    leaf.entries.each_with_index { |(k, v), i| if k == key && v == ov
      leaf.entries.delete_at(i); leaf.mu.unlock; return true
    end }
    leaf.mu.unlock; false
  end

  def clear : Nil
    @root.set(Node(K, V).new(nil, 0).as(Void*), :release)
  end

  def each(& : K, V -> _) : Nil
    stack = [as_node(@root.get(:acquire))]
    while n = stack.pop?
      if n.leaf?
        n.entries.each { |(k, v)| return unless yield(k, v) }
      else
        SIZE.times { |j| c = n.load_child(j.to_i); stack.push(as_node(c)) if c.address != 0 }
      end
    end
  end

  def size : Int32
    count = 0; each { |_, _| count += 1 }; count
  end
end
