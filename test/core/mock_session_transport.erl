%%%-------------------------------------------------------------------
%%% @doc Mock transport for beam_agent_session_engine tests.
%%%
%%% Implements `beam_agent_transport` as an in-process message passer.
%%% The transport ref is the owner pid. Messages are delivered via
%%% `{mock_transport_data, Message}` Erlang messages.
%%% @end
%%%-------------------------------------------------------------------
-module(mock_session_transport).

-behaviour(beam_agent_transport).

-export([start/1, send/2, close/1, is_ready/1, classify_message/2]).

-spec start(map()) -> {ok, pid()} | {error, term()}.
start(#{owner := Owner}) ->
    {ok, Owner};
start(_Opts) ->
    {error, {missing_option, owner}}.

-spec send(pid(), iodata()) -> ok | {error, term()}.
send(_Ref, _Data) ->
    ok.

-spec close(pid()) -> ok.
close(_Ref) ->
    ok.

-spec is_ready(pid()) -> boolean().
is_ready(Ref) ->
    erlang:is_process_alive(Ref).

-spec classify_message(term(), pid()) ->
    beam_agent_session_handler:transport_event() | ignore.
classify_message({mock_transport_data, Msg}, _Ref) when is_map(Msg) ->
    %% Deliver pre-built messages as data events.
    %% Encode as JSONL so the engine can pass to handle_data.
    Encoded = iolist_to_binary(json:encode(Msg)),
    {data, <<Encoded/binary, $\n>>};
classify_message({mock_transport_exit, Status}, _Ref) ->
    {exit, Status};
classify_message(_, _) ->
    ignore.
