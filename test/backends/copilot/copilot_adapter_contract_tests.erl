%%%-------------------------------------------------------------------
%%% @doc Export contract checks for Copilot adapter closure helpers.
%%%-------------------------------------------------------------------
-module(copilot_adapter_contract_tests).

-include_lib("eunit/include/eunit.hrl").

exports_shared_contract_helpers_test() ->
    ?assertMatch({module, copilot_client}, code:ensure_loaded(copilot_client)),
    lists:foreach(
        fun({Function, Arity}) ->
            ?assert(erlang:function_exported(copilot_client, Function, Arity))
        end,
        [{event_subscribe, 1},
         {receive_event, 3},
         {event_unsubscribe, 2},
         {model_list, 2},
         {list_server_agents, 1},
         {session_messages, 1},
         {session_messages, 2},
         {thread_resume, 3},
         {thread_list, 2},
         {thread_unsubscribe, 2},
         {thread_name_set, 3},
         {thread_metadata_update, 3},
         {thread_loaded_list, 1},
         {thread_loaded_list, 2},
         {thread_compact, 2},
         {turn_interrupt, 3},
         {thread_realtime_start, 2},
         {thread_realtime_append_audio, 3},
         {thread_realtime_append_text, 3},
         {thread_realtime_stop, 2},
         {review_start, 2},
         {collaboration_mode_list, 1},
         {experimental_feature_list, 1},
         {experimental_feature_list, 2},
         {list_commands, 1},
         {skills_list, 1},
         {skills_list, 2},
         {skills_remote_list, 1},
         {skills_remote_list, 2},
         {mcp_status, 1},
         {mcp_server_status_list, 1},
         {account_rate_limits, 1}]
    ).
