%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for beam_agent_hooks_core.
%%%
%%% Tests hook constructor, registry composition, and dispatch
%%% properties for the SDK lifecycle hook system.
%%%
%%% Properties (200 test cases each):
%%%   1. hook/2 produces map with event and callback keys
%%%   2. register_hook adds hook under its event key
%%%   3. build_registry(undefined) and build_registry([]) return undefined
%%%   4. fire on undefined registry always returns ok
%%%   5. fire calls matching callbacks
%%%   6. fire with blocking event propagates {deny, Reason}
%%%   7. Matcher-based hooks only fire for matching tool names
%%% @end
%%%-------------------------------------------------------------------
-module(prop_beam_agent_hooks_core).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

hook_produces_valid_def_test() ->
    ?assert(proper:quickcheck(prop_hook_produces_valid_def(),
        [{numtests, 200}, {to_file, user}])).

register_hook_adds_to_event_test() ->
    ?assert(proper:quickcheck(prop_register_hook_adds_to_event(),
        [{numtests, 200}, {to_file, user}])).

build_registry_empty_inputs_test() ->
    ?assert(proper:quickcheck(prop_build_registry_empty_inputs(),
        [{numtests, 200}, {to_file, user}])).

fire_undefined_registry_ok_test() ->
    ?assert(proper:quickcheck(prop_fire_undefined_registry_ok(),
        [{numtests, 200}, {to_file, user}])).

fire_calls_matching_hooks_test() ->
    ?assert(proper:quickcheck(prop_fire_calls_matching_hooks(),
        [{numtests, 200}, {to_file, user}])).

fire_blocking_can_deny_test() ->
    ?assert(proper:quickcheck(prop_fire_blocking_can_deny(),
        [{numtests, 200}, {to_file, user}])).

matcher_filters_by_tool_name_test() ->
    ?assert(proper:quickcheck(prop_matcher_filters_by_tool_name(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: hook/2 always produces a map with event and callback keys
prop_hook_produces_valid_def() ->
    ?FORALL(Event, gen_hook_event(),
        begin
            Callback = fun(_Ctx) -> ok end,
            Def = beam_agent_hooks_core:hook(Event, Callback),
            is_map(Def) andalso
            maps:get(event, Def) =:= Event andalso
            is_function(maps:get(callback, Def), 1)
        end).

%% Property 2: register_hook places hook under the correct event key
prop_register_hook_adds_to_event() ->
    ?FORALL(Event, gen_hook_event(),
        begin
            Callback = fun(_Ctx) -> ok end,
            Hook = beam_agent_hooks_core:hook(Event, Callback),
            Registry = beam_agent_hooks_core:register_hook(
                Hook, beam_agent_hooks_core:new_registry()),
            Hooks = maps:get(Event, Registry, []),
            length(Hooks) =:= 1
        end).

%% Property 3: build_registry returns undefined for empty/undefined input
prop_build_registry_empty_inputs() ->
    ?FORALL(_, integer(),
        beam_agent_hooks_core:build_registry(undefined) =:= undefined andalso
        beam_agent_hooks_core:build_registry([]) =:= undefined).

%% Property 4: fire on undefined registry always returns ok
prop_fire_undefined_registry_ok() ->
    ?FORALL(Event, gen_hook_event(),
        ok =:= beam_agent_hooks_core:fire(Event, #{event => Event}, undefined)).

%% Property 5: fire invokes callbacks for matching events
prop_fire_calls_matching_hooks() ->
    ?FORALL(Event, gen_notification_event(),
        begin
            Self = self(),
            Ref = make_ref(),
            Callback = fun(_Ctx) -> Self ! {hook_fired, Ref}, ok end,
            Hook = beam_agent_hooks_core:hook(Event, Callback),
            Registry = beam_agent_hooks_core:build_registry([Hook]),
            ok = beam_agent_hooks_core:fire(Event, #{event => Event}, Registry),
            receive
                {hook_fired, Ref} -> true
            after 100 ->
                false
            end
        end).

%% Property 6: Blocking events propagate {deny, Reason} from callbacks
prop_fire_blocking_can_deny() ->
    ?FORALL(Reason, non_empty(binary()),
        begin
            Callback = fun(_Ctx) -> {deny, Reason} end,
            Hook = beam_agent_hooks_core:hook(pre_tool_use, Callback),
            Registry = beam_agent_hooks_core:build_registry([Hook]),
            {deny, Reason} =:= beam_agent_hooks_core:fire(
                pre_tool_use, #{event => pre_tool_use}, Registry)
        end).

%% Property 7: Hooks with tool_name matcher only fire for matching tools
prop_matcher_filters_by_tool_name() ->
    ?FORALL(ToolName, gen_tool_name(),
        begin
            Self = self(),
            Ref = make_ref(),
            Callback = fun(_Ctx) -> Self ! {hook_fired, Ref}, ok end,
            Hook = beam_agent_hooks_core:hook(post_tool_use, Callback,
                #{tool_name => <<"^Bash$">>}),
            Registry = beam_agent_hooks_core:build_registry([Hook]),
            ok = beam_agent_hooks_core:fire(
                post_tool_use,
                #{event => post_tool_use, tool_name => ToolName},
                Registry),
            Fired = receive
                {hook_fired, Ref} -> true
            after 1 ->
                false
            end,
            case ToolName of
                <<"Bash">> -> Fired =:= true;
                _ -> Fired =:= false
            end
        end).

%%====================================================================
%% Generators
%%====================================================================

gen_hook_event() ->
    oneof([
        pre_tool_use, post_tool_use, post_tool_use_failure,
        stop, session_start, session_end, user_prompt_submit,
        subagent_start, subagent_stop, pre_compact,
        notification, permission_request, config_change,
        task_completed, teammate_idle
    ]).

%% Non-blocking events only (for testing callback invocation without deny logic).
gen_notification_event() ->
    oneof([
        post_tool_use, post_tool_use_failure,
        stop, session_start, session_end,
        subagent_start, subagent_stop, pre_compact,
        notification, config_change,
        task_completed, teammate_idle
    ]).

gen_tool_name() ->
    oneof([
        <<"Bash">>, <<"Read">>, <<"Write">>, <<"Edit">>,
        <<"Glob">>, <<"Grep">>, non_empty(binary())
    ]).
