# Resolve the build version: explicit HCODE_VERSION wins, then the most
# recent git tag (`git describe --tags --abbrev=0`), then "0.0.0-dev".
def hcode_build_version
  return ENV["HCODE_VERSION"] if ENV.key?("HCODE_VERSION")
  tag = `git describe --tags --abbrev=0 2>/dev/null`.strip
  tag.empty? ? "0.0.0-dev" : tag
end

def build_hcode(output = "hcode", release: false)
  flags = ["--warnings none", "--no-color"]
  flags << "--release" if release
  sh "HCODE_VERSION=#{hcode_build_version} crystal build src/hcode.cr -o #{output} #{flags.join(' ')}"
end

desc "Build the hcode binary"
task :build do
  build_hcode
end

desc "Build the hcode binary with --release"
task :build_release do
  build_hcode(release: true)
end

namespace :run do
  desc "Build (debug) and run the TUI"
  task :default => :build do
    sh "./hcode --yolo"
  end

  desc "Build with --release and run the TUI"
  task :release => :build_release do
    sh "./hcode --yolo"
  end
end

# Backward-compatible alias for `rake run:default`.
desc "Build (debug) and run the TUI (alias of run:default)"
task :run => "run:default"

desc "Run the test suite"
task :spec do
  sh "crystal spec --warnings none --no-color"
end

namespace :mock do
  desc "Run TUI with mock provider — default self-test script (parallel tools)"
  task :default => :build do
    sh "HCODE_PROVIDER=mock ./hcode --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking streaming demo (~5s)"
  task :thinking => :build do
    sh "HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=thinking ./hcode --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking + tool call demo"
  task :thinking_tools => :build do
    sh "HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=thinking-tools ./hcode --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — markdown rendering demo"
  task :markdown => :build do
    sh "HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=markdown ./hcode --tui-prompt 'mock' --yolo"
  end
end

namespace :mock do
  namespace :components do
    desc "Render the editor input box across wrapping test cases (self-test + LLM-friendly output)"
    task :input do
      sh "crystal run scripts/components/input_demo.cr --warnings none --no-color"
    end
  end
end

desc "Remove build artifacts"
task :clean do
  rm_f "hcode"
end
