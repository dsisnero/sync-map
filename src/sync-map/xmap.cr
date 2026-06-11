# Concurrent CLHT (Cache-Line Hash Table) map. Ported from puzpuzpuz/xsync.
#
# Cache-line-sized buckets (64B), 5 entries per bucket.
# Lock-free reads via atomic metadata + entry pointer loads.
# Per-bucket mutex for writes. SWAR-based meta lookup.
# Immutable entry pointers. Striped counter for size.
#
# Upstream: vendor/xsync/map.go (880af08)
require "sync/mutex"

class Sync::XMap(K, V)
  ENTRIES_PER_BUCKET =    5
  DEFAULT_MIN_LEN    =   32
  LOAD_FACTOR        = 0.75
  SHRINK_FRACTION    =  128

  # --- SWAR helpers (SIMD Within A Register) ---

  def self.broadcast(b : UInt8) : UInt64
    0x0101010101010101_u64 &* b.to_u64
  end

  # Classic SWAR zero-byte detection. Returns 0x80 in each byte lane
  # where the input byte is zero. May produce false positives (e.g. 0x0100).
  def self.mark_zero_bytes(w : UInt64) : UInt64
    ((w &- 0x0101010101010101_u64) & (~w) & 0x8080808080808080_u64)
  end

  def self.first_marked_byte_index(w : UInt64) : Int32
    (w.trailing_zeros_count // 8).to_i32
  end

  def self.set_byte(w : UInt64, b : UInt8, idx : Int32) : UInt64
    shift = idx << 3
    (w & ~(0xff_u64 << shift)) | (b.to_u64 << shift)
  end

  # --- Hash functions ---

  def self.h1(h : UInt64) : UInt64
    h >> 7
  end

  def self.h2(h : UInt64) : UInt8
    0x80_u8 | (h & 0x7f).to_u8
  end

  # --- Entry (immutable K/V pair, atomically swapped) ---

  class Entry(K, V)
    getter key : K
    getter value : V

    def initialize(@key : K, @value : V)
    end
  end

  # --- Bucket (64-byte cache line) ---

  class Bucket(K, V)
    @meta = Atomic(UInt64).new(0_u64)
    getter mu = Sync::Mutex.new(:unchecked)
    property next_bucket : Bucket(K, V)?
    @slots : StaticArray(Atomic(Pointer(Void)), ENTRIES_PER_BUCKET)

    def initialize
      @slots = StaticArray(Atomic(Pointer(Void)), ENTRIES_PER_BUCKET).new {
        Atomic(Pointer(Void)).new(Pointer(Void).null)
      }
    end

    def load_meta : UInt64
      @meta.get(:acquire)
    end

    def store_meta(val : UInt64)
      @meta.set(val, :release)
    end

    def update_meta(& : UInt64 -> UInt64) : UInt64
      loop do
        old = load_meta
        new_val = yield old
        _, ok = @meta.compare_and_set(old, new_val, :release, :relaxed)
        return new_val if ok
      end
    end

    def load_slot(idx : Int32) : Pointer(Void)
      @slots[idx].get(:acquire)
    end

    def store_slot(idx : Int32, ptr : Pointer(Void))
      @slots[idx] = Atomic(Pointer(Void)).new(ptr)
    end

    # Insert a new entry into the first empty slot. Returns true on success.
    OCCUPIED = 0x80808080808080_u64

    def insert(h2 : UInt8, entry_ptr : Pointer(Void)) : Bool
      meta = load_meta
      empty_w = ~meta & OCCUPIED
      return false if empty_w == 0
      idx = Sync::XMap.first_marked_byte_index(empty_w)
      return false if idx >= ENTRIES_PER_BUCKET
      store_meta(Sync::XMap.set_byte(meta, h2, idx))
      store_slot(idx, entry_ptr)
      true
    end
  end

  # --- Table ---

  class Table(K, V)
    getter buckets : Array(Bucket(K, V))
    getter seed : UInt64

    def initialize(len : Int32, @seed : UInt64)
      @buckets = Array(Bucket(K, V)).new(len) { Bucket(K, V).new }
    end
  end

  # --- Map state ---

  @table : Atomic(Pointer(Void))
  @seed : UInt64
  @size = Atomic(Int64).new(0_i64)

  def initialize
    @seed = Random::Secure.rand(UInt64)
    @table = Atomic(Pointer(Void)).new(Pointer(Void).null)
    @table.set(Table(K, V).new(DEFAULT_MIN_LEN, @seed).as(Void*), :release)
  end

  private def current_table : Table(K, V)
    @table.get(:acquire).as(Table(K, V))
  end

  private def hash(key : K) : UInt64
    key.hash.to_u64
  end

  private def hash_with_seed(key : K) : UInt64
    hash(key) ^ @seed
  end

  # --- Public API ---

  def load(key : K) : {V?, Bool}
    h = hash_with_seed(key)
    table = current_table
    bidx = (Sync::XMap.h1(h) & (table.buckets.size - 1)).to_i
    b = table.buckets[bidx]
    h2w = Sync::XMap.broadcast(Sync::XMap.h2(h))

    loop do
      meta = b.load_meta
      marked = Sync::XMap.mark_zero_bytes(meta ^ h2w)
      while marked != 0
        idx = Sync::XMap.first_marked_byte_index(marked)
        return {nil, false} if idx >= ENTRIES_PER_BUCKET
        eptr = b.load_slot(idx)
        if eptr.address != 0
          e = eptr.as(Entry(K, V))
          return {e.value, true} if e.key == key
        end
        marked &= marked &- 1
      end
      nb = b.next_bucket
      break unless nb
      b = nb
    end
    {nil, false}
  end

  def store(key : K, value : V) : Nil
    h = hash_with_seed(key)
    table = current_table
    bidx = (Sync::XMap.h1(h) & (table.buckets.size - 1)).to_i
    rootb = table.buckets[bidx]

    rootb.mu.lock
    b = rootb
    h2 = Sync::XMap.h2(h)
    entry_ptr = Entry(K, V).new(key, value).as(Void*)

    loop do
      meta = b.load_meta
      h2w = Sync::XMap.broadcast(h2)
      marked = Sync::XMap.mark_zero_bytes(meta ^ h2w)

      # Check for existing key
      while marked != 0
        idx = Sync::XMap.first_marked_byte_index(marked)
        if idx < ENTRIES_PER_BUCKET
          eptr = b.load_slot(idx)
          if eptr.address != 0 && eptr.as(Entry(K, V)).key == key
            b.store_slot(idx, entry_ptr)
            rootb.mu.unlock
            return
          end
        end
        marked &= marked &- 1
      end

      # Try insert into empty slot
      if b.insert(h2, entry_ptr)
        @size.add(1, :release)
        rootb.mu.unlock
        return
      end

      # Overflow — create new bucket
      unless nb = b.next_bucket
        nb = Bucket(K, V).new
        nb.insert(h2, entry_ptr)
        b.next_bucket = nb
        @size.add(1, :release)
        rootb.mu.unlock
        return
      end
      b = nb
    end
  end

  def delete(key : K) : Nil
    load_and_delete(key)
  end

  def load_and_delete(key : K) : {V?, Bool}
    h = hash_with_seed(key)
    table = current_table
    bidx = (Sync::XMap.h1(h) & (table.buckets.size - 1)).to_i
    rootb = table.buckets[bidx]

    rootb.mu.lock
    b = rootb
    h2w = Sync::XMap.broadcast(Sync::XMap.h2(h))

    loop do
      meta = b.load_meta
      marked = Sync::XMap.mark_zero_bytes(meta ^ h2w)
      while marked != 0
        idx = Sync::XMap.first_marked_byte_index(marked)
        if idx < ENTRIES_PER_BUCKET
          eptr = b.load_slot(idx)
          if eptr.address != 0 && eptr.as(Entry(K, V)).key == key
            e = eptr.as(Entry(K, V))
            b.store_meta(Sync::XMap.set_byte(b.load_meta, 0_u8, idx))
            b.store_slot(idx, Pointer(Void).null)
            @size.add(-1, :release)
            rootb.mu.unlock
            return {e.value, true}
          end
        end
        marked &= marked &- 1
      end
      nb = b.next_bucket
      break unless nb
      b = nb
    end
    rootb.mu.unlock
    {nil, false}
  end

  def clear : Nil
    @table.set(Table(K, V).new(DEFAULT_MIN_LEN, @seed).as(Void*), :release)
    @size.set(0_i64, :release)
  end

  def size : Int32
    @size.get(:acquire).to_i32
  end

  def each(& : K, V -> _) : Nil
    table = current_table
    table.buckets.each do |rootb|
      b = rootb
      rootb.mu.lock
      loop do
        ENTRIES_PER_BUCKET.times do |idx|
          eptr = b.load_slot(idx)
          if eptr.address != 0
            e = eptr.as(Entry(K, V))
            return unless yield(e.key, e.value)
          end
        end
        nb = b.next_bucket
        break unless nb
        b = nb
      end
      rootb.mu.unlock
    end
  end
end
