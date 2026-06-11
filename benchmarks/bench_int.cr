require "../src/sync-map"
require "../src/sync-map/hash_trie_map"
require "../src/sync-map/xmap"

MAX   = 1_000
I_KEYS = (0...MAX).to_a
S_KEYS = I_KEYS.map(&.to_s)

def bench(label, map, keys, sizes)
  puts label
  sizes.each do |size|
    iters = size * 100
    t = Time.measure { iters.times { |i| map.load(keys[i % size]) } }
    ops = (iters / t.total_seconds).to_i
    puts "  size=#{size}: #{ops} ops/s"
  end
end

# Pre-fill helpers (named for reporting)
def prefill(label, factory, keys, n)
  map = factory.call
  t = Time.measure { n.times { |i| map.store(keys[i], i) } }
  puts "  #{label}: #{(n / t.total_seconds).to_i} stores/s"
  map
end

puts "=" * 56
puts "100% Reads (single-threaded, --release, pre-fill=#{MAX})"
puts "=" * 56

SIZES = [100, 500, 1_000]

puts "\n--- Int Keys ---"
sm = prefill("Sync::Map       ", ->{ Sync::Map(Int32, Int32).new }, I_KEYS, MAX)
ht = prefill("Sync::HashTrieMap", ->{ Sync::HashTrieMap(Int32, Int32).new }, I_KEYS, MAX)
xm = prefill("Sync::XMap      ", ->{ Sync::XMap(Int32, Int32).new }, I_KEYS, MAX)

puts "\nRead throughput:"
bench("  Sync::Map       ", sm, I_KEYS, SIZES)
bench("  Sync::HashTrieMap", ht, I_KEYS, SIZES)
bench("  Sync::XMap       ", xm, I_KEYS, SIZES)

puts "\n--- String Keys ---"
sms = prefill("Sync::Map       ", ->{ Sync::Map(String, Int32).new }, S_KEYS, MAX)
hts = prefill("Sync::HashTrieMap", ->{ Sync::HashTrieMap(String, Int32).new }, S_KEYS, MAX)
xms = prefill("Sync::XMap      ", ->{ Sync::XMap(String, Int32).new }, S_KEYS, MAX)

puts "\nRead throughput:"
bench("  Sync::Map       ", sms, S_KEYS, SIZES)
bench("  Sync::HashTrieMap", hts, S_KEYS, SIZES)
bench("  Sync::XMap       ", xms, S_KEYS, SIZES)

puts "\nDone."
