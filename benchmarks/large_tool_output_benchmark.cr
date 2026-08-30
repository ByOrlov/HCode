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

TOOL_SIZE = 10_000_000
COLS      =        120

measurements = [] of Measurement
puts "=== Large single tool output benchmark ==="
puts "Tool result size: #{(TOOL_SIZE / 1_048_576.0).round(2)} MB (matches Bash MAX_OUTPUT_BYTES)"
measurements << measure("Baseline")

_tool_output = "t" * TOOL_SIZE

memory = H2code::Context::Memory.new
memory.max_context_tokens = 262144
memory.add_user("Read a big file")
memory.add_assistant("")
memory.add_tool_result("tc_big", _tool_output)
ctx_m = measure("1. Context::Memory with 10 MB tool result")

messages = [] of TUIMessage
messages << TUIMessage.new("user", "Read a big file")
messages << TUIMessage.new("assistant", "")
messages << TUIMessage.new("tool", tool_preview_text(_tool_output))
tui_m = measure("2. TUI transcript (preview only)", "preview #{(messages[-1].content.bytesize / 1_048_576.0).round(3)} MB")

markdown = H2code::TUI::Markdown.new(H2code::TUI::Theme.dark)
rendered = markdown.render("```\n#{messages[-1].content}\n```", COLS)
render_m = measure("3. Markdown render of preview", "#{rendered.size} lines")

_request = H2code::LLM::ChatRequest.new(model: "mock", messages: memory.messages, tools: nil, stream: true)
_json_body = _request.to_json
json_m = measure("4. JSON request body", "#{(_json_body.bytesize / 1_048_576.0).round(2)} MB")

_tool_output = nil
memory.clear
_json_body = nil
_request = nil
messages.clear
after_clear = measure("5. After clearing everything")
final = measure("Final")

puts "\n=== Summary table ==="
puts "┌─────────────────────────────────────┬────────────────────────────────────┬────────────────────────────────────────────────┐"
puts "│ Что                                 │ Пиковый размер                     │ Роль в росте                                   │"
puts "├─────────────────────────────────────┼────────────────────────────────────┼────────────────────────────────────────────────┤"

puts "│ %-35s │ %34s │ %-46s │" % ["Context::Memory (full tool output)", "#{ctx_m.live_mb.round(2)} MB live", "Хранит полный 10 MB результат"]
puts "│ %-35s │ %34s │ %-46s │" % ["TUI transcript (preview)", "#{tui_m.live_mb.round(2)} MB live", "~1 KB превью вместо 10 MB"]
puts "│ %-35s │ %34s │ %-46s │" % ["Markdown render", "#{render_m.live_mb.round(2)} MB live", "Временный пик"]
puts "│ %-35s │ %34s │ %-46s │" % ["JSON request body", "#{json_m.live_mb.round(2)} MB live", "Пик сериализации 10 MB контекста"]
puts "│ %-35s │ %34s │ %-46s │" % ["After clear", "#{after_clear.rss_mb.round(2)} MB RSS", "GC не возвращает память ОС"]
puts "│ %-35s │ %34s │ %-46s │" % ["Final total RSS", "#{final.rss_mb.round(2)} MB", "Включая GC-страницы"]
puts "└─────────────────────────────────────┴────────────────────────────────────┴────────────────────────────────────────────────┘"
