module Hcode
  module TUI
    struct Theme
      struct Colors
        property primary : Int32
        property secondary : Int32
        property accent : Int32
        property success : Int32
        property warning : Int32
        property error : Int32
        property muted : Int32
        property dim : Int32
        property text : Int32
        property background : Int32
        property surface : Int32
        property border : Int32
        property info : Int32
        property highlight : Int32
        property user_msg : Int32
        property tool_header : Int32
        property tool_result : Int32
        property link : Int32
        property code : Int32
        property logo : Int32
        property telemetry : Int32

        def initialize(
          @primary = 52,
          @secondary = 88,
          @accent = 52,
          @success = 114,
          @warning = 221,
          @error = 203,
          @muted = 245,
          @dim = 240,
          @text = 252,
          @background = 235,
          @surface = 237,
          @border = 239,
          @info = 131,
          @highlight = 228,
          @user_msg = 131,
          @tool_header = 52,
          @tool_result = 245,
          @link = 52,
          @code = 228,
          @logo = 144,
          @telemetry = 221,
        )
        end
      end

      property colors : Colors
      property name : String

      def self.dark : Theme
        new("dark", Colors.new(
          primary: 75,
          secondary: 80,
          accent: 80,
          success: 78,
          warning: 215,
          error: 203,
          muted: 242,
          dim: 245,
          text: 254,
          background: 235,
          surface: 237,
          border: 240,
          info: 75,
          highlight: 215,
          user_msg: 222,
          tool_header: 75,
          tool_result: 245,
          link: 75,
          code: 75,
          logo: 144,
          telemetry: 221,
        ))
      end

      def self.light : Theme
        new("light", Colors.new(
          primary: 32,
          secondary: 30,
          accent: 30,
          success: 28,
          warning: 136,
          error: 160,
          muted: 59,
          dim: 238,
          text: 234,
          background: 255,
          surface: 254,
          border: 243,
          info: 32,
          highlight: 215,
          user_msg: 130,
          tool_header: 32,
          tool_result: 59,
          link: 32,
          code: 32,
          logo: 137,
          telemetry: 136,
        ))
      end

      def initialize(@name : String, @colors : Colors)
      end

      def method_missing(name, *args)
        colors.method_missing(name, *args)
      end
    end
  end
end
