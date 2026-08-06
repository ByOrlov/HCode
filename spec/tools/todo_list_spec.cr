require "../spec_helper"

describe Hcode::Tools::TodoList do
  it "exposes JS-schema parameter names" do
    todo = Hcode::Tools::TodoList.new
    props = todo.parameters["properties"].as_h
    props.has_key?("todos").should be_true
    item_props = props["todos"].as_h["items"].as_h["properties"].as_h
    item_props.has_key?("title").should be_true
    item_props.has_key?("status").should be_true
    item_props.has_key?("content").should be_false
    item_props.has_key?("priority").should be_false
    enum_values = item_props["status"].as_h["enum"].as_a.map(&.to_s)
    enum_values.should contain("pending")
    enum_values.should contain("in_progress")
    enum_values.should contain("done")
    enum_values.should_not contain("completed")
    enum_values.should_not contain("cancelled")
  end

  it "creates a todo list with JS status markers" do
    todo = Hcode::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"task A","status":"pending"},{"title":"task B","status":"done"}]})))
    result.is_error?.should be_false
    result.content.should contain("task A")
    result.content.should contain("task B")
    result.content.should contain("[pending]")
    result.content.should contain("[done]")
  end

  it "appends the write reminder after a mutation" do
    todo = Hcode::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"x","status":"in_progress"}]})))
    result.is_error?.should be_false
    result.content.should contain("in_progress")
    result.content.should contain("Ensure that you continue to use the todo list")
  end

  it "accepts in_progress status" do
    todo = Hcode::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"active","status":"in_progress"}]})))
    result.is_error?.should be_false
    result.content.should contain("[in_progress]")
  end

  it "handles empty todos (clear mode)" do
    todo = Hcode::Tools::TodoList.new
    # First populate
    todo.execute(JSON.parse(%({"todos":[{"title":"a","status":"pending"}]})))
    # Then clear
    result = todo.execute(JSON.parse(%({"todos":[]})))
    result.is_error?.should be_false
    result.content.should contain("cleared")
  end

  it "query mode: omit todos to read the current list without mutation" do
    todo = Hcode::Tools::TodoList.new
    todo.execute(JSON.parse(%({"todos":[{"title":"read me","status":"pending"}]})))
    result = todo.execute(JSON.parse(%({})))
    result.is_error?.should be_false
    result.content.should contain("read me")
    result.content.should contain("[pending]")
    # No write reminder in query mode.
    result.content.should_not contain("Ensure that you continue")
  end

  it "query mode on an empty list" do
    todo = Hcode::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({})))
    result.is_error?.should be_false
    result.content.should contain("empty")
  end

  it "accepts the legacy `completed` status as an alias for `done`" do
    todo = Hcode::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"old","status":"completed"}]})))
    result.is_error?.should be_false
    result.content.should contain("[done]")
  end

  it "defaults status to pending when missing" do
    todo = Hcode::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"no status"}]})))
    result.is_error?.should be_false
    result.content.should contain("[pending]")
  end
end
