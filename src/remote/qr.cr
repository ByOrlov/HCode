# QR-code rendering for the pairing banner, backed by the `goban` shard.
# Goban handles encoding (byte mode, ECC M by default); we only adapt its
# canvas into the shapes the TUI needs: a module matrix and terminal
# half-block rows with a quiet zone.
require "goban"

module H2code
  module Remote
    module Qr
      # Module matrix (true = dark) for `payload`.
      def self.matrix(payload : String) : Array(Array(Bool))
        qr = Goban::QR.encode_string(payload)
        size = qr.size
        m = Array.new(size) { Array(Bool).new(size, false) }
        qr.canvas.each_row do |row, y|
          row.each_with_index do |mod, x|
            m[y][x] = mod == 1
          end
        end
        m
      end

      # Render as terminal half-block rows ("█▀▄ "), 2 modules per cell row,
      # with a `quiet`-module quiet zone. Each character column is one module
      # wide (half-blocks halve the height, not the width). Scannable in any
      # modern terminal.
      def self.render(payload : String, quiet : Int32 = 2) : Array(String)
        m = matrix(payload)
        size = m.size
        total = size + quiet * 2
        cell_rows = (total + 1) // 2
        offset = quiet
        rows = [] of String
        cell_rows.times do |cr|
          top_r = cr * 2 - offset
          bot_r = top_r + 1
          line = String.build do |s|
            total.times do |c|
              top = in_bounds_dark?(m, top_r, c - offset)
              bot = in_bounds_dark?(m, bot_r, c - offset)
              s << case {top, bot}
              when {true, true}  then "█"
              when {true, false} then "▀"
              when {false, true} then "▄"
              else                    " "
              end
            end
          end
          rows << line
        end
        rows
      end

      private def self.in_bounds_dark?(m : Array(Array(Bool)), r : Int32, c : Int32) : Bool
        size = m.size
        return false if r < 0 || c < 0 || r >= size || c >= size
        m[r][c]
      end
    end
  end
end
