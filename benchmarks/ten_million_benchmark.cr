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
  property note : String

  def initialize(@label, @rss_mb, @heap_mb, @live_mb, @note = "")
  end
end

measurements = [] of Measurement

def rss_mb
  File.read("/proc/self/status").each_line do |line|
    if line.starts_with?("VmRSS:")
      return line.split[1].to_i / 1024.0
    end
  end
  0.0
end

def measure(label, note = "")
  GC.collect
  stats = GC.stats
  rss = rss_mb
  heap = stats.heap_size / 1_048_576.0
  live = heap - (stats.free_bytes / 1_048_576.0)
  m = Measurement.new(label, rss, heap, live, note)
  puts "#{label}: RSS #{rss.round(2)} MB | heap #{heap.round(2)} MB | live #{live.round(2)} MB #{note}"
  m
end

record TUIMessage, role : String, content : String

TOTAL_SIZE      = 10_000_000
CHUNK_SIZE      =    200_000
LINE_LEN        =      1_000
COLS            =        120
LINE_WITH_NL    = LINE_LEN + 1
LINES_PER_CHUNK = CHUNK_SIZE // LINE_WITH_NL
CHUNK_REAL_SIZE = LINES_PER_CHUNK * LINE_WITH_NL
CHUNK_COUNT     = TOTAL_SIZE // CHUNK_REAL_SIZE
REAL_TOTAL      = CHUNK_COUNT * CHUNK_REAL_SIZE

puts "=== Benchmark: cumulative #{TOTAL_SIZE} char assistant response ==="
puts "Chunk size: ~#{CHUNK_REAL_SIZE} chars (#{LINES_PER_CHUNK} lines of #{LINE_LEN} chars)"
puts "Total chunks: #{CHUNK_COUNT}, real total: #{REAL_TOTAL} chars (#{(REAL_TOTAL / 1_048_576.0).round(2)} MB raw)"

measurements << measure("Baseline")

def build_chunk(i : Int32, line_len : Int32, lines : Int32) : String
  marker = (i % 10).to_s
  line = ("a" * (line_len - 1)) + marker + "\n"
  line * lines
end

memory = H2code::Context::Memory.new
memory.max_context_tokens = 262144
memory.add_user("prompt")

messages = [] of TUIMessage
messages << TUIMessage.new("user", "prompt")

# Phase A: fill Context::Memory
CHUNK_COUNT.times do |i|
  chunk = build_chunk(i, LINE_LEN, LINES_PER_CHUNK)
  memory.add_assistant(chunk)

  if (i + 1) % 5 == 0 || i == CHUNK_COUNT - 1
    measurements << measure("Context chunk #{i + 1}/#{CHUNK_COUNT}", "#{(i + 1) * CHUNK_REAL_SIZE} chars")
  end
end
ctx_final = measurements.last

# Phase B: duplicate into TUI transcript
CHUNK_COUNT.times do |i|
  chunk = build_chunk(i, LINE_LEN, LINES_PER_CHUNK)
  messages << TUIMessage.new("assistant", chunk)

  if (i + 1) % 5 == 0 || i == CHUNK_COUNT - 1
    measurements << measure("TUI chunk #{i + 1}/#{CHUNK_COUNT}", "#{(i + 1) * CHUNK_REAL_SIZE} chars")
  end
end
tui_final = measurements.last

# Phase C: render markdown for all assistant messages
markdown = H2code::TUI::Markdown.new(H2code::TUI::Theme.dark)
rendered_lines = 0_i64
rendered_bytes = 0_i64
messages.each do |msg|
  next unless msg.role == "assistant"
  lines = markdown.render(msg.content, COLS)
  rendered_lines += lines.size
  rendered_bytes += lines.sum(&.bytesize)
end
render_m = measure("After markdown render", "#{rendered_lines} lines, #{(rendered_bytes / 1_048_576.0).round(2)} MB")

# Phase D: serialize request to JSON
_request = H2code::LLM::ChatRequest.new(
  model: "mock",
  messages: memory.messages,
  tools: nil,
  stream: true,
)
_json_body = _request.to_json
json_m = measure("After request.to_json", "JSON body #{(_json_body.bytesize / 1_048_576.0).round(2)} MB")

# Phase E: clear
memory.clear
_json_body = nil
_request = nil
measurements << measure("After Context::Memory cleared", "TUI still holds messages")

messages.clear
measurements << measure("After TUI transcript cleared", "objects freed")

final = measure("Final")

puts "\n=== Summary table ==="
puts "┌─────────────────────────────────────────┬────────────────────┬────────────────────────────────────────────────────┐"
puts "│ Что                                     │ Пиковый размер     │ Роль в росте                                       │"
puts "├─────────────────────────────────────────┼────────────────────┼────────────────────────────────────────────────────┤"

ctx_delta = ctx_final.rss_mb - measurements.first.rss_mb
tui_delta = tui_final.rss_mb - ctx_final.rss_mb
render_delta = render_m.rss_mb - tui_final.rss_mb
json_delta = json_m.rss_mb - render_m.rss_mb
after_clear = measurements[-2].rss_mb

puts "│ %-39s │ %18s │ %-50s │" % ["Context::Memory (cumulative)", "#{ctx_final.rss_mb.round(2)} MB", "+#{ctx_delta.round(2)} MB over baseline"]
puts "│ %-39s │ %18s │ %-50s │" % ["TUI transcript duplicate", "#{tui_final.rss_mb.round(2)} MB", "+#{tui_delta.round(2)} MB over context-only"]
puts "│ %-39s │ %18s │ %-50s │" % ["Markdown render", "#{render_m.rss_mb.round(2)} MB", "+#{render_delta.round(2)} MB transient"]
puts "│ %-39s │ %18s │ %-50s │" % ["JSON request body", "#{json_m.rss_mb.round(2)} MB", "+#{json_delta.round(2)} MB serialization peak"]
puts "│ %-39s │ %18s │ %-50s │" % ["Boehm GC after clear", "#{after_clear.round(2)} MB", "Heap pages not returned to OS"]
puts "│ %-39s │ %18s │ %-50s │" % ["Final total RSS", "#{final.rss_mb.round(2)} MB", "Includes GC hoarded pages"]
puts "└─────────────────────────────────────────┴────────────────────┴────────────────────────────────────────────────────┘"
puts "\nFinal GC heap: #{final.heap_mb.round(2)} MB, live: #{final.live_mb.round(2)} MB, free: #{(final.heap_mb - final.live_mb).round(2)} MB"
