module Hcode
  # Rolling-release version: YYYY.MM.DD.N (e.g. "2026.07.31.1").
  # Set at build time via the HCODE_VERSION env var (CI injects the git tag;
  # Rake tasks resolve it from `git describe --tags` for local builds).
  # Builds without the var fall back to "0.0.0-dev".
  VERSION = {{ (env("HCODE_VERSION") || "0.0.0-dev") }}
  # Build timestamp. Crystal has no compile-time -D flag like C, so we read
  # it from the SOURCE_DATE_EPOCH env var at build time when present (repro
  # builds set this); otherwise fall back to "dev".
  BUILD_DATE = (::ENV["SOURCE_DATE_EPOCH"]?).try { |s| Time.unix(s.to_i).to_s("%Y-%m-%d") } || "dev"

  def self.build_date : String?
    BUILD_DATE == "dev" ? nil : BUILD_DATE
  end
end
