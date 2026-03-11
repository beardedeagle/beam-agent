-module(beam_agent_content).
-moduledoc """
Content block conversion and message normalization.

This module provides bidirectional conversion between two message formats
used across the BeamAgent SDK:

  1. Content blocks -- Claude Code assistant messages carry a content_blocks
     list of heterogeneous blocks (text, thinking, tool_use, tool_result).
     This is the native Claude format.

  2. Flat messages -- All other adapters (Codex, Gemini, OpenCode, Copilot)
     emit individual typed messages (text, tool_use, etc.) at the top level.

The conversion functions let SDK consumers write adapter-agnostic code by
normalizing to whichever representation they prefer.

## Getting Started

```erlang
%% Normalize messages from ANY adapter into a flat stream:
Flat = beam_agent_content:normalize_messages(Messages),
lists:foreach(fun
    (#{type := text, content := C}) -> io:format("~s~n", [C]);
    (#{type := tool_use, tool_name := N}) -> io:format("Tool: ~s~n", [N]);
    (_) -> ok
end, Flat),

%% Parse raw JSON content blocks into typed blocks:
Blocks = beam_agent_content:parse_blocks(RawJsonBlocks),

%% Convert between blocks and messages:
Msg = beam_agent_content:block_to_message(Block),
Block2 = beam_agent_content:message_to_block(Msg).
```

## Key Concepts

  - Content Blocks: Structured representations of message fragments.
    Each block has a type (text, thinking, tool_use, tool_result, raw)
    and type-specific fields. Unknown block types are preserved as raw
    blocks for forward compatibility.

  - Normalization: The primary parity function. normalize_messages/1
    takes messages from any adapter and produces a uniform flat stream
    where each message has a single, specific type. Assistant messages
    with nested content_blocks are expanded inline while preserving
    correlation context (uuid, session_id, model, timestamp).

  - Round-tripping: message_to_block and block_to_message are inverses.
    Non-content message types (system, result, error, user) are wrapped
    in raw blocks so nothing is lost during conversion.

## Architecture

```
beam_agent_content (public API, re-exports content_block/0 type)
        |
        v
beam_agent_content_core (pure functions, no processes, no side effects)
```

== Core concepts ==

Different backends format their messages differently. Claude uses nested
content blocks, while Codex and Gemini use flat message maps. This module
converts between the two formats so your code does not need to care which
backend produced the message.

The most important function is normalize_messages/1. Give it a list of
messages from any backend, and it returns a uniform flat list where each
message has a single type (text, tool_use, tool_result, thinking, etc.)
and consistent field names.

Round-tripping is safe: you can convert a message to a block and back
without losing information. Unknown block types are preserved as raw
blocks for forward compatibility.

== Architecture deep dive ==

All functions in this module are pure -- no processes, no ETS, no side
effects. The module delegates to beam_agent_content_core which contains
the transformation logic.

The normalized format is map-based with type, content, and optional
metadata keys (uuid, session_id, model, timestamp). Assistant messages
with nested content_blocks are expanded inline during normalization,
preserving correlation context on each emitted message.

Every adapter calls normalize_messages during handle_data to ensure
consumers see a consistent message shape regardless of backend. The
content_block() type is re-exported from the core for caller convenience.

## See Also

  - `beam_agent` -- Main SDK entry point
  - `beam_agent_content_core` -- Core implementation (internal)
  - `beam_agent_core` -- Core types including message()
""".

-export([
    parse_blocks/1,
    block_to_message/1,
    message_to_block/1,
    flatten_assistant/1,
    messages_to_blocks/1,
    normalize_messages/1
]).

