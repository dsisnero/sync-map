# Proper benchmark harness with DCE prevention and multi-run averaging.
# Build: crystal build --release -o bin/bench benchmarks/bench_harness.cr
# Build MT: crystal build --release -Dpreview_mt -Dexecution_context -o bin/bench_mt benchmarks/bench_harness.cr
require "../src/sync-map"
require "../src/sync-map/hash_trie_map"
require "../src/sync-map/xmap"

SIZE  = 1_000
RUNS  = 5          # run 5 times, discard first (cold), average rest
ITERS = 500_000    # per run per map

KEYS = (0...SIZE).to_a

def bench(label, map, iters, runs, mt = false)
  # Pre-fill outside timing
  SIZE.times { |i| map.store(KEYS[i], i) }

  times = [] of Float64
  runs.times do |run|
    sink = 0_i64
    t = Time.measure do
      iters.times do |i|
        _, ok = map.load(KEYS[i % SIZE])
        sink &+= 1 if ok
      end
    end
    times << t.total_seconds
    # Verify sink to block DCE
    if sink != iters
      puts "  WARNING: #{label} sink=#{sink} expected=#{iters}"
    end
  end

  # Discard first (cold) run, average rest
  warm = times.shift
  avg = times.sum / times.size
  ops = (iters / avg).to_i
  puts "#{label}: #{ops} ops/s  (warm=#{warm.round(4)}s, avg(#{times.size})=#{avg.round(4)}s)"
end

puts "=" * 55
mode = {{ flag?(:preview_mt) ? "MT (multi-thread)" : "ST (single-thread)" }}
puts "Concurrent Map Benchmark — #{mode}"
puts "size=#{SIZE}, iters=#{ITERS}, runs=#{RUNS}"
puts "=" * 55

puts "\n100% Reads, Int Keys:"
bench("Sync::Map       ", Sync::Map(Int32, Int32).new,       ITERS, RUNS)
bench("HashTrieMap    ", Sync::HashTrieMap(Int32, Int32).new, ITERS, RUNS)
bench("XMap           ", Sync::XMap(Int32, Int32).new,        ITERS, RUNS)

puts "\nDone."
