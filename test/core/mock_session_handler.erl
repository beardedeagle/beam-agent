%%%-------------------------------------------------------------------
%%% @doc Mock session handler for beam_agent_session_engine tests.
%%%
%%% Implements `beam_agent_session_handler` with an in-process mock
%%% transport that delivers pre-configured responses. No real CLI
%%% subprocess is involved.
%%%
%%% Options:
%%%   `initial_state`  — `connecting | initializing | ready` (default: ready)
%%%   `mock_response`  — `[message()]` to deliver when a query arrives
%%%   `force_error`    — `true` to send mock transport exit after init
%%% @end
%%%-------------------------------------------------------------------
-module(mock_session_handler).

-behaviour(beam_agent_session_handler).

%% Required callbacks
-export([
    backend_name/0,
    init_handler/1,
    handle_data/2,
    encode_query/3,
    build_session_info/1,
    terminate_handler/2
]).

%%--------------------------------------------------------------------
%% Handler state
%%--------------------------------------------------------------------

-record(mock_state, {
    owner          :: pid(),
    responses = [] :: [beam_agent_core:message()],
    force_error    :: boolean()
}).

%%====================================================================
%% Required callbacks
%%====================================================================

backend_name() -> mock.

init_handler(Opts) ->
    InitState = maps:get(initial_state, Opts, ready),
    Responses = maps:get(mock_response, Opts, []),
    ForceError = maps:get(force_error, Opts, false),
    HState = #mock_state{
        owner       = self(),
        responses   = Responses,
        force_error = ForceError
    },
    %% If force_error, schedule a transport exit after a short delay
    case ForceError of
        true ->
            Engine = self(),
            spawn_link(fun() ->
                timer:sleep(50),
                Engine ! {mock_transport_exit, 1}
            end);
        false ->
            ok
    end,
    {ok, #{
        transport_spec => {mock_session_transport, #{owner => self()}},
        initial_state  => InitState,
        handler_state  => HState
    }}.

handle_data(Buffer, #mock_state{} = HState) ->
    extract_messages(Buffer, HState, []).

encode_query(Prompt, _Params, #mock_state{responses = Responses} = HState) ->
    %% Schedule mock responses to be delivered to the engine
    Owner = HState#mock_state.owner,
    spawn_link(fun() ->
        timer:sleep(10),
        lists:foreach(fun(Msg) ->
            Owner ! {mock_transport_data, Msg}
        end, Responses)
    end),
    Encoded = iolist_to_binary(json:encode(
        #{<<"type">> => <<"user">>,
          <<"message">> => #{<<"content">> => Prompt}})),
    {ok, Encoded, HState#mock_state{responses = []}}.

build_session_info(#mock_state{}) ->
    #{adapter => mock}.

terminate_handler(_Reason, _HState) ->
    ok.

%%====================================================================
%% Internal: JSONL message extraction
%%====================================================================

-spec extract_messages(binary(), #mock_state{},
                       [beam_agent_core:message()]) ->
    beam_agent_session_handler:data_result().
extract_messages(Buffer, HState, Acc) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none ->
            {ok, lists:reverse(Acc), Buffer, [], HState};
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok, RawMsg} ->
                    Msg = beam_agent_core:normalize_message(RawMsg),
                    extract_messages(Rest, HState, [Msg | Acc]);
                {error, _} ->
                    extract_messages(Rest, HState, Acc)
            end
    end.
