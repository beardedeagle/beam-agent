%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for beam_agent_core message normalization.
%%%
%%% Fuzz-tests the wire protocol parser with random inputs to verify
%%% robustness. Uses PropEr generators for message maps, stop reasons,
%%% and permission modes.
%%%
%%% Properties (200 test cases each):
%%%   1. normalize_message/1 never crashes on any map with type field
%%%   2. Common fields (uuid, session_id) preserved when present
%%%   3. parse_stop_reason/1 always returns a valid atom
%%%   4. parse_permission_mode/1 always returns a valid atom
%%%   5. Result messages with "result" field always populate content
%%%   6. Assistant messages always have content_blocks list
%%%   7. Maps without "type" key produce raw messages
%%% @end
%%%-------------------------------------------------------------------
-module(prop_beam_agent_core).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration — run PropEr properties via eunit
%%====================================================================

normalize_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_normalize_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

common_fields_preserved_test() ->
    ?assert(proper:quickcheck(prop_common_fields_preserved(),
        [{numtests, 200}, {to_file, user}])).

parse_stop_reason_valid_test() ->
    ?assert(proper:quickcheck(prop_parse_stop_reason_valid(),
        [{numtests, 200}, {to_file, user}])).

parse_permission_mode_valid_test() ->
    ?assert(proper:quickcheck(prop_parse_permission_mode_valid(),
        [{numtests, 200}, {to_file, user}])).

result_content_populated_test() ->
    ?assert(proper:quickcheck(prop_result_content_populated(),
        [{numtests, 200}, {to_file, user}])).

assistant_has_content_blocks_test() ->
    ?assert(proper:quickcheck(prop_assistant_has_content_blocks(),
        [{numtests, 200}, {to_file, user}])).

no_type_produces_raw_test() ->
    ?assert(proper:quickcheck(prop_no_type_produces_raw(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: normalize_message/1 never crashes on any map with type
prop_normalize_never_crashes() ->
    ?FORALL(RawMsg, gen_raw_message(),
        begin
            Msg = beam_agent_core:normalize_message(RawMsg),
            is_map(Msg) andalso maps:is_key(type, Msg)
        end).

%% Property 2: uuid and session_id are preserved when present
prop_common_fields_preserved() ->
    ?FORALL({RawMsg, Uuid, SessionId},
        {gen_raw_message(), binary(), binary()},
        begin
            Enriched = RawMsg#{<<"uuid">> => Uuid,
                               <<"session_id">> => SessionId},
            Msg = beam_agent_core:normalize_message(Enriched),
            maps:get(uuid, Msg) =:= Uuid andalso
            maps:get(session_id, Msg) =:= SessionId
        end).

%% Property 3: parse_stop_reason/1 always returns a valid stop_reason()
prop_parse_stop_reason_valid() ->
    ValidAtoms = [end_turn, max_tokens, stop_sequence,
                  refusal, tool_use_stop, unknown_stop],
    ?FORALL(Input, gen_stop_reason_bin(),
        lists:member(beam_agent_core:parse_stop_reason(Input), ValidAtoms)).

%% Property 4: parse_permission_mode/1 always returns a valid atom
prop_parse_permission_mode_valid() ->
    ValidAtoms = [default, accept_edits, bypass_permissions,
                  plan, dont_ask],
    ?FORALL(Input, gen_permission_mode_bin(),
        lists:member(beam_agent_core:parse_permission_mode(Input), ValidAtoms)).

%% Property 5: Result messages with "result" field populate content
prop_result_content_populated() ->
    ?FORALL(RawMsg, gen_result_message(),
        begin
            Msg = beam_agent_core:normalize_message(RawMsg),
            maps:get(type, Msg) =:= result andalso
            maps:is_key(content, Msg)
        end).

%% Property 6: Assistant messages always have content_blocks list
prop_assistant_has_content_blocks() ->
    ?FORALL(RawMsg, gen_assistant_message(),
        begin
            Msg = beam_agent_core:normalize_message(RawMsg),
            maps:get(type, Msg) =:= assistant andalso
            is_list(maps:get(content_blocks, Msg))
        end).

%% Property 7: Maps without "type" key produce raw messages
prop_no_type_produces_raw() ->
    ?FORALL(RawMsg, map(binary(), binary()),
        begin
            NoType = maps:remove(<<"type">>, RawMsg),
            Msg = beam_agent_core:normalize_message(NoType),
            maps:get(type, Msg) =:= raw
        end).

%%====================================================================
%% Generators
%%====================================================================

%% Generate a raw message map with a random type field.
gen_raw_message() ->
    ?LET(Type, oneof([
        <<"text">>, <<"assistant">>, <<"tool_use">>, <<"tool_result">>,
        <<"system">>, <<"result">>, <<"error">>, <<"user">>,
        <<"control">>, <<"control_request">>, <<"control_response">>,
        <<"stream_event">>, <<"thinking">>, <<"rate_limit_event">>,
        <<"tool_progress">>, <<"tool_use_summary">>,
        <<"prompt_suggestion">>, <<"auth_status">>,
        <<"unknown_type">>, binary()
    ]),
    ?LET(Extra, map(binary(), binary()),
        Extra#{<<"type">> => Type})).

%% Generate a result message with a "result" field.
gen_result_message() ->
    ?LET(ResultText, binary(),
        #{<<"type">> => <<"result">>,
          <<"result">> => ResultText}).

%% Generate an assistant message with optional content.
gen_assistant_message() ->
    ?LET(Blocks, list(gen_content_block_raw()),
        #{<<"type">> => <<"assistant">>,
          <<"content">> => Blocks}).

%% Generate a raw content block for assistant messages.
gen_content_block_raw() ->
    oneof([
        #{<<"type">> => <<"text">>, <<"text">> => binary()},
        #{<<"type">> => <<"thinking">>, <<"thinking">> => binary()},
        #{<<"type">> => <<"tool_use">>, <<"id">> => binary(),
          <<"name">> => binary(), <<"input">> => #{}},
        #{<<"data">> => binary()}  %% unknown block
    ]).

%% Generate stop reason inputs (both known and random binaries).
gen_stop_reason_bin() ->
    oneof([
        <<"end_turn">>, <<"max_tokens">>, <<"stop_sequence">>,
        <<"refusal">>, <<"tool_use">>,
        binary(),  %% random binary -> unknown_stop
        return(undefined),
        integer()
    ]).

%% Generate permission mode inputs (both known and random).
gen_permission_mode_bin() ->
    oneof([
        <<"default">>, <<"acceptEdits">>, <<"bypassPermissions">>,
        <<"plan">>, <<"dontAsk">>,
        binary(),  %% random binary -> default
        return(undefined)
    ]).
