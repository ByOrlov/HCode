require "../tools/skill"
require "../context/memory"
require "./types"

module H2code
  module Plugin
    module SessionStartInjector
      TAG_PREFIX = "<plugin_session_start"

      def self.render(session_starts : Array(EnabledPluginSessionStart),
                      catalog : H2code::Tools::SkillCatalog?,
                      memory : H2code::Context::Memory?) : Nil
        return if session_starts.empty?
        return unless catalog && memory
        return if already_injected?(memory)

        blocks = [] of String
        session_starts.each do |ss|
          skill = catalog.get_skill(ss.skill_name.downcase)
          next unless skill

          skill_content = catalog.render_skill_prompt(skill, "", nil)
          blocks << render_block(ss.plugin_id, skill.name, skill_content)
        end

        return if blocks.empty?
        memory.add_injection(blocks.join('\n'))
      end

      def self.render_block(plugin_id : String, skill_name : String,
                            skill_content : String) : String
        %(<plugin_session_start plugin="#{escape_attr(plugin_id)}" skill="#{escape_attr(skill_name)}">\n#{skill_content}\n</plugin_session_start>)
      end

      private def self.already_injected?(memory : H2code::Context::Memory) : Bool
        memory.history.any? do |cm|
          cm.origin.injection? && cm.message.content.includes?(TAG_PREFIX)
        end
      end

      private def self.escape_attr(s : String) : String
        s.gsub('&', "&amp;").gsub('"', "&quot;")
      end
    end
  end
end
