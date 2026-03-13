%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the canonical beam_agent facade.
%%%-------------------------------------------------------------------
-module(beam_agent_tests).

-include_lib("eunit/include/eunit.hrl").

list_backends_test() ->
    ?assertEqual([claude, codex, gemini, opencode, copilot],
        beam_agent:list_backends()).

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
    ensure_loaded(beam_agent_search),
    ?assert(erlang:function_exported(beam_agent_search,
                                     session_start,
                                     3)),
    ?assert(erlang:function_exported(beam_agent_search,
                                     session_update,
                                     3)),
    ?assert(erlang:function_exported(beam_agent_search,
                                     session_stop,
                                     2)).

exports_event_stream_subscription_api_test() ->
    ?assert(erlang:function_exported(beam_agent, event_subscribe, 1)),
    ?assert(erlang:function_exported(beam_agent, receive_event, 2)),
    ?assert(erlang:function_exported(beam_agent, receive_event, 3)),
    ?assert(erlang:function_exported(beam_agent, event_unsubscribe, 2)).

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
                                         beam_agent_skills, beam_agent_apps,
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
    ?assert(erlang:function_exported(beam_agent_apps, list, 1)),
    ?assert(erlang:function_exported(beam_agent_config, requirements_read, 1)),
    ?assert(erlang:function_exported(beam_agent_config, external_agent_detect, 1)),
    ?assert(erlang:function_exported(beam_agent_config, external_agent_import, 2)),
    ?assert(erlang:function_exported(beam_agent_mcp, server_oauth_login, 2)),
    ?assert(erlang:function_exported(beam_agent_command, command_write_stdin, 3)),
    ?assert(erlang:function_exported(beam_agent_command, command_write_stdin, 4)),
    ?assert(erlang:function_exported(beam_agent_command, submit_feedback, 2)),
    ?assert(erlang:function_exported(beam_agent_command, turn_respond, 3)).

exports_opencode_native_routes_test() ->
    lists:foreach(fun ensure_loaded/1, [beam_agent_apps, beam_agent_file,
                                         beam_agent_command]),
    ?assert(erlang:function_exported(beam_agent_apps, info, 1)),
    ?assert(erlang:function_exported(beam_agent_apps, init, 1)),
    ?assert(erlang:function_exported(beam_agent_apps, log, 2)),
    ?assert(erlang:function_exported(beam_agent_apps, modes, 1)),
    ?assert(erlang:function_exported(beam_agent_file, find_text, 2)),
    ?assert(erlang:function_exported(beam_agent_file, find_files, 2)),
    ?assert(erlang:function_exported(beam_agent_file, find_symbols, 2)),
    ?assert(erlang:function_exported(beam_agent_file, list, 2)),
    ?assert(erlang:function_exported(beam_agent_file, read, 2)),
    ?assert(erlang:function_exported(beam_agent_file, status, 1)),
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
