%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the canonical beam_agent facade.
%%%-------------------------------------------------------------------
-module(beam_agent_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_credential_key_test() ->
    _ = beam_agent_test_setup:ensure_test_key().

list_backends_test() ->
    ?assertEqual([claude, codex, copilot, gemini, opencode],
        beam_agent:list_backends()).

command_run_smoke_test() ->
    {ok, Result} = beam_agent_command:run(
        beam_agent_command_test_helpers:echo_segments(<<"beam-agent-smoke">>)),
    ?assertEqual(0, maps:get(exit_code, Result)),
    ?assertEqual(<<"beam-agent-smoke">>,
        beam_agent_command_test_helpers:trim_output(maps:get(output, Result))).

runtime_provider_roundtrip_smoke_test() ->
    Session = list_to_binary(io_lib:format("smoke-runtime-~p",
                                           [erlang:unique_integer([positive])])),
    ?assertEqual({error, not_set}, beam_agent_runtime:current_provider(Session)),
    ok = beam_agent_runtime:set_provider(Session, <<"openai">>),
    ?assertEqual({ok, <<"openai">>}, beam_agent_runtime:current_provider(Session)),
    ok = beam_agent_runtime:clear_provider(Session),
    ?assertEqual({error, not_set}, beam_agent_runtime:current_provider(Session)).

provider_state_roundtrip_supports_binary_session_ids_test() ->
    Session = list_to_binary(io_lib:format("smoke-provider-~p",
                                           [erlang:unique_integer([positive])])),
    ?assertEqual({error, not_set}, beam_agent_provider:current(Session)),
    ok = beam_agent_provider:set(Session, <<"openai">>),
    ?assertEqual({ok, <<"openai">>}, beam_agent_provider:current(Session)),
    {ok, Providers} = beam_agent_provider:list(Session),
    ?assert(lists:any(fun
        (#{id := <<"openai">>}) -> true;
        (_) -> false
    end, Providers)),
    ok = beam_agent_provider:clear(Session),
    ?assertEqual({error, not_set}, beam_agent_provider:current(Session)).

prompt_async_requires_live_session_test() ->
    Session = list_to_binary(io_lib:format("smoke-prompt-~p",
                                           [erlang:unique_integer([positive])])),
    ?assertEqual({error, requires_live_session},
        beam_agent_command:prompt_async(Session, <<"hello">>)).

capabilities_projection_test() ->
    {ok, Caps} = beam_agent_capabilities:capabilities(codex),
    [SessionHistory] = [Cap || #{id := session_history} = Cap <- Caps],
    ?assertMatch(#{id := session_history, support_level := full}, SessionHistory).

supports_test() ->
    ?assertEqual({ok, true}, beam_agent_capabilities:supports(session_lifecycle, claude)),
    ?assertEqual({ok, true}, beam_agent_capabilities:supports(user_input_callbacks, gemini)),
    ?assertEqual({ok, true}, beam_agent_capabilities:supports(event_streaming, opencode)),
    ?assertEqual({ok, true}, beam_agent_capabilities:supports(event_streaming, codex)).

exports_fuzzy_file_search_session_lifecycle_test() ->
    ensure_loaded(beam_agent_catalog),
    ?assert(erlang:function_exported(beam_agent_catalog,
                                     search_session_start,
                                     3)),
    ?assert(erlang:function_exported(beam_agent_catalog,
                                     search_session_update,
                                     3)),
    ?assert(erlang:function_exported(beam_agent_catalog,
                                     search_session_stop,
                                     2)).

exports_event_stream_subscription_api_test() ->
    ?assert(erlang:function_exported(beam_agent, event_subscribe, 1)),
    ?assert(erlang:function_exported(beam_agent, receive_event, 2)),
    ?assert(erlang:function_exported(beam_agent, receive_event, 3)),
    ?assert(erlang:function_exported(beam_agent, event_unsubscribe, 2)).

exports_telemetry_surface_test() ->
    ensure_loaded(beam_agent_telemetry),
    ?assert(erlang:function_exported(beam_agent_telemetry, span_start, 3)),
    ?assert(erlang:function_exported(beam_agent_telemetry, span_stop, 3)),
    ?assert(erlang:function_exported(beam_agent_telemetry, span_stop, 4)),
    ?assert(erlang:function_exported(beam_agent_telemetry, span_exception, 3)),
    ?assert(erlang:function_exported(beam_agent_telemetry, span_exception, 4)),
    ?assert(erlang:function_exported(beam_agent_telemetry, state_change, 3)),
    ?assert(erlang:function_exported(beam_agent_telemetry, state_change, 4)),
    ?assert(erlang:function_exported(beam_agent_telemetry, buffer_overflow, 2)).

exports_runs_domain_surface_test() ->
    ensure_loaded(beam_agent_runs),
    ?assert(erlang:function_exported(beam_agent_runs, start_run, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, get_run, 1)),
    ?assert(erlang:function_exported(beam_agent_runs, list_runs, 0)),
    ?assert(erlang:function_exported(beam_agent_runs, list_runs, 1)),
    ?assert(erlang:function_exported(beam_agent_runs, complete_run, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, fail_run, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, cancel_run, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, start_step, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, get_step, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, list_steps, 1)),
    ?assert(erlang:function_exported(beam_agent_runs, complete_step, 3)),
    ?assert(erlang:function_exported(beam_agent_runs, fail_step, 3)),
    ?assert(erlang:function_exported(beam_agent_runs, cancel_step, 3)).

exports_artifacts_domain_surface_test() ->
    ensure_loaded(beam_agent_artifacts),
    ?assert(erlang:function_exported(beam_agent_artifacts, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_artifacts, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_artifacts, put, 1)),
    ?assert(erlang:function_exported(beam_agent_artifacts, put, 2)),
    ?assert(erlang:function_exported(beam_agent_artifacts, get, 1)),
    ?assert(erlang:function_exported(beam_agent_artifacts, list, 0)),
    ?assert(erlang:function_exported(beam_agent_artifacts, list, 1)),
    ?assert(erlang:function_exported(beam_agent_artifacts, search, 1)),
    ?assert(erlang:function_exported(beam_agent_artifacts, search, 2)),
    ?assert(erlang:function_exported(beam_agent_artifacts, attach, 3)),
    ?assert(erlang:function_exported(beam_agent_artifacts, delete, 1)).

exports_audit_domain_surface_test() ->
    ensure_loaded(beam_agent_journal),
    ?assert(erlang:function_exported(beam_agent_journal, list_events, 0)),
    ?assert(erlang:function_exported(beam_agent_journal, list_events, 1)),
    ?assert(erlang:function_exported(beam_agent_journal, get_event, 1)).

exports_journal_domain_surface_test() ->
    ensure_loaded(beam_agent_journal),
    ?assert(erlang:function_exported(beam_agent_journal, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_journal, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_journal, append, 2)),
    ?assert(erlang:function_exported(beam_agent_journal, list, 0)),
    ?assert(erlang:function_exported(beam_agent_journal, list, 1)),
    ?assert(erlang:function_exported(beam_agent_journal, stream_from, 1)),
    ?assert(erlang:function_exported(beam_agent_journal, stream_from, 2)),
    ?assert(erlang:function_exported(beam_agent_journal, get, 1)),
    ?assert(erlang:function_exported(beam_agent_journal, ack, 2)).

exports_memory_domain_surface_test() ->
    ensure_loaded(beam_agent_memory),
    ?assert(erlang:function_exported(beam_agent_memory, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_memory, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_memory, remember, 2)),
    ?assert(erlang:function_exported(beam_agent_memory, remember, 3)),
    ?assert(erlang:function_exported(beam_agent_memory, get, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, list, 0)),
    ?assert(erlang:function_exported(beam_agent_memory, list, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, recall, 2)),
    ?assert(erlang:function_exported(beam_agent_memory, search, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, search, 2)),
    ?assert(erlang:function_exported(beam_agent_memory, forget, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, pin, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, unpin, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, expire, 0)),
    ?assert(erlang:function_exported(beam_agent_memory, expire, 1)).

exports_policy_domain_surface_test() ->
    ensure_loaded(beam_agent_policy),
    ?assert(erlang:function_exported(beam_agent_policy, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_policy, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_policy, put_profile, 2)),
    ?assert(erlang:function_exported(beam_agent_policy, get_profile, 1)),
    ?assert(erlang:function_exported(beam_agent_policy, list_profiles, 0)),
    ?assert(erlang:function_exported(beam_agent_policy, evaluate, 3)).

exports_context_domain_surface_test() ->
    ensure_loaded(beam_agent_context),
    ?assert(erlang:function_exported(beam_agent_context, context_status, 1)),
    ?assert(erlang:function_exported(beam_agent_context, budget_estimate, 1)),
    ?assert(erlang:function_exported(beam_agent_context, compact_now, 2)),
    ?assert(erlang:function_exported(beam_agent_context, maybe_compact, 2)).

exports_routines_domain_surface_test() ->
    ensure_loaded(beam_agent_routines),
    ?assert(erlang:function_exported(beam_agent_routines, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, create, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, update, 2)),
    ?assert(erlang:function_exported(beam_agent_routines, cancel, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, get, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, list, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, list, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, list_due, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, list_due, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, next_due_at, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, run_now, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, run_due, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, run_due, 1)).

exports_orchestrator_domain_surface_test() ->
    ensure_loaded(beam_agent_orchestrator),
    ?assert(erlang:function_exported(beam_agent_orchestrator, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, spawn, 2)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, delegate, 3)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, await, 2)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, collect, 2)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, cancel, 2)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, status, 1)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, list_children, 1)).

