# A concurrent hash-trie map. Ported from Go internal/sync.HashTrieMap (Go 1.24+).
#
# 16-way branching, lock-free reads via atomic pointer traversal,
# per-node mutex for writes, overflow chains for hash collisions.
#
# Tagged pointers (low bit: 0=indirect, 1=entry). Must strip tag
# before dereferencing.
#
# Upstream: vendor/go/src/internal/sync/hashtriemap.go (f2f369d)

require "sync/mutex"

class Sync::HashTrieMap(K, V)
  N    = 16
  MASK = 15

  private TAG_ENTRY    = 1_u64
  private TAG_INDIRECT = 0_u64

  @root : Atomic(Pointer(Void)) = Atomic(Pointer(Void)).new(Pointer(Void).null)
  @seed : UInt64

  def initialize
    @seed = Random::Secure.rand(UInt64)
    @root.set(tag(Indirect(K, V).new(nil).as(Void*), false), :release)
  end

  # --- Tagged pointer helpers ---

  private def tag(ptr : Void*, entry : Bool) : Void*
    Pointer(Void).new(ptr.address | (entry ? TAG_ENTRY : TAG_INDIRECT))
  end

  private def is_entry(p : Void*) : Bool
    (p.address & TAG_ENTRY) != 0
  end

  # Strip tag and dereference as Entry
  private def deref_entry(p : Void*) : Entry(K, V)
    Pointer(Void).new(p.address & ~TAG_ENTRY).as(Entry(K, V))
  end

  # Strip tag and dereference as Indirect
  private def deref_indirect(p : Void*) : Indirect(K, V)
    Pointer(Void).new(p.address & ~TAG_ENTRY).as(Indirect(K, V))
  end

  # Strip tag from a pointer (keeps it as Void* for storage)
  private def strip(p : Void*) : Void*
    Pointer(Void).new(p.address & ~TAG_ENTRY)
  end

  # --- Indirect node (internal trie node) ---

  private class Indirect(K, V)
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

    def store_child(idx : Int32, ptr : Pointer(Void)) : Nil
      @children[idx].set(ptr, :release)
    end
  end

  # --- Entry node (leaf) ---

  private class Entry(K, V)
    getter key : K
    property value : V
    @overflow = Atomic(Pointer(Void)).new(Pointer(Void).null)

    def initialize(@key : K, @value : V); end

    def ov; @overflow.get(:acquire); end
    def set_ov(p : Pointer(Void)); @overflow.set(p, :release); end

    def lookup(k : K) : {V?, Bool}
      e = self
      loop do
        return {e.value, true} if e.key == k
        n = e.ov; break if n.address == 0
        e = deref(n)
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
        e = deref(n)
      end
      {nil, false}
    end

    def swap(k : K, nv : V) : {Pointer(Void), V?, Bool}
      if @key == k
        ne = Entry(K, V).new(k, nv)
        o = ov; ne.set_ov(o) if o.address != 0
        return {tag_ent(ne), @value, true}
      end
      prev, c = self, ov
      loop do
        break if c.address == 0
        cur = deref(c)
        if cur.key == k
          ne = Entry(K, V).new(k, nv)
          ne.set_ov(cur.ov)
          prev.set_ov(tag_ent(ne))
          return {tag_ent(self), cur.value, true}
        end
        prev, c = cur, cur.ov
      end
      {tag_ent(self), nil, false}
    end

    def cas(k : K, ov_v : V, nv : V) : {Pointer(Void), Bool}
      if @key == k && @value == ov_v
        ne = Entry(K, V).new(k, nv)
        o = self.ov; ne.set_ov(o) if o.address != 0
        return {tag_ent(ne), true}
      end
      prev, c = self, self.ov
      loop do
        break if c.address == 0
        cur = deref(c)
        if cur.key == k && cur.value == ov_v
          ne = Entry(K, V).new(k, nv)
          ne.set_ov(cur.ov)
          prev.set_ov(tag_ent(ne))
          return {tag_ent(self), true}
        end
        prev, c = cur, cur.ov
      end
      {tag_ent(self), false}
    end

    def load_and_del(k : K) : {V?, Pointer(Void), Bool}
      if @key == k
        return {@value, ov, true}
      end
      prev, c = self, ov
      loop do
        break if c.address == 0
        cur = deref(c)
        if cur.key == k
          prev.set_ov(cur.ov)
          return {cur.value, tag_ent(self), true}
        end
        prev, c = cur, cur.ov
      end
      {nil, tag_ent(self), false}
    end

    def cad(k : K, v : V) : {Pointer(Void), Bool}
      if @key == k && @value == v
        return {ov, true}
      end
      prev, c = self, ov
      loop do
        break if c.address == 0
        cur = deref(c)
        if cur.key == k && cur.value == v
          prev.set_ov(cur.ov)
          return {tag_ent(self), true}
        end
        prev, c = cur, cur.ov
      end
      {tag_ent(self), false}
    end

    # Helper: dereference a tagged entry pointer from overflow chain
    private def deref(p : Pointer(Void)) : Entry(K, V)
      Pointer(Void).new(p.address & ~1_u64).as(Entry(K, V))
    end

    # Tag an entry pointer for storage
    private def tag_ent(e : Entry(K, V)) : Pointer(Void)
      Pointer(Void).new(e.as(Void*).address | 1_u64)
    end
  end

  private def hash(key : K) : UInt64
    key.hash.to_u64 ^ @seed
  end

  # --- Public API ---

  def load(key : K) : {V?, Bool}
    h = hash(key)
    i = deref_indirect(@root.get(:acquire))
    16.times do |level|
      shift = 60 - level * 4
      child = i.load_child(((h >> shift) & MASK).to_i)
      return {nil, false} if child.address == 0
      if is_entry(child)
        return deref_entry(child).lookup(key)
      end
      i = deref_indirect(child)
    end
    {nil, false}
  end

  def store(key : K, value : V) : Nil; swap(key, value); end

  def swap(key : K, nv : V) : {V?, Bool}
    h = hash(key)
    i, s, n = find_slot(h)
    i.mu.lock

    if n.address != 0
      chain, old, swapped = deref_entry(n).swap(key, nv)
      if swapped
        i.store_child(s, chain)
        i.mu.unlock
        return {old, true}
      end
    end
    ne = Entry(K, V).new(key, nv)
    if n.address == 0
      i.store_child(s, tag(ne.as(Void*), true))
    else
      i.store_child(s, expand(deref_entry(n), ne, h, i))
    end
    i.mu.unlock
    {nil, false}
  end

  def load_or_store(key : K, value : V) : {V?, Bool}
    h = hash(key)
    # Optimistic lock-free read
    i = deref_indirect(@root.get(:acquire))
    16.times do |level|
      shift = 60 - level * 4
      s = ((h >> shift) & MASK).to_i
      child = i.load_child(s)
      break if child.address == 0
      if is_entry(child)
        v, ok = deref_entry(child).lookup(key)
        return {v, true} if ok
        break
      end
      i = deref_indirect(child)
    end
    i, s, n = find_slot(h)
    i.mu.lock
    n2 = i.load_child(s)
    if n2.address != 0 && is_entry(n2)
      v, ok = deref_entry(n2).lookup(key)
      if ok; i.mu.unlock; return {v, true}; end
    end
    ne = Entry(K, V).new(key, value)
    if n2.address == 0
      i.store_child(s, tag(ne.as(Void*), true))
    else
      i.store_child(s, expand(deref_entry(n2), ne, h, i))
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
    v, chain, loaded = deref_entry(n).load_and_del(key)
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
    chain, ok = deref_entry(n).cas(key, ov, nv)
    i.store_child(s, chain) if ok
    i.mu.unlock; ok
  end

  def compare_and_delete(key : K, ov : V) : Bool
    h = hash(key)
    i, shift, s, n = find_entry(key, h)
    if n.address == 0; i.try(&.mu.unlock); return false; end
    i = i.not_nil!
    chain, ok = deref_entry(n).cad(key, ov)
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
    walk(deref_indirect(@root.get(:acquire))) { |k, v| yield(k, v) }
  end

  def clear : Nil
    @root.set(tag(Indirect(K, V).new(nil).as(Void*), false), :release)
  end

  # --- Internal ---

  private def find_slot(h)
    loop do
      i = deref_indirect(@root.get(:acquire))
      s = 0; n = Pointer(Void).null
      16.times do |level|
        shift = 60 - level * 4
        s = ((h >> shift) & MASK).to_i
        n = i.load_child(s)
        break if n.address == 0 || is_entry(n)
        i = deref_indirect(n)
      end
      i.mu.lock
      n2 = i.load_child(s)
      if (n2.address == 0 || is_entry(n2)) && !i.dead?
        return {i, s, n2}
      end; i.mu.unlock
    end
  end

  private def find_entry(key, h)
    loop do
      i = deref_indirect(@root.get(:acquire))
      shift = 0; s = 0; n = Pointer(Void).null; found = false
      16.times do |level|
        shift = 60 - level * 4
        s = ((h >> shift) & MASK).to_i
        n = i.load_child(s)
        if n.address == 0; return {nil, 0_u32, s, n}; end
        if is_entry(n)
          _, ok = deref_entry(n).lookup(key); found = ok; break
        end
        i = deref_indirect(n)
      end
      return {nil, 0_u32, s, Pointer(Void).null} unless found
      i.mu.lock
      n2 = i.load_child(s)
      if !i.dead? && (n2.address == 0 || is_entry(n2))
        return {i, shift.to_u32, s, n2}
      end; i.mu.unlock
    end
  end

  private def find_entry_val(key, h, val)
    loop do
      i = deref_indirect(@root.get(:acquire))
      s = 0; n = Pointer(Void).null; found = false
      16.times do |level|
        shift = 60 - level * 4
        s = ((h >> shift) & MASK).to_i
        n = i.load_child(s)
        if n.address == 0; return {nil, 0_u32, s, n}; end
        if is_entry(n)
          _, ok = deref_entry(n).lookup_val(key, val, true); found = ok; break
        end
        i = deref_indirect(n)
      end
      return {nil, 0_u32, s, Pointer(Void).null} unless found
      i.mu.lock
      n2 = i.load_child(s)
      if !i.dead? && (n2.address == 0 || is_entry(n2))
        return {i, 0_u32, s, n2}
      end; i.mu.unlock
    end
  end

  private def expand(old : Entry(K, V), ne : Entry(K, V), nh : UInt64, parent : Indirect(K, V)) : Void*
    oh = hash(old.key)
    if oh == nh
      ne.set_ov(tag(old.as(Void*), true))
      return tag(ne.as(Void*), true)
    end
    ni = Indirect(K, V).new(parent); top = ni
    16.times do |level|
      shift = 60 - level * 4
      oi = ((oh >> shift) & MASK).to_i
      ni_idx = ((nh >> shift) & MASK).to_i
      if oi != ni_idx
        ni.store_child(oi, tag(old.as(Void*), true))
        ni.store_child(ni_idx, tag(ne.as(Void*), true))
        break
      end
      next_ni = Indirect(K, V).new(ni)
      ni.store_child(oi, tag(next_ni.as(Void*), false))
      ni = next_ni
    end
    tag(top.as(Void*), false)
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
        if is_entry(c)
          e = deref_entry(c)
          loop do
            return unless yield(e.key, e.value)
            o = e.ov; break if o.address == 0
            e = deref_entry(o)
          end
        else
          stack.push(deref_indirect(c))
        end
      end
    end
  end
end
