module Hcode
  module Prompt
    class AgentsMd
      def self.discover(cwd : String) : String
        home = ENV["HOME"]? || "/tmp"
        hcode_home = ENV["HCODE_HOME"]? || File.join(home, ".hcode")

        paths = [] of String

        user_agents = File.join(hcode_home, "AGENTS.md")
        paths << user_agents if File.exists?(user_agents)

        user_agents2 = File.join(home, ".agents", "AGENTS.md")
        paths << user_agents2 if File.exists?(user_agents2)

        git_root = find_git_root(cwd)
        if git_root
          Dir.glob(File.join(git_root, "**", "AGENTS.md")).each do |p|
            next if p.includes?("/node_modules/") || p.includes?("/.git/")
            next if paths.includes?(p)
            paths << p
          end

          Dir.glob(File.join(git_root, "**", ".hcode", "AGENTS.md")).each do |p|
            next if p.includes?("/node_modules/") || p.includes?("/.git/")
            next if paths.includes?(p)
            paths << p
          end
        end

        paths.sort_by! { |p| p.size }

        return "" if paths.empty?

        sections = [] of String
        paths.each do |p|
          content = File.read(p).strip
          next if content.empty?
          rel = relative_to(p, cwd)
          sections << "<!-- From: #{rel} -->\n#{content}"
        end

        result = sections.join("\n\n")

        if result.bytesize > 32_768
          STDERR.puts "Warning: AGENTS.md content is large (#{result.bytesize} bytes)"
        end

        result
      end

      private def self.find_git_root(cwd : String) : String?
        current = cwd
        loop do
          if Dir.exists?(File.join(current, ".git"))
            return current
          end
          parent = File.dirname(current)
          break if parent == current
          current = parent
        end
        nil
      end

      private def self.relative_to(path : String, base : String) : String
        if path.starts_with?(base)
          rel = path[base.size..]
          rel.lchop('/')
        else
          path
        end
      end
    end
  end
end
