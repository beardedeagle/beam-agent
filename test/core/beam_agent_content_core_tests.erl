%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_content_core (content block handling).
%%%
%%% Tests cover:
%%%   - parse_blocks/1: JSON wire → content_block() (existing)
%%%   - block_to_message/1: content_block() → flat message
%%%   - message_to_block/1: flat message → content_block()
%%%   - flatten_assistant/1: assistant message → flat message list
%%%   - messages_to_blocks/1: flat messages → [content_block()]
%%%   - normalize_messages/1: any adapter output → uniform flat stream
%%%   - Round-trip preservation: block→message→block and vice versa
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_content_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% parse_blocks/1 (existing tests)
%%====================================================================

parse_single_text_block_test() ->
    Blocks = beam_agent_content_core:parse_blocks([
        #{<<"type">> => <<"text">>, <<"text">> => <<"hello world">>}
    ]),
    ?assertEqual(1, length(Blocks)),
    [Block] = Blocks,
    ?assertEqual(text, maps:get(type, Block)),
    ?assertEqual(<<"hello world">>, maps:get(text, Block)).

parse_single_thinking_block_test() ->
    Blocks = beam_agent_content_core:parse_blocks([
        #{<<"type">> => <<"thinking">>,
          <<"thinking">> => <<"let me reason...">>}
    ]),
    ?assertEqual(1, length(Blocks)),
    [Block] = Blocks,
    ?assertEqual(thinking, maps:get(type, Block)),
    ?assertEqual(<<"let me reason...">>, maps:get(thinking, Block)).

parse_single_tool_use_block_test() ->
    Blocks = beam_agent_content_core:parse_blocks([
        #{<<"type">> => <<"tool_use">>,
          <<"id">> => <<"tu_123">>,
          <<"name">> => <<"read_file">>,
          <<"input">> => #{<<"path">> => <<"/tmp/test">>}}
    ]),
    ?assertEqual(1, length(Blocks)),
    [Block] = Blocks,
    ?assertEqual(tool_use, maps:get(type, Block)),
    ?assertEqual(<<"tu_123">>, maps:get(id, Block)),
    ?assertEqual(<<"read_file">>, maps:get(name, Block)),
    ?assertEqual(#{<<"path">> => <<"/tmp/test">>}, maps:get(input, Block)).

parse_single_tool_result_block_test() ->
    Blocks = beam_agent_content_core:parse_blocks([
        #{<<"type">> => <<"tool_result">>,
          <<"tool_use_id">> => <<"tu_123">>,
          <<"content">> => <<"file contents here">>}
    ]),
    ?assertEqual(1, length(Blocks)),
    [Block] = Blocks,
    ?assertEqual(tool_result, maps:get(type, Block)),
    ?assertEqual(<<"tu_123">>, maps:get(tool_use_id, Block)),
    ?assertEqual(<<"file contents here">>, maps:get(content, Block)).

parse_mixed_content_blocks_test() ->
    Blocks = beam_agent_content_core:parse_blocks([
        #{<<"type">> => <<"thinking">>,
          <<"thinking">> => <<"analyzing...">>},
        #{<<"type">> => <<"text">>,
          <<"text">> => <<"Here's my answer">>},
        #{<<"type">> => <<"tool_use">>,
          <<"id">> => <<"tu_1">>,
          <<"name">> => <<"bash">>,
          <<"input">> => #{<<"command">> => <<"ls">>}}
    ]),
    ?assertEqual(3, length(Blocks)),
    [Thinking, Text, ToolUse] = Blocks,
    ?assertEqual(thinking, maps:get(type, Thinking)),
    ?assertEqual(text, maps:get(type, Text)),
    ?assertEqual(tool_use, maps:get(type, ToolUse)).

parse_empty_list_test() ->
    ?assertEqual([], beam_agent_content_core:parse_blocks([])).

