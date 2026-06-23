# Proper benchmark harness with DCE prevention and multi-run averaging.
# Build: crystal build --release -o bin/bench benchmarks/bench_harness.cr
# Build MT: crystal build --release -Dpreview_mt -Dexecution_context -o bin/bench_mt benchmarks/bench_harness.cr
require "../src/sync-map"
require "../src/sync-map/hash_trie_map"
require "../src/sync-map/xmap"
require "wait_group"

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

# MT workers must run on a real parallel context. With
# `-Dpreview_mt -Dexecution_context` the *default* context has capacity 1
# (single thread), so plain `spawn` measures concurrency, not parallelism.
# We spawn workers onto an explicit `ExecutionContext::Parallel` so they run
# on real OS threads and actually contend on the map.
{% if flag?(:execution_context) %}
  BENCH_CTX = WORKERS > 1 ? Fiber::ExecutionContext::Parallel.new("bench", WORKERS) : nil
{% end %}

macro bench_spawn(&block)
  {% if flag?(:execution_context) %}
    if ctx = BENCH_CTX
      ctx.spawn do
        {{ block.body }}
      end
    else
      spawn do
        {{ block.body }}
      end
    end
  {% else %}
    spawn do
      {{ block.body }}
    end
  {% end %}
end

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

  total = Atomic(Int64).new(0)
  base_iters = iters // workers
  extra = iters % workers
  wg = WaitGroup.new(workers)

  workers.times do |worker|
    local_iters = base_iters + (worker < extra ? 1 : 0)
    offset = worker * base_iters
    bench_spawn do
      local = 0_i64
      local_iters.times do |i|
        _, ok = map.load(KEYS[((offset + i) % SIZE)])
        local &+= 1 if ok
      end
      total.add(local)
      wg.done
    end
  end

  wg.wait
  total.get
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

  total = Atomic(Int64).new(0)
  base_iters = iters // workers
  extra = iters % workers
  wg = WaitGroup.new(workers)

  workers.times do |worker|
    local_iters = base_iters + (worker < extra ? 1 : 0)
    offset = worker * base_iters
    bench_spawn do
      local = 0_i64
      local_iters.times do |i|
        absolute_i = offset + i
        key = KEYS[absolute_i % SIZE]
        if (absolute_i & 7) == 0
          map.store(key, absolute_i)
        else
          _, ok = map.load(key)
          local &+= 1 if ok
        end
      end
      total.add(local)
      wg.done
    end
  end

  wg.wait
  total.get
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
{% if flag?(:execution_context) %}
  puts "default_ctx_capacity=#{Fiber::ExecutionContext.default.capacity}, bench_ctx_capacity=#{BENCH_CTX.try(&.capacity) || 1}"
{% end %}
puts "=" * 55

label = MODE == "mixed" ? "87.5% Reads / 12.5% Writes, Int Keys:" : "100% Reads, Int Keys:"
puts "\n#{label}"
bench("Sync::Map       ", Sync::Map(Int32, Int32).new, ITERS, RUNS, WORKERS, MODE)
bench("HashTrieMap    ", Sync::HashTrieMap(Int32, Int32).new, ITERS, RUNS, WORKERS, MODE)
bench("XMap           ", Sync::XMap(Int32, Int32).new, ITERS, RUNS, WORKERS, MODE)

puts "\nDone."
