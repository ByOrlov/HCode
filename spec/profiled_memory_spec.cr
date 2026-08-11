require "./spec_helper"

describe Hcode::ProfiledMemory do
  describe "String#profiled_bytes" do
    it "counts bytesize plus header overhead" do
      "hello".profiled_bytes.should eq(5 + 24)
      "".profiled_bytes.should eq(24)
      "привет".profiled_bytes.should eq(12 + 24) # UTF-8: 2 bytes per char
    end
  end

  describe ".register and .snapshot" do
    before_each do
      Hcode::ProfiledMemory.clear
    end

    it "registers a calculator and retrieves its snapshot" do
      val = 100_i64
      Hcode::ProfiledMemory.register("test", "Test Collection",
        calc: -> { val }, count: -> { 3 })

      snaps = Hcode::ProfiledMemory.snapshot
      snaps.size.should eq(1)
      snaps.first.id.should eq("test")
      snaps.first.label.should eq("Test Collection")
      snaps.first.bytes.should eq(100)
      snaps.first.count.should eq(3)
    end

    it "reflects live changes through the closure" do
      mem = Hcode::Context::Memory.new
      Hcode::ProfiledMemory.register("ctx", "context",
        calc: -> { mem.profiled_bytes }, count: -> { mem.profiled_count })

      before = Hcode::ProfiledMemory.snapshot.first.bytes
      mem.add_user("A" * 1000)
      after = Hcode::ProfiledMemory.snapshot.first.bytes
      after.should be > before
    end

    it "deduplicates by id (re-register replaces)" do
      Hcode::ProfiledMemory.register("dup", "First", calc: -> { 1_i64 })
      Hcode::ProfiledMemory.register("dup", "Second", calc: -> { 2_i64 })

      snaps = Hcode::ProfiledMemory.snapshot
      snaps.size.should eq(1)
      snaps.first.bytes.should eq(2)
      snaps.first.label.should eq("Second")
    end

    it "total_bytes sums all entries" do
      Hcode::ProfiledMemory.register("a", "A", calc: -> { 10_i64 })
      Hcode::ProfiledMemory.register("b", "B", calc: -> { 20_i64 })
      Hcode::ProfiledMemory.total_bytes.should eq(30)
    end

    it "format_report produces human-readable output" do
      Hcode::ProfiledMemory.register("big", "Big Collection",
        calc: -> { 2_000_000_i64 }, count: -> { 42 })
      report = Hcode::ProfiledMemory.format_report
      report.should contain("Memory Profile")
      report.should contain("tracked:")
      report.should contain("Big Collection")
      report.should contain("MB")
      report.should contain("42 items")
      report.should contain("GC heap:")
      report.should contain("GC arenas:")
      report.should contain("Binary + libs:")
      report.should contain("RSS (process)")
    end

    it "defaults count to 0 when counter omitted" do
      Hcode::ProfiledMemory.register("n", "NoCount", calc: -> { 50_i64 })
      Hcode::ProfiledMemory.snapshot.first.count.should eq(0)
    end

    it "registered? tracks ids" do
      Hcode::ProfiledMemory.registered?("x").should be_false
      Hcode::ProfiledMemory.register("x", "X", calc: -> { 0_i64 })
      Hcode::ProfiledMemory.registered?("x").should be_true
    end
  end
end

describe Hcode::LLM::Message do
  describe "#profiled_bytes" do
    it "sums role and content parts" do
      msg = Hcode::LLM::Message.user("hello")
      part = msg.content[0].as(Hcode::LLM::TextContent)
      expected = "user".profiled_bytes + part.profiled_bytes
      msg.profiled_bytes.should eq(expected)
    end

    it "includes tool_calls arguments" do
      tc = Hcode::LLM::ToolCall.new("id", Hcode::LLM::ToolCallFunction.new(Hcode::Tools::Names::BASH, "command"))
      msg = Hcode::LLM::Message.assistant("ran a command", [tc])
      part = msg.content.first
      expected = "assistant".profiled_bytes +
                 part.profiled_bytes +
                 "id".profiled_bytes + "function".profiled_bytes +
                 Hcode::Tools::Names::BASH.profiled_bytes + "command".profiled_bytes
      msg.profiled_bytes.should eq(expected)
    end
  end
end

describe Hcode::Context::Memory do
  describe "#profiled_bytes" do
    it "grows when messages are added" do
      mem = Hcode::Context::Memory.new
      before = mem.profiled_bytes
      mem.add_user("A" * 500)
      mem.profiled_bytes.should be > before
    end

    it "drops after clear" do
      mem = Hcode::Context::Memory.new
      mem.add_user("X" * 200)
      populated = mem.profiled_bytes
      mem.clear
      mem.profiled_bytes.should be < populated
    end
  end
end
