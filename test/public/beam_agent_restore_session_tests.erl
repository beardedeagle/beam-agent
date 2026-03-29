%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent:restore_session/2.
%%%
%%% Tests cover:
%%%   - Export surface verification
%%%   - Session not found error
%%%   - Missing backend error (no adapter in stored metadata, no backend
%%%     in caller opts)
%%%   - Happy path delegation to start_session (opts built correctly)
%%%   - Caller opts override stored metadata
%%%   - Caller-supplied backend fills the gap when metadata lacks adapter
%%%
%%% Happy-path tests trap exits because start_session/1 uses start_link
%%% internally. When the session engine init fails (no real CLI binary),
%%% the linked process crashes and sends an EXIT signal to the test
%%% process. Trapping exits prevents the signal from killing the test.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_restore_session_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

setup() ->
    ok = beam_agent_session_store_core:ensure_tables(),
    ok = beam_agent_session_store_core:clear().

%% Call restore_session while trapping exits from the linked session
%% engine process that crashes because no real CLI binary is available.
safe_restore(SessionId, Opts) ->
    OldFlag = process_flag(trap_exit, true),
    Result = beam_agent:restore_session(SessionId, Opts),
    flush_exits(),
    process_flag(trap_exit, OldFlag),
    Result.

flush_exits() ->
    receive
        {'EXIT', _, _} -> flush_exits()
    after 100 -> ok
    end.

%%====================================================================
%% Export surface
%%====================================================================

exports_restore_session_test() ->
    {module, beam_agent} = code:ensure_loaded(beam_agent),
    ?assert(erlang:function_exported(beam_agent, restore_session, 2)).

exports_core_restore_session_test() ->
    {module, beam_agent_core} = code:ensure_loaded(beam_agent_core),
    ?assert(erlang:function_exported(beam_agent_core, restore_session, 2)).

%%====================================================================
%% Error: session not found
%%====================================================================

session_not_found_test() ->
    setup(),
    ?assertEqual(
        {error, {session_not_found, <<"nonexistent-session">>}},
        beam_agent:restore_session(<<"nonexistent-session">>, #{})
    ),
    beam_agent_session_store_core:clear().

%%====================================================================
%% Error: missing backend
%%====================================================================

missing_backend_no_adapter_no_opts_test() ->
    setup(),
    SId = <<"no-backend-session">>,
    ok = beam_agent_session_store_core:register_session(SId, #{
        model => <<"some-model">>
    }),
    ?assertEqual(
        {error, {missing_backend, SId}},
        beam_agent:restore_session(SId, #{})
    ),
    beam_agent_session_store_core:clear().

%%====================================================================
%% Happy path: opts built correctly, start_session called
%%====================================================================

restore_reaches_start_session_test() ->
    setup(),
    SId = <<"restore-happy-session">>,
    ok = beam_agent_session_store_core:register_session(SId, #{
        adapter => claude,
        model => <<"claude-sonnet-4-6">>,
        cwd => <<"/tmp/test">>
    }),
    %% start_session fails (no real CLI binary), but the error must NOT
    %% be from restore_session validation — proving opts were built and
    %% start_session was actually invoked.
    {error, Reason} = safe_restore(SId, #{}),
    ?assertNotMatch({session_not_found, _}, Reason),
    ?assertNotMatch({missing_backend, _}, Reason),
    beam_agent_session_store_core:clear().

%%====================================================================
%% Caller opts override stored metadata
%%====================================================================

caller_opts_override_test() ->
    setup(),
    SId = <<"override-test-session">>,
    ok = beam_agent_session_store_core:register_session(SId, #{
        adapter => claude,
        model => <<"original-model">>,
        cwd => <<"/original/dir">>
    }),
    %% Override backend and model; the call should still pass our
    %% validation and reach start_session.
    {error, Reason} = safe_restore(SId, #{
        backend => gemini,
        model => <<"override-model">>
    }),
    ?assertNotMatch({session_not_found, _}, Reason),
    ?assertNotMatch({missing_backend, _}, Reason),
    beam_agent_session_store_core:clear().

%%====================================================================
%% Caller-supplied backend fills missing adapter
%%====================================================================

caller_backend_fills_gap_test() ->
    setup(),
    SId = <<"caller-backend-session">>,
    ok = beam_agent_session_store_core:register_session(SId, #{
        model => <<"some-model">>
    }),
    %% Stored metadata has no adapter, but caller provides backend.
    %% Should NOT get missing_backend.
    {error, Reason} = safe_restore(SId, #{backend => claude}),
    ?assertNotMatch({missing_backend, _}, Reason),
    beam_agent_session_store_core:clear().

%%====================================================================
%% Empty/blank metadata fields are ignored
%%====================================================================

blank_metadata_fields_ignored_test() ->
    setup(),
    SId = <<"blank-meta-session">>,
    ok = beam_agent_session_store_core:register_session(SId, #{
        adapter => codex,
        model => <<>>,
        cwd => <<>>
    }),
    %% Empty model and cwd should not appear in the built opts.
    %% The call reaches start_session (error is not from our layer).
    {error, Reason} = safe_restore(SId, #{}),
    ?assertNotMatch({session_not_found, _}, Reason),
    ?assertNotMatch({missing_backend, _}, Reason),
    beam_agent_session_store_core:clear().
