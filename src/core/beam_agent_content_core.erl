-module(beam_agent_content_core).
-moduledoc """
Content block handling for beam_agent_core messages.

Provides bidirectional conversion between two message formats:

1. **Content blocks** -- Claude Code assistant messages carry a
   `content_blocks` list of heterogeneous blocks (text, thinking,
   tool_use, tool_result). This is the native Claude format.

2. **Flat messages** -- All other adapters (Codex, Gemini, OpenCode,
   Copilot) emit individual typed messages (text, tool_use, etc.)
   at the top level.

The conversion functions here let SDK consumers write adapter-
agnostic code by normalizing to whichever representation they
prefer:

  - `normalize_messages/1` -- Flatten any adapter's output into a
    uniform stream of individual typed messages. Assistant messages
    with content_blocks are expanded inline; everything else passes
    through unchanged.

  - `messages_to_blocks/1` -- Collect individual typed messages into
    a list of content_blocks (the inverse direction).

Pure functions -- no processes, no side effects.
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

%% A single content block inside an assistant message.
%%
%% Variants:
%%   text:        #{type := text, text := binary()}
%%   thinking:    #{type := thinking, thinking := binary()}
%%   tool_use:    #{type := tool_use, id := binary(), name := binary(), input := map()}
%%   tool_result: #{type := tool_result, tool_use_id := binary(), content := binary()}
%%   raw:         #{type := raw, raw := map()}  — unknown block type, preserved
-type content_block() :: #{
    type := text | thinking | tool_use | tool_result | raw,
    text => binary(),
    thinking => binary(),
    id => binary(),
    name => binary(),
    input => map(),
    tool_use_id => binary(),
    content => binary(),
    raw => map()
}.

%%====================================================================
%% API: JSON Parsing (wire -> blocks)
%%====================================================================

-doc """
Parse a list of raw JSON content block maps into typed blocks.

Non-map elements are silently dropped. Unknown block types are
preserved as `raw` blocks for forward compatibility.
""".
-spec parse_blocks(list()) -> [content_block()].
parse_blocks(Blocks) when is_list(Blocks) ->
    lists:filtermap(fun parse_block/1, Blocks);
parse_blocks(_) ->
    [].

%%====================================================================
%% API: Block <-> Message Conversion
%%====================================================================

-doc """
Convert a single content_block() into an beam_agent_core:message().

This is the block->message direction. Each block variant maps
to a flat message with the corresponding type:

  - text       -> `#{type => text, content => Text}`
  - thinking   -> `#{type => thinking, content => Thinking}`
  - tool_use   -> `#{type => tool_use, tool_name => Name, tool_input => Input}`
  - tool_result -> `#{type => tool_result, content => Content}`
  - raw        -> `#{type => raw, raw => RawMap}`

Timestamps are NOT added -- the caller controls timestamping.
""".
-spec block_to_message(content_block()) -> map().
block_to_message(#{type := text, text := Text}) ->
    #{type => text, content => Text};
block_to_message(#{type := thinking, thinking := Thinking}) ->
    #{type => thinking, content => Thinking};
block_to_message(#{type := tool_use, id := Id, name := Name, input := Input}) ->
    #{type => tool_use, tool_name => Name, tool_input => Input,
      tool_use_id => Id};
block_to_message(#{type := tool_result, tool_use_id := ToolUseId, content := Content}) ->
    #{type => tool_result, content => Content, tool_use_id => ToolUseId};
block_to_message(#{type := raw, raw := RawMap}) ->
    #{type => raw, raw => RawMap};
%% Defensive: handle blocks with missing expected fields
block_to_message(#{type := text}) ->
    #{type => text, content => <<>>};
block_to_message(#{type := thinking}) ->
    #{type => thinking, content => <<>>};
block_to_message(#{type := tool_use} = B) ->
    #{type => tool_use,
      tool_name => maps:get(name, B, <<>>),
      tool_input => maps:get(input, B, #{}),
      tool_use_id => maps:get(id, B, <<>>)};
block_to_message(#{type := tool_result} = B) ->
    #{type => tool_result,
      content => maps:get(content, B, <<>>),
      tool_use_id => maps:get(tool_use_id, B, <<>>)};
block_to_message(#{type := raw} = B) ->
    #{type => raw, raw => maps:get(raw, B, #{})};
block_to_message(Other) when is_map(Other) ->
    #{type => raw, raw => Other}.

-doc """
Convert a single flat beam_agent_core:message() into a content_block().

This is the message->block direction. Supported message types:

  - text       -> `#{type => text, text => Content}`
  - thinking   -> `#{type => thinking, thinking => Content}`
  - tool_use   -> `#{type => tool_use, id => ToolUseId, name => ToolName, input => ToolInput}`
  - tool_result -> `#{type => tool_result, tool_use_id => ToolUseId, content => Content}`

