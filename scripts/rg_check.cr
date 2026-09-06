# Ripgrep detection checker (rake rg:check).
#
# Reproduces the macOS case where the parent process has a minimal PATH
# (e.g. "/usr/bin:/bin:/usr/sbin:/sbin" — GUI apps, launchd, IDE plugins)
# that misses the Homebrew/cargo directories the user's interactive shell
# sets up, so a bare `rg` lookup fails even though ripgrep is installed.
#
# Verifies that H2code::Tools::RunRg.resolve_rg_binary finds rg
#   1. via the real ENV["PATH"],
#   2. via the hardcoded fallbacks with a simulated minimal PATH, and
#   3. that the resolved binary actually spawns and reports a version.
#
# Output contract: a report, then a final "OK" or "FAIL" line. Exits 1 on
# failure.

require "../src/tools/run_rg"

problems = [] of String

platform = {{ flag?(:darwin) ? "darwin" : flag?(:win32) ? "win32" : "unix" }}
puts "platform:            #{platform}"
puts "PATH:                #{ENV["PATH"]? || "(unset)"}"
puts "HOME:                #{ENV["HOME"]? || "(unset)"}"

# Fallback locations, one line each (found even when PATH is broken).
H2code::Tools::RunRg::FALLBACK_RG_PATHS.each do |candidate|
  expanded = candidate.starts_with?('~') ? File.expand_path(candidate, home: ENV["HOME"]) : candidate
  state = File.file?(expanded) && File.executable?(expanded) ? "found" : "missing"
  puts "fallback:            #{expanded} (#{state})"
end

# Spawn the given rg path and check it reports a ripgrep version.
def rg_version(binary : String) : String?
  stdout_io = IO::Memory.new
  stderr_io = IO::Memory.new
  process = Process.new(binary, ["--version"], output: stdout_io, error: stderr_io)
  status = process.wait
  return nil unless status.success?
  first = stdout_io.to_s.lines.first?.try(&.strip)
  first.try(&.starts_with?("ripgrep")) ? first : nil
rescue ex : IO::Error | File::NotFoundError
  nil
end

# 1. Resolution with the real PATH.
resolved = H2code::Tools::RunRg.resolve_rg_binary(ENV["PATH"]?)
puts "resolve(ENV[PATH]):  #{resolved}"
if version = rg_version(resolved)
  puts "spawn:               #{version}"
else
  problems << "rg not found via PATH or fallbacks (resolved: #{resolved}) — install it: brew install ripgrep"
end

# 2. The macOS minimal-PATH scenario (launchd/GUI parent). PATH entries are
# skipped; only the fallback locations can find rg.
minimal_path = {{ flag?(:win32) ? "C:\\Windows\\System32;C:\\Windows" : "/usr/bin:/bin:/usr/sbin:/sbin" }}
resolved_minimal = H2code::Tools::RunRg.resolve_rg_binary(minimal_path)
puts "resolve(minimal):    #{resolved_minimal} (simulated PATH: #{minimal_path})"
if version = rg_version(resolved_minimal)
  puts "spawn (minimal):     #{version}"
else
  problems << "rg not found with a minimal PATH (#{minimal_path}) — expected a Homebrew/cargo fallback to kick in"
end

if problems.empty?
  puts "OK: ripgrep detection works (PATH + fallbacks)"
else
  problems.each { |p| puts "FAIL: #{p}" }
  exit 1
end
