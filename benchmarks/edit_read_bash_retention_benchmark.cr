require "json"
require "../src/llm/types"
require "../src/llm/token_counter"
require "../src/context/undo"
require "../src/context/memory"
require "../src/context/budget"

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

# Mirror TUI preview truncation.
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

def tool_args_preview(tool_name : String, args : String) : String
  return args if args.size <= 1000
  "#{args[0, 1000]}\n[... truncated; load session in /debug mode to expand ...]"
end

# Sizes chosen to mirror a real coding session:
#   - Edit: full method-body replacement. Model sends the surrounding
#     function as old_string and a slightly edited version as new_string.
#     Easily 5–30 KB on real refactors; bump to 80 KB to expose scaling.
#   - Read: full file 50 KB (right under Context::Budget threshold).
#   - Bash: 1 MB command output (test runner, build log) — budget truncates
#     to 50 KB before it lands in Memory.
#   - Thinking: reasoning trace, 8 KB per step.
EDIT_OLD_SIZE  =    80_000
EDIT_NEW_SIZE  =    80_000
READ_RESULT    =    50_000
BASH_RESULT    = 1_000_000
THINKING_SIZE  =     8_000
ASSISTANT_SIZE =     1_500
USER_SIZE      =       200

N_TURNS      = 100 # ~300 tool calls total
MAX_TOKENS   = ENV["H2CODE_MAX_TOKENS"]?.try(&.to_i?) || 262_144
COMPACT_KEEP = 6

puts "=== Edit + Read + Bash + thinking retention benchmark ==="
puts "Per-turn: 1 Edit(#{EDIT_OLD_SIZE / 1024}KB old+new) + 1 Read(#{READ_RESULT / 1024}KB) + 1 Bash(#{BASH_RESULT / 1024}KB→budget 50KB)"
puts "Plus thinking #{THINKING_SIZE / 1024}KB and assistant #{ASSISTANT_SIZE / 1024}KB per step"
puts "Turns: #{N_TURNS}, max_tokens=#{MAX_TOKENS} (compaction disabled)"
puts

measurements = [] of Measurement
measurements << measure("Baseline")

memory = H2code::Context::Memory.new
memory.max_context_tokens = MAX_TOKENS
memory.add_user("Initial prompt")
measurements << measure("After Memory.new")

# Track how much of Memory is tool_call.arguments vs everything else.
def breakdown(memory)
  args_bytes = 0_i64
  content_bytes = 0_i64
  memory.history.each do |cm|
    msg = cm.message
    if tcs = msg.tool_calls
      tcs.each { |tc| args_bytes += tc.arguments.bytesize }
    end
    c = msg.content.to_s
    content_bytes += c.bytesize
  end
  {args_bytes, content_bytes}
end

N_TURNS.times do |i|
  # === STEP 1: Edit call ===
  # Assistant emits thinking + tool_call(Edit) with full old/new strings.
  thinking_edit = "t" * THINKING_SIZE
  assistant_edit = thinking_edit + ("a" * ASSISTANT_SIZE)

  old_str = "o" * EDIT_OLD_SIZE
  new_str = "n" * EDIT_NEW_SIZE
  edit_args = %Q{{"path":"src/file#{i}.cr","old_string":"#{old_str}","new_string":"#{new_str}"}}
  edit_tc = H2code::LLM::ToolCall.new("tc_edit_#{i}", H2code::LLM::ToolCallFunction.new("Edit", edit_args))

  memory.add_assistant(assistant_edit, [edit_tc])
  memory.add_tool_result("tc_edit_#{i}", "Edited src/file#{i}.cr")

  # === STEP 2: Read call ===
  thinking_read = "t" * THINKING_SIZE
  assistant_read = thinking_read + ("a" * ASSISTANT_SIZE)
  read_args = %Q{{"file_path":"src/file#{i}.cr"}}
  read_tc = H2code::LLM::ToolCall.new("tc_read_#{i}", H2code::LLM::ToolCallFunction.new("Read", read_args))

  memory.add_assistant(assistant_read, [read_tc])

  # Read result goes through Context::Budget the same way ToolBatch does.
  raw_read = "r" * READ_RESULT
  budgeted_read, _tr = H2code::Context::Budget.budget("Read", "tc_read_#{i}", raw_read)
  memory.add_tool_result("tc_read_#{i}", budgeted_read)

  # === STEP 3: Bash call ===
  thinking_bash = "t" * THINKING_SIZE
  assistant_bash = thinking_bash + ("a" * ASSISTANT_SIZE)
  bash_args = %Q{{"command":"crystal spec && crystal tool format --check src/"}}
  bash_tc = H2code::LLM::ToolCall.new("tc_bash_#{i}", H2code::LLM::ToolCallFunction.new("Bash", bash_args))

  memory.add_assistant(assistant_bash, [bash_tc])

  raw_bash = "b" * BASH_RESULT
  budgeted_bash, _tb = H2code::Context::Budget.budget("Bash", "tc_bash_#{i}", raw_bash)
  memory.add_tool_result("tc_bash_#{i}", budgeted_bash)

  # === Compaction: mirrors Loop::Agent#trigger_compaction ===
  if memory.near_limit?
    old = memory.history
    kept_count = Math.min(COMPACT_KEEP, old.size)
    kept = old[-kept_count..] || [] of H2code::Context::ContextMessage
    summary = "[compaction summary after turn #{i}]"
    memory.apply_compaction(summary, kept)
  end

  if i % 10 == 9
    args_bytes, content_bytes = breakdown(memory)
    measurements << measure("  After turn #{i + 1}",
      "msgs=#{memory.history.size}, tokens=#{memory.token_count}, " \
      "args=#{(args_bytes / 1_048_576.0).round(2)}MB, content=#{(content_bytes / 1_048_576.0).round(2)}MB")
  end
