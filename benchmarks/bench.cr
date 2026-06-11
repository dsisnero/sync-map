# Concurrent map benchmarks. Run: crystal run --release benchmarks/bench.cr
require "../src/sync-map"
require "../src/sync-map/hash_trie_map"
require "../src/sync-map/xmap"

STR_KEYS = (0...10_000).map { |i| "what_a_looooooooooooooooooooooong_key_prefix_#{i}" }
INT_KEYS = (0...10_000).to_a

MAPS_INT = {
  "Sync::Map"         => ->{ Sync::Map(Int32, Int32).new },
  "Sync::HashTrieMap" => ->{ Sync::HashTrieMap(Int32, Int32).new },
  "Sync::XMap"        => ->{ Sync::XMap(Int32, Int32).new },
}
MAPS_STR = {
  "Sync::Map"         => ->{ Sync::Map(String, Int32).new },
  "Sync::HashTrieMap" => ->{ Sync::HashTrieMap(String, Int32).new },
  "Sync::XMap"        => ->{ Sync::XMap(String, Int32).new },
}

def bench(name, factory, keys, size, read_pct, iters)
  map = factory.call
  size.times { |i| map.store(keys[i], i) }
  rng = Random.new(42)

  t = Time.measure do
    if read_pct == 100
      iters.times { |i| map.load(keys[i % size]) }
    else
      iters.times do
        r = rng.rand(1000)
        k = keys[rng.rand(size)]
        if r < read_pct * 10
          map.load(k)
        elsif r < read_pct * 10 + (1000 - read_pct * 10) // 2
          map.store(k, 1)
        else
          map.delete(k)
        end
      end
    end
  end

  ops = iters / t.total_seconds
  puts "  #{name.ljust(20)} #{ops.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/,"\\1_").reverse.rjust(12)} ops/s"
end

puts "=" * 60
puts "Concurrent Map Benchmarks (single-threaded)"
puts "=" * 60

# Int keys
puts "\n--- Int Keys, 100% reads ---"
[100, 1_000, 5_000].each do |size|
  iters = size * 200
  puts "  size=#{size} iters=#{iters}:"
  MAPS_INT.each { |name, f| bench(name, f, INT_KEYS, size, 100, iters) }
end

puts "\n--- Int Keys, 90% reads ---"
[100, 1_000].each do |size|
  iters = size * 40
  puts "  size=#{size} iters=#{iters}:"
  MAPS_INT.each { |name, f| bench(name, f, INT_KEYS, size, 90, iters) }
end

# String keys
puts "\n--- String Keys, 100% reads ---"
[100, 1_000].each do |size|
  iters = size * 200
  puts "  size=#{size} iters=#{iters}:"
  MAPS_STR.each { |name, f| bench(name, f, STR_KEYS, size, 100, iters) }
end

puts "\n--- String Keys, 90% reads ---"
[100, 1_000].each do |size|
  iters = size * 40
  puts "  size=#{size} iters=#{iters}:"
  MAPS_STR.each { |name, f| bench(name, f, STR_KEYS, size, 90, iters) }
end

puts "\nDone."