parse_non_list_test() ->
    %% Non-list input returns empty
    ?assertEqual([], beam_agent_content_core:parse_blocks(<<"not a list">>)),
    ?assertEqual([], beam_agent_content_core:parse_blocks(#{})),
    ?assertEqual([], beam_agent_content_core:parse_blocks(42)).

parse_unknown_block_type_test() ->
    %% Unknown type is preserved as raw block
    UnknownBlock = #{<<"type">> => <<"server_tool_use">>,
                     <<"data">> => <<"stuff">>},
    Blocks = beam_agent_content_core:parse_blocks([UnknownBlock]),
    ?assertEqual(1, length(Blocks)),
    [Block] = Blocks,
    ?assertEqual(raw, maps:get(type, Block)),
    ?assertEqual(UnknownBlock, maps:get(raw, Block)).

parse_non_map_elements_dropped_test() ->
    %% Non-map elements in the list are silently dropped
    Blocks = beam_agent_content_core:parse_blocks([
        <<"not a map">>,
        #{<<"type">> => <<"text">>, <<"text">> => <<"valid">>},
        42,
        #{<<"type">> => <<"text">>, <<"text">> => <<"also valid">>}
    ]),
    ?assertEqual(2, length(Blocks)),
    [B1, B2] = Blocks,
    ?assertEqual(<<"valid">>, maps:get(text, B1)),
    ?assertEqual(<<"also valid">>, maps:get(text, B2)).

parse_missing_fields_default_test() ->
    %% Missing optional fields get defaults
    Blocks = beam_agent_content_core:parse_blocks([
        #{<<"type">> => <<"text">>},
        #{<<"type">> => <<"tool_use">>}
    ]),
    [TextBlock, ToolBlock] = Blocks,
    ?assertEqual(<<>>, maps:get(text, TextBlock)),
    ?assertEqual(<<>>, maps:get(id, ToolBlock)),
    ?assertEqual(<<>>, maps:get(name, ToolBlock)),
    ?assertEqual(#{}, maps:get(input, ToolBlock)).

parse_map_without_type_test() ->
    %% Map without <<"type">> key is preserved as raw
    Blocks = beam_agent_content_core:parse_blocks([
        #{<<"data">> => <<"no type field">>}
    ]),
    ?assertEqual(1, length(Blocks)),
    [Block] = Blocks,
    ?assertEqual(raw, maps:get(type, Block)).

%%====================================================================
%% block_to_message/1
%%====================================================================

block_to_message_text_test() ->
    Block = #{type => text, text => <<"hello">>},
    Msg = beam_agent_content_core:block_to_message(Block),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"hello">>, maps:get(content, Msg)).

block_to_message_thinking_test() ->
    Block = #{type => thinking, thinking => <<"reasoning...">>},
    Msg = beam_agent_content_core:block_to_message(Block),
    ?assertEqual(thinking, maps:get(type, Msg)),
    ?assertEqual(<<"reasoning...">>, maps:get(content, Msg)).

block_to_message_tool_use_test() ->
    Block = #{type => tool_use, id => <<"tu_1">>,
              name => <<"bash">>, input => #{<<"cmd">> => <<"ls">>}},
    Msg = beam_agent_content_core:block_to_message(Block),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"bash">>, maps:get(tool_name, Msg)),
    ?assertEqual(#{<<"cmd">> => <<"ls">>}, maps:get(tool_input, Msg)),
    ?assertEqual(<<"tu_1">>, maps:get(tool_use_id, Msg)).

block_to_message_tool_result_test() ->
    Block = #{type => tool_result, tool_use_id => <<"tu_1">>,
              content => <<"output here">>},
    Msg = beam_agent_content_core:block_to_message(Block),
    ?assertEqual(tool_result, maps:get(type, Msg)),
    ?assertEqual(<<"output here">>, maps:get(content, Msg)),
    ?assertEqual(<<"tu_1">>, maps:get(tool_use_id, Msg)).

block_to_message_raw_test() ->
    RawMap = #{<<"unknown">> => <<"data">>},
    Block = #{type => raw, raw => RawMap},
    Msg = beam_agent_content_core:block_to_message(Block),
    ?assertEqual(raw, maps:get(type, Msg)),
    ?assertEqual(RawMap, maps:get(raw, Msg)).

