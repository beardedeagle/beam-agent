-module(beam_agent_todo_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% extract_todos/1
%%====================================================================

extract_todos_empty_test() ->
    ?assertEqual([], beam_agent_todo:extract_todos([])).

extract_todos_no_assistant_test() ->
    Msgs = [
        #{type => system, content => <<"ready">>},
        #{type => result, content => <<"done">>}
    ],
    ?assertEqual([], beam_agent_todo:extract_todos(Msgs)).

extract_todos_assistant_no_tools_test() ->
    Msgs = [
        #{type => assistant,
          content_blocks => [
              #{type => text, text => <<"hello">>}
          ]}
    ],
    ?assertEqual([], beam_agent_todo:extract_todos(Msgs)).

extract_todos_single_todo_test() ->
    Msgs = [
        #{type => assistant,
          content_blocks => [
              #{type => tool_use,
                name => <<"TodoWrite">>,
                id => <<"tu-1">>,
                input => #{
                    <<"content">> => <<"Fix the bug">>,
                    <<"status">> => <<"pending">>
                }}
          ]}
    ],
    Todos = beam_agent_todo:extract_todos(Msgs),
    ?assertEqual(1, length(Todos)),
    [Todo] = Todos,
    ?assertEqual(<<"Fix the bug">>, maps:get(content, Todo)),
    ?assertEqual(pending, maps:get(status, Todo)).

extract_todos_with_active_form_test() ->
    Msgs = [
        #{type => assistant,
          content_blocks => [
              #{type => tool_use,
                name => <<"TodoWrite">>,
                id => <<"tu-1">>,
                input => #{
                    <<"content">> => <<"Run tests">>,
                    <<"status">> => <<"in_progress">>,
                    <<"activeForm">> => <<"Running tests">>
                }}
          ]}
    ],
    [Todo] = beam_agent_todo:extract_todos(Msgs),
    ?assertEqual(<<"Run tests">>, maps:get(content, Todo)),
    ?assertEqual(in_progress, maps:get(status, Todo)),
    ?assertEqual(<<"Running tests">>, maps:get(active_form, Todo)).

extract_todos_completed_test() ->
    Msgs = [
        #{type => assistant,
          content_blocks => [
              #{type => tool_use,
                name => <<"TodoWrite">>,
                id => <<"tu-1">>,
                input => #{
                    <<"content">> => <<"Done task">>,
                    <<"status">> => <<"completed">>
                }}
          ]}
    ],
    [Todo] = beam_agent_todo:extract_todos(Msgs),
    ?assertEqual(completed, maps:get(status, Todo)).

extract_todos_subject_fallback_test() ->
    %% Falls back to "subject" field if "content" isn't present
    Msgs = [
        #{type => assistant,
          content_blocks => [
              #{type => tool_use,
                name => <<"TodoWrite">>,
                id => <<"tu-1">>,
                input => #{
                    <<"subject">> => <<"Task via subject">>,
                    <<"status">> => <<"pending">>
                }}
          ]}
    ],
    [Todo] = beam_agent_todo:extract_todos(Msgs),
    ?assertEqual(<<"Task via subject">>, maps:get(content, Todo)).

extract_todos_multiple_messages_test() ->
    Msgs = [
        #{type => assistant,
          content_blocks => [
              #{type => tool_use,
                name => <<"TodoWrite">>,
                id => <<"tu-1">>,
                input => #{<<"content">> => <<"Task 1">>,
                           <<"status">> => <<"pending">>}},
              #{type => text, text => <<"Working on it">>},
              #{type => tool_use,
                name => <<"TodoWrite">>,
                id => <<"tu-2">>,
                input => #{<<"content">> => <<"Task 2">>,
                           <<"status">> => <<"completed">>}}
          ]},
        #{type => assistant,
          content_blocks => [
              #{type => tool_use,
                name => <<"TodoWrite">>,
                id => <<"tu-3">>,
                input => #{<<"content">> => <<"Task 3">>,
                           <<"status">> => <<"in_progress">>}}
          ]}
    ],
    Todos = beam_agent_todo:extract_todos(Msgs),
    ?assertEqual(3, length(Todos)).

extract_todos_ignores_other_tools_test() ->
    Msgs = [
        #{type => assistant,
          content_blocks => [
              #{type => tool_use,
                name => <<"Write">>,
                id => <<"tu-1">>,
                input => #{<<"path">> => <<"/tmp/test">>}},
              #{type => tool_use,
                name => <<"TodoWrite">>,
                id => <<"tu-2">>,
                input => #{<<"content">> => <<"Real todo">>,
                           <<"status">> => <<"pending">>}}
          ]}
    ],
    Todos = beam_agent_todo:extract_todos(Msgs),
    ?assertEqual(1, length(Todos)),
    ?assertEqual(<<"Real todo">>, maps:get(content, hd(Todos))).

extract_todos_missing_content_blocks_test() ->
    %% Assistant message without content_blocks key
    Msgs = [#{type => assistant}],
    ?assertEqual([], beam_agent_todo:extract_todos(Msgs)).

%%====================================================================
%% filter_by_status/2
%%====================================================================

filter_by_status_test() ->
    Todos = [
        #{content => <<"A">>, status => pending},
        #{content => <<"B">>, status => completed},
        #{content => <<"C">>, status => in_progress},
        #{content => <<"D">>, status => completed}
    ],
    Pending = beam_agent_todo:filter_by_status(Todos, pending),
    ?assertEqual(1, length(Pending)),
    ?assertEqual(<<"A">>, maps:get(content, hd(Pending))),

    Completed = beam_agent_todo:filter_by_status(Todos, completed),
    ?assertEqual(2, length(Completed)),

    InProg = beam_agent_todo:filter_by_status(Todos, in_progress),
    ?assertEqual(1, length(InProg)).

filter_by_status_empty_test() ->
    ?assertEqual([], beam_agent_todo:filter_by_status([], pending)).

%%====================================================================
%% todo_summary/1
%%====================================================================

todo_summary_test() ->
    Todos = [
        #{content => <<"A">>, status => pending},
        #{content => <<"B">>, status => completed},
        #{content => <<"C">>, status => in_progress},
        #{content => <<"D">>, status => completed},
        #{content => <<"E">>, status => pending}
    ],
    Summary = beam_agent_todo:todo_summary(Todos),
    ?assertEqual(2, maps:get(pending, Summary)),
    ?assertEqual(2, maps:get(completed, Summary)),
    ?assertEqual(1, maps:get(in_progress, Summary)),
    ?assertEqual(5, maps:get(total, Summary)).

todo_summary_empty_test() ->
    Summary = beam_agent_todo:todo_summary([]),
    ?assertEqual(0, maps:get(total, Summary)).

%%====================================================================
%% Unknown status defaults to pending
%%====================================================================

unknown_status_defaults_to_pending_test() ->
    Msgs = [
        #{type => assistant,
          content_blocks => [
              #{type => tool_use,
                name => <<"TodoWrite">>,
                id => <<"tu-1">>,
                input => #{<<"content">> => <<"Unknown">>,
                           <<"status">> => <<"some_future_status">>}}
          ]}
    ],
    [Todo] = beam_agent_todo:extract_todos(Msgs),
    ?assertEqual(pending, maps:get(status, Todo)).