end

args_bytes, content_bytes = breakdown(memory)
final_m = measure("1. After #{N_TURNS} turns (Memory)",
  "msgs=#{memory.history.size}, args=#{(args_bytes / 1_048_576.0).round(2)}MB, " \
  "content=#{(content_bytes / 1_048_576.0).round(2)}MB")

# Phase 2: simulate TUI transcript alongside (only previews).
tui_messages = [] of {String, String}
N_TURNS.times do |i|
  tui_messages << {"user", "u" * USER_SIZE}
  tui_messages << {"assistant_thinking", "t" * THINKING_SIZE}
  tui_messages << {"assistant_text", "a" * ASSISTANT_SIZE}
  # Edit card: tool_args is previewed in TUI, tool_result is previewed.
  tui_messages << {"tool_edit_args", tool_args_preview("Edit",
    %Q{{"path":"src/file#{i}.cr","old_string":"#{"o" * EDIT_OLD_SIZE}","new_string":"#{"n" * EDIT_NEW_SIZE}"}})}
  tui_messages << {"tool_edit_result", tool_preview_text("Edited src/file#{i}.cr")}
  # Read card.
  tui_messages << {"tool_read_args", %Q{{"file_path":"src/file#{i}.cr"}}}
  tui_messages << {"tool_read_result", tool_preview_text("r" * READ_RESULT)}
  # Bash card.
  tui_messages << {"tool_bash_args", %Q{{"command":"crystal spec"}}}
  tui_messages << {"tool_bash_result", tool_preview_text("b" * BASH_RESULT)}
end
tui_m = measure("2. TUI transcript (previews only)",
  "msgs=#{tui_messages.size}, stored=#{(tui_messages.sum { |_, c| c.bytesize } / 1_048_576.0).round(2)}MB")

# Phase 3: simulate per-step JSON request serialization peak.
_request = H2code::LLM::ChatRequest.new(model: "mock", messages: memory.messages, tools: nil, stream: true)
_json_body = _request.to_json
json_m = measure("3. JSON request body", "#{(_json_body.bytesize / 1_048_576.0).round(2)} MB")

# Phase 4: simulate one full markdown render of the TUI transcript (peak).
markdown = H2code::TUI::Markdown.new(H2code::TUI::Theme.dark)
rendered_bytes = 0_i64
tui_messages.each do |_, content|
  next if content.empty?
  rendered_bytes += markdown.render("```\n#{content}\n```", 120).sum(&.bytesize)
end
render_m = measure("4. Markdown render all TUI msgs", "#{(rendered_bytes / 1_048_576.0).round(2)} MB rendered")

# Phase 5: clear one thing at a time.
_json_body = nil
_request = nil
markdown = H2code::TUI::Markdown.new(H2code::TUI::Theme.dark)
measure("5. After JSON+request cleared")

tui_messages.clear
measure("6. After TUI transcript cleared")

memory.clear
after_memory_clear = measure("7. After Context::Memory cleared")

final = measure("Final")

puts
puts "=== Breakdown: what Memory actually holds ==="
puts "  tool_calls.arguments total: #{(args_bytes / 1_048_576.0).round(2)} MB " \
     "(#{(args_bytes.to_f64 / [1_i64, content_bytes].max).round(2)}x of content)"
puts "  content (assistant+user+tool_result) total: #{(content_bytes / 1_048_576.0).round(2)} MB"
puts
puts "=== Summary ==="
puts "┌─────────────────────────────────────┬───────────────┬──────────────────────────────────┐"
puts "│ Что                                 │ RSS, MB       │ Примечание                       │"
puts "├─────────────────────────────────────┼───────────────┼──────────────────────────────────┤"
puts "│ %-35s │ %13s │ %-32s │" % ["Baseline", measurements[0].rss_mb.round(2), "чистый стартап"]
puts "│ %-35s │ %13s │ %-32s │" % ["Memory после #{N_TURNS} turns", final_m.rss_mb.round(2), "args=#{(args_bytes / 1_048_576.0).round(2)}MB content=#{(content_bytes / 1_048_576.0).round(2)}MB"]
puts "│ %-35s │ %13s │ %-32s │" % ["+ TUI transcript (previews)", tui_m.rss_mb.round(2), "stored=#{(tui_messages.sum { |_, c| c.bytesize } / 1_048_576.0).round(2)}MB"]
puts "│ %-35s │ %13s │ %-32s │" % ["+ JSON request body", json_m.rss_mb.round(2), "body=#{(json_m.rss_mb - tui_m.rss_mb).round(2)}MB"]
puts "│ %-35s │ %13s │ %-32s │" % ["+ Markdown render", render_m.rss_mb.round(2), "transient"]
puts "│ %-35s │ %13s │ %-32s │" % ["After Memory.clear", after_memory_clear.rss_mb.round(2), "GC hoards pages"]
puts "│ %-35s │ %13s │ %-32s │" % ["Final RSS", final.rss_mb.round(2), ""]
puts "└─────────────────────────────────────┴───────────────┴──────────────────────────────────┘"