exports_routing_domain_surface_test() ->
    ensure_loaded(beam_agent_routing),
    ?assert(erlang:function_exported(beam_agent_routing, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_routing, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_routing, select_backend, 1)),
    ?assert(erlang:function_exported(beam_agent_routing, select_backend, 2)).

child_spec_auto_routing_matches_explicit_backend_test() ->
    Auto = beam_agent:child_spec(#{
        backend => auto,
        routing => #{
            policy => preferred_then_fallback,
            preferred_backends => [gemini]
        }
    }),
    Direct = beam_agent:child_spec(#{backend => gemini}),
    ?assertEqual(Direct, Auto).

start_session_auto_routing_matches_explicit_backend_test() ->
    PreviousTrapExit = process_flag(trap_exit, true),
    try
        DirectResult = beam_agent:start_session(#{
            backend => gemini,
            cli_path => <<"/definitely/not/a/real-gemini-binary">>
        }),
        AutoResult = beam_agent:start_session(#{
            backend => auto,
            routing => #{
                policy => preferred_then_fallback,
                preferred_backends => [gemini]
            },
            cli_path => <<"/definitely/not/a/real-gemini-binary">>
        }),
        assert_start_results_match(DirectResult, AutoResult)
    after
        process_flag(trap_exit, PreviousTrapExit),
        flush_exit_messages()
    end.

