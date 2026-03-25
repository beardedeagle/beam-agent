%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_hooks_core.
%%%
%%% Covers:
%%%   - Constructors (hook/2, hook/3)
%%%   - Registry (new_registry, register_hook, register_hooks)
%%%   - Dispatch — notification-only events (ignore deny/ask)
%%%   - Dispatch — blocking events (first deny/ask wins, context threading)
%%%   - Matchers (exact, regex, no matcher)
%%%   - Crash protection (callback crash/throw)
%%%   - New blocking events (subagent_start, pre_compact, config_change)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_hooks_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Constructor Tests
%%====================================================================

hook_2_creates_valid_def_test() ->
    Cb = fun(Ctx) -> {ok, Ctx} end,
    H = beam_agent_hooks_core:hook(pre_tool_use, Cb),
    ?assertEqual(pre_tool_use, maps:get(event, H)),
    ?assertEqual(Cb, maps:get(callback, H)),
    ?assertNot(maps:is_key(matcher, H)).

hook_3_creates_def_with_matcher_test() ->
    Cb = fun(Ctx) -> {ok, Ctx} end,
    Matcher = #{tool_name => <<"Bash">>},
    H = beam_agent_hooks_core:hook(pre_tool_use, Cb, Matcher),
    ?assertEqual(pre_tool_use, maps:get(event, H)),
    ?assertEqual(Cb, maps:get(callback, H)),
    ?assertEqual(Matcher, maps:get(matcher, H)).

all_supported_hook_event_types_accepted_test_() ->
    Events = [pre_tool_use,
              post_tool_use,
              post_tool_use_failure,
              stop,
              session_start,
              session_end,
              user_prompt_submit,
              subagent_start,
              subagent_stop,
              pre_compact,
              notification,
              permission_request,
              config_change,
              task_completed,
              teammate_idle],
    [{"event " ++ atom_to_list(E),
      fun() ->
          H = beam_agent_hooks_core:hook(E, fun(Ctx) -> {ok, Ctx} end),
          ?assertEqual(E, maps:get(event, H))
      end} || E <- Events].

%%====================================================================
%% Registry Tests
%%====================================================================

new_registry_returns_empty_map_test() ->
    ?assertEqual(#{}, beam_agent_hooks_core:new_registry()).

register_hook_adds_under_event_test() ->
    H = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) -> {ok, Ctx} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    ?assertEqual([H], maps:get(pre_tool_use, Reg)).

register_hooks_registers_multiple_test() ->
    H1 = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) -> {ok, Ctx} end),
    H2 = beam_agent_hooks_core:hook(stop, fun(Ctx) -> {ok, Ctx} end),
    H3 = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) -> {ok, Ctx} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [H1, H2, H3], beam_agent_hooks_core:new_registry()),
    ?assertEqual(2, length(maps:get(pre_tool_use, Reg))),
    ?assertEqual(1, length(maps:get(stop, Reg))).

multiple_hooks_per_event_preserved_in_order_test() ->
    %% Verify hooks fire in registration order.
    %% Registry stores reversed (prepend = O(1)); fire/3 reverses.
    Self = self(),
    Cb1 = fun(Ctx) -> Self ! {fired, 1}, {ok, Ctx} end,
    Cb2 = fun(Ctx) -> Self ! {fired, 2}, {ok, Ctx} end,
    H1 = beam_agent_hooks_core:hook(stop, Cb1),
    H2 = beam_agent_hooks_core:hook(stop, Cb2),
    Reg = beam_agent_hooks_core:register_hooks(
        [H1, H2], beam_agent_hooks_core:new_registry()),
    ?assertEqual(2, length(maps:get(stop, Reg))),
    %% Fire and verify execution order matches registration order
    {ok, _} = beam_agent_hooks_core:fire(stop, #{event => stop}, Reg),
    ?assertEqual({fired, 1}, receive M1 -> M1 after 100 -> timeout end),
    ?assertEqual({fired, 2}, receive M2 -> M2 after 100 -> timeout end).

%%====================================================================
%% Dispatch — Notification-only Events
%%====================================================================

fire_empty_registry_returns_ok_ctx_test() ->
    Ctx = #{event => stop},
    ?assertEqual({ok, Ctx}, beam_agent_hooks_core:fire(
        stop, Ctx, beam_agent_hooks_core:new_registry())).

fire_undefined_registry_returns_ok_ctx_test() ->
    Ctx = #{event => stop},
    ?assertEqual({ok, Ctx}, beam_agent_hooks_core:fire(
        stop, Ctx, undefined)).

fire_calls_callback_with_context_test() ->
    Self = self(),
    Ref = make_ref(),
    Cb = fun(Ctx) -> Self ! {Ref, Ctx}, {ok, Ctx} end,
    H = beam_agent_hooks_core:hook(stop, Cb),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => stop, session_id => <<"sess-1">>},
    ?assertMatch({ok, _}, beam_agent_hooks_core:fire(stop, Ctx, Reg)),
    receive
        {Ref, ReceivedCtx} ->
            ?assertEqual(<<"sess-1">>, maps:get(session_id, ReceivedCtx))
    after 1000 ->
        ?assert(false)
    end.

