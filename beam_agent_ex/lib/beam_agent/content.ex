defmodule BeamAgent.Content do
  @moduledoc """
  Content block conversion and message normalisation for the BeamAgent SDK.

  This module provides bidirectional conversion between two message formats used
  across the BeamAgent SDK:

  1. **Content blocks** — Claude Code assistant messages carry a `content_blocks`
     list of heterogeneous blocks (text, thinking, tool_use, tool_result). This is
     the native Claude format.

  2. **Flat messages** — All other adapters (Codex, Gemini, OpenCode, Copilot)
     emit individual typed messages (text, tool_use, etc.) at the top level.

  The conversion functions let SDK consumers write adapter-agnostic code by
  normalising to whichever representation they prefer.

  ## When to use directly vs through `BeamAgent`

  Use this module when you need to process raw message streams from adapters,
  build a display layer that renders messages uniformly, or implement a custom
  adapter that needs to convert between formats.

  ## Quick example

  ```elixir
  # Normalise messages from ANY adapter into a flat stream:
  flat = BeamAgent.Content.normalize_messages(messages)
  texts = for %{type: :text, content: c} <- flat, do: c

  # Parse raw JSON content blocks into typed blocks:
  blocks = BeamAgent.Content.parse_blocks(raw_json_blocks)

  # Convert between blocks and messages:
  msg = BeamAgent.Content.block_to_message(block)
  block2 = BeamAgent.Content.message_to_block(msg)
  ```

  ## Core concepts

  - **Content Blocks**: structured representations of message fragments. Each
    block has a `:type` (`:text`, `:thinking`, `:tool_use`, `:tool_result`,
    `:raw`) and type-specific fields. Unknown block types are preserved as
    `:raw` blocks for forward compatibility.

  - **Normalisation**: the primary parity function. `normalize_messages/1` takes
    messages from any adapter and produces a uniform flat stream where each
    message has a single, specific type — never nested `content_blocks`.

  - **Round-tripping**: `message_to_block/1` and `block_to_message/1` are
    inverses. Non-content message types (system, result, error, user) are wrapped
    in raw blocks so nothing is lost.

  ## Architecture deep dive

  This module is a thin Elixir facade delegating to `:beam_agent_content`. The
  underlying implementation (`:beam_agent_content_core`) contains only pure
  functions — no processes, no ETS, no side effects.

  See also: `BeamAgent`, `:beam_agent_core` (core types including `message()`).
  """

  @typedoc """
  A single content block inside an assistant message.

  Variants:
  - `%{type: :text, text: binary()}`
  - `%{type: :thinking, thinking: binary()}`
  - `%{type: :tool_use, id: binary(), name: binary(), input: map()}`
  - `%{type: :tool_result, tool_use_id: binary(), content: binary()}`
  - `%{type: :raw, raw: map()}` — unknown block type, preserved for forward
    compatibility
  """
  @type content_block() :: %{
          required(:type) => :text | :thinking | :tool_use | :tool_result | :raw,
          optional(:text) => binary(),
          optional(:thinking) => binary(),
          optional(:id) => binary(),
          optional(:name) => binary(),
          optional(:input) => map(),
          optional(:tool_use_id) => binary(),
          optional(:content) => binary(),
          optional(:raw) => map()
        }

  @doc """
  Parse a list of raw JSON content block maps into typed blocks.

  Converts binary-keyed JSON maps (e.g., `%{"type" => "text", "text" => "hello"}`)
  into atom-keyed `content_block()` maps. Non-map elements are silently dropped.
  Unknown block types are preserved as `:raw` blocks.

  ## Example

  ```elixir
  blocks = BeamAgent.Content.parse_blocks([
    %{"type" => "text", "text" => "Hello"},
    %{"type" => "thinking", "thinking" => "hmm"}
  ])
  [%{type: :text, text: "Hello"}, %{type: :thinking, thinking: "hmm"}] = blocks
  ```
  """
  @spec parse_blocks(list()) :: [content_block()]
  defdelegate parse_blocks(blocks), to: :beam_agent_content

  @doc """
  Convert a single content block into a flat message map.

  Maps each block variant to a message with the corresponding type:
  - `:text` → `%{type: :text, content: text}`
  - `:thinking` → `%{type: :thinking, content: thinking}`
  - `:tool_use` → `%{type: :tool_use, tool_name: name, tool_input: input}`
  - `:tool_result` → `%{type: :tool_result, content: content}`
  - `:raw` → `%{type: :raw, raw: raw_map}`

  Blocks with missing expected fields are handled defensively by substituting
  empty defaults. Timestamps are not added — the caller controls timestamping.
  """
  @spec block_to_message(content_block()) ::
          %{
            required(:type) => :text | :thinking | :tool_use | :tool_result | :raw,
            optional(:content) => term(),
            optional(:raw) => term(),
            optional(:tool_input) => term(),
            optional(:tool_name) => term(),
            optional(:tool_use_id) => term()
          }
  defdelegate block_to_message(block), to: :beam_agent_content

  @doc """
  Convert a single flat message map into a content block.

  Maps each message type to the corresponding block variant:
  - `:text` → `%{type: :text, text: content}`
  - `:thinking` → `%{type: :thinking, thinking: content}`
  - `:tool_use` → `%{type: :tool_use, id: tool_use_id, name: tool_name, input: tool_input}`
  - `:tool_result` → `%{type: :tool_result, tool_use_id: id, content: content}`

  Non-content message types (system, result, error, user, etc.) are wrapped in a
  `:raw` block for lossless round-tripping.
  """
  @spec message_to_block(map()) :: content_block()
  defdelegate message_to_block(message), to: :beam_agent_content

  @doc """
  Flatten an assistant message with content blocks into individual messages.

  If the message has `type: :assistant` and a non-empty `content_blocks` list,
  each block is converted to an individual message via `block_to_message/1`.
  Common fields from the parent assistant message (`:uuid`, `:session_id`,
  `:model`, `:timestamp`, `:message_id`) are propagated to each child message
  for correlation.

  If the message is not an assistant type or has no `content_blocks`, returns a
  single-element list containing the original message.
  """
  @spec flatten_assistant(map()) :: [map()]
  defdelegate flatten_assistant(message), to: :beam_agent_content

  @doc """
  Convert a list of flat messages into content blocks.

  Each message is converted via `message_to_block/1`. Non-map elements in the
  input list are silently dropped. This is the inverse of `flatten_assistant/1`
  — it collects flat messages into the `content_blocks` format used by Claude.
  """
  @spec messages_to_blocks([map()]) :: [content_block()]
  defdelegate messages_to_blocks(messages), to: :beam_agent_content

  @doc """
  Normalise messages from any adapter into a uniform flat stream.

  This is the primary parity function. It handles:
  - **Claude adapter**: assistant messages with `content_blocks` are expanded
    inline into individual text/thinking/tool_use messages.
  - **All other adapters**: messages pass through unchanged.

  The result is always a flat list where each message has a single, specific
  type — never nested `content_blocks`. Message ordering is preserved. Context
  fields (`:uuid`, `:session_id`, `:model`, `:timestamp`) from assistant
  messages are propagated to flattened children.

  ## Example

  ```elixir
  # Works identically regardless of which adapter produced messages:
  flat = BeamAgent.Content.normalize_messages(messages)
  texts = for %{type: :text, content: c} <- flat, do: c
  ```
  """
  @spec normalize_messages([map()]) :: [map()]
  defdelegate normalize_messages(messages), to: :beam_agent_content
end
