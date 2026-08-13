require "json"

module Hcode
  module Tools
    # Cron tools — CronCreate, CronList, CronDelete.
    #
    # Контракты перенесены 1:1 из
    # `packages/agent-core-v2/src/session/cron/tools/`.
    #
    # Все 3 тула регистрируются только для main agent.
    #
    # См. детальный план портирования в `md-tools/cron.md`.
    module Cron
      MAX_CRON_JOBS_PER_SESSION = 50
      MAX_PROMPT_BYTES          = 8 * 1024
      ONE_SHOT_MAX_FUTURE_MS    = 350_i64 * 24 * 60 * 60 * 1000
      MS_PER_DAY                = 86_400_000_i64
      PROMPT_PREVIEW_BYTES      =            200
      STALE_THRESHOLD_MS        = 7_i64 * MS_PER_DAY

      # Принимает 8-hex или 26-char Crockford Base32 ULID (case-insensitive).
      ID_PATTERN = Regex.new("\\A(?:[0-9a-f]{8}|[0-9A-HJKMNP-TV-Z]{26})\\z", Regex::Options::IGNORE_CASE)

      @@service : SessionCronService?

      def self.service=(s : SessionCronService?)
        @@service = s
      end

      def self.service : SessionCronService?
        @@service
      end
    end

    class CronParseError < Exception
    end

    # 5-field parsed cron expression. Каждое поле — Set(Int32) допустимых
    # значений. Звёздочка → все допустимые значения.
    class ParsedCronExpression
      getter minute : Set(Int32)
      getter hour : Set(Int32)
      getter dom : Set(Int32)
      getter month : Set(Int32)
      getter dow : Set(Int32)

      def initialize(@minute : Set(Int32), @hour : Set(Int32),
                     @dom : Set(Int32), @month : Set(Int32), @dow : Set(Int32))
      end

      # dom и dow — OR-семантика (Vixie cron): если оба не `*` (полные
      # наборы), fire когда либо dom либо dow совпадает.
      def dom_dow_or? : Bool
        !@dom_full && !@dow_full
      end

      # Храним флаги "был *" для dom/dow OR-семантики.
      property? dom_full : Bool = false
      property? dow_full : Bool = false

      # Минимальный inter-fire period (мс) — для jitter cap.
      def min_period_ms : Int64
        step_min = @minute.size > 1 ? (@minute.max - @minute.min) // (@minute.size - 1) : 60
        step_min = 60 if step_min < 1
        step_min.to_i64 * 60_000
      end
    end

    struct CronTask
      property id : String
      property cron : String
      property prompt : String
      property? recurring : Bool
      property created_at : Int64
      property last_fired_at : Int64?
      property coalesced_count : Int32

      def initialize(@id : String,
                     @cron : String,
                     @prompt : String,
                     @recurring : Bool = true,
                     @created_at : Int64 = 0_i64,
                     @last_fired_at : Int64? = nil,
                     @coalesced_count : Int32 = 0)
      end

      def profiled_bytes : Int64
        @id.profiled_bytes + @cron.profiled_bytes + @prompt.profiled_bytes
      end

      def to_json_str : String
        JSON.build do |json|
          json.object do
            json.field "id", @id
            json.field "cron", @cron
            json.field "prompt", @prompt
            json.field "recurring", @recurring
            json.field "created_at", @created_at
            json.field "last_fired_at", @last_fired_at unless @last_fired_at.nil?
            json.field "coalesced_count", @coalesced_count
          end
        end
      end

      def self.from_json_obj(parsed : JSON::Any) : CronTask
        CronTask.new(
          id: parsed["id"]?.try(&.to_s) || "",
          cron: parsed["cron"]?.try(&.to_s) || "",
          prompt: parsed["prompt"]?.try(&.to_s) || "",
          recurring: parsed["recurring"]?.try(&.as_bool?) || true,
          created_at: parsed["created_at"]?.try(&.as_i64) || 0_i64,
          last_fired_at: parsed["last_fired_at"]?.try(&.as_i64?),
          coalesced_count: parsed["coalesced_count"]?.try(&.as_i?) || 0,
        )
      end
    end

    struct CronTaskInit
      getter cron : String
      getter prompt : String
      getter? recurring : Bool

      def initialize(@cron : String, @prompt : String, @recurring : Bool = true)
      end
    end

    abstract class SessionCronService
      abstract def enabled? : Bool
      abstract def disabled? : Bool
      abstract def add_task(init : CronTaskInit) : CronTask
      abstract def remove_tasks(ids : Array(String)) : Array(String)
      abstract def get_task(id : String) : CronTask?
      abstract def list : Array(CronTask)
      abstract def now : Int64
      abstract def stale?(task : CronTask) : Bool
      abstract def get_next_fire_for_task(task_id : String) : Int64?
      abstract def compute_display_next_fire(task : CronTask, parsed : ParsedCronExpression, ideal_ms : Int64) : Int64?
      abstract def emit_scheduled(task : CronTask) : Nil
      abstract def emit_deleted(task_id : String) : Nil
    end

    # Простейшая in-memory реализация. Не использует persistence/tick-loop —
    # только валидация, хранение и базовые расчёты для тестов и как
    # fallback. Реальный CronService добавит persistence + firing отдельно.
    class InMemoryCronService < SessionCronService
      @tasks = [] of CronTask
      @enabled : Bool = true
      @no_stale : Bool = false
      @next_fires = {} of String => Int64

      def initialize(@enabled : Bool = true, @no_stale : Bool = false)
      end

      def profiled_bytes : Int64
        @tasks.sum(&.profiled_bytes)
      end

      def profiled_count : Int32
        @tasks.size
      end

      def enabled? : Bool
        @enabled
      end

      def disabled? : Bool
        !@enabled
      end

      def disable! : Nil
        @enabled = false
      end

      def enable! : Nil
        @enabled = true
      end

      def add_task(init : CronTaskInit) : CronTask
        task = CronTask.new(
          id: generate_id,
          cron: init.cron,
          prompt: init.prompt,
          recurring: init.recurring?,
          created_at: now,
        )
        @tasks << task
        task
      end

      def remove_tasks(ids : Array(String)) : Array(String)
        removed = [] of String
        @tasks.reject! do |t|
          if ids.includes?(t.id)
            removed << t.id
            @next_fires.delete(t.id)
            true
          else
            false
          end
        end
        removed
      end

      def get_task(id : String) : CronTask?
        @tasks.find { |t| t.id == id }
      end

      def list : Array(CronTask)
        @tasks.dup
      end

      # Test helper: direct inject (bypasses validation).
      def insert_task(task : CronTask) : Nil
        @tasks << task
      end

      def now : Int64
        Time.utc.to_unix_ms
      end

      def stale?(task : CronTask) : Bool
        return false unless task.recurring?
        return false if @no_stale
        (now - task.created_at) >= Cron::STALE_THRESHOLD_MS
      end

      def get_next_fire_for_task(task_id : String) : Int64?
        @next_fires[task_id]?
      end

      def set_next_fire_for_task(task_id : String, fire_ms : Int64) : Nil
        @next_fires[task_id] = fire_ms
      end

      def compute_display_next_fire(task : CronTask, parsed : ParsedCronExpression, ideal_ms : Int64) : Int64?
        ideal_ms
      end

      def emit_scheduled(task : CronTask) : Nil
      end

      def emit_deleted(task_id : String) : Nil
      end

      private def generate_id : String
        Random::Secure.hex(4)
      end
    end

    # Live cron scheduler: inherits the in-memory storage from
    # `InMemoryCronService` and adds a polling tick-loop, deterministic
    # jitter, coalescing of missed fires, stale auto-delete, and
    # persistence to `Session::Store`. The tick fires only when the agent
    # is idle (`@agent.busy?` is false) — cron never interrupts a running
    # turn. Deliveries go through the `@delivery` callback as a
    # `<cron-fire>` XML envelope.
    class LiveCronService < InMemoryCronService
      @store : Session::Store?
      @agent : Loop::Agent?
      @delivery : (String -> Nil)?
      @running : Bool = false
      @last_seen_at = {} of String => Int64
      @seeded = Set(String).new
      @delivered = [] of String

      DEFAULT_POLL_INTERVAL_MS =  1_000
      MAX_COALESCE_ITERATIONS  = 10_000
      JITTER_CAP_MS            = 15 * 60 * 1000
      ONE_SHOT_BACKWARD_MS     = 90_000

      def initialize(@store : Session::Store? = nil,
                     @agent : Loop::Agent? = nil,
                     @delivery : (String -> Nil)? = nil,
                     enabled : Bool = true,
                     no_stale : Bool = false)
        super(enabled, no_stale)
      end

      # Test-only setter for the delivery callback.
      def delivery=(cb : (String -> Nil)?) : Nil
        @delivery = cb
      end

      # List of fired cron-fire envelopes since the last call (for tests).
      def delivered : Array(String)
        @delivered.dup
      end

      # ----------------------------------------------------------------
      # Lifecycle
      # ----------------------------------------------------------------

      def start : Nil
        return if @running
        load_from_store
        @running = true
        spawn do
          while @running
            begin
              tick
            rescue ex
              # A tick must never crash the loop — log and continue.
              STDERR.puts "[cron] tick error: #{ex.message}" if @agent.try(&.debug?)
            end
            sleep DEFAULT_POLL_INTERVAL_MS.milliseconds
            Fiber.yield
          end
        end
      end

      def stop : Nil
        @running = false
        persist!
      end

      # ----------------------------------------------------------------
      # Persistence
      # ----------------------------------------------------------------

      def load_from_store(replace : Bool = true) : Nil
        s = @store
        return if s.nil?
        @tasks.clear if replace
        @last_seen_at.clear if replace
        @seeded.clear if replace
        s.read_cron_tasks.each do |raw|
          begin
            task = CronTask.from_json_obj(raw)
            next if task.id.empty?
            next if @tasks.any? { |t| t.id == task.id }
            @tasks << task
          rescue
            # Skip corrupt entries.
          end
        end
      end

      def persist! : Nil
        s = @store
        return if s.nil?
        json = JSON.build do |builder|
          builder.array do
            @tasks.each do |t|
              builder.raw(t.to_json_str)
            end
          end
        end
        s.write_cron_tasks(json)
      end

      # ----------------------------------------------------------------
      # Overrides that persist on mutation
      # ----------------------------------------------------------------

      def add_task(init : CronTaskInit) : CronTask
        task = super
        persist!
        task
      end

      def remove_tasks(ids : Array(String)) : Array(String)
        removed = super
        unless removed.empty?
          removed.each { |id| @last_seen_at.delete(id) }
          persist!
        end
        removed
      end

      # ----------------------------------------------------------------
      # Tick
      # ----------------------------------------------------------------

      def tick : Nil
        return if disabled?
        return if @tasks.empty?
        return if @agent.try(&.busy?)
        now_ms = now
        # Iterate over a snapshot — process_due may remove tasks (stale/one-shot).
        @tasks.dup.each do |task|
          process_due(task, now_ms)
        end
      end

      def process_due(task : CronTask, now_ms : Int64) : Nil
        parsed = parse_safe(task.cron)
        return if parsed.nil?

        # Seed the cursor from the persisted last_fired_at (once per task).
        unless @seeded.includes?(task.id)
          if (lf = task.last_fired_at) && lf <= now_ms
            @last_seen_at[task.id] = lf
          end
          @seeded.add(task.id)
        end

        seen = @last_seen_at[task.id]?
        base_ms = (seen && seen > task.created_at) ? seen : task.created_at

        ideal = Cron.compute_next_cron_run(parsed, base_ms)
        return if ideal.nil?

        jittered = apply_jitter(task, parsed, ideal)
        return if now_ms < jittered

        # Count coalesced fires (how many ideal fires elapsed since the cursor).
        coalesced = count_coalesced(parsed, ideal, now_ms)
        stale = stale?(task)

        deliver_fire(task, coalesced, stale)

        # Advance the cursor to the last ideal fire whose jittered delivery
        # has completed, so any later ideal whose jitter slipped past now
        # stays reachable next tick.
        last_ideal = last_completed_ideal(parsed, ideal, now_ms)
        task.last_fired_at = last_ideal
        @last_seen_at[task.id] = last_ideal
        persist!

        if stale || !task.recurring?
          remove_tasks([task.id])
        end
      end

      # ----------------------------------------------------------------
      # Delivery
      # ----------------------------------------------------------------

      private def deliver_fire(task : CronTask, coalesced : Int32, stale : Bool) : Nil
        xml = render_cron_fire_xml(task, coalesced, stale)
        @delivered << xml
        @delivery.try(&.call(xml))
      end

      def render_cron_fire_xml(task : CronTask, coalesced : Int32, stale : Bool) : String
        String.build do |s|
          s << "<cron-fire"
          s << %( jobId="#{escape_attr(task.id)}")
          s << %( cron="#{escape_attr(task.cron)}")
          s << %( recurring="#{task.recurring?}")
          s << %( coalescedCount="#{coalesced}")
          s << %( stale="#{stale}")
          s << ">\n"
          s << "<prompt>\n"
          s << task.prompt
          s << "\n</prompt>\n"
          s << "</cron-fire>"
        end
      end

      # ----------------------------------------------------------------
      # Jitter (deterministic per task_id)
      # ----------------------------------------------------------------

      private def apply_jitter(task : CronTask, parsed : ParsedCronExpression, ideal_ms : Int64) : Int64
        if task.recurring?
          period = parsed.min_period_ms
          cap = Math.min((period * 0.1).to_i64, JITTER_CAP_MS.to_i64)
          cap = 0_i64 if cap < 0
          offset = deterministic_offset(task.id, cap) if cap > 0
          offset ||= 0_i64
          ideal_ms + offset
        else
          # One-shot: backward jitter up to 90s, only if the ideal fire lands
          # on a :00 or :30 minute mark.
          t = Time.unix_ms(ideal_ms).to_local
          if t.minute == 0 || t.minute == 30
            offset = deterministic_offset(task.id, ONE_SHOT_BACKWARD_MS.to_i64)
            ideal_ms - offset
          else
            ideal_ms
          end
        end
      end

      private def deterministic_offset(id : String, max_ms : Int64) : Int64
        return 0_i64 if max_ms <= 0
        hash = 0_i64
        id.each_byte { |b| hash = hash * 31 + b.to_i64 }
        (hash.abs % (max_ms + 1))
      end

      # ----------------------------------------------------------------
      # Coalesce counting
      # ----------------------------------------------------------------

      private def count_coalesced(parsed : ParsedCronExpression, first_ideal : Int64, now_ms : Int64) : Int32
        count = 1
        cursor = first_ideal
        max = MAX_COALESCE_ITERATIONS
        while count < max
          nxt = Cron.compute_next_cron_run(parsed, cursor)
          break if nxt.nil?
          break if nxt > now_ms
          cursor = nxt
          count += 1
        end
        count
      end

      private def last_completed_ideal(parsed : ParsedCronExpression, first_ideal : Int64, now_ms : Int64) : Int64
        cursor = first_ideal
        max = MAX_COALESCE_ITERATIONS
        max.times do
          nxt = Cron.compute_next_cron_run(parsed, cursor)
          break if nxt.nil? || nxt > now_ms
          cursor = nxt
        end
        cursor
      end

      # ----------------------------------------------------------------
      # Helpers
      # ----------------------------------------------------------------

      private def parse_safe(cron : String) : ParsedCronExpression?
        Cron.parse_expression(cron)
      rescue CronParseError
        nil
      end

      private def escape_attr(value : String) : String
        Tools.escape_xml_attr(value)
      end

      # Test helper: expose last_seen_at for verification.
      def last_seen_for(task_id : String) : Int64?
        @last_seen_at[task_id]?
      end

      # Test helper: mark the cursor as seen without firing.
      def set_seen(task_id : String, ms : Int64) : Nil
        @last_seen_at[task_id] = ms
        @seeded.add(task_id)
      end
    end

    # --------------------------------------------------------------------
    # Cron expression parser
    # --------------------------------------------------------------------

    module Cron
      extend self

      # Парсит 5-field cron expression. Бросает CronParseError.
      def parse_expression(raw : String) : ParsedCronExpression
        normalized = raw.strip.split(/\s+/).join(" ")
        fields = normalized.split(" ")
        raise CronParseError.new("Cron expression must have 5 fields, got #{fields.size}") unless fields.size == 5

        minute = parse_field(fields[0], 0, 59)
        hour = parse_field(fields[1], 0, 23)
        dom = parse_field(fields[2], 1, 31)
        month = parse_field(fields[3], 1, 12)
        dow_field = fields[4]
        dow = parse_dow(dow_field)

        expr = ParsedCronExpression.new(minute, hour, dom, month, dow)
        expr.dom_full = (fields[2] == "*")
        expr.dow_full = (fields[4] == "*")
        expr
      end

      private def parse_field(spec : String, min_v : Int32, max_v : Int32) : Set(Int32)
        result = Set(Int32).new
        spec.split(",").each do |part|
          parse_part(part, min_v, max_v, result)
        end
        if result.empty?
          raise CronParseError.new("Empty cron field: #{spec}")
        end
        result
      end

      private def parse_part(part : String, min_v : Int32, max_v : Int32, result : Set(Int32)) : Nil
        if part == "*"
          (min_v..max_v).each { |n| result << n }
          return
        end

        # `*/N`
        if m = part.match(/^\*\/(\d+)$/)
          step = m[1].to_i
          raise CronParseError.new("Step must be >= 1: #{part}") if step < 1
          v = min_v
          while v <= max_v
            result << v
            v += step
          end
          return
        end

        # `N-M/S`
        if m = part.match(/^(\d+)-(\d+)\/(\d+)$/)
          lo = m[1].to_i
          hi = m[2].to_i
          step = m[3].to_i
          validate_range(lo, hi, min_v, max_v, part)
          raise CronParseError.new("Step must be >= 1: #{part}") if step < 1
          v = lo
          while v <= hi
            result << v
            v += step
          end
          return
        end

        # `N-M`
        if m = part.match(/^(\d+)-(\d+)$/)
          lo = m[1].to_i
          hi = m[2].to_i
          validate_range(lo, hi, min_v, max_v, part)
          (lo..hi).each { |n| result << n }
          return
        end

        # `N`
        if m = part.match(/^(\d+)$/)
          v = m[1].to_i
          raise CronParseError.new("Value #{v} out of range [#{min_v}, #{max_v}]: #{part}") if v < min_v || v > max_v
          result << v
          return
        end

        raise CronParseError.new("Unrecognized cron field: #{part}")
      end

      private def validate_range(lo : Int32, hi : Int32, min_v : Int32, max_v : Int32, part : String) : Nil
        raise CronParseError.new("Range start #{lo} out of range [#{min_v}, #{max_v}]: #{part}") if lo < min_v || lo > max_v
        raise CronParseError.new("Range end #{hi} out of range [#{min_v}, #{max_v}]: #{part}") if hi < min_v || hi > max_v
        raise CronParseError.new("Range start > end: #{part}") if lo > hi
      end

      # dow: 0 и 7 — оба Sunday. Конвертируем 7 → 0.
      private def parse_dow(spec : String) : Set(Int32)
        result = Set(Int32).new
        if spec == "*"
          (0..6).each { |n| result << n }
          return result
        end
        spec.split(",").each do |part|
          normalized = part.gsub("7", "0")
          parse_part(normalized, 0, 6, result)
        end
        if result.empty?
          raise CronParseError.new("Empty dow field: #{spec}")
        end
        result
      end

      # Следующий матч после `from_ms` (не включительно). Минутный сканер.
      # Возвращает nil если нет матча в течение ~5 лет.
      def compute_next_cron_run(parsed : ParsedCronExpression, from_ms : Int64) : Int64?
        from = Time.unix_ms(from_ms).to_local
        # Начинаем с начала текущей минуты.
        cursor = from.at_beginning_of_minute

        # Сдвигаемся на 1 минуту вперёд (не включительно от from).
        cursor = cursor + 1.minute

        # Hard cap: 5 лет от from.
        max_cursor = from + 5.years
        max_iter = 5_i64 * 365 * 24 * 60 # ~5 лет в минутах
        iter = 0_i64

        while iter < max_iter && cursor < max_cursor
          iter += 1

          month_match = parsed.month.includes?(cursor.month)
          unless month_match
            # Скачок к 1-му числу следующего месяца.
            cursor = advance_to_next_month_start(cursor)
            next
          end

          dom_match = parsed.dom.includes?(cursor.day)
          # Crystal: day_of_week.value — Sunday=0, Monday=1, ..., Saturday=6.
          dow_match = parsed.dow.includes?(cursor.day_of_week.value)
          day_match =
            if parsed.dom_dow_or?
              dom_match || dow_match
            else
              dom_match && dow_match
            end
          unless day_match
            cursor = (cursor + 1.day).at_beginning_of_day
            next
          end

          hour_match = parsed.hour.includes?(cursor.hour)
          unless hour_match
            cursor = (cursor + 1.hour).at_beginning_of_hour
            next
          end

          minute_match = parsed.minute.includes?(cursor.minute)
          unless minute_match
            cursor = cursor + 1.minute
            next
          end

          return cursor.to_unix_ms
        end

        nil
      end

      private def advance_to_next_month_start(t : Time) : Time
        # Advance to first day of next month, preserving location.
        # Используем безопасный путь: первый день текущего месяца + 1 month.
        first_of_this = t.at_beginning_of_month
        first_of_this + 1.month
      end

      # True если есть fire в пределах `years` лет от `from_ms`.
      def has_fire_within_years?(parsed : ParsedCronExpression, years : Int32, from_ms : Int64) : Bool
        nxt = compute_next_cron_run(parsed, from_ms)
        return false if nxt.nil?
        max_future_ms = from_ms + years.to_i64 * 365 * MS_PER_DAY
        nxt <= max_future_ms
      end

      # Best-effort English-описание.
      def to_human(parsed : ParsedCronExpression) : String
        minutes = parsed.minute.to_a.sort
        hours = parsed.hour.to_a.sort

        # `*/N * * * *` → every N minutes
        if parsed.dow_full? && parsed.dom_full? && hours.size == 24 && minutes.size > 1
          step = minutes[1] - minutes[0]
          if step > 1 && minutes.each_cons_pair.all? { |a, b| b - a == step }
            return "every #{step} minutes"
          end
        end

        # `0 N * * *` → at N:00 daily
        if parsed.dow_full? && parsed.dom_full? && minutes == [0] && hours.size == 1
          return "at #{hours[0]}:00 daily"
        end

        # `0 N * * 1-5` → at N:00 on weekdays
        if !parsed.dow_full? && parsed.dow.size == 5 &&
           parsed.dow.includes?(1) && parsed.dow.includes?(2) &&
           parsed.dow.includes?(3) && parsed.dow.includes?(4) &&
           parsed.dow.includes?(5) &&
           parsed.dom_full? && minutes == [0] && hours.size == 1
          return "at #{hours[0]}:00 on weekdays"
        end

        # `0 N * * 0` → at N:00 on Sunday
        if !parsed.dow_full? && parsed.dow.size == 1 && parsed.dow.includes?(0) &&
           parsed.dom_full? && minutes == [0] && hours.size == 1
          return "at #{hours[0]}:00 on Sunday"
        end

        # Generic fallback: list field values.
        "cron: #{format_field(parsed.minute, 0, 59)} #{format_field(parsed.hour, 0, 23)} #{format_field(parsed.dom, 1, 31)} #{format_field(parsed.month, 1, 12)} #{format_field(parsed.dow, 0, 6)}"
      end

      private def format_field(set : Set(Int32), min_v : Int32, max_v : Int32) : String
        if set.size == (max_v - min_v + 1)
          "*"
        else
          set.to_a.sort.join(",")
        end
      end
    end

    # --------------------------------------------------------------------
    # format_local_iso_with_offset — ISO 8601 с numeric offset.
    # --------------------------------------------------------------------

    def self.format_local_iso_with_offset(ms : Int64) : String
      t = Time.unix_ms(ms).to_local
      t.to_rfc3339
    end

    # --------------------------------------------------------------------
    # Tools
    # --------------------------------------------------------------------

    class CronCreate < Tool
      DESCRIPTION = <<-TEXT
        Schedule a prompt to run on a 5-field cron schedule in local time.

        Use this for recurring work ("check the deploy every 5 minutes", "ping the API every weekday at 9am") or for one-shot reminders ("remind me at 2:30pm on Mar 5"). The agent will receive the `prompt` as a synthetic user message at each fire time.

        One-shot vs recurring:
        - `recurring: false` — fires once at the next match, then auto-deletes. Use this for "remind me at X" requests with a pinned minute/hour/dom/month.
        - `recurring: true` (default) — fires on every cron match until deleted, or until it auto-expires after 7 days of inactivity.

        Guidelines:
        - Avoid scheduling on `:00` or `:30` when the request is approximate ("around 9am"); pick an off-round minute to avoid herd effects.
        - Coalesce: if multiple fires were missed (e.g. the runtime was paused), only one delivery happens on wake-up, with `coalescedCount` reflecting how many were skipped.
        - Cron-fire envelope: at fire time, the prompt arrives in a `<cron-fire>` XML block in your context.
        - 7-day stale: recurring jobs that haven't fired in 7 days emit one final delivery with `stale: true` and then auto-delete.
        - Session lifetime: cron jobs persist on `hcode resume` of the same session.
        - Limits: max 50 jobs per session, prompt ≤ 8 KiB UTF-8. Expressions with no fire within 5 years are rejected.

        After scheduling, tell the user how to cancel (`CronDelete`) or modify (delete + recreate).
      TEXT

      def name : String
        Names::CRON_CREATE
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "cron": {
              "type": "string",
              "description": "5-field cron expression in local time: \"M H DoM Mon DoW\" (e.g. \"*/5 * * * *\" = every 5 minutes; \"30 14 28 2 *\" = Feb 28 at 2:30pm local — a pinned date like this repeats yearly unless you also pass recurring: false)."
            },
            "prompt": {
              "type": "string",
              "minLength": 1,
              "maxLength": 8192,
              "description": "The prompt to enqueue at each fire time. Limited to 8 KiB (UTF-8)."
            },
            "recurring": {
              "type": "boolean",
              "default": true,
              "description": "true (default) = fire on every cron match until deleted or auto-expired after 7 days. false = fire once at the next match, then auto-delete. Use false for \"remind me at X\" one-shot requests with pinned minute/hour/dom/month."
            }
          },
          "required": ["cron", "prompt"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = Cron.service
        return ToolResult.error("Cron service is not initialized.") if service.nil?

        svc = service

        if svc.disabled?
          return ToolResult.error("Cron scheduling is disabled.")
        end

        cron_raw = input["cron"]?.try(&.to_s) || ""
        prompt = input["prompt"]?.try(&.to_s) || ""
        recurring_raw = input["recurring"]?.try(&.as_bool?)
        recurring = recurring_raw.nil? ? true : recurring_raw

        normalized = cron_raw.strip.split(/\s+/).join(" ")
        if normalized.empty?
          return ToolResult.error("`cron` is required.")
        end
        if prompt.strip.empty?
          return ToolResult.error("`prompt` must not be empty.")
        end

        begin
          parsed = Cron.parse_expression(normalized)
        rescue ex : CronParseError
          return ToolResult.error("Invalid cron expression: #{ex.message}")
        end

        now_ms = svc.now

        unless Cron.has_fire_within_years?(parsed, 5, now_ms)
          return ToolResult.error("Cron expression #{normalized.inspect} has no fire within 5 years; refusing to schedule.")
        end

        if svc.list.size >= Cron::MAX_CRON_JOBS_PER_SESSION
          return ToolResult.error("Cron job cap reached (max #{Cron::MAX_CRON_JOBS_PER_SESSION} per session).")
        end

        prompt_bytes = prompt.bytesize
        if prompt_bytes > Cron::MAX_PROMPT_BYTES
          return ToolResult.error("Prompt exceeds #{Cron::MAX_PROMPT_BYTES} bytes (got #{prompt_bytes}).")
        end

        ideal = Cron.compute_next_cron_run(parsed, now_ms)

        if !recurring && !ideal.nil?
          future_ms = ideal - now_ms
          if future_ms > Cron::ONE_SHOT_MAX_FUTURE_MS
            return ToolResult.error("One-shot cron #{normalized.inspect} would not fire until #{Tools.format_local_iso_with_offset(ideal)} (more than a year out). Pass recurring: true or pick an earlier schedule.")
          end
        end

        # Re-check cap (race-safe).
        if svc.list.size >= Cron::MAX_CRON_JOBS_PER_SESSION
          return ToolResult.error("Cron job cap reached (max #{Cron::MAX_CRON_JOBS_PER_SESSION} per session).")
        end

        task = svc.add_task(CronTaskInit.new(cron: normalized, prompt: prompt, recurring: recurring))

        display_next = ideal.nil? ? nil : svc.compute_display_next_fire(task, parsed, ideal)
        unless display_next.nil?
          svc.set_next_fire_for_task(task.id, display_next) if svc.is_a?(InMemoryCronService)
        end

        human = Cron.to_human(parsed)

        svc.emit_scheduled(task)

        lines = [] of String
        lines << "id: #{task.id}"
        lines << "cron: #{normalized}"
        lines << "humanSchedule: #{human}"
        lines << "recurring: #{recurring}"
        lines << "nextFireAt: #{display_next.nil? ? "null" : Tools.format_local_iso_with_offset(display_next)}"
        ToolResult.success(lines.join('\n'))
      end
    end

    class CronList < Tool
      DESCRIPTION = <<-TEXT
        List scheduled cron jobs.

        Returns each job's id, cron expression, human-readable schedule, prompt preview, next fire time, recurring flag, age in days, and stale flag.

        Use this to refresh your view after CronCreate or to find an id for CronDelete. Jobs auto-expire after 7 days of inactivity (one final delivery with `stale: true`).
      TEXT

      def name : String
        Names::CRON_LIST
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = Cron.service
        return ToolResult.error("Cron service is not initialized.") if service.nil?

        svc = service
        tasks = svc.list
        return ToolResult.success("cron_jobs: 0\nNo cron jobs scheduled.") if tasks.empty?

        now_ms = svc.now
        body = tasks.map { |t| render_record(svc, t, now_ms) }.join("\n---\n")
        ToolResult.success("cron_jobs: #{tasks.size}\n#{body}")
      end

      def render_record(svc : SessionCronService, task : CronTask, now_ms : Int64) : String
        age_ms = now_ms - task.created_at
        age_days = (age_ms.to_f / Cron::MS_PER_DAY.to_f).round(2)
        stale = svc.stale?(task)

        human_schedule = task.cron
        next_fire_iso = "null"
        begin
          parsed = Cron.parse_expression(task.cron)
          human_schedule = Cron.to_human(parsed)
          nf = svc.get_next_fire_for_task(task.id)
          next_fire_iso = Tools.format_local_iso_with_offset(nf) unless nf.nil?
        rescue
          # Defensive: render with raw cron + null next fire.
        end

        lines = [] of String
        lines << "id: #{task.id}"
        lines << "cron: #{task.cron}"
        lines << "humanSchedule: #{human_schedule}"
        lines << %(prompt: #{preview_prompt(task.prompt).inspect})
        lines << "nextFireAt: #{next_fire_iso}"
        lines << "recurring: #{task.recurring?}"
        lines << "ageDays: #{age_days}"
        lines << "stale: #{stale}"
        lines.join('\n')
      end

      # UTF-8 safe truncation до 200 байт.
      def preview_prompt(prompt : String) : String
        bytes = prompt.bytes
        return prompt if bytes.size <= Cron::PROMPT_PREVIEW_BYTES
        end_idx = Cron::PROMPT_PREVIEW_BYTES
        while end_idx > 0 && (bytes[end_idx] & 0b1100_0000) == 0b1000_0000
          end_idx -= 1
        end
        slice = Bytes.new(end_idx)
        end_idx.times { |i| slice[i] = bytes[i] }
        String.new(slice) + "…(truncated)"
      end
    end

    class CronDelete < Tool
      DESCRIPTION = <<-TEXT
        Delete a scheduled cron job by id.

        Use CronList first if you don't have the id handy. Deletion is irreversible — to modify, delete and recreate with CronCreate.
      TEXT

      def name : String
        Names::CRON_DELETE
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "The cron job id (ULID) returned by CronCreate / CronList."
            }
          },
          "required": ["id"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = Cron.service
        return ToolResult.error("Cron service is not initialized.") if service.nil?

        id = input["id"]?.try(&.to_s) || ""
        return ToolResult.error("`id` is required.") if id.empty?

        unless Cron::ID_PATTERN.matches?(id)
          return ToolResult.error("Invalid cron job id #{id.inspect} — must be a ULID.")
        end

        svc = service
        removed = svc.remove_tasks([id])
        if removed.empty?
          return ToolResult.error("No cron job with id #{id}.")
        end

        svc.emit_deleted(id)
        ToolResult.success("Deleted cron job #{id}.")
      end
    end
  end
end