fire_post_tool_use_ignores_deny_test() ->
    H = beam_agent_hooks_core:hook(post_tool_use,
        fun(_) -> {deny, <<"nope">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => post_tool_use},
    ?assertMatch({ok, _}, beam_agent_hooks_core:fire(
        post_tool_use, Ctx, Reg)).

fire_post_tool_use_ignores_ask_test() ->
    H = beam_agent_hooks_core:hook(post_tool_use,
        fun(_) -> {ask, <<"maybe">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => post_tool_use},
    ?assertMatch({ok, _}, beam_agent_hooks_core:fire(
        post_tool_use, Ctx, Reg)).

fire_stop_ignores_deny_test() ->
    H = beam_agent_hooks_core:hook(stop,
        fun(_) -> {deny, <<"nope">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => stop},
    ?assertMatch({ok, _}, beam_agent_hooks_core:fire(stop, Ctx, Reg)).

fire_session_start_ignores_deny_test() ->
    H = beam_agent_hooks_core:hook(session_start,
        fun(_) -> {deny, <<"nope">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => session_start},
    ?assertMatch({ok, _}, beam_agent_hooks_core:fire(
        session_start, Ctx, Reg)).

fire_session_end_ignores_deny_test() ->
    H = beam_agent_hooks_core:hook(session_end,
        fun(_) -> {deny, <<"nope">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => session_end},
    ?assertMatch({ok, _}, beam_agent_hooks_core:fire(
        session_end, Ctx, Reg)).

%%====================================================================
%% Dispatch — Blocking Events
%%====================================================================

fire_pre_tool_use_returns_deny_test() ->
    H = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {deny, <<"blocked">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    ?assertEqual({deny, <<"blocked">>},
        beam_agent_hooks_core:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"Bash">>}, Reg)).

fire_user_prompt_submit_returns_deny_test() ->
    H = beam_agent_hooks_core:hook(user_prompt_submit,
        fun(_) -> {deny, <<"no prompts">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    ?assertEqual({deny, <<"no prompts">>},
        beam_agent_hooks_core:fire(user_prompt_submit,
            #{event => user_prompt_submit, prompt => <<"hi">>}, Reg)).

fire_first_deny_wins_test() ->
    H1 = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {deny, <<"first">>} end),
    H2 = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {deny, <<"second">>} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [H1, H2], beam_agent_hooks_core:new_registry()),
    ?assertEqual({deny, <<"first">>},
        beam_agent_hooks_core:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"X">>}, Reg)).

fire_all_ok_returns_ok_ctx_test() ->
    H1 = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) -> {ok, Ctx} end),
    H2 = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) -> {ok, Ctx} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [H1, H2], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"X">>},
    ?assertMatch({ok, _},
        beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg)).

fire_ok_then_deny_returns_deny_test() ->
    H1 = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) -> {ok, Ctx} end),
    H2 = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {deny, <<"blocked">>} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [H1, H2], beam_agent_hooks_core:new_registry()),
    ?assertEqual({deny, <<"blocked">>},
        beam_agent_hooks_core:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"X">>}, Reg)).

%%====================================================================
%% Ask Return Tests
%%====================================================================

fire_pre_tool_use_returns_ask_test() ->
    H = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {ask, <<"should I allow this?">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    ?assertEqual({ask, <<"should I allow this?">>},
        beam_agent_hooks_core:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"Bash">>}, Reg)).

fire_first_ask_wins_test() ->
    H1 = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {ask, <<"first ask">>} end),
    H2 = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {deny, <<"never reached">>} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [H1, H2], beam_agent_hooks_core:new_registry()),
    ?assertEqual({ask, <<"first ask">>},
        beam_agent_hooks_core:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"X">>}, Reg)).

fire_ok_then_ask_returns_ask_test() ->
    H1 = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) -> {ok, Ctx} end),
    H2 = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {ask, <<"escalate">>} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [H1, H2], beam_agent_hooks_core:new_registry()),
    ?assertEqual({ask, <<"escalate">>},
        beam_agent_hooks_core:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"X">>}, Reg)).

%%====================================================================
%% New Blocking Event Tests
%%====================================================================

