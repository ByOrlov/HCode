require "http/client"
require "file_utils"
require "json"

module Hcode
  # Self-update: downloads the latest GitHub release asset that matches the
  # current binary's target and replaces the running executable in place.
  # Triggered by the `/upgrade` TUI command.
  module Upgrader
    REPO = "ByOrlov/HCode"

    # Injectable so specs can stub the network. Returns the raw response body.
    @@http_get : Proc(String, String) = ->(url : String) { real_http_get(url) }

    def self.http_get : Proc(String, String)
      @@http_get
    end

    def self.http_get=(proc : Proc(String, String))
      @@http_get = proc
    end

    # Asset name for the binary's own platform, baked at compile time.
    def self.asset_name : String
      os = {{ flag?(:darwin) ? "darwin" : flag?(:win32) ? "windows" : "linux" }}
      arch = {{ flag?(:aarch64) ? "aarch64" : "x86_64" }}
      ext = {{ flag?(:win32) ? "zip" : "tar.gz" }}
      "hcode-#{arch}-#{os}.#{ext}"
    end

    def self.current_version : String
      Hcode::VERSION
    end

    # Returns the latest release tag (e.g. "2026.07.31.3"), or nil on error.
    def self.latest_version : String?
      body = @@http_get.call("https://api.github.com/repos/#{REPO}/releases/latest")
      json = JSON.parse(body)
      json["tag_name"]?.try(&.as_s)
    rescue ex
      nil
    end

    # Runs the full check → download → replace flow.
    # Returns a human-readable status message; success is reflected in the
    # first element of the returned tuple.
    def self.run : {Bool, String}
      latest = latest_version
      if latest.nil?
        return {false, Hcode.t("ui.upgrade_fetch_failed")}
      end

      if !VersionCompare.newer?(latest, current_version)
        return {true, Hcode.t("ui.upgrade_uptodate", version: current_version)}
      end

      asset = asset_name
      url = "https://github.com/#{REPO}/releases/latest/download/#{asset}"
      begin
        data = @@http_get.call(url)
      rescue ex
        return {false, Hcode.t("ui.upgrade_download_failed", error: ex.message || ex.to_s)}
      end

      begin
        replace_binary(data)
      rescue ex
        return {false, Hcode.t("ui.upgrade_install_failed", error: ex.message || ex.to_s)}
      end

      {true, Hcode.t("ui.upgrade_done", version: latest)}
    end

    # --- Binary replacement -------------------------------------------------

    private def self.replace_binary(archive_bytes : String) : Nil
      tmp_dir = nil.as(String?)
      tmp_dir = Dir.tempdir + "/hcode-upgrade-#{Random::Secure.hex(4)}"
      Dir.mkdir_p(tmp_dir)

      archive_name = asset_name
      archive_path = File.join(tmp_dir, archive_name)
      File.write(archive_path, archive_bytes)

      # Extract: tar handles both .tar.gz and .zip on modern systems.
      bin_name = {{ flag?(:win32) ? "hcode.exe" : "hcode" }}
      if archive_name.ends_with?(".zip")
        # Windows: use built-in tar (Windows 10 1803+) which reads zip.
        run_shell("tar -xf #{Process.quote(archive_path)} -C #{Process.quote(tmp_dir)}")
      else
        run_shell("tar -xzf #{Process.quote(archive_path)} -C #{Process.quote(tmp_dir)}")
      end

      new_bin = File.join(tmp_dir, bin_name)
      unless File.exists?(new_bin)
        raise "extracted binary not found at #{new_bin}"
      end

      cur = current_executable
      {% if flag?(:win32) %}
        # Windows cannot overwrite a running .exe — move the old one aside.
        old = cur + ".old"
        File.delete(old) if File.exists?(old)
        File.rename(cur, old)
        File.rename(new_bin, cur)
      {% else %}
        # Unix: rename over the running binary (inode stays valid for the
        # active process; new invocations pick up the new file).
        File.chmod(new_bin, 0o755)
        File.rename(new_bin, cur)
      {% end %}
    ensure
      FileUtils.rm_rf(tmp_dir) if tmp_dir
    end

    def self.current_executable : String
      {% if flag?(:linux) %}
        File.readlink("/proc/self/exe")
      {% else %}
        File.realpath(PROGRAM_NAME)
      {% end %}
    rescue
      PROGRAM_NAME
    end

    private def self.run_shell(cmd : String) : Nil
      status = Process.run(cmd, shell: true, output: Process::Redirect::Close, error: Process::Redirect::Inherit)
      raise "extraction command failed: #{cmd}" unless status.success?
    end

    # Real HTTP GET — follows redirects, returns the body as a string.
    private def self.real_http_get(url : String) : String
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.tls.verify_mode = OpenSSL::SSL::VerifyMode::PEER if uri.scheme == "https"
      response = client.get(uri.request_target)
      if (300..399).includes?(response.status_code)
        location = response.headers["Location"]?
        client.close
        raise "redirect without Location" unless location
        return real_http_get(location)
      end
      raise "HTTP #{response.status_code}" unless response.status.success?
      body = response.body
      client.close
      body
    end
  end
end
