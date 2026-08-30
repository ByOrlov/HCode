require "../spec_helper"

describe H2code::Plugin::Store do
  it "returns empty array when installed.json does not exist" do
    with_tmpdir do |home|
      H2code::Plugin::Store.read(home).should eq([] of H2code::Plugin::Store::InstalledRecord)
    end
  end

  it "round-trips records through write + read" do
    with_tmpdir do |home|
      records = [
        H2code::Plugin::Store::InstalledRecord.new(
          id: "my-plugin",
          root: "/some/path",
          source: "local-path",
          enabled: true,
          installed_at: "2026-01-01T00:00:00Z",
          original_source: "/original",
        ),
        H2code::Plugin::Store::InstalledRecord.new(
          id: "disabled-plugin",
          root: "/other/path",
          source: "github",
          enabled: false,
          installed_at: "2026-02-01T00:00:00Z",
        ),
      ]
      H2code::Plugin::Store.write(home, records)

      read_back = H2code::Plugin::Store.read(home)
      read_back.size.should eq(2)

      r0 = read_back[0]
      r0.id.should eq("my-plugin")
      r0.root.should eq("/some/path")
      r0.source.should eq("local-path")
      r0.enabled?.should be_true
      r0.installed_at.should eq("2026-01-01T00:00:00Z")
      r0.original_source.should eq("/original")
    end
  end

  it "persists and reads back capabilities" do
    with_tmpdir do |home|
      caps = H2code::Plugin::PluginCapabilityState.new(
        {"server1" => H2code::Plugin::PluginMcpServerState.new(false)}
      )
      record = H2code::Plugin::Store::InstalledRecord.new(
        id: "cap-plugin", root: "/path", source: "local-path",
        enabled: true, capabilities: caps,
      )
      H2code::Plugin::Store.write(home, [record])

      read_back = H2code::Plugin::Store.read(home)
      r = read_back[0]
      r.capabilities.should_not be_nil
      if caps = r.capabilities
        caps.mcp_servers["server1"].enabled?.should be_false
      end
    end
  end
end
