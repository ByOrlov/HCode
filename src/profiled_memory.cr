module Hcode
  # Central registry for memory profiling of long-lived growing collections.
  #
  # Instead of wrapping every Array/Hash in a profiling container, each
  # long-lived owner registers a *calculator* closure that returns the current
  # byte size of its data. The closures capture the owner objects (which are
  # already alive for the whole process), so no extra references are pinned
  # in the GC's old generation and no per-mutation bookkeeping is needed.
  #
  # `snapshot` walks the registered calculators on demand (e.g. when the user
  # runs `/memory`) and returns the current figures. Computing the totals is
  # O(total elements across ~15 collections) — microseconds-to-milliseconds,
  # acceptable for a manual command invoked a handful of times per session.
  module ProfiledMemory
    struct Snapshot
      getter id : String
      getter label : String
      getter bytes : Int64
      getter count : Int32

      def initialize(@id : String, @label : String, @bytes : Int64, @count : Int32)
      end
    end

    private struct Entry
      getter id : String
      getter label : String
      getter calculator : -> Int64
      getter counter : -> Int32

      def initialize(@id : String, @label : String, @calculator : -> Int64, @counter : -> Int32)
      end
    end

    @@entries = [] of Entry
    @@registered_ids = Set(String).new

    # Register (or replace) a profiling entry. The `id` deduplicates so
    # re-registration (e.g. on `/new` creating a fresh Memory) replaces the
    # stale closure instead of piling up dead ones. `&calc` returns the deep
    # byte size of the collection; `&count` returns the element count (0 when
    # the concept of "element" does not apply, e.g. a single big string).
    def self.register(id : String, label : String, *,
                      calc : -> Int64,
                      count : -> Int32 = -> { 0 }) : Nil
      @@entries.reject!(&.id.==(id))
      @@entries << Entry.new(id, label, calc, count)
      @@registered_ids << id
    end

    def self.snapshot : Array(Snapshot)
      @@entries.map do |e|
        bytes = e.calculator.call rescue 0_i64
        count = e.counter.call rescue 0
        Snapshot.new(e.id, e.label, bytes, count)
      end
    end

    def self.total_bytes : Int64
      snapshot.sum(&.bytes)
    end

    # Human-readable report for the `/memory` command. Sorted by bytes desc.
    # The tracked-collections total only covers registered long-lived arrays;
    # the rest of RSS is binary code, shared libraries, and GC arena overhead
    # — none of which the profiler can "track" per-item. The footer breaks
    # RSS into its physical categories so the gap is explainable at a glance.
    def self.format_report : String
      snaps = snapshot.sort_by!(&.bytes.-)
      total = snaps.sum(&.bytes)

      String.build do |s|
        s << "Memory Profile"
        s << sprintf("   tracked: %.1f MB\n", total / 1_048_576.0)
        s << "─" * 60
        s << '\n'
        snaps.each do |snap|
          mb = snap.bytes / 1_048_576.0
          if mb >= 0.01
            s << sprintf("%-28s %7.2f MB", snap.label, mb)
          else
            s << sprintf("%-28s %7d B", snap.label, snap.bytes)
          end
          s << "   #{snap.count} items" unless snap.count == 0
          s << '\n'
        end
        s << "─" * 60
        s << '\n'
        gc = GC.stats
        gc_kb = gc.heap_size // 1024
        free_kb = gc.free_bytes // 1024
        total_rss_kb = rss_kb
        anon_kb, code_kb, libs_kb = rss_breakdown
        s << sprintf("GC heap:        %5d KB (%d free)\n", gc_kb, free_kb)
        s << sprintf("GC arenas:      %5d KB\n", anon_kb)
        s << sprintf("Binary + libs:  %5d KB\n", code_kb + libs_kb)
        s << sprintf("RSS (process):  %5d KB\n", total_rss_kb)
      end
    end

    # Current process RSS in KB from /proc/self/status (Linux only).
    private def self.rss_kb : Int64
      File.read("/proc/self/status").each_line do |line|
        if line.starts_with?("VmRSS:")
          return line.split[1].to_i64
        end
      end
      0_i64
    rescue
      0_i64
    end

    # Split RSS into physical categories by parsing /proc/self/maps + smaps:
    # anon = anonymous mappings (GC arenas, malloc heap, stacks)
    # code = the executable's own LOAD segments (text + rodata + data)
    # libs = shared libraries (libc, libssl, libpcre, ...)
    # Returns {anon_kb, code_kb, libs_kb}. On non-Linux returns {0,0,0}.
    private def self.rss_breakdown : {Int64, Int64, Int64}
      anon = 0_i64
      code = 0_i64
      libs = 0_i64
      pss = 0_i64
      current_path = ""

      File.read("/proc/self/smaps").each_line do |line|
        # Mapping header line: start-end perm offset dev inode path
        if line.starts_with?(/[0-9a-f]+-[0-9a-f]+\s/)
          current_path = line.split(/\s+/).last? || ""
        elsif line.starts_with?("Pss:")
          pss = line.split[1].to_i64
          next if pss == 0
          case current_path
          when .empty?, "[heap]", "[stack]", "[anon:", .starts_with?("[anon")
            anon += pss
          when /\[/
            # [vvar], [vdso], etc. — negligible, lump into anon
            anon += pss
          when /\.so/, /libc/, /libssl/, /libcrypto/, /libpcre/, /libgc/, /libevent/, /ld-linux/
            libs += pss
          else
            # The executable itself
            code += pss
          end
        end
      end
      {anon, code, libs}
    rescue
      {0_i64, 0_i64, 0_i64}
    end

    # Current process RSS in MB. Reads /proc/self/status on Linux, returns
    # 0.0 elsewhere. Extracted here so the profiler has no dependency back
    # into the CLI module.
    def self.rss_mb : Float64
      rss_kb.to_f64 / 1024.0
    end

    def self.clear : Nil
      @@entries.clear
      @@registered_ids.clear
    end

    def self.registered?(id : String) : Bool
      @@registered_ids.includes?(id)
    end
  end
end

# Base case: the deep byte cost of a String. The +24 accounts for the Crystal
# String header (type id, length, bytesize, capacity). Numbers/enums are not
# profiled (negligible relative to text).
class String
  def profiled_bytes : Int64
    bytesize.to_i64 + 24
  end
end
