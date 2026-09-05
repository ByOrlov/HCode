# Cloud-sync orchestration shared by `h2code sync` (CLI) and `/sync` (TUI):
# pairing-code storage and the QR banner. Config (`sync.enabled` /
# `sync.relay_url` / `sync.email`) lives in config.json; the 12-digit code
# in `$H2CODE_HOME/remote/code` (same file `h2code-remote password` writes).
# The h2code-remote daemon itself is MANUAL-ONLY — see the NOTE below.
require "random/secure"
require "process"
require "file_utils"
require "socket"
require "./qr"

module H2code
  module Remote
    module Sync
      # Продакшн-релей по умолчанию (совпадает с DEFAULT_CLOUD_URL демона);
      # локальный LAN-релей — только явным relay_url в конфиге или resync.
      # Shared by `h2code sync` (CLI) and `/sync` (TUI).
      DEFAULT_RELAY_URL = "wss://relay.h2code.dev:8443/api/v1/stream"

      # State dir: `$H2CODE_HOME/remote` (default `~/.h2code/remote`).
      def self.state_dir : String
        home = ENV["H2CODE_HOME"]? || File.join(ENV["HOME"]? || "/tmp", ".h2code")
        dir = File.join(home, "remote")
        Dir.mkdir_p(dir)
        dir
      end

      # The machine's LAN IP (eth/wlan outbound interface). Connects a UDP
      # socket to a public address — no packet is sent, the kernel just
      # picks the default-route interface; local_address then yields its IP.
      def self.lan_ip : String
        sock = UDPSocket.new(Socket::Family::INET)
        begin
          sock.connect("8.8.8.8", 53)
          sock.local_address.address
        rescue ex : Socket::Error
          "127.0.0.1"
        ensure
          sock.close
        end
      end

      def self.code_path : String
        File.join(state_dir, "code")
      end

      # External, dialable-from-the-LAN form of a relay URL — what the QR
      # banner must hand out. A wildcard/loopback host means "this machine,
      # whichever interface": replace it with the LAN IP (keeping
      # scheme/port/path). A real host (domain or foreign IP) passes
      # through unchanged. nil for an empty URL.
      def self.external_relay_url(cloud_url : String) : String?
        return nil if cloud_url.empty?
        uri = URI.parse(cloud_url)
        host = uri.host.to_s.downcase
        if host.empty? || {"0.0.0.0", "::", "127.0.0.1", "localhost"}.includes?(host)
          uri.host = lan_ip
        end
        uri.to_s
      rescue ex : ArgumentError | URI::Error
        cloud_url
      end

      def self.relay_url_path : String
        File.join(state_dir, "relay.url")
      end

      # The external relay URL the daemon last connected to (nil if it
      # never ran in cloud mode). The h2code-remote daemon writes it on
      # startup; `h2code sync resync` re-reads it so `sync.relay_url` tracks
      # the daemon's actual uplink instead of a stale address.
      def self.stored_relay_url : String?
        return nil unless File.exists?(relay_url_path)
        url = File.read(relay_url_path).strip
        url.empty? ? nil : url
      end

      def self.pid_path : String
        File.join(state_dir, "daemon.pid")
      end

      # 16-digit pairing code, created on first use (mode 0600). A legacy
      # 12-digit file is still honored for manual entry.
      def self.read_or_create_code : String
        if File.exists?(code_path)
          code = File.read(code_path).strip.gsub(/\D/, "")
          return code if code.size == 16 || code.size == 12
        end
        code = (0...16).map { Random::Secure.rand(10).to_s }.join
        File.write(code_path, code)
        File.chmod(code_path, 0o600)
        code
      end

      # Force a fresh 16-digit pairing code, overwriting the stored one.
      # Used by `h2code sync resync` / `h2code resync`: the old code dies with
      # the old relay so a re-pair can't silently reuse stale credentials.
      def self.regenerate_code : String
        code = (0...16).map { Random::Secure.rand(10).to_s }.join
        File.write(code_path, code)
        File.chmod(code_path, 0o600)
        code
      end

      def self.daemon_pid : Int32?
        return nil unless File.exists?(pid_path)
        pid = File.read(pid_path).strip.to_i?
        return nil unless pid && pid > 1
        pid
      end

      def self.daemon_running? : Bool
        pid = daemon_pid
        pid ? Process.exists?(pid) : false
      end

      # The bridge URL the running daemon (or a fresh one) is reachable at.
      def self.bridge_url : String
        port = ENV["REMOTE_CLOUD_PORT"]?.try(&.to_i?) || 8788
        "ws://#{lan_ip}:#{port}"
      end

      # NOTE (2026-09-03): hcode NEVER spawns or stops the h2code-remote
      # daemon. It is a separate manual service (the user runs it himself,
      # e.g. from his own systemd unit or shell); the former autostart at
      # TUI launch and the start/stop wiring in `h2code sync` / `/sync`
      # were removed after they spammed daemon.log with lock errors from
      # repeated spawn attempts. hcode only reads daemon state (pid file)
      # for `sync status` and manages the pairing code/QR.

      # Full QR banner text: half-block rows plus the formatted code. The QR
      # payload is the pairing URL — the app scans it and learns both the
      # code and where the relay lives (plans/QrAuth.md).
      def self.qr_banner(code : String, relay_url : String, quiet : Int32 = 2) : String
        pretty = pretty_code(code)
        pair_url = "https://pair.h2code/?code=#{code}&url=#{URI.encode_path(relay_url)}"
        String.build do |s|
          Qr.render(pair_url, quiet).each { |row| s << row << '\n' }
          s << "Pairing code: " << pretty << '\n'
          s << "Relay: " << relay_url
        end
      end

      # 1234-1234-1234[-1234] depending on code length.
      def self.pretty_code(code : String) : String
        code.chars.each_slice(4).map(&.join).join("-")
      end
    end
  end
end
