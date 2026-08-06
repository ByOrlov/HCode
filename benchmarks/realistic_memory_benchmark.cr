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

def rss_mb
  File.read("/proc/self/status").each_line do |line|
    if line.starts_with?("VmRSS:")
      return line.split[1].to_i / 1024.0
    end
  end
  0.0
end

def gc_and_measure(label)
  GC.collect
  stats = GC.stats
  puts "#{label}: RSS #{rss_mb.round(2)} MB | heap #{stats.heap_size / 1_048_576.0} MB | free #{stats.free_bytes / 1_048_576.0} MB"
end

record TUIMessage, role : String, content : String, tool_result : String? = nil

N_TURNS        =   2000
TOOL_SIZE      = 50_000
ASSISTANT_SIZE =  5_000
USER_SIZE      =    200
MAX_TOKENS     = 262144
COMPACT_KEEP   =      6

memory = Hcode::Context::Memory.new
memory.max_context_tokens = MAX_TOKENS

messages = [] of TUIMessage
markdown = Hcode::TUI::Markdown.new(Hcode::TUI::Theme.dark)

compaction_count = 0
json_peak = 0.0
context_peak = 0.0

puts "=== Realistic benchmark with compaction ==="
gc_and_measure("Baseline")

N_TURNS.times do |i|
  user = "u" * USER_SIZE
  assistant = "a" * ASSISTANT_SIZE
  tool = "t" * TOOL_SIZE

  memory.add_user(user)
  memory.add_assistant(assistant)
  memory.add_tool_result("tc_#{i}", tool)

  messages << TUIMessage.new("user", user)
  messages << TUIMessage.new("assistant", assistant)
  messages << TUIMessage.new("tool", "", tool)

  # Trigger compaction when near limit, similar to Agent#run_turn
  if memory.token_count >= (MAX_TOKENS * 0.85).to_i
    compaction_count += 1
    old = memory.history.dup
    kept_count = Math.min(COMPACT_KEEP, old.size)
    kept = old[-kept_count..] || [] of Hcode::Context::ContextMessage
    summary = "[compaction summary for turns #{i - old.size + 1}..#{i}]"
    memory.apply_compaction(summary, kept)

    if (h = memory.history.size * (USER_SIZE + ASSISTANT_SIZE + TOOL_SIZE) / 1_048_576.0) > context_peak
      context_peak = h
    end
  end

  if i % 500 == 0 && i > 0
    # measure JSON request size at this point
    req = Hcode::LLM::ChatRequest.new(model: "mock", messages: memory.messages, tools: nil, stream: true)
    json = req.to_json
    json_peak = {json_peak, json.bytesize / 1_048_576.0}.max
    gc_and_measure("After #{i} turns, compactions=#{compaction_count}")
    puts "   Context messages: #{memory.history.size}, tokens: #{memory.token_count}, TUI messages: #{messages.size}, JSON: #{(json.bytesize / 1_048_576.0).round(2)} MB"
  end
end

gc_and_measure("After all turns")
puts "Compaction count: #{compaction_count}"
puts "Peak JSON body: #{json_peak.round(2)} MB"
puts "Approx raw text in TUI: #{(messages.size * (USER_SIZE + ASSISTANT_SIZE + TOOL_SIZE) / 3.0 / 1_048_576.0).round(2)} MB"

# Clear context but keep TUI
memory.clear
GC.collect
gc_and_measure("After Context::Memory cleared")

# Render TUI messages once
rendered_bytes = 0_i64
messages.each do |msg|
  content = msg.tool_result || msg.content
  next if content.empty?
  rendered_bytes += markdown.render("```\n#{content}\n```", 120).sum(&.bytesize)
end
gc_and_measure("After rendering all TUI messages")
puts "Rendered bytes: #{(rendered_bytes / 1_048_576.0).round(2)} MB"

messages.clear
GC.collect
gc_and_measure("After TUI cleared")
