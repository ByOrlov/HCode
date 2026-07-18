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

# Same preview logic the TUI now uses after DEBUG-MODE.
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

N_TURNS        = 2000
TOOL_SIZE      = 50_000
ASSISTANT_SIZE = 5_000
USER_SIZE      = 200
MAX_TOKENS     = 262144
COMPACT_KEEP   = 6
COLS           = 120

measurements = [] of Measurement

puts "=== 2000 turns benchmark (post DEBUG-MODE) ==="
puts "Tool results in TUI are stored as #{TOOL_PREVIEW_LINES}-line / #{TOOL_PREVIEW_CHARS}-char previews"
measurements << measure("Baseline")

# Phase 1: Context::Memory with realistic compaction.
memory = Hcode::Context::Memory.new
memory.max_context_tokens = MAX_TOKENS

compaction_count = 0
json_peak_mb = 0.0
context_peak_raw_mb = 0.0

N_TURNS.times do |i|
  memory.add_user("u" * USER_SIZE)
  memory.add_assistant("a" * ASSISTANT_SIZE)
  memory.add_tool_result("tc_#{i}", "t" * TOOL_SIZE)

  if memory.token_count >= (MAX_TOKENS * 0.85).to_i
    old = memory.history.dup
    kept_count = Math.min(COMPACT_KEEP, old.size)
    kept = old[-kept_count..] || [] of Hcode::Context::ContextMessage
    summary = "[compaction summary for turns #{i - old.size + 1}..#{i}]"
    memory.apply_compaction(summary, kept)
    compaction_count += 1
  end

  ctx_raw_mb = memory.history.sum do |cm|
    msg = cm.message
    base = msg.content.to_s.size
    extra = msg.tool_calls.try { |tcs| tcs.sum { |tc| tc.name.size + tc.arguments.size } } || 0
    base + extra
  end / 1_048_576.0
  context_peak_raw_mb = {context_peak_raw_mb, ctx_raw_mb}.max

  if i % 500 == 0 && i > 0
    req = Hcode::LLM::ChatRequest.new(model: "mock", messages: memory.messages, tools: nil, stream: true)
    json = req.to_json
    json_peak_mb = {json_peak_mb, json.bytesize / 1_048_576.0}.max
    measure("   at turn #{i}", "compactions=#{compaction_count}, context msgs=#{memory.history.size}, tokens=#{memory.token_count}, JSON=#{(json.bytesize / 1_048_576.0).round(2)} MB")
  end
end

ctx_m = measure("1. Context::Memory filled", "compactions=#{compaction_count}, msgs=#{memory.history.size}, tokens=#{memory.token_count}")
puts "   Context raw text peak (compacted): #{context_peak_raw_mb.round(2)} MB"

# Phase 2: TUI transcript keeps only tool previews.
messages = [] of TUIMessage
N_TURNS.times do |i|
  messages << TUIMessage.new("user", "u" * USER_SIZE)
  messages << TUIMessage.new("assistant", "a" * ASSISTANT_SIZE)
  messages << TUIMessage.new("tool", tool_preview_text("t" * TOOL_SIZE))
end

tui_stored_mb = messages.sum(&.content.bytesize) / 1_048_576.0
tui_raw_mb = N_TURNS * (USER_SIZE + ASSISTANT_SIZE + TOOL_SIZE) / 1_048_576.0
tui_m = measure("2. TUI transcript with previews", "stored #{tui_stored_mb.round(2)} MB vs full #{tui_raw_mb.round(2)} MB")

# Phase 3: render markdown for the TUI transcript.
markdown = Hcode::TUI::Markdown.new(Hcode::TUI::Theme.dark)
rendered_bytes = 0_i64
messages.each do |msg|
  content = msg.content
  next if content.empty?
  rendered_bytes += markdown.render("```\n#{content}\n```", COLS).sum(&.bytesize)
end
render_m = measure("3. Markdown render", "#{rendered_bytes / 1_048_576.0} MB rendered")

# Phase 4: serialize compacted context to JSON.
request = Hcode::LLM::ChatRequest.new(model: "mock", messages: memory.messages, tools: nil, stream: true)
json_body = request.to_json
json_peak_mb = {json_peak_mb, json_body.bytesize / 1_048_576.0}.max
json_m = measure("4. JSON request body", "JSON body #{(json_body.bytesize / 1_048_576.0).round(2)} MB, peak #{json_peak_mb.round(2)} MB")

# Phase 5: clear everything.
memory.clear
json_body = nil
request = nil
after_ctx_clear = measure("5. After Context::Memory cleared", "TUI still holds messages")

messages.clear
markdown = Hcode::TUI::Markdown.new(Hcode::TUI::Theme.dark)
after_tui_clear = measure("6. After TUI transcript cleared")

final = measure("Final")

puts "\n=== Summary table ==="
puts "┌─────────────────────────────────────┬────────────────────────────────────┬────────────────────────────────────────────────┐"
puts "│ Что                                 │ Пиковый размер                     │ Роль в росте                                   │"
puts "├─────────────────────────────────────┼────────────────────────────────────┼────────────────────────────────────────────────┤"

ctx_delta = ctx_m.live_mb - measurements.first.live_mb
tui_delta = tui_m.live_mb - ctx_m.live_mb
render_delta = render_m.live_mb - tui_m.live_mb
json_delta = json_m.live_mb - render_m.live_mb

puts "│ %-35s │ %34s │ %-46s │" % ["Context::Memory с compaction", "#{ctx_m.live_mb.round(2)} MB live", "+#{ctx_delta.round(2)} MB; compaction держит ~#{COMPACT_KEEP} сообщений"]
puts "│ %-35s │ %34s │ %-46s │" % ["TUI transcript (@messages)", "#{tui_m.live_mb.round(2)} MB live", "+#{tui_delta.round(2)} MB; только превью (#{tui_stored_mb.round(2)} MB из #{tui_raw_mb.round(2)} MB)"]
puts "│ %-35s │ %34s │ %-46s │" % ["Markdown render", "#{render_m.live_mb.round(2)} MB live", "+#{render_delta.round(2)} MB временный пик"]
puts "│ %-35s │ %34s │ %-46s │" % ["JSON request body (request.to_json)", "#{json_m.live_mb.round(2)} MB live", "+#{json_delta.round(2)} MB; пик JSON #{json_peak_mb.round(2)} MB"]
puts "│ %-35s │ %34s │ %-46s │" % ["Boehm GC после очистки всего", "#{after_tui_clear.rss_mb.round(2)} MB RSS", "free #{(after_tui_clear.heap_mb - after_tui_clear.live_mb).round(2)} MB не возвращает ОС"]
puts "│ %-35s │ %34s │ %-46s │" % ["Final total RSS", "#{final.rss_mb.round(2)} MB", "Включая GC-страницы"]
puts "└─────────────────────────────────────┴────────────────────────────────────┴────────────────────────────────────────────────┘"
