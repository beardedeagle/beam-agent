-module(beam_agent_todo).
-moduledoc """
Todo tracking helpers for BeamAgent message streams.

This module extracts, filters, and summarizes todo items from the message
history produced by any agentic coder backend. Backends emit structured
todo lists as part of their message streams; this module provides a uniform
API for consuming them regardless of which backend produced the messages.

Use this module when you need to inspect task progress in a session — for
example, to display a task dashboard, poll for completion, or gate
downstream actions on todo status.

## Getting Started

```erlang
{ok, Messages} = beam_agent_session_store:get_session_messages(SessionId),
Todos = beam_agent_todo:extract_todos(Messages),
InProgress = beam_agent_todo:filter_by_status(Todos, in_progress),
Summary = beam_agent_todo:todo_summary(Todos).
%% => #{total => 5, pending => 2, in_progress => 1, completed => 2}
```

## Core Concepts

Todo items are maps with a `content' binary (the task description) and
a `status' (`pending', `in_progress', or `completed'). Some items also
carry an `active_form' field with the in-progress display variant.

`extract_todos/1' scans a flat message list for assistant messages
carrying `TodoWrite' tool-use blocks and returns all todo items found,
in order. `todo_summary/1' returns a map with `total' and one key per
distinct status value, giving counts at a glance.

All functions are pure — no ETS, no processes, no side effects.

## See Also

- `beam_agent_session_store' — retrieve session messages to pass to `extract_todos/1'
""".

-export([
    extract_todos/1,
    filter_by_status/2,
    todo_summary/1
]).

-export_type([todo_item/0, todo_status/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type todo_status() :: pending | in_progress | completed.

-type todo_item() :: #{
    content := binary(),
    status := todo_status(),
    active_form => binary()
}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc """
Extract all `TodoWrite` tool use blocks from a list of messages.
Scans assistant messages for `tool_use` content blocks where the
tool name is `TodoWrite`. Returns a flat list of todo items.
""".
-spec extract_todos([beam_agent_core:message()]) -> [todo_item()].
extract_todos(Messages) when is_list(Messages) ->
    lists:flatmap(fun extract_from_message/1, Messages).

-doc "Filter todo items by status.".
-spec filter_by_status([todo_item()], todo_status()) -> [todo_item()].
filter_by_status(Todos, Status) ->
    [T || #{status := S} = T <- Todos, S =:= Status].

-doc """
Return a summary map of todo counts by status.
Example: `#{pending => 2, in_progress => 1, completed => 3, total => 6}`
""".
-spec todo_summary([todo_item()]) -> #{atom() => non_neg_integer()}.
todo_summary(Todos) ->
    Counts = lists:foldl(fun(#{status := S}, Acc) ->
        maps:update_with(S, fun(N) -> N + 1 end, 1, Acc)
    end, #{}, Todos),
    Counts#{total => length(Todos)}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec extract_from_message(beam_agent_core:message()) -> [todo_item()].
extract_from_message(#{type := assistant, content_blocks := Blocks})
  when is_list(Blocks) ->
    lists:filtermap(fun parse_todo_block/1, Blocks);
extract_from_message(_) ->
    [].

-spec parse_todo_block(beam_agent_content_core:content_block()) ->
    {true, todo_item()} | false.
parse_todo_block(#{type := tool_use, name := <<"TodoWrite">>,
                   input := Input}) when is_map(Input) ->
    Content = maps:get(<<"content">>, Input,
                  maps:get(<<"subject">>, Input, <<>>)),
    Status = parse_todo_status(maps:get(<<"status">>, Input, <<"pending">>)),
    Item = #{content => Content, status => Status},
    Item2 = case maps:get(<<"activeForm">>, Input, undefined) of
        undefined -> Item;
        AF -> Item#{active_form => AF}
    end,
    {true, Item2};
parse_todo_block(_) ->
    false.

-spec parse_todo_status(binary()) -> todo_status().
parse_todo_status(<<"in_progress">>) -> in_progress;
parse_todo_status(<<"completed">>)   -> completed;
parse_todo_status(_)                 -> pending.
