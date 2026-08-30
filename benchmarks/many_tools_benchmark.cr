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

record TUIMessage, role : String, content : String

def rss_mb
  File.read("/proc/self/status").each_line do |line|
    if line.starts_with?("VmRSS:")
      return line.split[1].to_i / 1024.0
    end
  end
  0.0
end

def measure(label, note = "") : Measurement
  GC.collect
  stats = GC.stats
  rss = rss_mb
  heap = stats.heap_size / 1_048_576.0
  live = heap - (stats.free_bytes / 1_048_576.0)
  m = Measurement.new(label, rss, heap, live, note)
  puts "#{label}: RSS #{rss.round(2)} MB | heap #{heap.round(2)} MB | live #{live.round(2)} MB #{note}"
  m
end

TOOL_PREVIEW_LINES =   10
TOOL_PREVIEW_CHARS = 1000

def tool_preview_text(text : String) : String
  return text if text.empty?
  return text if text.size <= TOOL_PREVIEW_CHARS && text.count('\n') <= TOOL_PREVIEW_LINES

  preview = String.build(capacity: TOOL_PREVIEW_CHARS + 64) do |s|
    line_count = 0
    chars = 0
    text.each_char do |c|
      if c == '\n'
        line_count += 1
        break if line_count > TOOL_PREVIEW_LINES
      end
      break if chars >= TOOL_PREVIEW_CHARS
      s << c
      chars += 1
    end
  end
  preview + "\n[... truncated; load session in /debug mode to expand ...]"
end

N_TOOLS    = 10_000
TOOL_SIZE  =  1_000
MAX_TOKENS = 262144
COLS       =    120

measurements = [] of Measurement
puts "=== Many tool calls benchmark ==="
puts "Tool calls: #{N_TOOLS}, result each: #{TOOL_SIZE} chars"
measurements << measure("Baseline")

# Phase 1: Context::Memory with many tool results. Compaction will fire repeatedly.
memory = H2code::Context::Memory.new
memory.max_context_tokens = MAX_TOKENS
memory.add_user("Run many reads")
memory.add_assistant("")

compaction_count = 0
N_TOOLS.times do |i|
  memory.add_tool_result("tc_#{i}", "r" * TOOL_SIZE)

  if memory.token_count >= (MAX_TOKENS * 0.85).to_i
    old = memory.history.dup
    kept_count = Math.min(6, old.size)
    kept = old[-kept_count..] || [] of H2code::Context::ContextMessage
    summary = "[compaction summary after #{i} tool calls]"
    memory.apply_compaction(summary, kept)
    compaction_count += 1
  end
end
ctx_m = measure("1. Context::Memory filled", "compactions=#{compaction_count}, msgs=#{memory.history.size}, tokens=#{memory.token_count}")

# Phase 2: TUI transcript with previews only.
messages = [] of TUIMessage
N_TOOLS.times do |_|
  messages << TUIMessage.new("tool", tool_preview_text("r" * TOOL_SIZE))
end
tui_stored_mb = messages.sum(&.content.bytesize) / 1_048_576.0
tui_raw_mb = N_TOOLS * TOOL_SIZE / 1_048_576.0
tui_m = measure("2. TUI transcript with previews", "stored #{tui_stored_mb.round(2)} MB vs full #{tui_raw_mb.round(2)} MB")

# Phase 3: render markdown for all previews.
markdown = H2code::TUI::Markdown.new(H2code::TUI::Theme.dark)
rendered_bytes = 0_i64
messages.each do |msg|
  rendered_bytes += markdown.render("```\n#{msg.content}\n```", COLS).sum(&.bytesize)
end
render_m = measure("3. Markdown render", "#{rendered_bytes / 1_048_576.0} MB rendered")

# Phase 4: JSON request from compacted context.
_request = H2code::LLM::ChatRequest.new(model: "mock", messages: memory.messages, tools: nil, stream: true)
_json_body = _request.to_json
json_size_mb = _json_body.bytesize / 1_048_576.0
json_m = measure("4. JSON request body", "#{json_size_mb.round(2)} MB")

memory.clear
_json_body = nil
_request = nil
messages.clear
markdown = H2code::TUI::Markdown.new(H2code::TUI::Theme.dark)
after_clear = measure("5. After clearing everything")
final = measure("Final")

puts "\n=== Summary table ==="
puts "┌─────────────────────────────────────┬────────────────────────────────────┬────────────────────────────────────────────────┐"
puts "│ Что                                 │ Пиковый размер                     │ Роль в росте                                   │"
puts "├─────────────────────────────────────┼────────────────────────────────────┼────────────────────────────────────────────────┤"

puts "│ %-35s │ %34s │ %-46s │" % ["Context::Memory с compaction", "#{ctx_m.live_mb.round(2)} MB live", "compactions=#{compaction_count}, ~6 msgs"]
puts "│ %-35s │ %34s │ %-46s │" % ["TUI transcript (10k previews)", "#{tui_m.live_mb.round(2)} MB live", "#{tui_stored_mb.round(2)} MB stored vs #{tui_raw_mb.round(2)} MB full"]
puts "│ %-35s │ %34s │ %-46s │" % ["Markdown render", "#{render_m.live_mb.round(2)} MB live", "Временный пик"]
puts "│ %-35s │ %34s │ %-46s │" % ["JSON request body", "#{json_m.live_mb.round(2)} MB live", "#{json_size_mb.round(2)} MB compacted"]
puts "│ %-35s │ %34s │ %-46s │" % ["After clear", "#{after_clear.rss_mb.round(2)} MB RSS", "GC не возвращает память ОС"]
puts "│ %-35s │ %34s │ %-46s │" % ["Final total RSS", "#{final.rss_mb.round(2)} MB", "Включая GC-страницы"]
puts "└─────────────────────────────────────┴────────────────────────────────────┴────────────────────────────────────────────────┘"
