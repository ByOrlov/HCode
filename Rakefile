# Resolve the build version: explicit HCODE_VERSION wins, then the most
# recent git tag (`git describe --tags --abbrev=0`), then "0.0.0-dev".
def hcode_build_version
  return ENV["HCODE_VERSION"] if ENV.key?("HCODE_VERSION")
  tag = `git describe --tags --abbrev=0 2>/dev/null`.strip
  tag.empty? ? "0.0.0-dev" : tag
end

MINIAUDIO_DIR = File.expand_path("vendor/miniaudio", __dir__)
MINIAUDIO_LIB = File.join(MINIAUDIO_DIR, "libminiaudio_bridge.a")

# Platform-specific linker flags for miniaudio. On Linux it dlopens the audio
# backend (PulseAudio/ALSA) at runtime, so only -ldl/-lpthread/-lm are needed.
def miniaudio_link_flags
  case RUBY_PLATFORM
  when /darwin/
    "-framework CoreAudio -framework AudioToolbox -framework CoreFoundation"
  else
    "-ldl -lpthread -lm"
  end
end

def build_miniaudio_bridge(release: false)
  cflags = release ? "-O2" : "-O0 -g"
  sh "cc -c #{cflags} -I#{MINIAUDIO_DIR} " \
     "#{File.join(MINIAUDIO_DIR, "miniaudio_bridge.c")} " \
     "-o #{File.join(MINIAUDIO_DIR, "miniaudio_bridge.o")}"
  sh "ar rcs #{MINIAUDIO_LIB} #{File.join(MINIAUDIO_DIR, "miniaudio_bridge.o")}"
end

def build_hcode(output = "hcode", release: false)
  build_miniaudio_bridge(release: release)
  link_flags = "-L#{MINIAUDIO_DIR} -lminiaudio_bridge #{miniaudio_link_flags}"
  flags = ["--warnings none", "--no-color"]
  flags << "--release" if release
  flags << "--link-flags \"#{link_flags}\""
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
  build_miniaudio_bridge
  link_flags = "-L#{MINIAUDIO_DIR} -lminiaudio_bridge #{miniaudio_link_flags}"
  sh "crystal spec --warnings none --no-color --link-flags \"#{link_flags}\""
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

  desc "Run TUI with mock provider — sound notification on turn completion"
  task :sound => :build do
    sh "HCODE_PROVIDER=mock HCODE_SOUND=1 ./hcode --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — sudo terminal exec demo (requires bin/mocksudo on PATH)"
  task :mocksudo => :build do
    sh "HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=sudo PATH=#{File.dirname(__FILE__)}/bin:$PATH ./hcode --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — TodoList completion → log migration demo"
  task :todos => :build do
    sh "HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=todos ./hcode --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — long-plan review (EnterPlanMode → Write → ExitPlanMode)"
  task :plan => :build do
    sh "HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=plan ./hcode --tui-prompt 'mock' --yolo"
  end

  # Simulate a first run with no config so the setup wizard launches. HCODE_HOME
  # is pointed at a throwaway dir inside the project and config.json is wiped
  # first, so the wizard sees an unconfigured state. Writes go to that throwaway
  # dir only — the real ~/.hcode is never touched. HCODE_PROVIDER is NOT set:
  # setting it to "mock" would mark the provider as configured and skip the
  # wizard entirely.
  desc "Simulate a first run (no config) to exercise the setup wizard"
  task :welcome => :build do
    welcome_home = File.expand_path("tmp/hcode_welcome_home", __dir__)
    rm_rf welcome_home
    mkdir_p welcome_home
    sh "HCODE_HOME=#{welcome_home} ./hcode"
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

desc "Build and run mock-hcode (simulated 100-tool LLM output for render testing)"
task :mockrun do
  sh "crystal build bin/mock_hcode.cr -o bin/mock-hcode --warnings none --no-color"
  sh "./bin/mock-hcode"
end

desc "Build and run mockfast-hcode (big plan + couple of tools for quick render check)"
task :mockfast do
  sh "crystal build bin/mockfast_hcode.cr -o bin/mockfast_hcode --warnings none --no-color"
  sh "./bin/mockfast_hcode"
end

desc "Remove build artifacts"
task :clean do
  rm_f "hcode"
  rm_f File.join(MINIAUDIO_DIR, "miniaudio_bridge.o")
  rm_f MINIAUDIO_LIB
end