Unsupported message types (system, result, error, user, etc.)
are wrapped in a raw block for lossless round-tripping.
""".
-spec message_to_block(map()) -> content_block().
message_to_block(#{type := text, content := Content}) ->
    #{type => text, text => Content};
message_to_block(#{type := thinking, content := Content}) ->
    #{type => thinking, thinking => Content};
message_to_block(#{type := tool_use} = Msg) ->
    #{type => tool_use,
      id => maps:get(tool_use_id, Msg, <<>>),
      name => maps:get(tool_name, Msg, <<>>),
      input => maps:get(tool_input, Msg, #{})};
message_to_block(#{type := tool_result} = Msg) ->
    #{type => tool_result,
      tool_use_id => maps:get(tool_use_id, Msg, <<>>),
      content => maps:get(content, Msg, <<>>)};
%% Non-content message types -> raw block (lossless)
message_to_block(Msg) when is_map(Msg) ->
    #{type => raw, raw => Msg}.

-doc """
Flatten an assistant message (with content_blocks) into a list
of individual typed messages.

If the message is not an assistant type or has no content_blocks,
returns a single-element list containing the original message.

Common fields from the parent assistant message (uuid, session_id,
model, timestamp) are propagated to each child message so that
correlation context is preserved.

Example:

```erlang
flatten_assistant(#{type => assistant,
                    session_id => <<"s1">>,
                    content_blocks => [
                        #{type => thinking, thinking => <<"hmm">>},
                        #{type => text, text => <<"hello">>}
                    ]})
%% => [#{type => thinking, content => <<"hmm">>, session_id => <<"s1">>},
%%      #{type => text, content => <<"hello">>, session_id => <<"s1">>}]
```
""".
-spec flatten_assistant(map()) -> [map()].
flatten_assistant(#{type := assistant, content_blocks := Blocks} = Msg)
  when is_list(Blocks), Blocks =/= [] ->
    Context = extract_context(Msg),
    [maps:merge(Context, block_to_message(B)) || B <- Blocks];
flatten_assistant(Msg) when is_map(Msg) ->
    [Msg].

-doc """
Convert a list of flat messages into content_block() list.

Only messages with convertible types (text, thinking, tool_use,
tool_result) are included. Other message types (system, result,
error, user, etc.) are wrapped in raw blocks so nothing is lost.

This is the inverse of flatten_assistant -- it collects flat
messages into the content_blocks format used by Claude.
""".
-spec messages_to_blocks([map()]) -> [content_block()].
messages_to_blocks(Msgs) when is_list(Msgs) ->
    [message_to_block(M) || M <- Msgs, is_map(M)];
messages_to_blocks(_) ->
    [].

-doc """
Normalize a list of messages from ANY adapter into a uniform
flat stream of individual typed messages.

This is the primary parity function. It handles:
- Claude adapter: assistant messages with content_blocks are
  expanded inline into individual text/thinking/tool_use/etc.
- All other adapters: messages pass through unchanged.

The result is always a flat list of messages where each message
has a single, specific type -- never nested content_blocks.

Message ordering is preserved. Context fields (uuid, session_id,
model, timestamp) from assistant messages are propagated to the
flattened children.

Example usage:

```erlang
%% Works identically regardless of which adapter produced Msgs:
Flat = beam_agent_content_core:normalize_messages(Msgs),
lists:foreach(fun
    (#{type := text, content := C}) -> io:format("~s~n", [C]);
    (#{type := tool_use, tool_name := N}) -> io:format("Tool: ~s~n", [N]);
    (_) -> ok
end, Flat).
```
""".
-spec normalize_messages([map()]) -> [map()].
normalize_messages(Msgs) when is_list(Msgs) ->
    lists:flatmap(fun flatten_assistant/1, Msgs);
normalize_messages(_) ->
    [].

%%====================================================================
%% Internal: JSON block parsing
%%====================================================================

-spec parse_block(term()) -> {true, content_block()} | false.
parse_block(#{<<"type">> := <<"text">>} = Raw) ->
    {true, #{type => text, text => maps:get(<<"text">>, Raw, <<>>)}};
parse_block(#{<<"type">> := <<"thinking">>} = Raw) ->
    {true, #{type => thinking, thinking => maps:get(<<"thinking">>, Raw, <<>>)}};
parse_block(#{<<"type">> := <<"tool_use">>} = Raw) ->
    {true, #{
        type => tool_use,
        id => maps:get(<<"id">>, Raw, <<>>),
        name => maps:get(<<"name">>, Raw, <<>>),
        input => maps:get(<<"input">>, Raw, #{})
    }};
parse_block(#{<<"type">> := <<"tool_result">>} = Raw) ->
    {true, #{
        type => tool_result,
        tool_use_id => maps:get(<<"tool_use_id">>, Raw, <<>>),
        content => maps:get(<<"content">>, Raw, <<>>)
    }};
parse_block(Raw) when is_map(Raw) ->
    %% Unknown block type — preserve as raw for forward compatibility
    {true, #{type => raw, raw => Raw}};
parse_block(_) ->
    false.

%%====================================================================
%% Internal: Context propagation for flatten_assistant
%%====================================================================

%% Extract common fields from a parent assistant message that
%% should be propagated to flattened child messages.
%% Spec is intentionally broader — called from flatten_assistant which
%% already guards on assistant type, but the function itself is generic.
-dialyzer({no_underspecs, extract_context/1}).
-spec extract_context(map()) -> map().
extract_context(Msg) ->
    Fields = [uuid, session_id, model, timestamp, message_id],
    maps:with(Fields, Msg).
