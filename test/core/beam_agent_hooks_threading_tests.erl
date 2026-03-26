%%%-------------------------------------------------------------------
%%% @doc Context threading tests for beam_agent_hooks_core.
%%%
%%% Tests the core enhancement: hooks receive and return modified
%%% context, threaded through the chain like a fold/reduce.
%%%
%%% Covers:
%%%   - Blocking: context flows through hook chain
%%%   - Blocking: deny mid-chain preserves prior context
%%%   - Blocking: ask mid-chain propagates to caller
%%%   - Blocking: crash mid-chain denies and stops chain (fail-closed)
%%%   - Notification: context flows through hook chain
%%%   - Notification: deny/ask ignored, context passes through
%%%   - Handler integration: fire/3 returns final context
%%%   - Multi-hook composition: chained transformations
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_hooks_threading_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Blocking Context Threading
%%====================================================================

blocking_hooks_thread_context_test() ->
    %% Hook A modifies tool_input, Hook B sees the modified value
    HookA = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) ->
            Input = maps:get(tool_input, Ctx, #{}),
            {ok, Ctx#{tool_input => Input#{sanitized => true}}}
        end),
    Self = self(),
    Ref = make_ref(),
    HookB = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) ->
            Input = maps:get(tool_input, Ctx, #{}),
            Self ! {Ref, maps:get(sanitized, Input, false)},
            {ok, Ctx}
        end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"Bash">>,
            tool_input => #{<<"command">> => <<"ls">>}},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg),
    %% Hook B saw the sanitized flag from Hook A
    ?assertEqual(true, receive {Ref, V} -> V after 500 -> timeout end),
    %% Final context includes both the original key and the added flag
    FinalInput = maps:get(tool_input, FinalCtx),
    ?assertEqual(true, maps:get(sanitized, FinalInput)),
    ?assertEqual(<<"ls">>, maps:get(<<"command">>, FinalInput)).

blocking_deny_stops_chain_test() ->
    %% Hook A allows, Hook B denies — Hook C never fires
    Self = self(),
    Ref = make_ref(),
    HookA = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> {ok, Ctx#{step => a}} end),
    HookB = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {deny, <<"blocked by B">>} end),
    HookC = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> Self ! {Ref, fired_c}, {ok, Ctx} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB, HookC], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"X">>},
    Result = beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg),
    ?assertEqual({deny, <<"blocked by B">>}, Result),
    %% Hook C never fires
    receive {Ref, fired_c} -> ?assert(false)
    after 100 -> ok
    end.

blocking_ask_stops_chain_test() ->
    %% Hook A allows, Hook B asks — Hook C never fires
    Self = self(),
    Ref = make_ref(),
    HookA = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> {ok, Ctx#{step => a}} end),
    HookB = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> {ask, <<"should I proceed?">>} end),
    HookC = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> Self ! {Ref, fired_c}, {ok, Ctx} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB, HookC], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"X">>},
    Result = beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg),
    ?assertEqual({ask, <<"should I proceed?">>}, Result),
    %% Hook C never fires
    receive {Ref, fired_c} -> ?assert(false)
    after 100 -> ok
    end.

blocking_crash_denies_and_stops_chain_test() ->
    %% Hook A modifies context, Hook B crashes — chain stops with deny.
    %% Hook C never fires (fail-closed for blocking events).
    Self = self(),
    Ref = make_ref(),
    HookA = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> {ok, Ctx#{from_a => true}} end),
    HookB = beam_agent_hooks_core:hook(pre_tool_use,
        fun(_) -> error(intentional_crash) end),
    HookC = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) ->
            Self ! {Ref, fired_c},
            {ok, Ctx}
        end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB, HookC], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"X">>},
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    try
        Result = beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg),
        %% Blocking crash returns deny (fail-closed)
        ?assertEqual({deny, <<"hook crashed (fail-safe deny)">>}, Result),
        %% Hook C never fired — chain stopped by deny
        receive {Ref, fired_c} -> ?assert(false)
        after 100 -> ok
        end
    after
        logger:set_primary_config(level, OldLevel)
    end.

