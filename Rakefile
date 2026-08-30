require "colorize"

# Resolve the build version: explicit H2CODE_VERSION wins, then the most
# recent git tag (`git describe --tags --abbrev=0`), then "0.0.0-dev".
def h2code_build_version
  return ENV["H2CODE_VERSION"] if ENV.key?("H2CODE_VERSION")
  tag = `git describe --tags --abbrev=0 2>/dev/null`.strip
  tag.empty? ? "0.0.0-dev" : tag
end

MINIAUDIO_DIR = File.expand_path("vendor/miniaudio", __dir__)
MINIAUDIO_LIB = File.join(MINIAUDIO_DIR, "libminiaudio_bridge.a")

def windows?
  RUBY_PLATFORM =~ /mingw|mswin|cygwin/i
end

# Locate a Visual Studio installation via vswhere. Returns the installation
# path (forward slashes) or nil.
def find_vs_install
  vswhere = [
    "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe",
    "C:/Program Files/Microsoft Visual Studio/Installer/vswhere.exe",
  ].find { |p| File.file?(p) }
  return nil unless vswhere
  install_path = `"#{vswhere}" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`.strip
  return nil if install_path.empty?
  install_path.tr("\\", "/")
end

# Locate an MSVC cl.exe on Windows. Crystal uses MSVC as its native toolchain,
# so the bridge must be compiled with cl.exe too — mixing a MinGW-compiled
# archive with the MSVC link step causes C-runtime symbol mismatches.
def find_msvc_cl
  # Already on PATH (Developer Command Prompt)?
  exts = ENV["PATHEXT"] ? ENV["PATHEXT"].split(";") : [".EXE", ".BAT", ".CMD"]
  ENV["PATH"].split(File::PATH_SEPARATOR).each do |dir|
    exts.each do |ext|
      candidate = File.join(dir, "cl#{ext}")
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end
  end
  # Locate via vswhere (covers "Developer Command Prompt not open" cases).
  install_path = find_vs_install
  return nil unless install_path
  Dir.glob("#{install_path}/VC/Tools/MSVC/*/bin/Hostx64/x64/cl.exe").sort.last
end

# Set up the MSVC environment (INCLUDE, LIB, PATH) by running vcvarsall.bat.
# When cl.exe is launched from a plain cmd.exe the SDK headers/libs are not on
# the default search paths, so #include <stdio.h> fails with C1083.
# Idempotent: no-op if INCLUDE is already set (Developer Command Prompt).
def setup_msvc_environment
  return if ENV["INCLUDE"] && !ENV["INCLUDE"].empty?
  install_path = find_vs_install
  return unless install_path
  vcvarsall = "#{install_path}/VC/Auxiliary/Build/vcvarsall.bat"
  return unless File.file?(vcvarsall)
  # Run vcvarsall and dump the resulting environment, then merge it in.
  output = `cmd /c "#{vcvarsall}" x64 >nul 2>nul && set`
  output.each_line do |line|
    key, val = line.chomp.split("=", 2)
    next unless key && val
    ENV[key] = val
  end
end

# Full linker flags for miniaudio: the object/archive path plus platform-specific
# backend libraries. On Linux the backend (PulseAudio/ALSA) is dlopened at
# runtime, so only -ldl/-lpthread/-lm are needed.
def miniaudio_link_flags
  if windows?
    "#{File.join(MINIAUDIO_DIR, "miniaudio_bridge.obj")} winmm.lib ole32.lib ksuser.lib"
  else
    extra = case RUBY_PLATFORM
            when /darwin/
              "-framework CoreAudio -framework AudioToolbox -framework CoreFoundation"
            else
              "-ldl -lpthread -lm"
            end
    "-L#{MINIAUDIO_DIR} -lminiaudio_bridge #{extra}"
  end
end

def build_miniaudio_bridge(release: false)
  if windows?
    setup_msvc_environment
    cl = find_msvc_cl
    unless cl
      abort "Could not find MSVC cl.exe. Open the \"Developer Command Prompt for VS\" " \
            "or install Visual Studio Build Tools with the \"Desktop development with C++\" workload."
    end
    obj = File.join(MINIAUDIO_DIR, "miniaudio_bridge.obj")
    rm_f Dir.glob("#{MINIAUDIO_DIR}/miniaudio_bridge.{o,a,obj,lib}")
    opt = release ? "-O2" : "-Od -Z7"
    sh "\"#{cl}\" -nologo #{opt} -c -I\"#{MINIAUDIO_DIR}\" " \
       "\"#{File.join(MINIAUDIO_DIR, "miniaudio_bridge.c")}\" -Fo\"#{obj}\""
  else
    cflags = release ? "-O2" : "-O0 -g"
    sh "cc -c #{cflags} -I#{MINIAUDIO_DIR} " \
       "#{File.join(MINIAUDIO_DIR, "miniaudio_bridge.c")} " \
       "-o #{File.join(MINIAUDIO_DIR, "miniaudio_bridge.o")}"
    sh "ar rcs #{MINIAUDIO_LIB} #{File.join(MINIAUDIO_DIR, "miniaudio_bridge.o")}"
  end
end

# Print a blue "building X" banner before each build step.
def building(name)
  puts "▶ Building #{name}".colorize(:blue)
end

