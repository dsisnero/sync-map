# Concurrent hash-trie map. Ported from Go's internal/sync.HashTrieMap
# (stdlib sync.Map backend since Go 1.24).
#
# 16-way branching (4 bits per level), unlimited depth via hash-bits
# exhaustion.  Lock-free reads, per-indirect-node mutex for writes.
# Entry nodes hold a single K/V pair with an overflow chain for
# hash collisions.
require "sync/mutex"

class Sync::HashTrieMap(K, V)
  BITS = 4; SIZE =     16; MASK            = SIZE - 1
  HASH_SHIFT_INIT = 64_u32

  # --- Node types ---

  private class Node(K, V)
    property is_entry : Bool
    getter mu = Sync::Mutex.new(:unchecked)

    def initialize(@is_entry : Bool)
    end
  end

  private class Indirect(K, V) < Node(K, V)
    property parent : Indirect(K, V)?
    getter dead = Atomic(Bool).new(false)
    @children : StaticArray(Atomic(Pointer(Void)), SIZE)

    def initialize(@parent : Indirect(K, V)?)
      super(false)
      @children = StaticArray(Atomic(Pointer(Void)), SIZE).new {
        Atomic(Pointer(Void)).new(Pointer(Void).null)
      }
    end

    def load_child(idx : Int32) : Pointer(Void)
      @children[idx].get(:acquire)
    end

    def store_child(idx : Int32, ptr : Pointer(Void))
      @children[idx] = Atomic(Pointer(Void)).new(ptr)
    end

    def empty? : Bool
      SIZE.times.all? { |i| @children[i].get(:relaxed).address == 0 }
    end
  end

  private class Entry(K, V) < Node(K, V)
    getter key : K
    property value : V
    @overflow : Atomic(Pointer(Void))

    def initialize(@key : K, @value : V)
      super(true)
      @overflow = Atomic(Pointer(Void)).new(Pointer(Void).null)
    end

    def load_overflow : Pointer(Void)
      @overflow.get(:acquire)
    end

    def store_overflow(e : Entry(K, V))
      @overflow.set(e.as(Void*), :release)
    end

    def lookup(key : K) : {V?, Bool}
      cur = self
      loop do
        return {cur.value, true} if cur.key == key
        next_ptr = cur.load_overflow
        return {nil, false} if next_ptr.address == 0
        cur = next_ptr.as(Entry(K, V))
      end
    end

    def swap(key : K, nv : V) : {Entry(K, V), V?, Bool}
      if @key == key
        new_head = Entry(K, V).new(key, nv)
        ov = load_overflow
        new_head.store_overflow(ov.as(Entry(K, V))) if ov.address != 0
        return {new_head, value, true}
      end
      prev = self
      cur_ptr = load_overflow
      while cur_ptr.address != 0
        cur = cur_ptr.as(Entry(K, V))
        if cur.key == key
          new_entry = Entry(K, V).new(key, nv)
          next_ptr = cur.load_overflow
          new_entry.store_overflow(next_ptr.as(Entry(K, V))) if next_ptr.address != 0
          prev.store_overflow(new_entry)
          return {self, cur.value, true}
        end
        prev = cur
        cur_ptr = cur.load_overflow
      end
      {self, nil, false}
    end

    def delete_key(key : K) : {Entry(K, V)?, V?, Bool}
      if @key == key
        ov = load_overflow
        return {ov.address != 0 ? ov.as(Entry(K, V)) : nil, value, true}
      end
      prev = self
      cur_ptr = load_overflow
      while cur_ptr.address != 0
        cur = cur_ptr.as(Entry(K, V))
        if cur.key == key
          next_ptr = cur.load_overflow
          prev.store_overflow(next_ptr.as(Entry(K, V))) if next_ptr.address != 0
          return {self, cur.value, true}
        end
        prev = cur
        cur_ptr = cur.load_overflow
      end
      {self, nil, false}
    end
  end

  # --- Map state ---

  @root : Atomic(Pointer(Void))
  @seed : UInt64

  def initialize
    @root = Atomic(Pointer(Void)).new(Pointer(Void).null)
    @seed = Random::Secure.rand(UInt64).to_u64
    @root.set(Indirect(K, V).new(nil).as(Void*), :release)
  end

  private def hash(key : K) : UInt64
    key.hash.to_u64 ^ @seed
  end

  # --- Lock-free read ---

  def load(key : K) : {V?, Bool}
    h = hash(key)
    i = @root.get(:acquire).as(Indirect(K, V))
    hash_shift = HASH_SHIFT_INIT
    loop do
      return {nil, false} if hash_shift < BITS
      hash_shift &-= BITS
      idx = ((h >> hash_shift) & MASK).to_i
      child = i.load_child(idx)
      return {nil, false} if child.address == 0
      n = child.as(Node(K, V))
      if n.is_entry
        return n.as(Entry(K, V)).lookup(key)
      end
      i = n.as(Indirect(K, V))
    end
  end

  # --- Mutating operations ---

  def store(key : K, value : V) : Nil
    h = hash(key)
    new_entry = Entry(K, V).new(key, value)
    do_insert(h, new_entry)
  end

  def swap(key : K, nv : V) : {V?, Bool}
    h = hash(key)
    swap_or_insert(h, key, nv)
  end

  def delete(key : K) : Nil
    h = hash(key)
    do_delete(h, key)
  end

  def load_and_delete(key : K) : {V?, Bool}
    h = hash(key)
    delete_find(h, key)
  end

  def clear : Nil
    @root.set(Indirect(K, V).new(nil).as(Void*), :release)
  end

  def load_or_store(key : K, value : V) : {V?, Bool}
    h = hash(key)
    swap_or_insert(h, key, value)
  end

  def compare_and_swap(key : K, ov : V, nv : V) : Bool
    v, ok = load(key)
    return false unless ok && v == ov
    h = hash(key)
    loop do
      i, idx, child, hs = find_slot(h)
      return false if child.address == 0
      i.mu.lock
      child2 = i.load_child(idx)
      if child2.address == 0
        i.mu.unlock
        return false
      end
      n = child2.as(Node(K, V))
      unless n.is_entry
        i.mu.unlock
        next
      end
      old_entry = n.as(Entry(K, V))
      old_v, found = old_entry.lookup(key)
      unless found && old_v == ov
        i.mu.unlock
        return false
      end
      new_head, _, _ = old_entry.swap(key, nv)
      i.store_child(idx, new_head.as(Void*))
      i.mu.unlock
      return true
    end
  end

  def compare_and_delete(key : K, ov : V) : Bool
    v, ok = load(key)
    return false unless ok && v == ov
    h = hash(key)
    loop do
      i, idx, child, hs = find_slot(h)
      return false if child.address == 0
      i.mu.lock
      child2 = i.load_child(idx)
      if child2.address == 0
        i.mu.unlock
        return false
      end
      n = child2.as(Node(K, V))
      unless n.is_entry
        i.mu.unlock
        next
      end
      old_entry = n.as(Entry(K, V))
      old_v, found = old_entry.lookup(key)
      unless found && old_v == ov
        i.mu.unlock
        return false
      end
      new_head, _, _ = old_entry.delete_key(key)
      if new_head
        i.store_child(idx, new_head.as(Void*))
      else
        i.store_child(idx, Pointer(Void).null)
      end
      i.mu.unlock
      cleanup_if_empty(i, idx)
      return true
    end
  end

  # --- Internal helpers ---

  private def find_slot(h : UInt64) : {Indirect(K, V), Int32, Pointer(Void), UInt32}
    i = @root.get(:acquire).as(Indirect(K, V))
    hash_shift = HASH_SHIFT_INIT
    loop do
      return {i, 0, Pointer(Void).null, hash_shift} if hash_shift < BITS
      hash_shift &-= BITS
      idx = ((h >> hash_shift) & MASK).to_i
      child = i.load_child(idx)
      return {i, idx, child, hash_shift} if child.address == 0
      n = child.as(Node(K, V))
      if n.is_entry
        return {i, idx, child, hash_shift}
      end
      i = n.as(Indirect(K, V))
    end
  end

  private def swap_or_insert(h : UInt64, key : K, nv : V) : {V?, Bool}
    loop do
      i, idx, child, hs = find_slot(h)
      i.mu.lock
      child2 = i.load_child(idx)
      if child2.address != 0
        n = child2.as(Node(K, V))
        if n.is_entry
          old_entry = n.as(Entry(K, V))
          new_head, old_val, swapped = old_entry.swap(key, nv)
          if swapped
            i.store_child(idx, new_head.as(Void*))
            i.mu.unlock
            return {old_val, true}
          end
          new_entry = Entry(K, V).new(key, nv)
          new_node = expand(old_entry, new_entry, h, i, hs)
          i.store_child(idx, new_node.as(Void*))
          i.mu.unlock
          return {nil, false}
        end
        i.mu.unlock
        next
      end
      new_entry = Entry(K, V).new(key, nv)
      i.store_child(idx, new_entry.as(Void*))
      i.mu.unlock
      return {nil, false}
    end
  end

  private def do_insert(h : UInt64, new_entry : Entry(K, V)) : Nil
    loop do
      i, idx, child, hs = find_slot(h)
      i.mu.lock
      child2 = i.load_child(idx)
      if child2.address == 0
        i.store_child(idx, new_entry.as(Void*))
        i.mu.unlock
        return
      end
      n = child2.as(Node(K, V))
      unless n.is_entry
        i.mu.unlock
        next
      end
      old_entry = n.as(Entry(K, V))
      new_head, _, swapped = old_entry.swap(new_entry.key, new_entry.value)
      if swapped
        i.store_child(idx, new_head.as(Void*))
        i.mu.unlock
        return
      end
      new_node = expand(old_entry, new_entry, h, i, hs)
      i.store_child(idx, new_node.as(Void*))
      i.mu.unlock
    end
  end

  private def expand(old_entry : Entry(K, V), new_entry : Entry(K, V), h : UInt64, parent : Indirect(K, V), hash_shift : UInt32) : Node(K, V)
    old_h = hash(old_entry.key)
    return new_with_overflow(old_entry, new_entry).as(Node(K, V)) if old_h == h

    new_indirect = Indirect(K, V).new(parent)
    top = new_indirect
    loop do
      raise "ran out of hash bits" if hash_shift < BITS
      hash_shift &-= BITS
      oi = ((old_h >> hash_shift) & MASK).to_i
      ni = ((h >> hash_shift) & MASK).to_i
      if oi != ni
        new_indirect.store_child(oi, old_entry.as(Void*))
        new_indirect.store_child(ni, new_entry.as(Void*))
        break
      end
      child_indirect = Indirect(K, V).new(new_indirect)
      new_indirect.store_child(oi, child_indirect.as(Void*))
      new_indirect = child_indirect
    end
    top.as(Node(K, V))
  end

  private def new_with_overflow(old_entry : Entry(K, V), new_entry : Entry(K, V)) : Entry(K, V)
    new_entry.store_overflow(old_entry)
    new_entry
  end

  private def do_delete(h : UInt64, key : K) : Nil
    loop do
      i, idx, child, hs = find_slot(h)
      return if child.address == 0
      i.mu.lock
      child2 = i.load_child(idx)
      if child2.address == 0
        i.mu.unlock
        return
      end
      n = child2.as(Node(K, V))
      unless n.is_entry
        i.mu.unlock
        next
      end
      old_entry = n.as(Entry(K, V))
      new_head, _, deleted = old_entry.delete_key(key)
      unless deleted
        i.mu.unlock
        return
      end
      if new_head
        i.store_child(idx, new_head.as(Void*))
      else
        i.store_child(idx, Pointer(Void).null)
      end
      i.mu.unlock
      cleanup_if_empty(i, idx)
      return
    end
  end

  private def delete_find(h : UInt64, key : K) : {V?, Bool}
    loop do
      i, idx, child, hs = find_slot(h)
      return {nil, false} if child.address == 0
      i.mu.lock
      child2 = i.load_child(idx)
      if child2.address == 0
        i.mu.unlock
        return {nil, false}
      end
      n = child2.as(Node(K, V))
      unless n.is_entry
        i.mu.unlock
        next
      end
      old_entry = n.as(Entry(K, V))
      new_head, deleted_val, deleted = old_entry.delete_key(key)
      unless deleted
        i.mu.unlock
        return {nil, false}
      end
      if new_head
        i.store_child(idx, new_head.as(Void*))
      else
        i.store_child(idx, Pointer(Void).null)
      end
      i.mu.unlock
      cleanup_if_empty(i, idx)
      return {deleted_val, true}
    end
  end

  private def cleanup_if_empty(ind : Indirect(K, V), from_idx : Int32) : Nil
    parent = ind.parent
    return unless parent && ind.empty?
    parent.mu.lock
    parent.store_child(from_idx, Pointer(Void).null)
    parent.mu.unlock
  end

  # --- Iteration ---

  def each(& : K, V -> _) : Nil
    stack = [{@root.get(:acquire).as(Indirect(K, V)), 0}]
    while pair = stack.pop?
      ind, i = pair
      if i < SIZE
        stack.push({ind, i + 1})
        child = ind.load_child(i)
        if child.address != 0
          n = child.as(Node(K, V))
          if n.is_entry
            e = n.as(Entry(K, V))
            loop do
              yield(e.key, e.value)
              next_ptr = e.load_overflow
              break unless next_ptr.address != 0
              e = next_ptr.as(Entry(K, V))
            end
          else
            stack.push({n.as(Indirect(K, V)), 0})
          end
        end
      end
    end
  end

  def size : Int32
    count = 0; each { |_, _| count += 1 }; count
  end

  def []=(key : K, value : V) : V
    store(key, value)
    value
  end

  def [](key : K) : V
    v, _ = load(key)
    v
  end

  def []?(key : K) : V?
    v, ok = load(key)
    ok ? v : nil
  end

  def has_key?(key : K) : Bool
    _, ok = load(key)
    ok
  end
end
