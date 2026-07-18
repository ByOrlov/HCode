module Hcode
  module LLM
    alias StopReason = String

    enum Role
      System
      User
      Assistant
      Tool

      def to_s : String
        case self
        in System    then "system"
        in User      then "user"
        in Assistant then "assistant"
        in Tool      then "tool"
        end
      end
    end

    struct Usage
      include JSON::Serializable

      property prompt_tokens : Int32 = 0
      property completion_tokens : Int32 = 0
      property total_tokens : Int32 = 0

      def initialize(@prompt_tokens = 0, @completion_tokens = 0, @total_tokens = 0)
      end

      def +(other : Usage) : Usage
        Usage.new(
          prompt_tokens: @prompt_tokens + other.prompt_tokens,
          completion_tokens: @completion_tokens + other.completion_tokens,
          total_tokens: @total_tokens + other.total_tokens,
        )
      end
    end

    struct ToolCall
      include JSON::Serializable

      property id : String
      property type : String = "function"
      property function : ToolCallFunction

      def initialize(@id : String, @function : ToolCallFunction, @type : String = "function")
      end

      def name : String
        @function.name
      end

      def arguments : String
        @function.arguments
      end
    end

    struct ToolCallFunction
      include JSON::Serializable

      property name : String
      property arguments : String

      def initialize(@name : String, @arguments : String = "")
      end
    end

    struct ToolDefinition
      include JSON::Serializable

      property type : String = "function"
      property function : ToolFunction

      def initialize(@function : ToolFunction, @type : String = "function")
      end

      def name : String
        @function.name
      end
    end

    struct ToolFunction
      include JSON::Serializable

      property name : String
      property description : String
      property parameters : JSON::Any

      def initialize(@name : String, @description : String, @parameters : JSON::Any)
      end
    end

    struct Message
      include JSON::Serializable

      property role : String
      @[JSON::Field(emit_null: false)]
      property content : String?
      @[JSON::Field(emit_null: false)]
      property tool_calls : Array(ToolCall)?
      @[JSON::Field(emit_null: false)]
      property tool_call_id : String?

      def initialize(@role : String, @content : String? = nil,
                     @tool_calls : Array(ToolCall)? = nil,
                     @tool_call_id : String? = nil)
      end

      def self.system(content : String) : Message
        new("system", content)
      end

      def self.user(content : String) : Message
        new("user", content)
      end

      def self.assistant(content : String? = nil, tool_calls : Array(ToolCall)? = nil) : Message
        new("assistant", content, tool_calls)
      end

      def self.tool(content : String, tool_call_id : String) : Message
        new("tool", content, nil, tool_call_id)
      end
    end

    # How a provider transmits the reasoning-effort hint on the wire. Each
    # backend speaks a different dialect, so the chosen shape is per-provider
    # (mirrors the TS kosong adapters):
    #
    #   Moonshot        — top-level `thinking:{type, effort?}` object
    #                     (Moonshot-proprietary). `effort` only when the model
    #                     declares it in its `think_efforts.valid_efforts`.
    #   ReasoningEffort — top-level `reasoning_effort` string
    #                     (OpenAI / ZAI / Zhipu GLM). Plain value, no object.
    #   None            — backend has no effort control; nothing is sent.
    enum ThinkingWire
      None
      Moonshot
      ReasoningEffort
    end

    # Moonshot-proprietary thinking control, sent as a top-level `thinking`
    # object on the Chat Completions request body. `type: "enabled"` enables
    # reasoning; `effort` (low/high/max) scales the reasoning budget. `effort`
    # is only emitted when the model actually supports it — sending an
    # unsupported value (e.g. "medium" to the boolean-only `kimi-for-coding`)
    # is rejected with HTTP 400 by the endpoint.
    struct ThinkingConfig
      include JSON::Serializable

      property type : String
      @[JSON::Field(emit_null: false)]
      property effort : String?

      def initialize(@type : String, @effort : String? = nil)
      end
    end

    struct ChatRequest
      include JSON::Serializable

      property model : String
      property messages : Array(Message)
      property tools : Array(ToolDefinition)?
      property stream : Bool = true
      property temperature : Float64?
      property max_tokens : Int32?
      # Preferred over the legacy `max_tokens` alias on the wire (matches the
      # Moonshot API contract). When both are set `max_completion_tokens`
      # is emitted and `max_tokens` is dropped.
      property max_completion_tokens : Int32?
      # Session affinity: the stable key under which the provider caches the
      # prompt prefix. Without it every step reprocesses the full, growing
      # context from scratch (O(N^2) over a sequential read loop).
      property prompt_cache_key : String?
      property thinking : ThinkingConfig?
      # OpenAI / ZAI / GLM reasoning-effort token (top-level string). Sent
      # instead of `thinking` for backends whose wire dialect is
      # `reasoning_effort` (see ThinkingWire::ReasoningEffort). `off`/`on` have
      # no wire encoding on these endpoints and are omitted.
      property reasoning_effort : String?
      # OpenAI-compatible parameter that lets the model emit multiple tool calls
      # in a single response. Without it some backends default to one call per
      # turn, which serialises multi-file reads.
      property parallel_tool_calls : Bool?

      def initialize(@model : String, @messages : Array(Message),
                     @tools : Array(ToolDefinition)? = nil,
                     @stream : Bool = true,
                     @temperature : Float64? = nil,
                     @max_tokens : Int32? = nil,
                     @max_completion_tokens : Int32? = nil,
                     @prompt_cache_key : String? = nil,
                     @parallel_tool_calls : Bool? = nil)
      end

      # Disable any previously applied thinking hint. Provider-specific effort
      # resolution now lives on the provider (it needs model metadata), but this
      # keeps a request's thinking state clearable.
      def clear_thinking : Nil
        @thinking = nil
        @reasoning_effort = nil
      end

      def to_json
        JSON.build do |json|
          json.object do
            json.field "model", @model
            json.field "messages" do
              @messages.to_json(json)
            end
            if t = @tools
              json.field "tools" do
                t.to_json(json)
              end
            end
            json.field "stream", @stream
            if temp = @temperature
              json.field "temperature", temp
            end
            if mct = @max_completion_tokens
              json.field "max_completion_tokens", mct
            elsif mt = @max_tokens
              json.field "max_tokens", mt
            end
            if key = @prompt_cache_key
              json.field "prompt_cache_key", key
            end
            if re = @reasoning_effort
              json.field "reasoning_effort", re
            end
            if ptc = @parallel_tool_calls
              json.field "parallel_tool_calls", ptc
            end
            if @stream
              json.field "stream_options" do
                json.object do
                  json.field "include_usage", true
                end
              end
            end
            if t = @thinking
              json.field "thinking" do
                json.object do
                  json.field "type", t.type
                  if e = t.effort
                    json.field "effort", e
                  end
                end
              end
            end
          end
        end
      end
    end

    struct StreamChunk
      include JSON::Serializable

      property id : String?
      property object : String?
      property model : String?
      property choices : Array(StreamChoice) = [] of StreamChoice
      property usage : Usage?

      def initialize
      end
    end

    struct StreamChoice
      include JSON::Serializable

      property index : Int32 = 0
      property delta : Delta?
      property finish_reason : String?
      # Moonshot proprietary: usage may appear inside the first choice
      # instead of the top-level `usage` field. Mirrors the TS extractor
      # `extractUsageFromChunk` (kimi.ts:222).
      property usage : Usage?

      def initialize
      end
    end

    struct Delta
      include JSON::Serializable

      property role : String?
      property content : String?
      property reasoning_content : String?
      property tool_calls : Array(DeltaToolCall)?

      def initialize
      end
    end

    struct DeltaToolCall
      include JSON::Serializable

      property index : Int32 = 0
      property id : String?
      property type : String?
      property function : DeltaToolCallFunction?

      def initialize
      end
    end

    struct DeltaToolCallFunction
      include JSON::Serializable

      property name : String?
      property arguments : String?

      def initialize
      end
    end

    enum MessagePartType
      Text
      Think
      ToolCall
      Usage
      Finish
    end

    abstract class MessagePart
      property type : MessagePartType

      def initialize(@type : MessagePartType)
      end
    end

    class TextPart < MessagePart
      property text : String

      def initialize(@text : String)
        super(MessagePartType::Text)
      end
    end

    class ThinkPart < MessagePart
      property text : String

      def initialize(@text : String)
        super(MessagePartType::Think)
      end
    end

    class ToolCallPart < MessagePart
      property id : String
      property name : String
      property arguments : String

      def initialize(@id : String, @name : String, @arguments : String)
        super(MessagePartType::ToolCall)
      end
    end

    class UsagePart < MessagePart
      property usage : Usage

      def initialize(@usage : Usage)
        super(MessagePartType::Usage)
      end
    end

    class FinishPart < MessagePart
      property reason : String

      def initialize(@reason : String)
        super(MessagePartType::Finish)
      end
    end

    struct StepResult
      property stop_reason : String
      property text : String
      property tool_calls : Array(ToolCall)
      property usage : Usage

      def initialize(@stop_reason : String = "end_turn",
                     @text : String = "",
                     @tool_calls : Array(ToolCall) = [] of ToolCall,
                     @usage : Usage = Usage.new)
      end

      def tool_use? : Bool
        @stop_reason == "tool_use" || (@tool_calls.size > 0 && @stop_reason != "end_turn")
      end
    end

    struct TurnResult
      property stop_reason : String
      property steps : Int32
      property usage : Usage

      def initialize(@stop_reason : String = "end_turn",
                     @steps : Int32 = 0,
                     @usage : Usage = Usage.new)
      end
    end

    # Error returned by the upstream chat-completions endpoint.
    # Carries the HTTP status code and a precomputed `retryable?` flag so the
    # agent loop can decide whether to back off (transient) or fail fast
    # (e.g. 401/403/404 — retrying won't help).
    class ApiError < Exception
      getter status_code : Int32
      getter? retryable : Bool

      def initialize(@status_code : Int32, message : String, @retryable : Bool = true)
        super(message)
      end

      def self.retryable_status?(status_code : Int32) : Bool
        status_code == 408 || status_code == 429 || status_code >= 500
      end
    end

    # Raised when an in-flight request is aborted by the user. Lets the
    # streaming worker unwind so the agent loop can surface a cancellation.
    class AbortedError < Exception
      def initialize(message : String = "request aborted")
        super(message)
      end
    end
  end
end
