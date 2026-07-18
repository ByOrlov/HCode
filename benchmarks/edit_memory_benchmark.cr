require "json"
require "../src/llm/types"
require "../src/llm/token_counter"
require "../src/context/undo"
require "../src/context/memory"

require "../src/tui/terminal"
require "../src/tui/input"
require "../src/tui/component"
require "../src/tui/char_width"
require "../src/tui/text"
require "../src/tui/theme"
require "../src/tui/markdown"

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

N_EDITS = 3
EDIT_SIZE = 3_000_000

puts "=== Edit tool memory benchmark ==="
puts "#{N_EDITS} edits, old/new string ~#{(EDIT_SIZE / 1_048_576.0).round(2)} MB each"
measure("Baseline")

memory = Hcode::Context::Memory.new
memory.max_context_tokens = 262144
memory.add_user("Edit some files")
memory.add_assistant("")

N_EDITS.times do |i|
  old_str = "o" * EDIT_SIZE
  new_str = "n" * EDIT_SIZE
  args = %Q{{"path": "file#{i}.txt", "old_string": "#{old_str}", "new_string": "#{new_str}"}}
  tool_call = Hcode::LLM::ToolCall.new("tc_#{i}", Hcode::LLM::ToolCallFunction.new("Edit", args))
  memory.add_assistant("", [tool_call])
  memory.add_tool_result("tc_#{i}", "Edited file#{i}.txt")
end

measure("After Context::Memory with edits")

# Simulate TUI preview storage (truncated args + result previews).
tui_messages = [] of String
N_EDITS.times do |i|
  args_preview = %Q{{"path": "file#{i}.txt", "old_string": "#{("o" * EDIT_SIZE)[0, 1000]}\n[... truncated; load session in /debug mode to expand ...]", "new_string": "#{("n" * EDIT_SIZE)[0, 1000]}\n[... truncated; load session in /debug mode to expand ...]"}}
  tui_messages << args_preview
  tui_messages << "Edited file#{i}.txt"
end
measure("After TUI previews")

# JSON serialization peak with streaming vs string.
request = Hcode::LLM::ChatRequest.new(model: "mock", messages: memory.messages, tools: nil, stream: true)
json_body = request.to_json
measure("After request.to_json (string)")
json_body = nil
GC.collect

# Streaming: serialize to /dev/null to measure transient memory.
io = File.open("/dev/null", "w")
request.to_json(io)
io.close
measure("After request.to_json (stream to /dev/null)")

memory.clear
request = nil
GC.collect
measure("After clearing")