block_to_message_text_missing_text_field_test() ->
    %% Defensive: text block without text field → empty content
    Block = #{type => text},
    Msg = beam_agent_content_core:block_to_message(Block),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(content, Msg)).

block_to_message_tool_use_missing_fields_test() ->
    %% Defensive: tool_use block with missing fields → defaults
    Block = #{type => tool_use},
    Msg = beam_agent_content_core:block_to_message(Block),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(tool_name, Msg)),
    ?assertEqual(#{}, maps:get(tool_input, Msg)),
    ?assertEqual(<<>>, maps:get(tool_use_id, Msg)).

block_to_message_unknown_map_test() ->
    %% Completely unknown map → raw
    Unknown = #{foo => bar},
    Msg = beam_agent_content_core:block_to_message(Unknown),
    ?assertEqual(raw, maps:get(type, Msg)),
    ?assertEqual(Unknown, maps:get(raw, Msg)).

%%====================================================================
%% message_to_block/1
%%====================================================================

message_to_block_text_test() ->
    Msg = #{type => text, content => <<"hello">>},
    Block = beam_agent_content_core:message_to_block(Msg),
    ?assertEqual(text, maps:get(type, Block)),
    ?assertEqual(<<"hello">>, maps:get(text, Block)).

message_to_block_thinking_test() ->
    Msg = #{type => thinking, content => <<"reasoning...">>},
    Block = beam_agent_content_core:message_to_block(Msg),
    ?assertEqual(thinking, maps:get(type, Block)),
    ?assertEqual(<<"reasoning...">>, maps:get(thinking, Block)).

message_to_block_tool_use_test() ->
    Msg = #{type => tool_use, tool_name => <<"read">>,
            tool_input => #{<<"path">> => <<"/tmp">>},
            tool_use_id => <<"tu_42">>},
    Block = beam_agent_content_core:message_to_block(Msg),
    ?assertEqual(tool_use, maps:get(type, Block)),
    ?assertEqual(<<"tu_42">>, maps:get(id, Block)),
    ?assertEqual(<<"read">>, maps:get(name, Block)),
    ?assertEqual(#{<<"path">> => <<"/tmp">>}, maps:get(input, Block)).

message_to_block_tool_use_missing_id_test() ->
    %% tool_use without tool_use_id → default empty
    Msg = #{type => tool_use, tool_name => <<"bash">>,
            tool_input => #{}},
    Block = beam_agent_content_core:message_to_block(Msg),
    ?assertEqual(<<>>, maps:get(id, Block)).

message_to_block_tool_result_test() ->
    Msg = #{type => tool_result, content => <<"output">>,
            tool_use_id => <<"tu_42">>},
    Block = beam_agent_content_core:message_to_block(Msg),
    ?assertEqual(tool_result, maps:get(type, Block)),
    ?assertEqual(<<"tu_42">>, maps:get(tool_use_id, Block)),
    ?assertEqual(<<"output">>, maps:get(content, Block)).

message_to_block_tool_result_missing_fields_test() ->
    %% tool_result with minimal fields → defaults
    Msg = #{type => tool_result},
    Block = beam_agent_content_core:message_to_block(Msg),
    ?assertEqual(tool_result, maps:get(type, Block)),
    ?assertEqual(<<>>, maps:get(tool_use_id, Block)),
    ?assertEqual(<<>>, maps:get(content, Block)).

message_to_block_system_wraps_raw_test() ->
    %% Non-content types (system, result, error) → raw block
    Msg = #{type => system, content => <<"init">>, subtype => <<"init">>},
    Block = beam_agent_content_core:message_to_block(Msg),
    ?assertEqual(raw, maps:get(type, Block)),
    ?assertEqual(Msg, maps:get(raw, Block)).

message_to_block_result_wraps_raw_test() ->
    Msg = #{type => result, content => <<"done">>},
    Block = beam_agent_content_core:message_to_block(Msg),
    ?assertEqual(raw, maps:get(type, Block)),
    ?assertEqual(Msg, maps:get(raw, Block)).

