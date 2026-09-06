# Tips integrity checker for tips/*.json (startup tips — see src/tips/tips.cr).
#
# CLI only (no compile-time macro mode): `crystal run scripts/tips_check.cr` —
# prints a report and exits 1 when problems are found. Wired as
# `rake tips:check` and included in `rake precommit`.
#
# Output contract (mirrors scripts/i18n_check.cr): the first line is
# "OK ..." or "FAIL ...", followed by one line per problem.
#
# Checks:
#   1. Locale inventory: one <locale>.json per SUPPORTED_LOCALES locale from
#      src/i18n/i18n.cr — no missing, no extra files.
#   2. Every file parses as a JSON array of objects, each with non-empty
#      string "code" and "text", and no duplicate codes within a file.
#   3. Tip-code parity with en.json across locales (a tip must exist in
#      every language).

require "json"

tips_dir = File.expand_path("../tips", __DIR__)
i18n_cr_path = File.expand_path("../src/i18n/i18n.cr", __DIR__)
reference = "en"

problems = [] of String

# 1. Locale inventory.
src = File.read(i18n_cr_path)
supported = if m = src.match(/SUPPORTED_LOCALES\s*=\s*\{([^}]*)\}/)
              m[1].scan(/"([a-z]{2})"/).map { |sm| sm[1] }.uniq!.sort!
            else
              problems << "cannot parse SUPPORTED_LOCALES from src/i18n/i18n.cr"
              [] of String
            end
on_disk = Dir.glob("#{tips_dir.gsub('\\', '/')}/*.json").map { |p| File.basename(p, ".json") }.sort!

(supported - on_disk).each { |loc| problems << "#{loc}.json: missing (locale is supported by the UI)" }
(on_disk - supported).each { |loc| problems << "#{loc}.json: extra (locale is not in SUPPORTED_LOCALES)" }

# 2 + 3. Per-file checks and code parity against the reference locale.
parsed = Hash(String, Array(String)).new

on_disk.each do |loc|
  path = File.join(tips_dir, "#{loc}.json")
  begin
    entries = JSON.parse(File.read(path)).as_a
    codes = [] of String
    entries.each_with_index do |entry, i|
      obj = entry.as_h
      code = obj["code"]?.try(&.as_s?)
      text = obj["text"]?.try(&.as_s?)
      if code.nil? || code.strip.empty?
        problems << "#{loc}.json: entry ##{i} has no \"code\""
      elsif codes.includes?(code)
        problems << "#{loc}.json: duplicate tip code \"#{code}\""
      else
        codes << code
      end
      problems << "#{loc}.json: tip \"#{code || i}\" has empty \"text\"" if text.nil? || text.strip.empty?
    end
    problems << "#{loc}.json: no tips" if entries.empty?
    parsed[loc] = codes
  rescue ex : JSON::ParseException
    problems << "#{loc}.json: invalid JSON — #{ex.message}"
  rescue ex : Exception
    problems << "#{loc}.json: failed to load — #{ex.class}: #{ex.message}"
  end
end

if ref = parsed[reference]?
  parsed.each do |loc, codes|
    next if loc == reference
    (ref - codes).sort.each { |c| problems << "#{loc}.json: missing tip \"#{c}\" (present in #{reference}.json)" }
    (codes - ref).sort.each { |c| problems << "#{loc}.json: extra tip \"#{c}\" (not in #{reference}.json)" }
  end
end

if problems.empty?
  ref_size = parsed[reference]?.try(&.size) || 0
  puts "OK (#{on_disk.size} locales, #{ref_size} tips in #{reference}.json)"
else
  problems.sort!
  puts "FAIL (#{problems.size} problem(s) in tips):"
  problems.each { |p| puts "  #{p}" }
  exit 1
end
