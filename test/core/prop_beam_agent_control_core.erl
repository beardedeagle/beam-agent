%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for beam_agent_control_core.
%%%
%%% Tests session configuration, permission mode, and thinking token
%%% invariants via the ETS-backed exported API.
%%%
%%% Properties (200 test cases each):
%%%   1. set_config → get_config round-trips any value
%%%   2. get_config returns not_set for unset keys
%%%   3. set_permission_mode → get_permission_mode round-trips
%%%   4. set_max_thinking_tokens → get_max_thinking_tokens round-trips
%%%   5. clear_config removes all keys for a session
%%%   6. get_all_config returns all set keys as a map
%%% @end
%%%-------------------------------------------------------------------
-module(prop_beam_agent_control_core).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

config_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_config_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

config_not_set_test() ->
    ?assert(proper:quickcheck(prop_config_not_set(),
        [{numtests, 200}, {to_file, user}])).

permission_mode_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_permission_mode_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

max_thinking_tokens_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_max_thinking_tokens_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

clear_config_removes_all_test() ->
    ?assert(proper:quickcheck(prop_clear_config_removes_all(),
        [{numtests, 200}, {to_file, user}])).

get_all_config_returns_map_test() ->
    ?assert(proper:quickcheck(prop_get_all_config_returns_map(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: set_config then get_config returns the stored value
prop_config_roundtrip() ->
    ?FORALL({SessionId, Key, Value},
        {gen_session_id(), gen_config_key(), gen_config_value()},
        begin
            fresh_tables(),
            ok = beam_agent_control_core:set_config(SessionId, Key, Value),
            {ok, Value} =:=
                beam_agent_control_core:get_config(SessionId, Key)
        end).

%% Property 2: get_config returns not_set for keys that were never written
prop_config_not_set() ->
    ?FORALL({SessionId, Key}, {gen_session_id(), gen_config_key()},
        begin
            fresh_tables(),
            {error, not_set} =:=
                beam_agent_control_core:get_config(SessionId, Key)
        end).

%% Property 3: set_permission_mode then get_permission_mode round-trips
prop_permission_mode_roundtrip() ->
    ?FORALL({SessionId, Mode},
        {gen_session_id(), gen_permission_mode()},
        begin
            fresh_tables(),
            ok = beam_agent_control_core:set_permission_mode(SessionId, Mode),
            {ok, Mode} =:=
                beam_agent_control_core:get_permission_mode(SessionId)
        end).

%% Property 4: set_max_thinking_tokens then get_max_thinking_tokens round-trips
prop_max_thinking_tokens_roundtrip() ->
    ?FORALL({SessionId, Tokens},
        {gen_session_id(), pos_integer()},
        begin
            fresh_tables(),
            ok = beam_agent_control_core:set_max_thinking_tokens(
                SessionId, Tokens),
            {ok, Tokens} =:=
                beam_agent_control_core:get_max_thinking_tokens(SessionId)
        end).

%% Property 5: clear_config removes all keys for the target session
prop_clear_config_removes_all() ->
    ?FORALL({SessionId, Keys},
        {gen_session_id(), non_empty(list(gen_config_key()))},
        begin
            fresh_tables(),
            lists:foreach(fun(Key) ->
                beam_agent_control_core:set_config(SessionId, Key, true)
            end, Keys),
            ok = beam_agent_control_core:clear_config(SessionId),
            lists:all(fun(Key) ->
                {error, not_set} =:=
                    beam_agent_control_core:get_config(SessionId, Key)
            end, Keys)
        end).

%% Property 6: get_all_config returns a map of all set keys
prop_get_all_config_returns_map() ->
    ?FORALL({SessionId, Key1, Val1, Key2, Val2},
        {gen_session_id(), gen_config_key(), gen_config_value(),
         gen_config_key(), gen_config_value()},
        ?IMPLIES(Key1 =/= Key2,
            begin
                fresh_tables(),
                ok = beam_agent_control_core:set_config(
                    SessionId, Key1, Val1),
                ok = beam_agent_control_core:set_config(
                    SessionId, Key2, Val2),
                {ok, Config} = beam_agent_control_core:get_all_config(
                    SessionId),
                maps:get(Key1, Config) =:= Val1 andalso
                maps:get(Key2, Config) =:= Val2
            end)).

%%====================================================================
%% Generators
%%====================================================================

gen_session_id() ->
    ?LET(Suffix, non_empty(binary()),
        <<"prop_ctrl_", Suffix/binary>>).

gen_config_key() ->
    oneof([model, permission_mode, max_thinking_tokens,
           system_prompt, cwd, timeout]).

gen_config_value() ->
    oneof([
        non_empty(binary()),
        pos_integer(),
        return(true),
        return(false)
    ]).

gen_permission_mode() ->
    oneof([
        <<"default">>, <<"acceptEdits">>, <<"bypassPermissions">>,
        <<"plan">>, <<"dontAsk">>, non_empty(binary())
    ]).

%%====================================================================
%% Helpers
%%====================================================================

%% Reset ETS tables to clean state before each property evaluation.
fresh_tables() ->
    beam_agent_control_core:ensure_tables(),
    beam_agent_control_core:clear().