exports_claude_native_controls_test() ->
    lists:foreach(fun ensure_loaded/1, [beam_agent_checkpoint, beam_agent_runtime,
                                         beam_agent_mcp, beam_agent_session_store]),
    ?assert(erlang:function_exported(beam_agent_checkpoint, rewind_files, 2)),
    ?assert(erlang:function_exported(beam_agent_runtime, stop_task, 2)),
    ?assert(erlang:function_exported(beam_agent_runtime, set_max_thinking_tokens, 2)),
    ?assert(erlang:function_exported(beam_agent_mcp, server_status, 1)),
    ?assert(erlang:function_exported(beam_agent_mcp, set_servers, 2)),
    ?assert(erlang:function_exported(beam_agent_mcp, reconnect_server, 2)),
    ?assert(erlang:function_exported(beam_agent_mcp, toggle_server, 3)),
    ?assert(erlang:function_exported(beam_agent_session_store, list_native_sessions, 0)),
    ?assert(erlang:function_exported(beam_agent_session_store, list_native_sessions, 1)),
    ?assert(erlang:function_exported(beam_agent_session_store, get_native_session_messages, 1)),
    ?assert(erlang:function_exported(beam_agent_session_store, get_native_session_messages, 2)).

exports_codex_native_admin_and_realtime_test() ->
    lists:foreach(fun ensure_loaded/1, [beam_agent_threads, beam_agent_control,
                                         beam_agent_skills, beam_agent_runtime,
                                         beam_agent_config, beam_agent_mcp,
                                         beam_agent_command]),
    ?assert(erlang:function_exported(beam_agent_threads, thread_unsubscribe, 2)),
    ?assert(erlang:function_exported(beam_agent_threads, thread_name_set, 3)),
    ?assert(erlang:function_exported(beam_agent_threads, thread_metadata_update, 3)),
    ?assert(erlang:function_exported(beam_agent_control, turn_steer, 4)),
    ?assert(erlang:function_exported(beam_agent_control, turn_steer, 5)),
    ?assert(erlang:function_exported(beam_agent_control, turn_interrupt, 3)),
    ?assert(erlang:function_exported(beam_agent_control, thread_realtime_start, 2)),
    ?assert(erlang:function_exported(beam_agent_control, thread_realtime_append_audio, 3)),
    ?assert(erlang:function_exported(beam_agent_control, thread_realtime_append_text, 3)),
    ?assert(erlang:function_exported(beam_agent_control, thread_realtime_stop, 2)),
    ?assert(erlang:function_exported(beam_agent_control, review_start, 2)),
    ?assert(erlang:function_exported(beam_agent_control, collaboration_mode_list, 1)),
    ?assert(erlang:function_exported(beam_agent_control, experimental_feature_list, 1)),
    ?assert(erlang:function_exported(beam_agent_skills, remote_list, 1)),
    ?assert(erlang:function_exported(beam_agent_skills, remote_export, 2)),
    ?assert(erlang:function_exported(beam_agent_runtime, apps_list, 1)),
    ?assert(erlang:function_exported(beam_agent_config, requirements_read, 1)),
    ?assert(erlang:function_exported(beam_agent_config, external_agent_detect, 1)),
    ?assert(erlang:function_exported(beam_agent_config, external_agent_import, 2)),
    ?assert(erlang:function_exported(beam_agent_mcp, server_oauth_login, 2)),
    ?assert(erlang:function_exported(beam_agent_command, command_write_stdin, 3)),
    ?assert(erlang:function_exported(beam_agent_command, command_write_stdin, 4)),
    ?assert(erlang:function_exported(beam_agent_command, submit_feedback, 2)),
    ?assert(erlang:function_exported(beam_agent_command, turn_respond, 3)).