message_to_block_error_wraps_raw_test() ->
    Msg = #{type => error, content => <<"oops">>},
    Block = beam_agent_content_core:message_to_block(Msg),
    ?assertEqual(raw, maps:get(type, Block)),
    ?assertEqual(Msg, maps:get(raw, Block)).

%%====================================================================
%% flatten_assistant/1
%%====================================================================

flatten_assistant_expands_content_blocks_test() ->
    Msg = #{type => assistant,
            session_id => <<"sess_1">>,
            uuid => <<"uuid_1">>,
            model => <<"claude-opus-4-20250514">>,
            timestamp => 1234567890,
            content_blocks => [
                #{type => thinking, thinking => <<"hmm...">>},
                #{type => text, text => <<"Hello!">>},
                #{type => tool_use, id => <<"tu_1">>,
                  name => <<"bash">>,
                  input => #{<<"cmd">> => <<"ls">>}}
            ]},
    Flat = beam_agent_content_core:flatten_assistant(Msg),
    ?assertEqual(3, length(Flat)),
    [Think, Text, Tool] = Flat,
    %% Types correct
    ?assertEqual(thinking, maps:get(type, Think)),
    ?assertEqual(text, maps:get(type, Text)),
    ?assertEqual(tool_use, maps:get(type, Tool)),
    %% Content correct
    ?assertEqual(<<"hmm...">>, maps:get(content, Think)),
    ?assertEqual(<<"Hello!">>, maps:get(content, Text)),
    ?assertEqual(<<"bash">>, maps:get(tool_name, Tool)),
    %% Context propagated from parent assistant message
    ?assertEqual(<<"sess_1">>, maps:get(session_id, Think)),
    ?assertEqual(<<"sess_1">>, maps:get(session_id, Text)),
    ?assertEqual(<<"uuid_1">>, maps:get(uuid, Tool)),
    ?assertEqual(<<"claude-opus-4-20250514">>, maps:get(model, Text)).

flatten_assistant_empty_blocks_returns_original_test() ->
    %% Empty content_blocks → return original message as-is
    Msg = #{type => assistant, content_blocks => []},
    ?assertEqual([Msg], beam_agent_content_core:flatten_assistant(Msg)).

flatten_assistant_no_blocks_key_returns_original_test() ->
    %% Missing content_blocks key → return original
    Msg = #{type => assistant, content => <<"text only">>},
    ?assertEqual([Msg], beam_agent_content_core:flatten_assistant(Msg)).

flatten_assistant_non_assistant_passthrough_test() ->
    %% Non-assistant messages pass through unchanged
    Msg = #{type => text, content => <<"hello">>},
    ?assertEqual([Msg], beam_agent_content_core:flatten_assistant(Msg)).

flatten_assistant_system_message_passthrough_test() ->
    Msg = #{type => system, content => <<"init">>},
    ?assertEqual([Msg], beam_agent_content_core:flatten_assistant(Msg)).

flatten_assistant_preserves_message_id_test() ->
    Msg = #{type => assistant,
            message_id => <<"msg_abc">>,
            content_blocks => [
                #{type => text, text => <<"hi">>}
            ]},
    [Flat] = beam_agent_content_core:flatten_assistant(Msg),
    ?assertEqual(<<"msg_abc">>, maps:get(message_id, Flat)).

%%====================================================================
%% messages_to_blocks/1
%%====================================================================

messages_to_blocks_converts_flat_messages_test() ->
    Msgs = [
        #{type => text, content => <<"hello">>},
        #{type => thinking, content => <<"reasoning">>},
        #{type => tool_use, tool_name => <<"bash">>,
          tool_input => #{}, tool_use_id => <<"tu_1">>}
    ],
    Blocks = beam_agent_content_core:messages_to_blocks(Msgs),
    ?assertEqual(3, length(Blocks)),
    [TextB, ThinkB, ToolB] = Blocks,
    ?assertEqual(text, maps:get(type, TextB)),
    ?assertEqual(<<"hello">>, maps:get(text, TextB)),
    ?assertEqual(thinking, maps:get(type, ThinkB)),
    ?assertEqual(<<"reasoning">>, maps:get(thinking, ThinkB)),
    ?assertEqual(tool_use, maps:get(type, ToolB)),
    ?assertEqual(<<"bash">>, maps:get(name, ToolB)).

