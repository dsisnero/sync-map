# Proper benchmark harness with DCE prevention and multi-run averaging.
# Build: crystal build --release -o bin/bench benchmarks/bench_harness.cr
# Build MT: crystal build --release -Dpreview_mt -Dexecution_context -o bin/bench_mt benchmarks/bench_harness.cr
require "../src/sync-map"
require "../src/sync-map/hash_trie_map"
require "../src/sync-map/xmap"

DEFAULT_SIZE    =   1_000
DEFAULT_RUNS    =       5 # run 5 times, discard first (cold), average rest
DEFAULT_ITERS   = 500_000 # per run per map
DEFAULT_WORKERS = {{ flag?(:preview_mt) ? 8 : 1 }}
DEFAULT_MODE    = "read"
SIZE            = (ENV["BENCH_SIZE"]? || DEFAULT_SIZE.to_s).to_i
RUNS            = (ENV["BENCH_RUNS"]? || DEFAULT_RUNS.to_s).to_i
ITERS           = (ENV["BENCH_ITERS"]? || DEFAULT_ITERS.to_s).to_i
WORKERS         = (ENV["BENCH_WORKERS"]? || DEFAULT_WORKERS.to_s).to_i
MODE            = ENV["BENCH_MODE"]? || DEFAULT_MODE

KEYS = (0...SIZE).to_a

def measure_reads(map, iters, workers) : Int64
  return 0_i64 if iters <= 0

  if workers <= 1
    sink = 0_i64
    iters.times do |i|
      _, ok = map.load(KEYS[i % SIZE])
      sink &+= 1 if ok
    end
    return sink
  end

  done = Channel(Int64).new
  start = Channel(Nil).new
  ready = Channel(Nil).new
  base_iters = iters // workers
  extra = iters % workers

  workers.times do |worker|
    spawn do
      local_iters = base_iters + (worker < extra ? 1 : 0)
      offset = worker * base_iters
      ready.send(nil)
      start.receive

      sink = 0_i64
      local_iters.times do |i|
        _, ok = map.load(KEYS[(offset + i) % SIZE])
        sink &+= 1 if ok
      end
      done.send(sink)
    end
  end

  workers.times { ready.receive }
  workers.times { start.send(nil) }

  sink = 0_i64
  workers.times { sink &+= done.receive }
  sink
end

def measure_mixed(map, iters, workers) : Int64
  return 0_i64 if iters <= 0

  if workers <= 1
    sink = 0_i64
    iters.times do |i|
      key = KEYS[i % SIZE]
      if (i & 7) == 0
        map.store(key, i)
      else
        _, ok = map.load(key)
        sink &+= 1 if ok
      end
    end
    return sink
  end

  done = Channel(Int64).new
  start = Channel(Nil).new
  ready = Channel(Nil).new
  base_iters = iters // workers
  extra = iters % workers

  workers.times do |worker|
    spawn do
      local_iters = base_iters + (worker < extra ? 1 : 0)
      offset = worker * base_iters
      ready.send(nil)
      start.receive

      sink = 0_i64
      local_iters.times do |i|
        absolute_i = offset + i
        key = KEYS[absolute_i % SIZE]
        if (absolute_i & 7) == 0
          map.store(key, absolute_i)
        else
          _, ok = map.load(key)
          sink &+= 1 if ok
        end
      end
      done.send(sink)
    end
  end

  workers.times { ready.receive }
  workers.times { start.send(nil) }

  sink = 0_i64
  workers.times { sink &+= done.receive }
  sink
end

def expected_sink(iters) : Int64
  iters - ((iters + 7) // 8)
end

def measure_workload(map, iters, workers, mode) : Int64
  case mode
  when "read"
    measure_reads(map, iters, workers)
  when "mixed"
    measure_mixed(map, iters, workers)
  else
    raise "Unknown BENCH_MODE=#{mode.inspect}"
  end
end

def bench(label, map, iters, runs, workers, mode)
  # Pre-fill outside timing
  SIZE.times { |i| map.store(KEYS[i], i) }
  expected = mode == "read" ? iters.to_i64 : expected_sink(iters.to_i64)

  times = [] of Float64
  runs.times do |run|
    t = Time.measure do
      sink = measure_workload(map, iters, workers, mode)
      if sink != expected
        puts "  WARNING: #{label} sink=#{sink} expected=#{expected}"
      end
    end
    times << t.total_seconds
  end

  # Discard first (cold) run, average rest
  warm = times.shift
  avg = times.sum / times.size
  ops = (iters / avg).to_i
  puts "#{label}: #{ops} ops/s  (workers=#{workers}, warm=#{warm.round(4)}s, avg(#{times.size})=#{avg.round(4)}s)"
end

puts "=" * 55
mode = {{ flag?(:preview_mt) ? "MT (multi-thread)" : "ST (single-thread)" }}
puts "Concurrent Map Benchmark — #{mode}"
puts "size=#{SIZE}, iters=#{ITERS}, runs=#{RUNS}, workers=#{WORKERS}, bench_mode=#{MODE}"
puts "=" * 55

label = MODE == "mixed" ? "87.5% Reads / 12.5% Writes, Int Keys:" : "100% Reads, Int Keys:"
puts "\n#{label}"
bench("Sync::Map       ", Sync::Map(Int32, Int32).new, ITERS, RUNS, WORKERS, MODE)
bench("HashTrieMap    ", Sync::HashTrieMap(Int32, Int32).new, ITERS, RUNS, WORKERS, MODE)
bench("XMap           ", Sync::XMap(Int32, Int32).new, ITERS, RUNS, WORKERS, MODE)

puts "\nDone."