-export_type([content_block/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc """
A single content block inside an assistant message.

Variants:

  - text:        #{type := text, text := binary()}
  - thinking:    #{type := thinking, thinking := binary()}
  - tool_use:    #{type := tool_use, id := binary(), name := binary(), input := map()}
  - tool_result: #{type := tool_result, tool_use_id := binary(), content := binary()}
  - raw:         #{type := raw, raw := map()} -- unknown block type, preserved
""".
-type content_block() :: beam_agent_content_core:content_block().

%%--------------------------------------------------------------------
%% API: JSON Parsing (wire -> blocks)
%%--------------------------------------------------------------------

-doc """
Parse a list of raw JSON content block maps into typed blocks.

Converts binary-keyed JSON maps (e.g., #{<<"type">> => <<"text">>,
<<"text">> => <<"hello">>}) into atom-keyed content_block() maps.
Non-map elements are silently dropped. Unknown block types are
preserved as raw blocks for forward compatibility.

Example:

```erlang
Blocks = beam_agent_content:parse_blocks([
    #{<<"type">> => <<"text">>, <<"text">> => <<"Hello">>},
    #{<<"type">> => <<"thinking">>, <<"thinking">> => <<"hmm">>}
]),
[#{type := text, text := <<"Hello">>},
 #{type := thinking, thinking := <<"hmm">>}] = Blocks.
```
""".
-spec parse_blocks(list()) -> [content_block()].
parse_blocks(Blocks) -> beam_agent_content_core:parse_blocks(Blocks).

%%--------------------------------------------------------------------
%% API: Block <-> Message Conversion
%%--------------------------------------------------------------------

-doc """
Convert a single content block into a flat message map.

Maps each block variant to a message with the corresponding type:

  - text       -> #{type => text, content => Text}
  - thinking   -> #{type => thinking, content => Thinking}
  - tool_use   -> #{type => tool_use, tool_name => Name, tool_input => Input}
  - tool_result -> #{type => tool_result, content => Content}
  - raw        -> #{type => raw, raw => RawMap}

Blocks with missing expected fields are handled defensively by
substituting empty defaults. Timestamps are not added -- the caller
controls timestamping.
""".
-spec block_to_message(beam_agent_content_core:content_block()) ->
    #{type := text | thinking | tool_use | tool_result | raw,
      content => term(), raw => term(), tool_input => term(),
      tool_name => term(), tool_use_id => term()}.
block_to_message(Block) -> beam_agent_content_core:block_to_message(Block).

-doc """
Convert a single flat message map into a content block.

Maps each message type to the corresponding block variant:

  - text       -> #{type => text, text => Content}
  - thinking   -> #{type => thinking, thinking => Content}
  - tool_use   -> #{type => tool_use, id => ToolUseId, name => ToolName, input => ToolInput}
  - tool_result -> #{type => tool_result, tool_use_id => ToolUseId, content => Content}

Non-content message types (system, result, error, user, etc.) are
wrapped in a raw block for lossless round-tripping.
""".
-spec message_to_block(map()) -> content_block().
message_to_block(Message) -> beam_agent_content_core:message_to_block(Message).

-doc """
Flatten an assistant message with content blocks into individual messages.

If the message has type => assistant and a non-empty content_blocks
list, each block is converted to an individual message via
block_to_message/1. Common fields from the parent assistant message
(uuid, session_id, model, timestamp, message_id) are propagated to
each child message for correlation.

If the message is not an assistant type or has no content_blocks,
returns a single-element list containing the original message.
""".
-spec flatten_assistant(map()) -> [map()].
flatten_assistant(Message) -> beam_agent_content_core:flatten_assistant(Message).

-doc """
Convert a list of flat messages into content blocks.

Each message is converted via message_to_block/1. Non-map elements
in the input list are silently dropped. This is the inverse of
flatten_assistant/1 -- it collects flat messages into the
content_blocks format used by Claude.
""".
-spec messages_to_blocks([map()]) -> [content_block()].
messages_to_blocks(Messages) -> beam_agent_content_core:messages_to_blocks(Messages).

-doc """
Normalize messages from any adapter into a uniform flat stream.

This is the primary parity function. It handles:

  - Claude adapter: assistant messages with content_blocks are
    expanded inline into individual text/thinking/tool_use messages.
  - All other adapters: messages pass through unchanged.

The result is always a flat list where each message has a single,
specific type -- never nested content_blocks. Message ordering is
preserved. Context fields (uuid, session_id, model, timestamp) from
assistant messages are propagated to flattened children.

Example:

```erlang
%% Works identically regardless of which adapter produced Msgs:
Flat = beam_agent_content:normalize_messages(Msgs),
Texts = [C || #{type := text, content := C} <- Flat].
```
""".
-spec normalize_messages([map()]) -> [map()].
normalize_messages(Messages) -> beam_agent_content_core:normalize_messages(Messages).
