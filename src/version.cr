module Hcode
  VERSION = "0.1.0"
  # Build timestamp. Crystal has no compile-time -D flag like C, so we read
  # it from the SOURCE_DATE_EPOCH env var at build time when present (repro
  # builds set this); otherwise fall back to "dev".
  BUILD_DATE = (::ENV["SOURCE_DATE_EPOCH"]?).try { |s| Time.unix(s.to_i).to_s("%Y-%m-%d") } || "dev"

  def self.build_date : String?
    BUILD_DATE == "dev" ? nil : BUILD_DATE
  end
end
