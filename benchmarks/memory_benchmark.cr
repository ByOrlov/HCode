require "json"
require "../src/llm/types"
require "../src/llm/token_counter"
require "../src/context/undo"
require "../src/context/memory"

# TUI render stack
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
  free_mb = stats.free_bytes / 1_048_576.0
  heap_mb = stats.heap_size / 1_048_576.0
  puts "#{label}: RSS #{rss_mb.round(2)} MB | GC heap #{heap_mb.round(2)} MB | GC free #{free_mb.round(2)} MB"
end

record TUIMessage, role : String, content : String, tool_result : String? = nil

N_TURNS        = 1000
TOOL_SIZE      = 50_000
ASSISTANT_SIZE = 5_000
USER_SIZE      = 200
COLS           = 120

puts "=== Memory benchmark ==="
puts "Turns: #{N_TURNS}, tool_result: #{TOOL_SIZE} chars, assistant: #{ASSISTANT_SIZE} chars, user: #{USER_SIZE} chars"
gc_and_measure("Baseline")

# 1. Context::Memory
memory = Hcode::Context::Memory.new
memory.max_context_tokens = 262144

N_TURNS.times do |i|
  memory.add_user("u" * USER_SIZE)
  memory.add_assistant("a" * ASSISTANT_SIZE)
  memory.add_tool_result("tc_#{i}", "t" * TOOL_SIZE)
end
gc_and_measure("1. Context::Memory filled")

# Calculate raw text stored
raw_text_bytes = N_TURNS * (USER_SIZE + ASSISTANT_SIZE + TOOL_SIZE)
puts "   Raw text in context: #{(raw_text_bytes / 1_048_576.0).round(2)} MB"
puts "   Messages: #{memory.history.size}, token estimate: #{memory.token_count}"

# 2. TUI duplicate transcript
messages = [] of TUIMessage
N_TURNS.times do |i|
  messages << TUIMessage.new("user", "u" * USER_SIZE)
  messages << TUIMessage.new("assistant", "a" * ASSISTANT_SIZE)
  messages << TUIMessage.new("tool", "", "t" * TOOL_SIZE)
end
gc_and_measure("2. TUI transcript duplicate")

# 3. Rendered markdown lines (assistant + tool results)
markdown = Hcode::TUI::Markdown.new(Hcode::TUI::Theme.dark)
rendered_lines = 0
rendered_chars = 0

N_TURNS.times do |i|
  assistant_lines = markdown.render("a" * ASSISTANT_SIZE, COLS)
  rendered_lines += assistant_lines.size
  rendered_chars += assistant_lines.sum(&.bytesize)

  tool_lines = markdown.render("```\n" + ("t" * TOOL_SIZE) + "\n```", COLS)
  rendered_lines += tool_lines.size
  rendered_chars += tool_lines.sum(&.bytesize)
end
gc_and_measure("3. After markdown render of all messages")
puts "   Rendered lines: #{rendered_lines}, rendered bytes: #{(rendered_chars / 1_048_576.0).round(2)} MB"

# 4. HTTP request JSON serialization
request = Hcode::LLM::ChatRequest.new(
  model: "mock",
  messages: memory.messages,
  tools: nil,
  stream: true,
)
json_body = request.to_json
gc_and_measure("4. After request.to_json")
puts "   JSON body size: #{(json_body.bytesize / 1_048_576.0).round(2)} MB"

# 5. Simulated Bash peak: 5 parallel captures of 10 MB each
buffers = [] of String
5.times do
  io = IO::Memory.new
  io.write(Bytes.new(10 * 1024 * 1024, 65_u8))
  buffers << io.to_s
end
gc_and_measure("5. Peak: 5 Bash buffers x 10 MB")
buffers.clear
gc_and_measure("   After clearing Bash buffers")

# 6. Simulate compaction: Context::Memory is cleared, but TUI transcript stays
memory.clear
json_body = nil
request = nil
GC.collect
gc_and_measure("6. After Context::Memory cleared (TUI still holds history)")

# 7. Clear TUI transcript too
messages.clear
GC.collect
gc_and_measure("7. After TUI transcript cleared")

puts "=== Final RSS: #{rss_mb.round(2)} MB ==="