def build_h2code(output = "h2code", release: false)
  build_miniaudio_bridge(release: release)
  link_flags = miniaudio_link_flags
  flags = ["--warnings none", "--no-color"]
  flags << "--release" if release
  flags << "--link-flags \"#{link_flags}\""
  ENV["H2CODE_VERSION"] = h2code_build_version
  sh "crystal build src/h2code.cr -o #{output} #{flags.join(' ')}"
end

desc "Build the h2code binary"
task :build do
  build_h2code
end

desc "Build the h2code binary with --release"
task :build_release do
  build_h2code(release: true)
end

namespace :build do
  desc "Build every binary: h2code, ameba, lines_demo, mock_h2code, mockfast_h2code, mockshort_h2code"
  task :all => [:h2code, :ameba, :lines_demo, :mock_h2code, :mockfast_h2code, :mockshort_h2code]

  desc "Build the h2code binary (debug)"
  task :h2code do
    building "h2code"
    build_h2code
  end

  desc "Build bin/ameba"
  task :ameba do
    building "bin/ameba"
    sh "crystal build bin/ameba.cr -o bin/ameba --warnings none --no-color"
  end

  desc "Build bin/lines_demo"
  task :lines_demo do
    building "bin/lines_demo"
    sh "crystal build bin/lines_demo.cr -o bin/lines_demo --warnings none --no-color"
  end

  desc "Build bin/mock_h2code (simulated 100-tool LLM output)"
  task :mock_h2code do
    building "bin/mock_h2code"
    sh "crystal build bin/mock_h2code.cr -o bin/mock_h2code --warnings none --no-color"
  end

  desc "Build bin/mockfast_h2code (quick render check)"
  task :mockfast_h2code do
    building "bin/mockfast_h2code"
    sh "crystal build bin/mockfast_h2code.cr -o bin/mockfast_h2code --warnings none --no-color"
  end

  desc "Build bin/mockshort_h2code (short 10-line streamed answer + couple of tools)"
  task :mockshort_h2code do
    building "bin/mockshort_h2code"
    sh "crystal build bin/mockshort_h2code.cr -o bin/mockshort_h2code --warnings none --no-color"
  end
end

namespace :run do
  desc "Build (debug) and run the TUI"
  task :default => :build do
    sh "./h2code --yolo"
  end

  desc "Build with --release and run the TUI"
  task :release => :build_release do
    sh "./h2code --yolo"
  end
end

# Backward-compatible alias for `rake run:default`.
desc "Build (debug) and run the TUI (alias of run:default)"
task :run => "run:default"

desc "Run the test suite"
task :spec do
  build_miniaudio_bridge
  link_flags = miniaudio_link_flags
  sh "crystal spec --warnings none --no-color --link-flags \"#{link_flags}\""
end

namespace :mock do
  desc "Run TUI with mock provider — default self-test script (parallel tools)"
  task :default => :build do
    sh "H2CODE_PROVIDER=mock ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking streaming demo (~5s)"
  task :thinking => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=thinking ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking + tool call demo"
  task :thinking_tools => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=thinking-tools ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — markdown rendering demo"
  task :markdown => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=markdown ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — broken-token markdown list streaming bug repro"
  task :markdown_tokens => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=markdown_tokens ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — sound notification on turn completion"
  task :sound => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_SOUND=1 ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — sudo terminal exec demo (requires bin/mocksudo on PATH)"
  task :mocksudo => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=sudo PATH=#{File.dirname(__FILE__)}/bin:$PATH ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — TodoList completion → log migration demo"
  task :todos => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=todos ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — long-plan review (EnterPlanMode → Write → ExitPlanMode)"
  task :plan => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=plan ./h2code --tui-prompt 'mock' --yolo"
  end

  # --- standalone mock binaries (built by build:mock_h2code / build:mockfast_h2code) ---

  desc "Build and run bin/mock_h2code (simulated 100-tool LLM output for render testing)"
  task :run => "build:mock_h2code" do
    sh "./bin/mock_h2code"
  end

  desc "Build and run bin/mockfast_h2code (big plan + couple of tools for quick render check)"
  task :fast => "build:mockfast_h2code" do
    sh "./bin/mockfast_h2code"
  end

  desc "Build and run bin/mockshort_h2code (short 10-line streamed answer + couple of tools)"
  task :short => "build:mockshort_h2code" do
    sh "./bin/mockshort_h2code"
  end

  # Simulate a first run with no config so the setup wizard launches. H2CODE_HOME
  # is pointed at a throwaway dir inside the project and config.json is wiped
  # first, so the wizard sees an unconfigured state. Writes go to that throwaway
  # dir only — the real ~/.h2code is never touched. H2CODE_PROVIDER is NOT set:
  # setting it to "mock" would mark the provider as configured and skip the
  # wizard entirely.
  desc "Simulate a first run (no config) to exercise the setup wizard"
  task :welcome => :build do
    welcome_home = File.expand_path("tmp/h2code_welcome_home", __dir__)
    rm_rf welcome_home
    mkdir_p welcome_home
    sh "H2CODE_HOME=#{welcome_home} ./h2code"
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
  rm_f "h2code"
  rm_f Dir.glob("#{MINIAUDIO_DIR}/miniaudio_bridge.{o,a,obj,lib}")
end
