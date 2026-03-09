%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the explicit beam_agent_raw escape hatch.
%%%
%%% beam_agent_raw exposes ONLY transport/debug escape hatches.
%%% All user-visible features are routed through the canonical
%%% beam_agent module with universal fallbacks.
%%%-------------------------------------------------------------------
-module(beam_agent_raw_tests).

-include_lib("eunit/include/eunit.hrl").

generic_raw_helpers_test() ->
    ?assert(erlang:function_exported(beam_agent_raw, backend, 1)),
    ?assert(erlang:function_exported(beam_agent_raw, adapter_module, 1)),
    ?assert(erlang:function_exported(beam_agent_raw, call, 3)),
    ?assert(erlang:function_exported(beam_agent_raw, call_backend, 3)).

exports_native_session_access_test() ->
    lists:foreach(
        fun({Function, Arity}) ->
            ?assert(erlang:function_exported(beam_agent_raw, Function, Arity))
        end,
        [{list_native_sessions, 0},
         {list_native_sessions, 1},
         {get_native_session_messages, 1},
         {get_native_session_messages, 2}]
    ).

exports_transport_level_probes_test() ->
    lists:foreach(
        fun({Function, Arity}) ->
            ?assert(erlang:function_exported(beam_agent_raw, Function, Arity))
        end,
        [{session_destroy, 1},
         {session_destroy, 2},
         {server_health, 1},
         {get_status, 1},
         {get_auth_status, 1},
         {get_last_session_id, 1}]
    ).

raw_module_does_not_export_user_features_test() ->
    %% These functions were intentionally moved to beam_agent with
    %% universal fallbacks.  They must NOT exist on beam_agent_raw.
    RemovedFunctions =
        [{set_max_thinking_tokens, 2},
         {rewind_files, 2},
         {stop_task, 2},
         {thread_unsubscribe, 2},
         {thread_name_set, 3},
         {thread_metadata_update, 3},
         {turn_steer, 4},
         {turn_steer, 5},
         {turn_interrupt, 3},
         {skills_remote_list, 1},
         {skills_remote_export, 2},
         {apps_list, 1},
         {fuzzy_file_search, 2},
         {fuzzy_file_search, 3},
         {fuzzy_file_search_session_start, 3},
         {fuzzy_file_search_session_update, 3},
         {fuzzy_file_search_session_stop, 2},
         {command_write_stdin, 3},
         {command_write_stdin, 4},
         {app_info, 1},
         {app_init, 1},
         {app_log, 2},
         {app_modes, 1},
         {find_text, 2},
         {find_files, 2},
         {find_symbols, 2},
         {file_list, 2},
         {file_read, 2},
         {file_status, 1},
         {account_login, 2},
         {account_login_cancel, 2},
         {account_logout, 1},
         {prompt_async, 2},
         {prompt_async, 3},
         {shell_command, 2},
         {shell_command, 3},
         {tui_append_prompt, 2},
         {tui_open_help, 1},
         {command_run, 2},
         {command_run, 3},
         {submit_feedback, 2},
         {turn_respond, 3},
         {add_mcp_server, 2},
         {mcp_server_status, 1},
         {set_mcp_servers, 2},
         {reconnect_mcp_server, 2},
         {toggle_mcp_server, 3},
         {mcp_server_oauth_login, 2},
         {mcp_server_reload, 1}],
    lists:foreach(
        fun({Function, Arity}) ->
            ?assertNot(erlang:function_exported(beam_agent_raw, Function, Arity))
        end,
        RemovedFunctions
    ).

raw_export_count_test() ->
    %% Guard against accidental re-bloat. The raw module should export
    %% exactly 14 functions (4 generic + 4 native sessions + 6 probes).
    Exports = beam_agent_raw:module_info(exports),
    %% module_info/0 and module_info/1 are auto-generated, exclude them.
    UserExports = [E || E = {F, _} <- Exports, F =/= module_info],
    ?assertEqual(14, length(UserExports)).
