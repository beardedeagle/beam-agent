%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for beam_agent_session_store_core.
%%%
%%% Tests session registration, retrieval, filtering, and metadata
%%% invariants via the ETS-backed exported API.
%%%
%%% Properties (200 test cases each):
%%%   1. register_session → get_session round-trips metadata
%%%   2. session_count matches the number of registered sessions
%%%   3. update_session merges fields into existing session
%%%   4. list_sessions with adapter filter returns only matching
%%%   5. list_sessions with limit respects the cap
%%%   6. get_session returns not_found for unregistered IDs
%%% @end
%%%-------------------------------------------------------------------
-module(prop_beam_agent_session_store_core).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

register_then_get_test() ->
    ?assert(proper:quickcheck(prop_register_then_get(),
        [{numtests, 200}, {to_file, user}])).

session_count_matches_test() ->
    ?assert(proper:quickcheck(prop_session_count_matches(),
        [{numtests, 200}, {to_file, user}])).

update_merges_fields_test() ->
    ?assert(proper:quickcheck(prop_update_merges_fields(),
        [{numtests, 200}, {to_file, user}])).

list_sessions_adapter_filter_test() ->
    ?assert(proper:quickcheck(prop_list_sessions_adapter_filter(),
        [{numtests, 200}, {to_file, user}])).

list_sessions_limit_test() ->
    ?assert(proper:quickcheck(prop_list_sessions_limit(),
        [{numtests, 200}, {to_file, user}])).

get_session_not_found_test() ->
    ?assert(proper:quickcheck(prop_get_session_not_found(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: register_session then get_session returns the stored metadata
prop_register_then_get() ->
    ?FORALL({SessionId, Adapter, Model},
        {gen_session_id(), gen_adapter(), gen_model()},
        begin
            fresh_tables(),
            ok = beam_agent_session_store_core:register_session(
                SessionId, #{adapter => Adapter, model => Model}),
            {ok, Meta} = beam_agent_session_store_core:get_session(SessionId),
            maps:get(session_id, Meta) =:= SessionId andalso
            maps:get(adapter, Meta) =:= Adapter andalso
            maps:get(model, Meta) =:= Model andalso
            maps:get(message_count, Meta) =:= 0
        end).

%% Property 2: session_count equals number of registered sessions
prop_session_count_matches() ->
    ?FORALL(Count, integer(1, 10),
        begin
            fresh_tables(),
            Ids = [gen_unique_id(I) || I <- lists:seq(1, Count)],
            lists:foreach(fun(Id) ->
                beam_agent_session_store_core:register_session(Id, #{})
            end, Ids),
            beam_agent_session_store_core:session_count() =:= Count
        end).

%% Property 3: update_session merges new fields into existing session
prop_update_merges_fields() ->
    ?FORALL({SessionId, Model1, Model2},
        {gen_session_id(), gen_model(), gen_model()},
        begin
            fresh_tables(),
            ok = beam_agent_session_store_core:register_session(
                SessionId, #{model => Model1}),
            ok = beam_agent_session_store_core:update_session(
                SessionId, #{model => Model2}),
            {ok, Meta} = beam_agent_session_store_core:get_session(SessionId),
            maps:get(model, Meta) =:= Model2
        end).

%% Property 4: list_sessions with adapter filter returns only matching sessions
prop_list_sessions_adapter_filter() ->
    ?FORALL({Id1, Id2, Adapter1, Adapter2},
        {gen_session_id(), gen_session_id(), gen_adapter(), gen_adapter()},
        ?IMPLIES(Id1 =/= Id2 andalso Adapter1 =/= Adapter2,
            begin
                fresh_tables(),
                ok = beam_agent_session_store_core:register_session(
                    Id1, #{adapter => Adapter1}),
                ok = beam_agent_session_store_core:register_session(
                    Id2, #{adapter => Adapter2}),
                {ok, Filtered} = beam_agent_session_store_core:list_sessions(
                    #{adapter => Adapter1}),
                length(Filtered) =:= 1 andalso
                maps:get(session_id, hd(Filtered)) =:= Id1
            end)).

%% Property 5: list_sessions with limit returns at most N sessions
prop_list_sessions_limit() ->
    ?FORALL({Count, Limit},
        {integer(3, 8), integer(1, 5)},
        begin
            fresh_tables(),
            lists:foreach(fun(I) ->
                beam_agent_session_store_core:register_session(
                    gen_unique_id(I), #{})
            end, lists:seq(1, Count)),
            {ok, Results} = beam_agent_session_store_core:list_sessions(
                #{limit => Limit}),
            length(Results) =:= min(Count, Limit)
        end).

%% Property 6: get_session returns not_found for never-registered IDs
prop_get_session_not_found() ->
    ?FORALL(SessionId, gen_session_id(),
        begin
            fresh_tables(),
            {error, not_found} =:=
                beam_agent_session_store_core:get_session(SessionId)
        end).

%%====================================================================
%% Generators
%%====================================================================

gen_session_id() ->
    ?LET(Suffix, non_empty(binary()),
        <<"prop_sess_", Suffix/binary>>).

gen_adapter() ->
    oneof([claude, codex, gemini, opencode, copilot]).

gen_model() ->
    oneof([<<"claude-sonnet-4-6">>, <<"gpt-4o">>,
           <<"gemini-2.5-pro">>, <<"codex-1">>,
           non_empty(binary())]).

%%====================================================================
%% Helpers
%%====================================================================

%% Reset ETS tables to clean state before each property evaluation.
fresh_tables() ->
    beam_agent_session_store_core:ensure_tables(),
    beam_agent_session_store_core:clear().

%% Generate a deterministic unique ID for bulk registration.
-spec gen_unique_id(pos_integer()) -> binary().
gen_unique_id(I) ->
    <<"prop_sess_", (integer_to_binary(I))/binary>>.
