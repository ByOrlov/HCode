require "http/client"
require "file"
require "file_utils"
require "./manifest"

module Hcode
  module Plugin
    module Archive
      DOWNLOAD_TIMEOUT = 300.seconds

      def self.download_zip(url : String) : Bytes
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = DOWNLOAD_TIMEOUT

        response = client.get(uri.request_target)
        unless response.status.success?
          raise "Failed to download zip: HTTP #{response.status_code}"
        end

        response.body.to_slice
      end

      def self.extract_zip(data : Bytes, dest_dir : String) : String
        FileUtils.mkdir_p(dest_dir)

        tmpfile_path = File.join(dest_dir, ".download-#{Random::Secure.hex(4)}.zip")
        File.write(tmpfile_path, data)
        begin
          output = IO::Memory.new
          error = IO::Memory.new
          status = Process.run("unzip", ["-o", "-qq", tmpfile_path, "-d", dest_dir],
            output: output, error: error)

          unless status.success?
            raise "unzip failed (exit #{status.exit_code}): #{error.to_s.strip}"
          end
        ensure
          File.delete(tmpfile_path) rescue nil
        end

        detect_plugin_root(dest_dir)
      end

      def self.detect_plugin_root(dir : String) : String
        return dir if has_manifest?(dir)

        children = Dir.children(dir).reject { |e| e.starts_with?('.') }
        if children.size == 1
          child = File.join(dir, children[0])
          return child if Dir.exists?(child) && has_manifest?(child)
        end

        dir
      end

      def self.has_manifest?(dir : String) : Bool
        File.file?(File.join(dir, KIMI_PLUGIN_ROOT_PATH)) ||
          File.file?(File.join(dir, KIMI_PLUGIN_DIR_PATH))
      end

      def self.verify_within?(extracted_dir : String) : Bool
        root_real = File.realpath(extracted_dir)
        Dir.glob(File.join(extracted_dir, "**", "*")).each do |path|
          real = begin
            File.realpath(path)
          rescue
            path
          end
          rel = File.relative_path(real, root_real)
          return false if rel.starts_with?("..")
        end
        true
      rescue
        true
      end
    end
  end
end
