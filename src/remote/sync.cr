# Cloud-sync orchestration shared by `hcode sync` (CLI) and `/sync` (TUI):
# pairing-code storage, `hcode-remote --cloud` daemon lifecycle, and the
# QR banner. Config (`sync.enabled` / `sync.relay_url` / `sync.email`)
# lives in config.json; the 12-digit code in `$HCODE_HOME/remote/code`
# (same file `hcode-remote password` writes).
require "random/secure"
require "process"
require "file_utils"
require "socket"
require "./qr"

module Hcode
  module Remote
    module Sync
      # State dir: `$HCODE_HOME/remote` (default `~/.hcode/remote`).
      def self.state_dir : String
        home = ENV["HCODE_HOME"]? || File.join(ENV["HOME"]? || "/tmp", ".hcode")
        dir = File.join(home, "remote")
        Dir.mkdir_p(dir)
        dir
      end

      # The machine's LAN IP (eth/wlan outbound interface). Connects a UDP
      # socket to a public address — no packet is sent, the kernel just
      # picks the default-route interface; getsockname then yields its IP.
      # (This stdlib version lacks Socket#local_address, hence the LibC call.)
      def self.lan_ip : String
        sock = Socket.udp(Socket::Family::INET)
        begin
          sock.connect("8.8.8.8", 53)
          addr = uninitialized LibC::SockaddrIn
          len = sizeof(LibC::SockaddrIn).to_u32
          if LibC.getsockname(sock.fd, pointerof(addr).as(LibC::Sockaddr*), pointerof(len)) == 0
            n = addr.sin_addr.s_addr
            return "#{n & 0xff}.#{(n >> 8) & 0xff}.#{(n >> 16) & 0xff}.#{(n >> 24) & 0xff}"
          end
          "127.0.0.1"
        rescue ex : Socket::Error
          "127.0.0.1"
        ensure
          sock.close
        end
      end

      def self.code_path : String
        File.join(state_dir, "code")
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
      # Used by `hcode sync resync` / `hcode resync`: the old code dies with
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

      # Resolve the hcode-remote binary: sibling of the running hcode
      # executable, then PATH lookup.
      private def self.resolve_remote_bin : String?
        if exe = Process.executable_path
          sibling = File.join(File.dirname(exe), "hcode-remote")
          return sibling if File.exists?(sibling) && File.executable?(sibling)
        end
        ENV["PATH"]?.try do |paths|
          paths.split(':').each do |dir|
            candidate = File.join(dir, "hcode-remote")
            return candidate if !dir.empty? && File.executable?(candidate)
          end
        end
        nil
      end

      # Start `hcode-remote --cloud` detached; logs go to
      # `remote/daemon.log`. The local WS port defaults to 8788 (or
      # `REMOTE_CLOUD_PORT`) so a local-mode hcode-remote on 8787 doesn't
      # collide with it. Returns the outcome for user feedback.
      def self.start_daemon(relay_url : String) : Symbol
        return :already if daemon_running?
        bin = resolve_remote_bin
        return :no_binary unless bin
        read_or_create_code # hcode-remote exits 2 without it
        port = ENV["REMOTE_CLOUD_PORT"]?.try(&.to_i?) || 8788
        log = File.open(File.join(state_dir, "daemon.log"), "a")
        begin
          proc = Process.new(bin, ["--port", port.to_s, "--host", "auto", "--cloud", relay_url],
            output: log, error: log)
          File.write(pid_path, proc.pid.to_s)
          :started
        rescue ex : IO::Error | File::Error
          :failed
        ensure
          log.close
        end
      end

      def self.stop_daemon : Symbol
        pid = daemon_pid
        return :not_running unless pid
        # Stdlib has no Process.kill in this version — call libc directly
        # (returns -1 and sets errno for a dead pid; nothing to raise).
        LibC.kill(pid, LibC::SIGTERM)
        File.delete(pid_path) if File.exists?(pid_path)
        :stopped
      end

      # Full QR banner text: half-block rows plus the formatted code. The QR
      # payload is the pairing URL — the app scans it and learns both the
      # code and where the relay lives (plans/QrAuth.md).
      def self.qr_banner(code : String, relay_url : String, quiet : Int32 = 2) : String
        pretty = pretty_code(code)
        pair_url = "https://pair.hcode/?code=#{code}&url=#{URI.encode_path(relay_url)}"
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
