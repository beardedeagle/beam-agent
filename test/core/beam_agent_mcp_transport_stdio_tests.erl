%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_mcp_transport_stdio.
%%%
%%% Tests cover classify_message/2 for all port data patterns, send/2
%%% error handling, and close/1 idempotency without spawning real
%%% subprocesses.
%%%
%%% A `make_ref()` value is used as a stand-in for the port() argument
%%% in classify_message/2 pattern-matching tests — the function only
%%% checks value equality between the two Port positions, not the type.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_transport_stdio_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Module loading
%%====================================================================

module_loaded_test() ->
    ?assert(erlang:module_loaded(beam_agent_mcp_transport_stdio) orelse
        code:ensure_loaded(beam_agent_mcp_transport_stdio) =:=
            {module, beam_agent_mcp_transport_stdio}).

%%====================================================================
%% classify_message/2 — eol (complete line returned as raw binary)
%%====================================================================

classify_eol_returns_raw_binary_test() ->
    FakePort = make_ref(),
    Line = <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}">>,
    ?assertEqual({data, Line},
        beam_agent_mcp_transport_stdio:classify_message(
            {FakePort, {data, {eol, Line}}}, FakePort)).

classify_eol_empty_line_returns_data_test() ->
    FakePort = make_ref(),
    ?assertEqual({data, <<>>},
        beam_agent_mcp_transport_stdio:classify_message(
            {FakePort, {data, {eol, <<>>}}}, FakePort)).

classify_eol_arbitrary_binary_returned_verbatim_test() ->
    FakePort = make_ref(),
    Line = <<"not valid { json">>,
    ?assertEqual({data, Line},
        beam_agent_mcp_transport_stdio:classify_message(
            {FakePort, {data, {eol, Line}}}, FakePort)).

%%====================================================================
%% classify_message/2 — noeol (partial chunk suppressed)
%%====================================================================

classify_noeol_returns_error_test() ->
    Port = make_ref(),
    ?assertEqual({error, line_overflow},
                 beam_agent_mcp_transport_stdio:classify_message(
                     {Port, {data, {noeol, <<"partial">>}}}, Port)).

classify_noeol_returns_error_on_chunk_test() ->
    FakePort = make_ref(),
    Chunk = <<"partial json fragment">>,
    ?assertEqual({error, line_overflow},
        beam_agent_mcp_transport_stdio:classify_message(
            {FakePort, {data, {noeol, Chunk}}}, FakePort)).

classify_noeol_empty_chunk_returns_error_test() ->
    FakePort = make_ref(),
    ?assertEqual({error, line_overflow},
        beam_agent_mcp_transport_stdio:classify_message(
            {FakePort, {data, {noeol, <<>>}}}, FakePort)).

%%====================================================================
%% classify_message/2 — exit_status
%%====================================================================

classify_exit_status_zero_test() ->
    FakePort = make_ref(),
    ?assertEqual({exit, 0},
        beam_agent_mcp_transport_stdio:classify_message(
            {FakePort, {exit_status, 0}}, FakePort)).

classify_exit_status_nonzero_test() ->
    FakePort = make_ref(),
    ?assertEqual({exit, 1},
        beam_agent_mcp_transport_stdio:classify_message(
            {FakePort, {exit_status, 1}}, FakePort)).

classify_exit_status_large_test() ->
    FakePort = make_ref(),
    ?assertEqual({exit, 255},
        beam_agent_mcp_transport_stdio:classify_message(
            {FakePort, {exit_status, 255}}, FakePort)).

%%====================================================================
%% classify_message/2 — non-matching messages
%%====================================================================

classify_wrong_port_returns_ignore_test() ->
    FakePort  = make_ref(),
    OtherPort = make_ref(),
    ?assertEqual(ignore,
        beam_agent_mcp_transport_stdio:classify_message(
            {FakePort, {data, {eol, <<"{}">>}}}, OtherPort)).

classify_arbitrary_message_returns_ignore_test() ->
    FakePort = make_ref(),
    ?assertEqual(ignore,
        beam_agent_mcp_transport_stdio:classify_message(
            {some, random, message}, FakePort)).

classify_atom_returns_ignore_test() ->
    FakePort = make_ref(),
    ?assertEqual(ignore,
        beam_agent_mcp_transport_stdio:classify_message(timeout, FakePort)).

%%====================================================================
%% send/2 — error on closed / non-existent port
%%====================================================================

send_returns_error_on_closed_port_test() ->
    %% make_ref() is not a port(); port_command/2 raises badarg → port_closed
    FakePort = make_ref(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"ping">>},
    ?assertEqual({error, port_closed},
        beam_agent_mcp_transport_stdio:send(FakePort, Msg)).

%%====================================================================
%% close/1 — idempotency
%%====================================================================

close_is_idempotent_test() ->
    %% Closing a non-port ref must not raise; catch absorbs the badarg.
    FakePort = make_ref(),
    ?assertEqual(ok, beam_agent_mcp_transport_stdio:close(FakePort)),
    ?assertEqual(ok, beam_agent_mcp_transport_stdio:close(FakePort)).
