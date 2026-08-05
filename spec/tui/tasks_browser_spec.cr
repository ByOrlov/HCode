require "../spec_helper"

private def make_task(id : String, status : Hcode::Tools::AgentTaskStatus,
                      description : String = "test task",
                      started_at : Int64 = Time.utc.to_unix - 60) : Hcode::Tools::AgentTaskInfo
  Hcode::Tools::AgentTaskInfo.new(
    task_id: id,
    description: description,
    status: status,
    started_at: started_at,
    detached: true,
  )
end

private def key_event(key : Hcode::TUI::Key) : Hcode::TUI::KeyEvent
  Hcode::TUI::KeyEvent.new(key)
end

private def char_event(c : Char) : Hcode::TUI::KeyEvent
  Hcode::TUI::KeyEvent.new(Hcode::TUI::Key::Char, c)
end

describe Hcode::TUI::TasksBrowser do
  it "opens hidden and becomes visible after show" do
    browser = Hcode::TUI::TasksBrowser.new(Hcode::TUI::Theme.dark)
    browser.visible?.should be_false
    tasks = [make_task("t1", Hcode::Tools::AgentTaskStatus::Running)]
    on_fetch = Proc(Array(Hcode::Tools::AgentTaskInfo)).new { tasks }
    on_select = Proc(String, Nil).new { |_| }
    browser.show(on_fetch, on_select)
    browser.visible?.should be_true
  end

  it "lists tasks sorted (active first)" do
    browser = Hcode::TUI::TasksBrowser.new(Hcode::TUI::Theme.dark)
    tasks = [
      make_task("t-done", Hcode::Tools::AgentTaskStatus::Completed, started_at: 100),
      make_task("t-running", Hcode::Tools::AgentTaskStatus::Running, started_at: 200),
    ]
    on_fetch = Proc(Array(Hcode::Tools::AgentTaskInfo)).new { tasks }
    on_select = Proc(String, Nil).new { |_| }
    on_toggle = Proc(Nil).new { }
    browser.show(on_fetch, on_select, on_toggle_filter: on_toggle, initial_filter: Hcode::TUI::TasksBrowser::Filter::All)
    lines = browser.render(120).join("\n")
    lines.should contain("t-running")
    lines.should contain("t-done")
  end

  it "filters active vs all via toggle" do
    browser = Hcode::TUI::TasksBrowser.new(Hcode::TUI::Theme.dark)
    tasks = [
      make_task("t-done", Hcode::Tools::AgentTaskStatus::Completed, started_at: 100),
      make_task("t-running", Hcode::Tools::AgentTaskStatus::Running, started_at: 200),
    ]
    on_fetch = Proc(Array(Hcode::Tools::AgentTaskInfo)).new { tasks }
    on_select = Proc(String, Nil).new { |_| }
    toggled = [] of Bool
    on_toggle = Proc(Nil).new { toggled << true }
    browser.show(on_fetch, on_select, on_toggle_filter: on_toggle)
    # Default filter = Active → only running tasks.
    browser.filter.should eq(Hcode::TUI::TasksBrowser::Filter::Active)
    lines = browser.render(80).join("\n")
    lines.should contain("t-running")
    lines.should_not contain("t-done")
  end

  it "navigates with arrow keys" do
    browser = Hcode::TUI::TasksBrowser.new(Hcode::TUI::Theme.dark)
    tasks = [
      make_task("t1", Hcode::Tools::AgentTaskStatus::Running),
      make_task("t2", Hcode::Tools::AgentTaskStatus::Running),
    ]
    on_fetch = Proc(Array(Hcode::Tools::AgentTaskInfo)).new { tasks }
    on_select = Proc(String, Nil).new { |_| }
    browser.show(on_fetch, on_select)
    browser.selected_index.should eq(0)
    browser.handle_input(key_event(Hcode::TUI::Key::Down))
    browser.selected_index.should eq(1)
    browser.handle_input(key_event(Hcode::TUI::Key::Up))
    browser.selected_index.should eq(0)
  end

  it "navigates with j/k vim-style bindings" do
    browser = Hcode::TUI::TasksBrowser.new(Hcode::TUI::Theme.dark)
    tasks = [
      make_task("t1", Hcode::Tools::AgentTaskStatus::Running),
      make_task("t2", Hcode::Tools::AgentTaskStatus::Running),
    ]
    on_fetch = Proc(Array(Hcode::Tools::AgentTaskInfo)).new { tasks }
    on_select = Proc(String, Nil).new { |_| }
    browser.show(on_fetch, on_select)
    browser.selected_index.should eq(0)
    browser.handle_input(char_event('j'))
    browser.selected_index.should eq(1)
    browser.handle_input(char_event('k'))
    browser.selected_index.should eq(0)
  end

  it "cancels on Esc / q" do
    browser = Hcode::TUI::TasksBrowser.new(Hcode::TUI::Theme.dark)
    tasks = [make_task("t1", Hcode::Tools::AgentTaskStatus::Running)]
    on_fetch = Proc(Array(Hcode::Tools::AgentTaskInfo)).new { tasks }
    on_select = Proc(String, Nil).new { |_| }
    cancelled = [] of Bool
    on_cancel = Proc(Nil).new { cancelled << true }
    browser.show(on_fetch, on_select, on_cancel: on_cancel)
    browser.handle_input(key_event(Hcode::TUI::Key::Escape))
    cancelled.should eq([true])
  end

  it "renders too-small fallback" do
    browser = Hcode::TUI::TasksBrowser.new(Hcode::TUI::Theme.dark)
    browser.rows = 5
    tasks = [make_task("t1", Hcode::Tools::AgentTaskStatus::Running)]
    on_fetch = Proc(Array(Hcode::Tools::AgentTaskInfo)).new { tasks }
    on_select = Proc(String, Nil).new { |_| }
    browser.show(on_fetch, on_select)
    lines = browser.render(80) # wide enough that width is OK; rows triggers fallback
    # Strip ANSI to test the visible message.
    plain = lines.join("\n").gsub(/\e\[[0-9;]*m/, "")
    plain.should contain("Terminal too small")
  end

  it "renders header with counts" do
    browser = Hcode::TUI::TasksBrowser.new(Hcode::TUI::Theme.dark)
    tasks = [
      make_task("t1", Hcode::Tools::AgentTaskStatus::Running),
      make_task("t2", Hcode::Tools::AgentTaskStatus::Running),
    ]
    on_fetch = Proc(Array(Hcode::Tools::AgentTaskInfo)).new { tasks }
    on_select = Proc(String, Nil).new { |_| }
    browser.show(on_fetch, on_select)
    plain = browser.render(120).join("\n").gsub(/\e\[[0-9;]*m/, "")
    plain.should contain("TASK BROWSER")
    plain.should contain("2 running")
    plain.should contain("2 total")
  end
end
