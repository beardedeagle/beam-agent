-module(beam_agent_gemini_wire).
-moduledoc """
Gemini ACP request builders and notification parsers.

This module keeps the protocol details out of the session state machine so the
session process only needs to manage lifecycle and routing.
""".

-dialyzer({no_underspecs,
           [protocol_version/0,
            initialize_params/0,
            authenticate_params/1,
            session_start_method/1,
            cancel_params/1,
            set_mode_params/2,
            set_model_params/2,
            parse_start_result/1]}).

-export([
    protocol_version/0,
    initialize_params/0,
    authenticate_params/1,
    session_start_method/1,
    session_start_params/2,
    prompt_params/2,
    cancel_params/1,
    set_mode_params/2,
    set_model_params/2,
    decode_message/1,
    parse_session_update/1,
    parse_permission_request/1,
    parse_start_result/1
]).

-type decoded_message() ::
    {request, beam_agent_jsonrpc:request_id(), binary(), map() | undefined}
  | {notification, binary(), map() | undefined}
  | {response, beam_agent_jsonrpc:request_id(), term()}
  | {error_response, beam_agent_jsonrpc:request_id(), integer(), binary(), term() | undefined}
  | {unknown, map()}.

-export_type([decoded_message/0]).

-spec protocol_version() -> pos_integer().
protocol_version() ->
    1.

-spec initialize_params() -> map().
initialize_params() ->
    #{
        <<"protocolVersion">> => protocol_version(),
        <<"clientCapabilities">> => #{
            <<"fs">> => #{
                <<"readTextFile">> => false,
                <<"writeTextFile">> => false
            },
            <<"terminal">> => false
        },
        <<"clientInfo">> => #{
            <<"name">> => <<"beam-agent">>,
            <<"version">> => <<"0.1.0">>
        }
    }.

-spec authenticate_params(binary()) -> map().
authenticate_params(MethodId) when is_binary(MethodId) ->
    #{<<"methodId">> => MethodId}.

-spec session_start_method(map()) -> binary().
session_start_method(Opts) when is_map(Opts) ->
    case start_session_id(Opts) of
        undefined -> <<"session/new">>;
        _ -> <<"session/load">>
    end.

-spec session_start_params(map(), [map()]) -> map().
session_start_params(Opts, McpServers) when is_map(Opts), is_list(McpServers) ->
    Cwd = absolute_cwd(Opts),
    Base = #{
        <<"cwd">> => Cwd,
        <<"mcpServers">> => McpServers
    },
    case start_session_id(Opts) of
        undefined ->
            Base;
        SessionId ->
            Base#{<<"sessionId">> => SessionId}
    end.

-spec prompt_params(binary(), [map()]) -> map().
prompt_params(SessionId, Blocks)
  when is_binary(SessionId), is_list(Blocks) ->
    #{
        <<"sessionId">> => SessionId,
        <<"prompt">> => Blocks
    }.

-spec cancel_params(binary()) -> map().
cancel_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

-spec set_mode_params(binary(), binary()) -> map().
set_mode_params(SessionId, ModeId)
  when is_binary(SessionId), is_binary(ModeId) ->
    #{
        <<"sessionId">> => SessionId,
        <<"modeId">> => ModeId
    }.

-spec set_model_params(binary(), binary()) -> map().
set_model_params(SessionId, ModelId)
  when is_binary(SessionId), is_binary(ModelId) ->
    #{
        <<"sessionId">> => SessionId,
        <<"modelId">> => ModelId
    }.

-spec decode_message(map()) -> decoded_message().
decode_message(Map) when is_map(Map) ->
    beam_agent_jsonrpc:decode(Map).

-spec parse_session_update(map() | undefined) ->
    {ok, binary(), binary(), map()} | {error, term()}.
parse_session_update(#{<<"sessionId">> := SessionId,
                       <<"update">> := Update} = _Params)
  when is_binary(SessionId), is_map(Update) ->
    case maps:get(<<"sessionUpdate">>, Update, undefined) of
        Kind when is_binary(Kind) ->
            {ok, SessionId, Kind, Update};
        _ ->
            {error, missing_session_update}
    end;
parse_session_update(#{<<"sessionId">> := SessionId,
                       <<"sessionUpdate">> := Kind} = Params)
  when is_binary(SessionId), is_binary(Kind) ->
    {ok, SessionId, Kind, maps:remove(<<"sessionId">>, Params)};
parse_session_update(_) ->
    {error, invalid_session_update}.

-spec parse_permission_request(map() | undefined) ->
    {ok, binary(), map(), [map()]} | {error, term()}.
parse_permission_request(#{<<"sessionId">> := SessionId,
                           <<"toolCall">> := ToolCall,
                           <<"options">> := Options})
  when is_binary(SessionId), is_map(ToolCall), is_list(Options) ->
    {ok, SessionId, ToolCall, Options};
parse_permission_request(_) ->
    {error, invalid_permission_request}.

-spec parse_start_result(map()) -> map().
parse_start_result(Result) when is_map(Result) ->
    #{
        session_id => maps:get(<<"sessionId">>, Result, undefined),
        modes => maps:get(<<"modes">>, Result, undefined),
        models => maps:get(<<"models">>, Result, undefined),
        config_options => maps:get(<<"configOptions">>, Result, undefined),
        raw => Result
    }.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec start_session_id(map()) -> binary() | undefined.
start_session_id(Opts) ->
    case maps:get(resume, Opts, undefined) of
        true ->
            <<"latest">>;
        latest ->
            <<"latest">>;
        <<"latest">> ->
            <<"latest">>;
        SessionId when is_binary(SessionId), byte_size(SessionId) > 0 ->
            SessionId;
        _ ->
            undefined
    end.

-spec absolute_cwd(map()) -> binary().
absolute_cwd(Opts) ->
    case maps:get(work_dir, Opts, undefined) of
        undefined ->
            case file:get_cwd() of
                {ok, Cwd} ->
                    unicode:characters_to_binary(Cwd);
                _ ->
                    <<".">>
            end;
        Dir when is_binary(Dir) ->
            Dir;
        Dir when is_list(Dir) ->
            unicode:characters_to_binary(Dir)
    end.