messages_to_blocks_wraps_non_content_as_raw_test() ->
    Msgs = [
        #{type => system, content => <<"init">>},
        #{type => text, content => <<"hello">>},
        #{type => result, content => <<"done">>}
    ],
    Blocks = beam_agent_content_core:messages_to_blocks(Msgs),
    ?assertEqual(3, length(Blocks)),
    [SysB, TextB, ResB] = Blocks,
    ?assertEqual(raw, maps:get(type, SysB)),
    ?assertEqual(text, maps:get(type, TextB)),
    ?assertEqual(raw, maps:get(type, ResB)).

messages_to_blocks_empty_list_test() ->
    ?assertEqual([], beam_agent_content_core:messages_to_blocks([])).

messages_to_blocks_non_list_test() ->
    ?assertEqual([], beam_agent_content_core:messages_to_blocks(not_a_list)).

%%====================================================================
%% normalize_messages/1
%%====================================================================

normalize_messages_flattens_assistant_inline_test() ->
    %% Simulates Claude adapter output: system → assistant(blocks) → result
    Msgs = [
        #{type => system, content => <<"init">>, subtype => <<"init">>},
        #{type => assistant,
          session_id => <<"s1">>,
          content_blocks => [
              #{type => thinking, thinking => <<"analyzing...">>},
              #{type => text, text => <<"The answer is 42.">>},
              #{type => tool_use, id => <<"tu_1">>,
                name => <<"bash">>, input => #{<<"cmd">> => <<"ls">>}},
              #{type => tool_result, tool_use_id => <<"tu_1">>,
                content => <<"file1.txt">>}
          ]},
        #{type => result, content => <<>>}
    ],
    Flat = beam_agent_content_core:normalize_messages(Msgs),
    %% 1 system + 4 flattened blocks + 1 result = 6
    ?assertEqual(6, length(Flat)),
    Types = [maps:get(type, M) || M <- Flat],
    ?assertEqual([system, thinking, text, tool_use, tool_result, result], Types),
    %% Session ID propagated to flattened messages
    [_, Think, Text, Tool, ToolRes, _] = Flat,
    ?assertEqual(<<"s1">>, maps:get(session_id, Think)),
    ?assertEqual(<<"s1">>, maps:get(session_id, Text)),
    ?assertEqual(<<"s1">>, maps:get(session_id, Tool)),
    ?assertEqual(<<"s1">>, maps:get(session_id, ToolRes)).

normalize_messages_codex_passthrough_test() ->
    %% Simulates Codex adapter output: already flat
    Msgs = [
        #{type => system, content => <<"turn started">>},
        #{type => text, content => <<"Hello!">>},
        #{type => tool_use, tool_name => <<"bash">>, tool_input => #{}},
        #{type => tool_result, tool_name => <<"bash">>, content => <<"ok">>},
        #{type => result, content => <<>>}
    ],
    Flat = beam_agent_content_core:normalize_messages(Msgs),
    %% Already flat — passes through unchanged
    ?assertEqual(Msgs, Flat).

normalize_messages_gemini_passthrough_test() ->
    %% Simulates Gemini adapter output: already flat
    Msgs = [
        #{type => system, subtype => <<"init">>, content => <<>>},
        #{type => text, content => <<"Hi there">>},
        #{type => result, content => <<>>}
    ],
    Flat = beam_agent_content_core:normalize_messages(Msgs),
    ?assertEqual(Msgs, Flat).

normalize_messages_opencode_passthrough_test() ->
    %% Simulates OpenCode adapter output: already flat
    Msgs = [
        #{type => system, subtype => <<"connected">>},
        #{type => text, content => <<"Response text">>},
        #{type => thinking, content => <<"reasoning...">>},
        #{type => tool_use, tool_name => <<"edit">>, tool_input => #{}},
        #{type => tool_result, tool_name => <<"edit">>, content => <<"ok">>},
        #{type => result, content => <<>>}
    ],
    Flat = beam_agent_content_core:normalize_messages(Msgs),
    ?assertEqual(Msgs, Flat).

