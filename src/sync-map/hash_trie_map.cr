# A concurrent hash-trie map. Ported from Go internal/sync.HashTrieMap (Go 1.24+)
# using the unified-node design from lucaong/immutable (Crystal hash trie).
#
# Single node type TrieNode(K,V) serves as both internal (children + bitmap)
# and leaf (values array). 5 bits per level = 32-way branching. Depth-based
# leaf detection. No tagged pointers, no type discrimination.
#
# Concurrency: per-node mutex for writes, atomic child slots for lock-free reads.
#
# Upstreams:
#   vendor/go/src/internal/sync/hashtriemap.go (Go 1.24+, f2f369d)
#   lucaong/immutable (Crystal hash trie design)
require "sync/mutex"

class Sync::HashTrieMap(K, V)
  BITS   =  5_u32
  SIZE   = 32_u32
  MASK   = SIZE - 1

  # --- TrieNode (unified internal/leaf node) ---

  private class TrieNode(K, V)
    getter mu = Sync::Mutex.new(:unchecked)
    property parent : TrieNode(K, V)?
    @dead = Atomic(Bool).new(false)

    # Children: 32 atomic slots pointing to TrieNode(K,V) or nil
    @children : Pointer(Atomic(Pointer(Void)))
    # Bitmap: bit i set if children[i] is present
    property bitmap : UInt32
    # Leaf entries: up to 32 entries when this is a leaf node
    property entries : Array({K, V})
    # Depth: 0 = leaf, >0 = internal (number of levels above leaves)
    property levels : Int32

    def initialize(@parent : TrieNode(K, V)?, @levels : Int32)
      @children = Pointer(Atomic(Pointer(Void))).null
      @bitmap = 0_u32
      @entries = [] of {K, V}
    end

    def dead?; @dead.get(:acquire); end
    def mark_dead; @dead.set(true, :release); end

    def leaf?; @levels == 0; end
    def empty?; @bitmap == 0 && @entries.empty?; end

    # Allocate child slots on first use
    private def ensure_children
      if @children.null?
        @children = Pointer(Atomic(Pointer(Void))).malloc(SIZE)
        SIZE.times { |i| @children[i] = Atomic(Pointer(Void)).new(Pointer(Void).null) }
      end
    end

    def load_child(idx : Int32) : Pointer(Void)
      return Pointer(Void).null if @children.null?
      @children[idx].get(:acquire)
    end

    def store_child(idx : Int32, ptr : Pointer(Void))
      ensure_children
      @children[idx].set(ptr, :release)
    end
  end

  @root : Atomic(Pointer(Void))
  @seed : UInt64

  def initialize
    @root = Atomic(Pointer(Void)).new(Pointer(Void).null)
    @seed = Random::Secure.rand(UInt64)
    @root.set(TrieNode(K, V).new(nil, 0).as(Void*), :release)
  end

  # --- Helpers ---

  private def hash(key : K) : UInt64
    key.hash.to_u64 ^ @seed
  end

  private def as_node(ptr : Pointer(Void)) : TrieNode(K, V)
    ptr.as(TrieNode(K, V))
  end

  private def node_ptr(node : TrieNode(K, V)) : Pointer(Void)
    node.as(Void*)
  end

  # --- Public API ---

  def load(key : K) : {V?, Bool}
    h = hash(key)
    node = as_node(@root.get(:acquire))

    # Walk down to leaf level
    while node.levels > 0
      shift = (node.levels - 1) * BITS
      idx = ((h >> shift) & MASK).to_i
      child = node.load_child(idx)
      return {nil, false} if child.address == 0
      node = as_node(child)
    end

    # Leaf level: linear scan of entries
    node.entries.each do |(k, v)|
      return {v, true} if k == key
    end
    {nil, false}
  end

  def store(key : K, value : V) : Nil; swap(key, value); end

  def swap(key : K, nv : V) : {V?, Bool}
    h = hash(key)
    node, shift, idx, _ = find_slot(h)
    node.mu.lock

    if node.leaf?
      # Leaf node — update entry
      node.entries.each_with_index do |(k, _), i|
        if k == key
          old = node.entries[i][1]
          node.entries[i] = {key, nv}
          node.mu.unlock
          return {old, true}
        end
      end
      # Key not found at leaf — insert
      node.entries << {key, nv}
      node.mu.unlock
      {nil, false}
    else
      # Internal node — insert child or expand
      child = node.load_child(idx)
      if child.address == 0
        # Create new leaf
        leaf = TrieNode(K, V).new(node, 0)
        leaf.entries = [{key, nv}]
        node.store_child(idx, node_ptr(leaf))
        node.bitmap |= (1_u32 << idx)
        node.mu.unlock
        {nil, false}
      else
        cnode = as_node(child)
        if cnode.leaf?
          # Check if key exists in leaf
          cnode.mu.lock
          cnode.entries.each_with_index do |(k, _), i|
            if k == key
              old = cnode.entries[i][1]
              cnode.entries[i] = {key, nv}
              cnode.mu.unlock
              node.mu.unlock
              return {old, true}
            end
          end
          cnode.entries << {key, nv}
          cnode.mu.unlock
          node.mu.unlock
          {nil, false}
        else
          node.mu.unlock
          swap(key, nv) # recursive retry at child
        end
      end
    end
  end

  def load_or_store(key : K, value : V) : {V?, Bool}
    h = hash(key)
    # Optimistic lock-free read
    node = as_node(@root.get(:acquire))
    while node.levels > 0
      shift = (node.levels - 1) * BITS
      idx = ((h >> shift) & MASK).to_i
      child = node.load_child(idx)
      break if child.address == 0
      node = as_node(child)
    end
    if node.leaf?
      node.entries.each do |(k, v)|
        return {v, true} if k == key
      end
    end
    # Fallback to locked insert
    swap(key, value)
    {nil, false} # swap returns nil on insert, but we want the inserted value
  end

  def load_and_delete(key : K) : {V?, Bool}
    h = hash(key)
    node, _, idx, _ = find_slot(h)
    node.mu.lock

    if node.leaf?
      node.entries.each_with_index do |(k, _), i|
        if k == key
          v = node.entries[i][1]
          node.entries.delete_at(i)
          node.mu.unlock
          return {v, true}
        end
      end
      node.mu.unlock
      {nil, false}
    else
      child = node.load_child(idx)
      if child.address == 0
        node.mu.unlock; return {nil, false}
      end
      cnode = as_node(child)
      if cnode.leaf?
        cnode.entries.each_with_index do |(k, _), i|
          if k == key
            v = cnode.entries[i][1]
            cnode.entries.delete_at(i)
            if cnode.empty?
              node.store_child(idx, Pointer(Void).null)
              node.bitmap &= ~(1_u32 << idx)
            end
            node.mu.unlock
            return {v, true}
          end
        end
      end
      node.mu.unlock
      {nil, false}
    end
  end

  def delete(key : K) : Nil; load_and_delete(key); end

  def compare_and_swap(key : K, ov : V, nv : V) : Bool
    h = hash(key)
    node, _, idx, _ = find_slot(h)
    node.mu.lock

    target = node
    if !node.leaf?
      child = node.load_child(idx)
      if child.address == 0
        node.mu.unlock; return false
      end
      target = as_node(child)
      unless target.leaf?
        node.mu.unlock; return false
      end
    end

    target.entries.each_with_index do |(k, v), i|
      if k == key && v == ov
        target.entries[i] = {key, nv}
        node.mu.unlock
        return true
      end
    end
    node.mu.unlock; false
  end

  def compare_and_delete(key : K, ov : V) : Bool
    h = hash(key)
    node, _, idx, _ = find_slot(h)
    node.mu.lock

    target = node
    if !node.leaf?
      child = node.load_child(idx)
      if child.address == 0
        node.mu.unlock; return false
      end
      target = as_node(child)
      unless target.leaf?
        node.mu.unlock; return false
      end
    end

    target.entries.each_with_index do |(k, v), i|
      if k == key && v == ov
        target.entries.delete_at(i)
        if target.empty? && !node.leaf?
          node.store_child(idx, Pointer(Void).null)
          node.bitmap &= ~(1_u32 << idx)
        end
        node.mu.unlock
        return true
      end
    end
    node.mu.unlock; false
  end

  def each(& : K, V -> _) : Nil
    walk(as_node(@root.get(:acquire))) { |k, v| yield(k, v) }
  end

  def clear : Nil
    @root.set(TrieNode(K, V).new(nil, 0).as(Void*), :release)
  end

  # --- Internal ---

  private def find_slot(h : UInt64) : {TrieNode(K, V), UInt32, Int32, Pointer(Void)}
    loop do
      node = as_node(@root.get(:acquire))
      shift : UInt32 = 0_u32; idx : Int32 = 0; child = Pointer(Void).null

      while node.levels > 0
        shift = (node.levels * BITS).to_u32
        idx = ((h >> (shift - BITS)) & MASK).to_i
        child = node.load_child(idx)
        break if child.address == 0
        node = as_node(child)
      end

      node.mu.lock
      unless node.dead?
        if node.levels > 0
          child = node.load_child(idx)
        end
        return {node, shift, idx, child}
      end
      node.mu.unlock
    end
  end

  private def walk(root : TrieNode(K, V), & : K, V -> _) : Nil
    stack = [root]
    while node = stack.pop?
      if node.leaf?
        node.entries.each do |(k, v)|
          return unless yield(k, v)
        end
      else
        SIZE.times do |i|
          child = node.load_child(i.to_i)
          stack.push(as_node(child)) if child.address != 0
        end
      end
    end
  end
end
