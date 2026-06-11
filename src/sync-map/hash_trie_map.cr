# Concurrent hash-trie map. Unified-node design from lucaong/immutable.
# 32-way branching, lock-free reads, per-node mutex writes.
# Children: StaticArray(Atomic(Pointer(Void)), 32) — inline, no pointer indirection.
require "sync/mutex"

class Sync::HashTrieMap(K, V)
  BITS = 5_u32; SIZE =    32; MASK       = SIZE - 1
  LEAF_LIMIT =    32
  MAX_DEPTH  = 6_i32

  private class Node(K, V)
    getter mu = Sync::Mutex.new(:unchecked)
    @children : StaticArray(Atomic(Pointer(Void)), SIZE)
    property entries : Array({K, V}) = [] of {K, V}
    property levels : Int32

    def initialize(@levels : Int32)
      @children = StaticArray(Atomic(Pointer(Void)), SIZE).new { Atomic(Pointer(Void)).new(Pointer(Void).null) }
    end

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

  private def hash(key : K) : UInt64
    key.hash.to_u64 ^ @seed
  end

  private def as_node(p : Pointer(Void)) : Node(K, V)
    p.as(Node(K, V))
  end

  private def lock_leaf(h : UInt64) : Node(K, V)
    loop do
      node = as_node(@root.get(:acquire))
      while node.levels > 0
        shift = (node.levels * BITS).to_u32
        idx = ((h >> (shift - BITS)) & MASK).to_i
        child = node.load_child(idx)
        if child.address == 0
          node.mu.lock
          child = node.load_child(idx)
          if child.address == 0
            new_child = Node(K, V).new(node.levels - 1)
            node.store_child(idx, new_child.as(Void*))
            node.mu.unlock
            node = new_child
            next
          end
          node.mu.unlock
        end
        node = as_node(child)
      end
      node.mu.lock
      if node.entries.size >= LEAF_LIMIT
        expand(node)
        node.mu.unlock
        next
      end
      return node
    end
  end

  private def expand(node : Node(K, V))
    node.levels = {node.levels + 1, MAX_DEPTH}.min
    old = node.entries
    node.entries = [] of {K, V}
    old.each do |(k, v)|
      eh = hash(k)
      idx = ((eh >> ((node.levels * BITS).to_u32 - BITS)) & MASK).to_i
      child_ptr = node.load_child(idx)
      if child_ptr.address == 0
        child = Node(K, V).new(0)
        child.entries = [{k, v}]
        node.store_child(idx, child.as(Void*))
      else
        child = as_node(child_ptr)
        child.mu.lock
        child.entries << {k, v}
        child.mu.unlock
      end
    end
  end

  # --- API ---

  def load(key : K) : {V?, Bool}
    node = as_node(@root.get(:acquire))
    while node.levels > 0
      shift = (node.levels * BITS).to_u32
      idx = ((hash(key) >> (shift - BITS)) & MASK).to_i
      child = node.load_child(idx)
      return {nil, false} if child.address == 0
      node = as_node(child)
    end
    node.entries.each { |(k, v)| return {v, true} if k == key }
    {nil, false}
  end

  def store(key : K, value : V) : Nil
    leaf = lock_leaf(hash(key))
    leaf.entries.each_with_index { |(k, _), i| if k == key
      leaf.entries[i] = {key, value}; leaf.mu.unlock; return
    end }
    leaf.entries << {key, value}
    leaf.mu.unlock
  end

  def swap(key : K, nv : V) : {V?, Bool}
    leaf = lock_leaf(hash(key))
    leaf.entries.each_with_index { |(k, _), i| if k == key
      old = leaf.entries[i][1]; leaf.entries[i] = {key, nv}; leaf.mu.unlock; return {old, true}
    end }
    leaf.entries << {key, nv}
    leaf.mu.unlock; {nil, false}
  end

  def delete(key : K) : Nil
    leaf = lock_leaf(hash(key))
    leaf.entries.each_with_index { |(k, _), i| if k == key
      leaf.entries.delete_at(i); leaf.mu.unlock; return
    end }
    leaf.mu.unlock
  end

  def load_or_store(key : K, value : V) : {V?, Bool}
    leaf = lock_leaf(hash(key))
    leaf.entries.each_with_index { |(k, _), i| if k == key
      v = leaf.entries[i][1]; leaf.mu.unlock; return {v, true}
    end }
    leaf.entries << {key, value}
    leaf.mu.unlock; {nil, false}
  end

  def load_and_delete(key : K) : {V?, Bool}
    leaf = lock_leaf(hash(key))
    leaf.entries.each_with_index { |(k, _), i| if k == key
      v = leaf.entries[i][1]; leaf.entries.delete_at(i); leaf.mu.unlock; return {v, true}
    end }
    leaf.mu.unlock; {nil, false}
  end

  def compare_and_swap(key : K, ov : V, nv : V) : Bool
    leaf = lock_leaf(hash(key))
    leaf.entries.each_with_index { |(k, v), i| if k == key && v == ov
      leaf.entries[i] = {key, nv}; leaf.mu.unlock; return true
    end }
    leaf.mu.unlock; false
  end

  def compare_and_delete(key : K, ov : V) : Bool
    leaf = lock_leaf(hash(key))
    leaf.entries.each_with_index { |(k, v), i| if k == key && v == ov
      leaf.entries.delete_at(i); leaf.mu.unlock; return true
    end }
    leaf.mu.unlock; false
  end

  def clear : Nil
    @root.set(Node(K, V).new(0).as(Void*), :release)
  end

  def each(& : K, V -> _) : Nil
    stack = [as_node(@root.get(:acquire))]
    while n = stack.pop?
      if n.levels == 0
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
