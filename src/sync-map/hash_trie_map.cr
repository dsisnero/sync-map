# A concurrent hash-trie map. Ported from Go internal/sync.HashTrieMap (Go 1.24+).
#
# 16-way branching, lock-free reads via atomic pointer traversal,
# per-node mutex for writes, overflow chains for hash collisions.
#
# Node types use Crystal's class hierarchy (is_a? dispatch) instead of
# tagged pointers, making the port idiomatic and compiler-friendly.
#
# Upstream: vendor/go/src/internal/sync/hashtriemap.go (f2f369d)
require "sync/mutex"

class Sync::HashTrieMap(K, V)
  N    = 16
  MASK = 15

  # Node hierarchy: Indirect (internal) or Entry (leaf)
  private class Node(K, V)
    def entry? : Bool
      false
    end
  end

  private class Indirect(K, V) < Node(K, V)
    getter mu = Sync::Mutex.new(:unchecked)
    property parent : Indirect(K, V)?
    @dead = Atomic(Bool).new(false)
    @children : Pointer(Atomic(Pointer(Void)))

    def initialize(@parent : Indirect(K, V)?)
      @children = Pointer(Atomic(Pointer(Void))).malloc(N)
      N.times { |i| @children[i] = Atomic(Pointer(Void)).new(Pointer(Void).null) }
    end

    def dead?; @dead.get(:acquire); end
    def mark_dead; @dead.set(true, :release); end

    def empty?
      N.times { |i| return false if @children[i].get(:relaxed).address != 0 }
      true
    end

    def load_child(idx : Int32) : Pointer(Void)
      @children[idx].get(:acquire)
    end

    def store_child(idx : Int32, ptr : Pointer(Void))
      @children[idx].set(ptr, :release)
    end
  end

  private class Entry(K, V) < Node(K, V)
    getter key : K
    property value : V
    @overflow = Atomic(Pointer(Void)).new(Pointer(Void).null)

    def entry? : Bool
      true
    end

    def initialize(@key : K, @value : V); end

    def ov; @overflow.get(:acquire); end
    def set_ov(p : Pointer(Void)); @overflow.set(p, :release); end

    def lookup(k : K) : {V?, Bool}
      e = self
      loop do
        return {e.value, true} if e.key == k
        n = e.ov; break if n.address == 0
        e = n.as(Entry(K, V))
      end
      {nil, false}
    end

    def lookup_val(k : K, v : V, chk : Bool) : {V?, Bool}
      e = self
      loop do
        if e.key == k
          return {e.value, true} unless chk
          return {e.value, true} if e.value == v
        end
        n = e.ov; break if n.address == 0
        e = n.as(Entry(K, V))
      end
      {nil, false}
    end

    def swap(k : K, nv : V) : {Pointer(Void), V?, Bool}
      if @key == k
        ne = Entry(K, V).new(k, nv)
        o = ov; ne.set_ov(o) if o.address != 0
        return {ne.as(Void*), @value, true}
      end
      prev = self
      c = ov
      loop do
        break if c.address == 0
        cur = c.as(Entry(K, V))
        if cur.key == k
          ne = Entry(K, V).new(k, nv)
          ne.set_ov(cur.ov)
          prev.set_ov(ne.as(Void*))
          return {self.as(Void*), cur.value, true}
        end
        prev = cur
        c = cur.ov
      end
      {self.as(Void*), nil, false}
    end

    def cas(k : K, ov_v : V, nv : V) : {Pointer(Void), Bool}
      if @key == k && @value == ov_v
        ne = Entry(K, V).new(k, nv)
        o = self.ov; ne.set_ov(o) if o.address != 0
        return {ne.as(Void*), true}
      end
      prev = self
      c = self.ov
      loop do
        break if c.address == 0
        cur = c.as(Entry(K, V))
        if cur.key == k && cur.value == ov_v
          ne = Entry(K, V).new(k, nv)
          ne.set_ov(cur.ov)
          prev.set_ov(ne.as(Void*))
          return {self.as(Void*), true}
        end
        prev = cur
        c = cur.ov
      end
      {self.as(Void*), false}
    end

    def load_and_del(k : K) : {V?, Pointer(Void), Bool}
      if @key == k
        return {@value, ov, true}
      end
      prev = self
      c = ov
      loop do
        break if c.address == 0
        cur = c.as(Entry(K, V))
        if cur.key == k
          prev.set_ov(cur.ov)
          return {cur.value, self.as(Void*), true}
        end
        prev = cur
        c = cur.ov
      end
      {nil, self.as(Void*), false}
    end

    def cad(k : K, v : V) : {Pointer(Void), Bool}
      if @key == k && @value == v
        return {ov, true}
      end
      prev = self
      c = ov
      loop do
        break if c.address == 0
        cur = c.as(Entry(K, V))
        if cur.key == k && cur.value == v
          prev.set_ov(cur.ov)
          return {self.as(Void*), true}
        end
        prev = cur
        c = cur.ov
      end
      {self.as(Void*), false}
    end
  end

  @root : Atomic(Pointer(Void)) = Atomic(Pointer(Void)).new(Pointer(Void).null)
  @seed : UInt64

  def initialize
    @seed = Random::Secure.rand(UInt64)
    @root.set(Indirect(K, V).new(nil).as(Void*), :release)
  end

  private def hash(key : K) : UInt64
    key.hash.to_u64 ^ @seed
  end

  # Reify a Void* child pointer back to the correct Node type
  private def as_node(ptr : Pointer(Void)) : Node(K, V)
    ptr.as(Node(K, V))
  end

  # --- Public API ---

  def load(key : K) : {V?, Bool}
    h = hash(key)
    i = as_node(@root.get(:acquire)).as(Indirect(K, V))
    16.times do |level|
      shift = 60 - level * 4
      child = i.load_child(((h >> shift) & MASK).to_i)
      return {nil, false} if child.address == 0
      if as_node(child).entry?
        return child.as(Entry(K, V)).lookup(key)
      end
      i = child.as(Indirect(K, V))
    end
    {nil, false}
  end

  def store(key : K, value : V) : Nil; swap(key, value); end

  def swap(key : K, nv : V) : {V?, Bool}
    h = hash(key)
    i, s, n = find_slot(h)
    i.mu.lock

    if n.address != 0
      chain, old, swapped = n.as(Entry(K, V)).swap(key, nv)
      if swapped
        i.store_child(s, chain)
        i.mu.unlock
        return {old, true}
      end
    end
    ne = Entry(K, V).new(key, nv)
    if n.address == 0
      i.store_child(s, ne.as(Void*))
    else
      i.store_child(s, expand(n.as(Entry(K, V)), ne, h, i))
    end
    i.mu.unlock
    {nil, false}
  end

  def load_or_store(key : K, value : V) : {V?, Bool}
    h = hash(key)
    # Optimistic lock-free read
    i = as_node(@root.get(:acquire)).as(Indirect(K, V))
    16.times do |level|
      shift = 60 - level * 4
      s = ((h >> shift) & MASK).to_i
      child = i.load_child(s)
      break if child.address == 0
      if as_node(child).entry?
        v, ok = child.as(Entry(K, V)).lookup(key)
        return {v, true} if ok
        break
      end
      i = child.as(Indirect(K, V))
    end
    i, s, n = find_slot(h)
    i.mu.lock
    n2 = i.load_child(s)
    if n2.address != 0 && as_node(n2).entry?
      v, ok = n2.as(Entry(K, V)).lookup(key)
      if ok; i.mu.unlock; return {v, true}; end
    end
    ne = Entry(K, V).new(key, value)
    if n2.address == 0
      i.store_child(s, ne.as(Void*))
    else
      i.store_child(s, expand(n2.as(Entry(K, V)), ne, h, i))
    end
    i.mu.unlock
    {value, false}
  end

  def load_and_delete(key : K) : {V?, Bool}
    h = hash(key)
    i, shift, s, n = find_entry(key, h)
    if n.address == 0
      i.try(&.mu.unlock)
      return {nil, false}
    end
    i = i.not_nil!
    v, chain, loaded = n.as(Entry(K, V)).load_and_del(key)
    unless loaded; i.mu.unlock; return {nil, false}; end
    if chain.address != 0
      i.store_child(s, chain); i.mu.unlock; return {v, true}
    end
    i.store_child(s, Pointer(Void).null)
    prune(i, h, shift)
    i.mu.unlock
    {v, true}
  end

  def delete(key : K) : Nil; load_and_delete(key); end

  def compare_and_swap(key : K, ov : V, nv : V) : Bool
    h = hash(key)
    i, _, s, n = find_entry_val(key, h, ov)
    if n.address == 0; i.try(&.mu.unlock); return false; end
    i = i.not_nil!
    chain, ok = n.as(Entry(K, V)).cas(key, ov, nv)
    i.store_child(s, chain) if ok
    i.mu.unlock; ok
  end

  def compare_and_delete(key : K, ov : V) : Bool
    h = hash(key)
    i, shift, s, n = find_entry(key, h)
    if n.address == 0; i.try(&.mu.unlock); return false; end
    i = i.not_nil!
    chain, ok = n.as(Entry(K, V)).cad(key, ov)
    unless ok; i.mu.unlock; return false; end
    if chain.address != 0
      i.store_child(s, chain); i.mu.unlock
    else
      i.store_child(s, Pointer(Void).null)
      prune(i, h, shift)
      i.mu.unlock
    end; true
  end

  def each(& : K, V -> _) : Nil
    walk(as_node(@root.get(:acquire)).as(Indirect(K, V))) { |k, v| yield(k, v) }
  end

  def clear : Nil
    @root.set(Indirect(K, V).new(nil).as(Void*), :release)
  end

  # --- Internal ---

  private def find_slot(h)
    loop do
      i = as_node(@root.get(:acquire)).as(Indirect(K, V))
      s = 0; n = Pointer(Void).null
      16.times do |level|
        shift = 60 - level * 4
        s = ((h >> shift) & MASK).to_i
        n = i.load_child(s)
        break if n.address == 0 || as_node(n).entry?
        i = n.as(Indirect(K, V))
      end
      i.mu.lock
      n2 = i.load_child(s)
      if (n2.address == 0 || as_node(n2).entry?) && !i.dead?
        return {i, s, n2}
      end; i.mu.unlock
    end
  end

  private def find_entry(key, h)
    loop do
      i = as_node(@root.get(:acquire)).as(Indirect(K, V))
      shift = 0; s = 0; n = Pointer(Void).null; found = false
      16.times do |level|
        shift = 60 - level * 4
        s = ((h >> shift) & MASK).to_i
        n = i.load_child(s)
        if n.address == 0; return {nil, 0_u32, s, n}; end
        if as_node(n).entry?
          _, ok = n.as(Entry(K, V)).lookup(key); found = ok; break
        end
        i = n.as(Indirect(K, V))
      end
      return {nil, 0_u32, s, Pointer(Void).null} unless found
      i.mu.lock
      n2 = i.load_child(s)
      if !i.dead? && (n2.address == 0 || as_node(n2).entry?)
        return {i, shift.to_u32, s, n2}
      end; i.mu.unlock
    end
  end

  private def find_entry_val(key, h, val)
    loop do
      i = as_node(@root.get(:acquire)).as(Indirect(K, V))
      s = 0; n = Pointer(Void).null; found = false
      16.times do |level|
        shift = 60 - level * 4
        s = ((h >> shift) & MASK).to_i
        n = i.load_child(s)
        if n.address == 0; return {nil, 0_u32, s, n}; end
        if as_node(n).entry?
          _, ok = n.as(Entry(K, V)).lookup_val(key, val, true); found = ok; break
        end
        i = n.as(Indirect(K, V))
      end
      return {nil, 0_u32, s, Pointer(Void).null} unless found
      i.mu.lock
      n2 = i.load_child(s)
      if !i.dead? && (n2.address == 0 || as_node(n2).entry?)
        return {i, 0_u32, s, n2}
      end; i.mu.unlock
    end
  end

  private def expand(old : Entry(K, V), ne : Entry(K, V), nh : UInt64, parent : Indirect(K, V)) : Void*
    oh = hash(old.key)
    if oh == nh
      ne.set_ov(old.as(Void*))
      return ne.as(Void*)
    end
    ni = Indirect(K, V).new(parent); top = ni
    16.times do |level|
      shift = 60 - level * 4
      oi = ((oh >> shift) & MASK).to_i
      ni_idx = ((nh >> shift) & MASK).to_i
      if oi != ni_idx
        ni.store_child(oi, old.as(Void*))
        ni.store_child(ni_idx, ne.as(Void*))
        break
      end
      next_ni = Indirect(K, V).new(ni)
      ni.store_child(oi, next_ni.as(Void*))
      ni = next_ni
    end
    top.as(Void*)
  end

  private def prune(ii : Indirect(K, V), h : UInt64, shift : UInt32)
    cur = ii
    while p = cur.parent
      break unless cur.empty?
      parent = p
      parent.mu.lock
      cur.mark_dead
      ps = ((h >> (shift + 4)) & MASK).to_i
      parent.store_child(ps, Pointer(Void).null)
      cur.mu.unlock
      cur = parent; shift += 4
    end
    cur.mu.unlock
  end

  private def walk(root : Indirect(K, V), & : K, V -> _) : Nil
    stack = [root]
    while node = stack.pop?
      N.times do |j|
        c = node.load_child(j)
        next if c.address == 0
        if as_node(c).entry?
          e = c.as(Entry(K, V))
          loop do
            return unless yield(e.key, e.value)
            o = e.ov; break if o.address == 0
            e = o.as(Entry(K, V))
          end
        else
          stack.push(c.as(Indirect(K, V)))
        end
      end
    end
  end
end