blocking_final_context_returned_to_caller_test() ->
    %% Three hooks each add a key — caller gets the accumulated result
    HookA = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> {ok, Ctx#{a => 1}} end),
    HookB = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> {ok, Ctx#{b => 2}} end),
    HookC = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> {ok, Ctx#{c => 3}} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB, HookC], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"T">>},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg),
    ?assertEqual(1, maps:get(a, FinalCtx)),
    ?assertEqual(2, maps:get(b, FinalCtx)),
    ?assertEqual(3, maps:get(c, FinalCtx)).

blocking_prompt_rewrite_test() ->
    %% Real use case: hook rewrites the prompt, handler uses rewritten value
    Hook = beam_agent_hooks_core:hook(user_prompt_submit,
        fun(Ctx) ->
            Prompt = maps:get(prompt, Ctx),
            {ok, Ctx#{prompt => <<"[System] ", Prompt/binary>>}}
        end),
    Reg = beam_agent_hooks_core:register_hook(
        Hook, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => user_prompt_submit, prompt => <<"hello">>},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(
        user_prompt_submit, Ctx, Reg),
    ?assertEqual(<<"[System] hello">>, maps:get(prompt, FinalCtx)).

%%====================================================================
%% Notification Context Threading
%%====================================================================

notification_hooks_thread_context_test() ->
    %% Notification hooks compose: Hook A adds metadata, Hook B sees it
    Self = self(),
    Ref = make_ref(),
    HookA = beam_agent_hooks_core:hook(post_tool_use,
        fun(Ctx) ->
            {ok, Ctx#{metadata => #{processed => true}}}
        end),
    HookB = beam_agent_hooks_core:hook(post_tool_use,
        fun(Ctx) ->
            Meta = maps:get(metadata, Ctx, #{}),
            Self ! {Ref, maps:get(processed, Meta, false)},
            {ok, Ctx}
        end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => post_tool_use, tool_name => <<"Read">>},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(post_tool_use, Ctx, Reg),
    ?assertEqual(true, receive {Ref, V} -> V after 500 -> timeout end),
    ?assertEqual(#{processed => true}, maps:get(metadata, FinalCtx)).

notification_ignores_deny_passes_context_test() ->
    %% Hook A modifies context, Hook B denies (ignored), Hook C fires
    %% with Hook A's context (not Hook B's deny)
    Self = self(),
    Ref = make_ref(),
    HookA = beam_agent_hooks_core:hook(post_tool_use,
        fun(Ctx) -> {ok, Ctx#{from_a => true}} end),
    HookB = beam_agent_hooks_core:hook(post_tool_use,
        fun(_) -> {deny, <<"ignored">>} end),
    HookC = beam_agent_hooks_core:hook(post_tool_use,
        fun(Ctx) ->
            Self ! {Ref, maps:get(from_a, Ctx, false)},
            {ok, Ctx#{from_c => true}}
        end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB, HookC], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => post_tool_use, tool_name => <<"X">>},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(post_tool_use, Ctx, Reg),
    %% Hook C saw Hook A's context (deny from B was ignored)
    ?assertEqual(true, receive {Ref, V} -> V after 500 -> timeout end),
    ?assertEqual(true, maps:get(from_a, FinalCtx)),
    ?assertEqual(true, maps:get(from_c, FinalCtx)).

notification_ignores_ask_passes_context_test() ->
    %% Same as deny test but with {ask, _}
    HookA = beam_agent_hooks_core:hook(session_start,
        fun(Ctx) -> {ok, Ctx#{from_a => true}} end),
    HookB = beam_agent_hooks_core:hook(session_start,
        fun(_) -> {ask, <<"ignored ask">>} end),
    HookC = beam_agent_hooks_core:hook(session_start,
        fun(Ctx) -> {ok, Ctx#{from_c => true}} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB, HookC], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => session_start},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(session_start, Ctx, Reg),
    ?assertEqual(true, maps:get(from_a, FinalCtx)),
    ?assertEqual(true, maps:get(from_c, FinalCtx)).

notification_crash_passes_context_through_test() ->
    %% Crash in notification hook preserves prior context
    HookA = beam_agent_hooks_core:hook(stop,
        fun(Ctx) -> {ok, Ctx#{from_a => true}} end),
    HookB = beam_agent_hooks_core:hook(stop,
        fun(_) -> error(boom) end),
    HookC = beam_agent_hooks_core:hook(stop,
        fun(Ctx) -> {ok, Ctx#{from_c => true}} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB, HookC], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => stop},
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    {ok, FinalCtx} = beam_agent_hooks_core:fire(stop, Ctx, Reg),
    logger:set_primary_config(level, OldLevel),
    ?assertEqual(true, maps:get(from_a, FinalCtx)),
    ?assertEqual(true, maps:get(from_c, FinalCtx)).

%%====================================================================
%% Fire Return Contract
%%====================================================================

fire_undefined_registry_returns_original_context_test() ->
    Ctx = #{event => pre_tool_use, tool_name => <<"X">>},
    ?assertEqual({ok, Ctx},
        beam_agent_hooks_core:fire(pre_tool_use, Ctx, undefined)).

fire_empty_registry_returns_original_context_test() ->
    Ctx = #{event => pre_tool_use, tool_name => <<"X">>},
    ?assertEqual({ok, Ctx},
        beam_agent_hooks_core:fire(pre_tool_use, Ctx,
            beam_agent_hooks_core:new_registry())).

fire_no_matching_hooks_returns_original_context_test() ->
    %% Hooks registered for a different event — context unchanged
    Hook = beam_agent_hooks_core:hook(stop, fun(Ctx) -> {ok, Ctx#{nope => true}} end),
    Reg = beam_agent_hooks_core:register_hook(
        Hook, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"X">>},
    ?assertEqual({ok, Ctx},
        beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg)).

%%====================================================================
%% Matcher + Threading Interaction
%%====================================================================

matcher_skipped_hook_preserves_context_test() ->
    %% Hook A fires (no matcher), Hook B skipped (matcher doesn't match),
    %% Hook C fires — C sees Hook A's context, not Hook B's
    HookA = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> {ok, Ctx#{from_a => true}} end),
    HookB = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> {ok, Ctx#{from_b => true}} end,
        #{tool_name => <<"Bash">>}),  %% only fires for Bash
    HookC = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) -> {ok, Ctx#{from_c => true}} end),
    Reg = beam_agent_hooks_core:register_hooks(
        [HookA, HookB, HookC], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"Read">>},  %% not Bash
    {ok, FinalCtx} = beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg),
    ?assertEqual(true, maps:get(from_a, FinalCtx)),
    ?assertNot(maps:is_key(from_b, FinalCtx)),  %% Hook B was skipped
    ?assertEqual(true, maps:get(from_c, FinalCtx)).

%%====================================================================
%% Composing Hooks (the whole point)
%%====================================================================

sanitize_then_audit_composition_test() ->
    %% Real use case: Hook A sanitizes input, Hook B audits the sanitized value
    Self = self(),
    Ref = make_ref(),
    Sanitize = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) ->
            Input = maps:get(tool_input, Ctx, #{}),
            %% Remove dangerous keys
            Safe = maps:without([<<"dangerous">>], Input),
            {ok, Ctx#{tool_input => Safe}}
        end),
    Audit = beam_agent_hooks_core:hook(pre_tool_use,
        fun(Ctx) ->
            Input = maps:get(tool_input, Ctx, #{}),
            Self ! {Ref, Input},
            {ok, Ctx}
        end),
    Reg = beam_agent_hooks_core:register_hooks(
        [Sanitize, Audit], beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"Bash">>,
            tool_input => #{<<"command">> => <<"ls">>,
                            <<"dangerous">> => <<"rm -rf /">>}},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(pre_tool_use, Ctx, Reg),
    %% Audit hook saw the sanitized input (no <<"dangerous">> key)
    AuditedInput = receive {Ref, I} -> I after 500 -> timeout end,
    ?assertNot(maps:is_key(<<"dangerous">>, AuditedInput)),
    ?assertEqual(<<"ls">>, maps:get(<<"command">>, AuditedInput)),
    %% Final context also has the sanitized input
    ?assertNot(maps:is_key(<<"dangerous">>, maps:get(tool_input, FinalCtx))).
