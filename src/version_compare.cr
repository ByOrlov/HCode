module Hcode
  # Compares rolling-release version strings of the form "YYYY.MM.DD.N".
  # Returns negative if a < b, zero if equal, positive if a > b. Missing
  # segments are treated as 0, so "2026.07.31" sorts before "2026.07.31.1".
  module VersionCompare
    def self.compare(a : String, b : String) : Int32
      pa = parse(a)
      pb = parse(b)
      pa <=> pb
    end

    def self.newer?(candidate : String, current : String) : Bool
      compare(candidate, current) > 0
    end

    private def self.parse(v : String) : {Int32, Int32, Int32, Int32}
      parts = v.split('.').map { |s| s.to_i? || 0 }
      {
        parts[0]?, parts[1]?, parts[2]?, parts[3]?,
      }.map { |n| n || 0 }
    end
  end
end
