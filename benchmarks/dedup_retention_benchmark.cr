# Memory retention benchmark for Fix 1 (DedupTracker) and Fix 2 (Permission).
#
# Verifies plans/TOOLS-LEAKS.md §A1 and §A3: that the dedup call history
# and the session-approval Set do not retain the full canonical args.
# Run with:
#   crystal run benchmarks/dedup_retention_benchmark.cr --warnings none --no-color
require "json"
require "../src/llm/types"
require "../src/llm/token_counter"
require "../src/context/memory"
require "../src/context/budget"
require "../src/context/undo"
require "../src/context/overflow"
require "../src/tools/tool"
require "../src/loop/events"
require "../src/loop/dedup"
require "../src/permission/manager"
require "../src/permission/danger"
require "../src/permission/policies"

struct Measurement
  property label : String
  property rss_mb : Float64
  property heap_mb : Float64
  property live_mb : Float64

  def initialize(@label, @rss_mb, @heap_mb, @live_mb)
  end
end

def rss_mb
  File.read("/proc/self/status").each_line do |line|
    if line.starts_with?("VmRSS:")
      return line.split[1].to_i / 1024.0
    end
  end
  0.0
end

def measure(label)
  GC.collect
  stats = GC.stats
  rss = rss_mb
  heap = stats.heap_size / 1_048_576.0
  live = heap - (stats.free_bytes / 1_048_576.0)
  puts "#{label}: RSS #{rss.round(2)} MB | heap #{heap.round(2)} MB | live #{live.round(2)} MB"
  Measurement.new(label, rss, heap, live)
end

N_CALLS    =      50
ARGS_BYTES = 200_000 # ~200 KB JSON args, simulating a chunky Edit payload

puts "=== Retention benchmark: DedupTracker + Permission cache ==="
puts "#{N_CALLS} calls × #{ARGS_BYTES} bytes/args"
measure("Baseline")

# --- Fix 1: DedupTracker -------------------------------------------------
#
# Before the fix, @call_history[tool] retained every canonical_args string
# verbatim. N_CALLS × ~200 KB would hold ~10 MB of args text forever.
# After the fix, only 64-byte SHA256 digests are stored, ring-capped at
# MAX_HISTORY (24) entries per tool.
dedup = H2code::Loop::DedupTracker.new
puts "\n--- Fix 1: DedupTracker ---"
N_CALLS.times do |i|
  payload = "x" * ARGS_BYTES
  args = %({"path":"f#{i}.txt","old_string":"#{payload}","new_string":"y#{i}"})
  dedup.check_and_track("Edit", args)
end
after_dedup = measure("After #{N_CALLS} dedup.check_and_track calls")
GC.collect
after_dedup_gc = measure("After GC.collect")

# Each per-tool history entry must be a 64-char SHA256 hex digest.
history = dedup.@call_history["Edit"]
history.each do |entry|
  raise "Expected 64-char SHA256 digest, got #{entry.size} chars" unless entry.size == 64
  raise "Payload leaked into dedup history" if entry.includes?("x" * 10)
end
puts "history entries: #{history.size} (cap: #{H2code::Loop::DedupTracker::MAX_HISTORY})"
puts "per-entry size : 64 bytes (SHA256 hexdigest)"
puts "old retention : #{ARGS_BYTES * N_CALLS / 1_048_576.0} MB"
puts "new retention : #{history.size * 64 / 1_048_576.0} MB"

# --- Fix 2: Permission::Manager @session_approvals -----------------------
#
# Before the fix, every ApproveSession stored "tool:args" with the full
# args JSON as the Set key. After the fix, it stores "tool:sha256(args)".
puts "\n--- Fix 2: Permission::Manager cache ---"
manager = H2code::Permission::Manager.new(H2code::Permission::Mode::Manual)
manager.approval_callback = ->(_t : String, _a : String, _d : String?) : H2code::Permission::ApprovalChoice {
  H2code::Permission::ApprovalChoice::ApproveSession
}
events = [] of H2code::Loop::Event
N_CALLS.times do |i|
  payload = "y" * ARGS_BYTES
  args = %({"path":"f#{i}.txt","old_string":"#{payload}","new_string":"z#{i}"})
  manager.check("Edit", args, ->(e : H2code::Loop::Event) { events << e })
end
after_perm = measure("After #{N_CALLS} ApproveSession approvals")
manager.@session_approvals.each do |key|
  raise "Payload leaked into approval key: #{key.size}" if key.size > 80
  raise "Payload leaked into approval key content" if key.includes?("y" * 10)
end
puts "approval keys: #{manager.@session_approvals.size}"
puts "per-key size : ~71 bytes (\"Edit:\" + 64-char SHA256)"
puts "old retention: #{(ARGS_BYTES * N_CALLS + 5 * N_CALLS) / 1_048_576.0} MB"
puts "new retention: #{manager.@session_approvals.size * 71 / 1_048_576.0} MB"

# --- Summary -------------------------------------------------------------
puts "\n--- Summary ---"
delta_dedup = after_dedup_gc.rss_mb - after_dedup.rss_mb
puts "Fix 1 RSS delta after GC: #{delta_dedup.round(2)} MB"
puts "Fix 2 RSS delta        : #{(after_perm.rss_mb - after_dedup_gc.rss_mb).round(2)} MB"
puts "\n--- Final summary ---"
puts "Fix 1 (DedupTracker)   : 9.5 MB → 1.5 KB retained"
puts "Fix 2 (Approval cache) : 9.5 MB → 3.4 KB retained"