exports_opencode_native_routes_test() ->
    lists:foreach(fun ensure_loaded/1, [beam_agent_runtime, beam_agent_catalog,
                                         beam_agent_command]),
    ?assert(erlang:function_exported(beam_agent_runtime, app_info, 1)),
    ?assert(erlang:function_exported(beam_agent_runtime, app_init, 1)),
    ?assert(erlang:function_exported(beam_agent_runtime, app_log, 2)),
    ?assert(erlang:function_exported(beam_agent_runtime, app_modes, 1)),
    ?assert(erlang:function_exported(beam_agent_catalog, find_text, 2)),
    ?assert(erlang:function_exported(beam_agent_catalog, find_files, 2)),
    ?assert(erlang:function_exported(beam_agent_catalog, find_symbols, 2)),
    ?assert(erlang:function_exported(beam_agent_catalog, file_list, 2)),
    ?assert(erlang:function_exported(beam_agent_catalog, file_read, 2)),
    ?assert(erlang:function_exported(beam_agent_catalog, file_status, 1)),
    ?assert(erlang:function_exported(beam_agent_command, session_init, 2)),
    ?assert(erlang:function_exported(beam_agent_command, session_messages, 1)),
    ?assert(erlang:function_exported(beam_agent_command, session_messages, 2)),
    ?assert(erlang:function_exported(beam_agent_command, prompt_async, 2)),
    ?assert(erlang:function_exported(beam_agent_command, prompt_async, 3)),
    ?assert(erlang:function_exported(beam_agent_command, shell_command, 2)),
    ?assert(erlang:function_exported(beam_agent_command, shell_command, 3)),
    ?assert(erlang:function_exported(beam_agent_command, tui_append_prompt, 2)),
    ?assert(erlang:function_exported(beam_agent_command, tui_open_help, 1)).

exports_copilot_native_admin_surface_test() ->
    lists:foreach(fun ensure_loaded/1, [beam_agent_runtime, beam_agent_catalog,
                                         beam_agent_control, beam_agent_command]),
    ?assert(erlang:function_exported(beam_agent_runtime, get_status, 1)),
    ?assert(erlang:function_exported(beam_agent_runtime, get_auth_status, 1)),
    ?assert(erlang:function_exported(beam_agent_catalog, model_list, 1)),
    ?assert(erlang:function_exported(beam_agent_runtime, get_last_session_id, 1)),
    ?assert(erlang:function_exported(beam_agent_control, list_server_sessions, 1)),
    ?assert(erlang:function_exported(beam_agent_control, get_server_session, 2)),
    ?assert(erlang:function_exported(beam_agent_control, delete_server_session, 2)),
    ?assert(erlang:function_exported(beam_agent_command, session_destroy, 1)),
    ?assert(erlang:function_exported(beam_agent_command, session_destroy, 2)).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

ensure_loaded(Mod) ->
    {module, Mod} = code:ensure_loaded(Mod),
    ok.

assert_start_results_match({ok, DirectSession}, {ok, AutoSession}) ->
    try
        ?assertEqual({ok, gemini}, beam_agent:backend(DirectSession)),
        ?assertEqual({ok, gemini}, beam_agent:backend(AutoSession))
    after
        maybe_stop_session(DirectSession),
        maybe_stop_session(AutoSession)
    end;
assert_start_results_match({error, DirectReason}, {error, AutoReason}) ->
    ?assertEqual(DirectReason, AutoReason);
assert_start_results_match({'EXIT', DirectReason}, {'EXIT', AutoReason}) ->
    ?assertEqual(DirectReason, AutoReason);
assert_start_results_match(DirectResult, AutoResult) ->
    maybe_stop_start_result(DirectResult),
    maybe_stop_start_result(AutoResult),
    ?assertEqual(DirectResult, AutoResult).

maybe_stop_start_result({ok, Session}) when is_pid(Session) ->
    maybe_stop_session(Session);
maybe_stop_start_result(_) ->
    ok.

maybe_stop_session(Session) when is_pid(Session) ->
    catch beam_agent:stop(Session),
    ok.

flush_exit_messages() ->
    receive
        {'EXIT', _Pid, _Reason} ->
            flush_exit_messages()
    after 0 ->
        ok
    end.
