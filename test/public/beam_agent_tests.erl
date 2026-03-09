%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the canonical beam_agent facade.
%%%-------------------------------------------------------------------
-module(beam_agent_tests).

-include_lib("eunit/include/eunit.hrl").

list_backends_test() ->
    ?assertEqual([claude, codex, gemini, opencode, copilot],
        beam_agent:list_backends()).

capabilities_projection_test() ->
    {ok, Caps} = beam_agent:capabilities(codex),
    [SessionHistory] = [Cap || #{id := session_history} = Cap <- Caps],
    ?assertMatch(#{id := session_history, support_level := full}, SessionHistory).

supports_test() ->
    ?assertEqual({ok, true}, beam_agent:supports(session_lifecycle, claude)),
    ?assertEqual({ok, true}, beam_agent:supports(user_input_callbacks, gemini)),
    ?assertEqual({ok, true}, beam_agent:supports(event_streaming, opencode)),
    ?assertEqual({ok, true}, beam_agent:supports(event_streaming, codex)).

exports_fuzzy_file_search_session_lifecycle_test() ->
    ?assert(erlang:function_exported(beam_agent,
                                     fuzzy_file_search_session_start,
                                     3)),
    ?assert(erlang:function_exported(beam_agent,
                                     fuzzy_file_search_session_update,
                                     3)),
    ?assert(erlang:function_exported(beam_agent,
                                     fuzzy_file_search_session_stop,
                                     2)).

exports_event_stream_subscription_api_test() ->
    ?assert(erlang:function_exported(beam_agent, event_subscribe, 1)),
    ?assert(erlang:function_exported(beam_agent, receive_event, 2)),
    ?assert(erlang:function_exported(beam_agent, receive_event, 3)),
    ?assert(erlang:function_exported(beam_agent, event_unsubscribe, 2)).

exports_claude_native_controls_test() ->
    ?assert(erlang:function_exported(beam_agent, rewind_files, 2)),
    ?assert(erlang:function_exported(beam_agent, stop_task, 2)),
    ?assert(erlang:function_exported(beam_agent, set_max_thinking_tokens, 2)),
    ?assert(erlang:function_exported(beam_agent, mcp_server_status, 1)),
    ?assert(erlang:function_exported(beam_agent, set_mcp_servers, 2)),
    ?assert(erlang:function_exported(beam_agent, reconnect_mcp_server, 2)),
    ?assert(erlang:function_exported(beam_agent, toggle_mcp_server, 3)),
    ?assert(erlang:function_exported(beam_agent, list_native_sessions, 0)),
    ?assert(erlang:function_exported(beam_agent, list_native_sessions, 1)),
    ?assert(erlang:function_exported(beam_agent, get_native_session_messages, 1)),
    ?assert(erlang:function_exported(beam_agent, get_native_session_messages, 2)).

exports_codex_native_admin_and_realtime_test() ->
    ?assert(erlang:function_exported(beam_agent, thread_unsubscribe, 2)),
    ?assert(erlang:function_exported(beam_agent, thread_name_set, 3)),
    ?assert(erlang:function_exported(beam_agent, thread_metadata_update, 3)),
    ?assert(erlang:function_exported(beam_agent, turn_steer, 4)),
    ?assert(erlang:function_exported(beam_agent, turn_steer, 5)),
    ?assert(erlang:function_exported(beam_agent, turn_interrupt, 3)),
    ?assert(erlang:function_exported(beam_agent, thread_realtime_start, 2)),
    ?assert(erlang:function_exported(beam_agent, thread_realtime_append_audio, 3)),
    ?assert(erlang:function_exported(beam_agent, thread_realtime_append_text, 3)),
    ?assert(erlang:function_exported(beam_agent, thread_realtime_stop, 2)),
    ?assert(erlang:function_exported(beam_agent, review_start, 2)),
    ?assert(erlang:function_exported(beam_agent, collaboration_mode_list, 1)),
    ?assert(erlang:function_exported(beam_agent, experimental_feature_list, 1)),
    ?assert(erlang:function_exported(beam_agent, skills_remote_list, 1)),
    ?assert(erlang:function_exported(beam_agent, skills_remote_export, 2)),
    ?assert(erlang:function_exported(beam_agent, apps_list, 1)),
    ?assert(erlang:function_exported(beam_agent, config_requirements_read, 1)),
    ?assert(erlang:function_exported(beam_agent, external_agent_config_detect, 1)),
    ?assert(erlang:function_exported(beam_agent, external_agent_config_import, 2)),
    ?assert(erlang:function_exported(beam_agent, mcp_server_oauth_login, 2)),
    ?assert(erlang:function_exported(beam_agent, command_write_stdin, 3)),
    ?assert(erlang:function_exported(beam_agent, command_write_stdin, 4)),
    ?assert(erlang:function_exported(beam_agent, submit_feedback, 2)),
    ?assert(erlang:function_exported(beam_agent, turn_respond, 3)).

exports_opencode_native_routes_test() ->
    ?assert(erlang:function_exported(beam_agent, app_info, 1)),
    ?assert(erlang:function_exported(beam_agent, app_init, 1)),
    ?assert(erlang:function_exported(beam_agent, app_log, 2)),
    ?assert(erlang:function_exported(beam_agent, app_modes, 1)),
    ?assert(erlang:function_exported(beam_agent, find_text, 2)),
    ?assert(erlang:function_exported(beam_agent, find_files, 2)),
    ?assert(erlang:function_exported(beam_agent, find_symbols, 2)),
    ?assert(erlang:function_exported(beam_agent, file_list, 2)),
    ?assert(erlang:function_exported(beam_agent, file_read, 2)),
    ?assert(erlang:function_exported(beam_agent, file_status, 1)),
    ?assert(erlang:function_exported(beam_agent, session_init, 2)),
    ?assert(erlang:function_exported(beam_agent, session_messages, 1)),
    ?assert(erlang:function_exported(beam_agent, session_messages, 2)),
    ?assert(erlang:function_exported(beam_agent, prompt_async, 2)),
    ?assert(erlang:function_exported(beam_agent, prompt_async, 3)),
    ?assert(erlang:function_exported(beam_agent, shell_command, 2)),
    ?assert(erlang:function_exported(beam_agent, shell_command, 3)),
    ?assert(erlang:function_exported(beam_agent, tui_append_prompt, 2)),
    ?assert(erlang:function_exported(beam_agent, tui_open_help, 1)).

exports_copilot_native_admin_surface_test() ->
    ?assert(erlang:function_exported(beam_agent, get_status, 1)),
    ?assert(erlang:function_exported(beam_agent, get_auth_status, 1)),
    ?assert(erlang:function_exported(beam_agent, model_list, 1)),
    ?assert(erlang:function_exported(beam_agent, get_last_session_id, 1)),
    ?assert(erlang:function_exported(beam_agent, list_server_sessions, 1)),
    ?assert(erlang:function_exported(beam_agent, get_server_session, 2)),
    ?assert(erlang:function_exported(beam_agent, delete_server_session, 2)),
    ?assert(erlang:function_exported(beam_agent, session_destroy, 1)),
    ?assert(erlang:function_exported(beam_agent, session_destroy, 2)).
