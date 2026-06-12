require "../src/sync-map"
require "../src/sync-map/hash_trie_map"
require "../src/sync-map/xmap"

SIZE  = 1_000
ITERS = 100_000
FIBERS = ENV["FIBERS"]?.try(&.to_i) || 4

def bench_concurrent(label, map, size, iters, fibers)
  keys = (0...size).to_a
  size.times { |i| map.store(keys[i], i) }

  done = Channel(Nil).new(fibers)
  t = Time.measure do
    fibers.times do
      spawn do
        iters.times { |i| map.load(keys[i % size]) }
        done.send(nil)
      end
    end
    fibers.times { done.receive }
  end

  total = iters * fibers
  ops = total / t.total_seconds
  puts "#{label} #{fibers}f x #{iters}it: #{ops.to_i} ops/s  (#{t.total_seconds.round(3)}s)"
end

puts "Concurrent Read Benchmark (#{FIBERS} fibers, size=#{SIZE}, -Dpreview_mt)"
puts "=" * 60

bench_concurrent("Sync::Map       ", Sync::Map(Int32, Int32).new, SIZE, ITERS, FIBERS)
bench_concurrent("HashTrieMap    ", Sync::HashTrieMap(Int32, Int32).new, SIZE, ITERS, FIBERS)
bench_concurrent("XMap           ", Sync::XMap(Int32, Int32).new, SIZE, ITERS, FIBERS)

puts "\nDone."
