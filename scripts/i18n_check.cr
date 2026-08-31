# Locale integrity checker for src/i18n/locales/*.yml.
#
# Two modes:
#   * CLI (default): `crystal run scripts/i18n_check.cr` — prints a report
#     and exits 1 when problems are found. Also wired as `rake i18n:check`.
#   * Macro ("macro" argv): invoked from src/i18n/i18n.cr at compile time
#     via the `run` macro, so broken locale files fail `crystal build` itself.
#     Always exits 0 in this mode (a non-zero exit surfaces as a generic
#     "Error executing run" without the report); i18n.cr raises instead when
#     the report starts with "FAIL".
#
# Output contract: the first line is "OK ..." or "FAIL ...", followed by one
# line per problem.
#
# Checks:
#   1. Locale inventory: SUPPORTED_LOCALES and the embedded
#      H2CODE_LOCALE_YAML_* constants in src/i18n/i18n.cr must match the
#      .yml files on disk.
#   2. Every file parses as YAML, has no duplicate keys (loaders keep the
#      last duplicate silently — the main way keys get lost without any
#      error), has the right single root key, and no empty values.
#   3. Key parity with en.yml (missing / extra keys per locale).
#   4. Interpolation placeholders (%{name}) match en.yml.

require "yaml"

macro_mode = ARGV.includes?("macro")

locales_dir = File.expand_path("../src/i18n/locales", __DIR__)
i18n_cr_path = File.expand_path("../src/i18n/i18n.cr", __DIR__)
reference = "en"

# Flatten a nested translation mapping into dotted keys:
# {"errors" => {"generic" => "..."}} => {"errors.generic" => "..."}
def flatten_keys(node : YAML::Any, prefix : String, acc : Hash(String, String)) : Nil
  if hash = node.as_h?
    hash.each do |k, v|
      key = prefix.empty? ? k.as_s : "#{prefix}.#{k.as_s}"
      flatten_keys(v, key, acc)
    end
  else
    acc[prefix] = node.to_s
  end
end

# Collect duplicate mapping keys from a YAML node tree, with the line of the
# duplicate occurrence.
def collect_duplicate_keys(node : YAML::Nodes::Node, path : String, acc : Array(Tuple(String, Int32))) : Nil
  return unless node.is_a?(YAML::Nodes::Mapping)
  mapping = node.as(YAML::Nodes::Mapping)
  counts = Hash(String, Int32).new(0)
  lines = Hash(String, Int32).new
  mapping.nodes.each_slice(2) do |pair|
    key = pair[0]
    next unless key.is_a?(YAML::Nodes::Scalar)
    counts[key.value] += 1
    lines[key.value] = key.start_line + 1 # start_line is 0-based
  end
  counts.each do |key, count|
    acc << {(path.empty? ? key : "#{path}.#{key}"), lines[key]} if count > 1
  end
  mapping.nodes.each_slice(2) do |pair|
    key, value = pair
    next unless key.is_a?(YAML::Nodes::Scalar)
    collect_duplicate_keys(value, path.empty? ? key.value : "#{path}.#{key.value}", acc)
  end
end

# Interpolation placeholders used by a translation string, e.g. %{message}.
def placeholders(text : String) : Array(String)
  text.scan(/%\{[^}]+\}/).map(&.to_s).sort!
end

problems = [] of String

# 1. Locale inventory.
src = File.read(i18n_cr_path)
supported = if m = src.match(/SUPPORTED_LOCALES\s*=\s*\{([^}]*)\}/)
              m[1].scan(/"([a-z]{2})"/).map { |sm| sm[1] }.uniq!.sort!
            else
              [] of String
            end
embedded = src.scan(/H2CODE_LOCALE_YAML_([A-Z]{2})\s*=/).map { |sm| sm[1].downcase }.uniq!.sort!
on_disk = Dir.glob(File.join(locales_dir, "*.yml")).map { |p| File.basename(p, ".yml") }.sort!

lists = {
  "SUPPORTED_LOCALES in i18n.cr"                       => supported,
  "embedded H2CODE_LOCALE_YAML_* constants in i18n.cr" => embedded,
  "locale files in src/i18n/locales"                   => on_disk,
}
lists.each do |a_label, a|
  lists.each do |b_label, b|
    next if a_label == b_label
    (a - b).each { |loc| problems << "#{loc}: present in #{a_label} but missing in #{b_label}" }
  end
end

# 2. Per-file checks.
parsed = Hash(String, Hash(String, String)).new

on_disk.each do |loc|
  path = File.join(locales_dir, "#{loc}.yml")
  begin
    dups = [] of Tuple(String, Int32)
    doc = YAML::Nodes.parse(File.read(path))
    collect_duplicate_keys(doc.nodes.first? || doc, "", dups)
    dups.each do |key, line|
      problems << "#{loc}.yml:#{line}: duplicate key \"#{key}\" (last one wins, earlier translation is lost)"
    end

    data = YAML.parse(File.read(path)).as_h
    roots = data.keys.map(&.as_s)
    unless roots == [loc]
      problems << "#{loc}.yml: root key must be #{loc.inspect}, got #{roots.inspect}"
      next
    end
    keys = Hash(String, String).new
    flatten_keys(data.values.first, "", keys)
    keys.each do |key, value|
      problems << "#{loc}.yml: empty value for key \"#{key}\"" if value.strip.empty?
    end
    parsed[loc] = keys
  rescue ex : YAML::Error
    problems << "#{loc}.yml: invalid YAML — #{ex.message}"
  rescue ex : Exception
    problems << "#{loc}.yml: failed to load — #{ex.class}: #{ex.message}"
  end
end

# 3 + 4. Key and placeholder parity against the reference locale.
if ref = parsed[reference]?
  parsed.each do |loc, keys|
    next if loc == reference
    (ref.keys - keys.keys).sort.each { |k| problems << "#{loc}.yml: missing key \"#{k}\" (present in #{reference}.yml)" }
    (keys.keys - ref.keys).sort.each { |k| problems << "#{loc}.yml: extra key \"#{k}\" (not in #{reference}.yml)" }
    keys.each do |key, value|
      next unless rv = ref[key]?
      unless placeholders(rv) == placeholders(value)
        problems << "#{loc}.yml: key \"#{key}\" has placeholders #{placeholders(value).inspect}, but #{reference}.yml has #{placeholders(rv).inspect}"
      end
    end
  end
end

if problems.empty?
  ref_size = parsed[reference]?.try(&.size) || 0
  puts "OK (#{on_disk.size} locales, #{ref_size} keys in #{reference}.yml)"
else
  problems.sort!
  puts "FAIL (#{problems.size} problem(s) in src/i18n/locales):"
  problems.each { |p| puts "  #{p}" }
  exit 1 unless macro_mode
end
