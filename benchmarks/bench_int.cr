require "../src/sync-map"
require "../src/sync-map/hash_trie_map"
require "../src/sync-map/xmap"

KEYS = (0...10_000).to_a

MAPS = {
  "Sync::Map"         => ->{ Sync::Map(Int32, Int32).new },
  "Sync::HashTrieMap" => ->{ Sync::HashTrieMap(Int32, Int32).new },
  "Sync::XMap"        => ->{ Sync::XMap(Int32, Int32).new },
}

def bench(name, factory, size, read_pct, iters)
  map = factory.call
  size.times { |i| map.store(KEYS[i], i) }
  rng = Random.new(42)

  t = Time.measure do
    if read_pct == 100
      iters.times { |i| map.load(KEYS[i % size]) }
    else
      iters.times do
        r = rng.rand(1000)
        k = KEYS[rng.rand(size)]
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

puts "Concurrent Map Benchmarks — Int Keys"
puts "=" * 50

[100, 1_000, 5_000].each do |size|
  iters = size * 50
  puts "\n100% reads, size=#{size} iters=#{iters}:"
  MAPS.each { |n, f| bench(n, f, size, 100, iters) }
end

[100, 1_000].each do |size|
  iters = size * 20
  puts "\n90% reads, size=#{size} iters=#{iters}:"
  MAPS.each { |n, f| bench(n, f, size, 90, iters) }
end

puts "\nDone."