fire_subagent_start_blocks_test() ->
    H = beam_agent_hooks_core:hook(subagent_start,
        fun(_) -> {deny, <<"no sub-agents">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    ?assertEqual({deny, <<"no sub-agents">>},
        beam_agent_hooks_core:fire(subagent_start,
            #{event => subagent_start, agent_id => <<"a1">>}, Reg)).

fire_pre_compact_blocks_test() ->
    H = beam_agent_hooks_core:hook(pre_compact,
        fun(_) -> {deny, <<"prevent compaction">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    ?assertEqual({deny, <<"prevent compaction">>},
        beam_agent_hooks_core:fire(pre_compact,
            #{event => pre_compact, session_id => <<"s1">>}, Reg)).

fire_config_change_blocks_test() ->
    H = beam_agent_hooks_core:hook(config_change,
        fun(_) -> {deny, <<"reject config">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    ?assertEqual({deny, <<"reject config">>},
        beam_agent_hooks_core:fire(config_change,
            #{event => config_change}, Reg)).

fire_subagent_start_allows_test() ->
    H = beam_agent_hooks_core:hook(subagent_start, fun(Ctx) -> {ok, Ctx} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => subagent_start, agent_id => <<"a1">>},
    ?assertMatch({ok, _},
        beam_agent_hooks_core:fire(subagent_start, Ctx, Reg)).

fire_subagent_stop_is_notification_test() ->
    %% subagent_stop is NOT blocking — deny should be ignored
    H = beam_agent_hooks_core:hook(subagent_stop,
        fun(_) -> {deny, <<"ignored">>} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => subagent_stop},
    ?assertMatch({ok, _},
        beam_agent_hooks_core:fire(subagent_stop, Ctx, Reg)).

%%====================================================================
%% Matcher Tests
%%====================================================================

matcher_exact_match_fires_test() ->
    Self = self(),
    Ref = make_ref(),
    H = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> Self ! {Ref, fired}, {ok, Ctx} end,
        #{tool_name => <<"Bash">>}),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    beam_agent_hooks_core:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"Bash">>}, Reg),
    receive {Ref, fired} -> ok
    after 500 -> ?assert(false)
    end.

matcher_exact_match_skips_nonmatching_test() ->
    Self = self(),
    Ref = make_ref(),
    H = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> Self ! {Ref, fired}, {ok, Ctx} end,
        #{tool_name => <<"Bash">>}),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    beam_agent_hooks_core:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"Read">>}, Reg),
    receive {Ref, fired} -> ?assert(false)
    after 100 -> ok
    end.

matcher_regex_pattern_matches_test() ->
    Self = self(),
    Ref = make_ref(),
    H = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> Self ! {Ref, fired}, {ok, Ctx} end,
        #{tool_name => <<"^Read.*">>}),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    beam_agent_hooks_core:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"ReadFile">>}, Reg),
    receive {Ref, fired} -> ok
    after 500 -> ?assert(false)
    end.

matcher_regex_pattern_skips_nonmatching_test() ->
    Self = self(),
    Ref = make_ref(),
    H = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> Self ! {Ref, fired}, {ok, Ctx} end,
        #{tool_name => <<"^Read.*">>}),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    beam_agent_hooks_core:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"Write">>}, Reg),
    receive {Ref, fired} -> ?assert(false)
    after 100 -> ok
    end.

no_matcher_fires_on_all_tools_test() ->
    Self = self(),
    Ref = make_ref(),
    H = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> Self ! {Ref, fired}, {ok, Ctx} end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    beam_agent_hooks_core:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"AnyTool">>}, Reg),
    receive {Ref, fired} -> ok
    after 500 -> ?assert(false)
    end.

%%====================================================================
%% Crash Protection Tests
%%====================================================================

callback_crash_is_caught_test() ->
    H1 = beam_agent_hooks_core:hook(stop, fun(_) -> error(boom) end),
    Self = self(),
    Ref = make_ref(),
    H2 = beam_agent_hooks_core:hook(stop,
        fun(Ctx) -> Self ! {Ref, survived}, {ok, Ctx} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [H1, H2], beam_agent_hooks_core:new_registry()),
    %% Suppress expected warning from safe_call crash handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    ?assertMatch({ok, _}, beam_agent_hooks_core:fire(
        stop, #{event => stop}, Reg)),
    logger:set_primary_config(level, OldLevel),
    receive {Ref, survived} -> ok
    after 500 -> ?assert(false)
    end.

callback_throw_is_caught_test() ->
    H = beam_agent_hooks_core:hook(stop, fun(_) -> throw(oops) end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    %% Suppress expected warning from safe_call crash handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    ?assertMatch({ok, _}, beam_agent_hooks_core:fire(
        stop, #{event => stop}, Reg)),
    logger:set_primary_config(level, OldLevel).

blocking_callback_crash_returns_ok_ctx_test() ->
    %% A crashing callback in a blocking event should NOT deny —
    %% it returns {ok, Context} and continues to next hook.
    H1 = beam_agent_hooks_core:hook(pre_tool_use, fun(_) -> error(crash) end),
    H2 = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) -> {ok, Ctx} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [H1, H2], beam_agent_hooks_core:new_registry()),
    %% Suppress expected warning from safe_call crash handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    ?assertMatch({ok, _}, beam_agent_hooks_core:fire(
        pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"X">>}, Reg)),
    logger:set_primary_config(level, OldLevel).

unexpected_return_treated_as_ok_test() ->
    %% A callback returning something unexpected (not {ok,_}, {deny,_}, {ask,_})
    %% is treated as {ok, Context} — context passes through unmodified.
    H = beam_agent_hooks_core:hook(pre_tool_use, fun(_) -> wat end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"X">>},
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    ?assertEqual({ok, Ctx},
        beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg)),
    logger:set_primary_config(level, OldLevel).