normalize_messages_copilot_passthrough_test() ->
    %% Simulates Copilot adapter output: already flat
    Msgs = [
        #{type => text, content => <<"Hello from Copilot">>},
        #{type => tool_use, tool_name => <<"read">>, tool_input => #{}},
        #{type => tool_result, tool_name => <<"read">>, content => <<"data">>},
        #{type => result}
    ],
    Flat = beam_agent_content_core:normalize_messages(Msgs),
    ?assertEqual(Msgs, Flat).

normalize_messages_empty_test() ->
    ?assertEqual([], beam_agent_content_core:normalize_messages([])).

normalize_messages_non_list_test() ->
    ?assertEqual([], beam_agent_content_core:normalize_messages(not_a_list)).

normalize_messages_mixed_assistant_and_flat_test() ->
    %% Edge case: if some messages are assistant (with blocks) and some flat
    Msgs = [
        #{type => text, content => <<"preamble">>},
        #{type => assistant,
          content_blocks => [
              #{type => text, text => <<"from assistant">>}
          ]},
        #{type => tool_use, tool_name => <<"bash">>, tool_input => #{}}
    ],
    Flat = beam_agent_content_core:normalize_messages(Msgs),
    ?assertEqual(3, length(Flat)),
    Types = [maps:get(type, M) || M <- Flat],
    ?assertEqual([text, text, tool_use], Types).

%%====================================================================
%% Round-trip preservation
%%====================================================================

roundtrip_block_to_message_to_block_text_test() ->
    Original = #{type => text, text => <<"hello">>},
    RoundTrip = beam_agent_content_core:message_to_block(
                    beam_agent_content_core:block_to_message(Original)),
    ?assertEqual(Original, RoundTrip).

roundtrip_block_to_message_to_block_thinking_test() ->
    Original = #{type => thinking, thinking => <<"hmm">>},
    RoundTrip = beam_agent_content_core:message_to_block(
                    beam_agent_content_core:block_to_message(Original)),
    ?assertEqual(Original, RoundTrip).

roundtrip_block_to_message_to_block_tool_use_test() ->
    Original = #{type => tool_use, id => <<"tu_1">>,
                 name => <<"bash">>, input => #{<<"cmd">> => <<"ls">>}},
    RoundTrip = beam_agent_content_core:message_to_block(
                    beam_agent_content_core:block_to_message(Original)),
    ?assertEqual(Original, RoundTrip).

roundtrip_block_to_message_to_block_tool_result_test() ->
    Original = #{type => tool_result, tool_use_id => <<"tu_1">>,
                 content => <<"output">>},
    RoundTrip = beam_agent_content_core:message_to_block(
                    beam_agent_content_core:block_to_message(Original)),
    ?assertEqual(Original, RoundTrip).

roundtrip_message_to_block_to_message_text_test() ->
    Original = #{type => text, content => <<"hello">>},
    RoundTrip = beam_agent_content_core:block_to_message(
                    beam_agent_content_core:message_to_block(Original)),
    ?assertEqual(Original, RoundTrip).

roundtrip_message_to_block_to_message_tool_use_test() ->
    Original = #{type => tool_use, tool_name => <<"bash">>,
                 tool_input => #{<<"cmd">> => <<"ls">>},
                 tool_use_id => <<"tu_1">>},
    RoundTrip = beam_agent_content_core:block_to_message(
                    beam_agent_content_core:message_to_block(Original)),
    ?assertEqual(Original, RoundTrip).

roundtrip_flatten_then_collect_test() ->
    %% Flatten an assistant message, then collect back into blocks
    Original = [
        #{type => thinking, thinking => <<"reason">>},
        #{type => text, text => <<"answer">>},
        #{type => tool_use, id => <<"tu_1">>,
          name => <<"bash">>, input => #{}}
    ],
    Assistant = #{type => assistant, content_blocks => Original},
    Flat = beam_agent_content_core:flatten_assistant(Assistant),
    Blocks = beam_agent_content_core:messages_to_blocks(Flat),
    ?assertEqual(Original, Blocks).
