-module(gemini_cli_protocol).
-moduledoc false.

-dialyzer({no_underspecs,
           [{protocol_version, 0},
            {start_session_method, 1},
            {start_session_params, 1},
            {set_mode_params, 2},
            {cancel_params, 1}]}).

-export([
    normalize_event/1,
    parse_stats/1,
    exit_code_to_error/1,
    protocol_version/0,
    initialize_params/1,
    should_authenticate/1,
    authenticate_params/2,
    start_session_method/1,
    start_session_params/1,
    prompt_request/2,
    set_mode_params/2,
    cancel_params/1,
    decode_frame/1,
    approval_response/2
]).

-spec normalize_event(map()) -> beam_agent_core:message().
normalize_event(#{<<"type">> := <<"init">>} = Raw) ->
    SessionId = maps:get(<<"session_id">>, Raw, <<>>),
    Model = maps:get(<<"model">>, Raw, <<>>),
    #{type => system,
      subtype => <<"init">>,
      session_id => SessionId,
      model => Model,
      content => <<>>,
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"message">>, <<"role">> := <<"user">>} =
                    Raw) ->
    #{type => user,
      content => maps:get(<<"content">>, Raw, <<>>),
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"message">>,
                  <<"role">> := <<"assistant">>} =
                    Raw) ->
    #{type => text,
      content => maps:get(<<"content">>, Raw, <<>>),
      delta => maps:get(<<"delta">>, Raw, false),
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"tool_use">>} = Raw) ->
    #{type => tool_use,
      tool_name => maps:get(<<"tool_name">>, Raw, <<>>),
      tool_input => maps:get(<<"parameters">>, Raw, #{}),
      tool_use_id => maps:get(<<"tool_id">>, Raw, <<>>),
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"tool_result">>,
                  <<"status">> := <<"success">>} =
                    Raw) ->
    #{type => tool_result,
      content => maps:get(<<"output">>, Raw, <<>>),
      tool_use_id => maps:get(<<"tool_id">>, Raw, <<>>),
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"tool_result">>,
                  <<"status">> := <<"error">>} =
                    Raw) ->
    #{type => error,
      content =>
          maps:get(<<"output">>,
                   Raw,
                   maps:get(<<"message">>, Raw, <<"tool_result error">>)),
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"error">>,
                  <<"severity">> := <<"warning">>} =
                    Raw) ->
    #{type => system,
      subtype => <<"warning">>,
      content => maps:get(<<"message">>, Raw, <<>>),
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"error">>} = Raw) ->
    #{type => error,
      content => maps:get(<<"message">>, Raw, <<>>),
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"result">>,
                  <<"status">> := <<"success">>} =
                    Raw) ->
    StatsRaw = maps:get(<<"stats">>, Raw, #{}),
    Stats = parse_stats(StatsRaw),
    #{type => result,
      content => maps:get(<<"content">>, Raw, <<>>),
      stats => Stats,
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"result">>,
                  <<"status">> := <<"error">>} =
                    Raw) ->
    #{type => error,
      content =>
          maps:get(<<"message">>,
                   Raw,
                   maps:get(<<"content">>, Raw, <<"result error">>)),
      raw => Raw,
      timestamp => erlang:system_time(millisecond)};
normalize_event(Raw) when is_map(Raw) ->
    #{type => raw,
      raw => Raw,
      timestamp => erlang:system_time(millisecond)}.

-spec parse_stats(map()) -> map().
parse_stats(Stats) when is_map(Stats) ->
    #{tokens_in => maps:get(<<"tokens_in">>, Stats, 0),
      tokens_out => maps:get(<<"tokens_out">>, Stats, 0),
      duration_ms => maps:get(<<"duration_ms">>, Stats, 0),
      tool_calls => maps:get(<<"tool_calls">>, Stats, 0)};
parse_stats(_) ->
    #{tokens_in => 0,
      tokens_out => 0,
      duration_ms => 0,
      tool_calls => 0}.

-spec exit_code_to_error(integer()) -> binary().
exit_code_to_error(0) ->
    <<"success">>;
exit_code_to_error(41) ->
    <<"auth_error">>;
exit_code_to_error(42) ->
    <<"input_error">>;
exit_code_to_error(52) ->
    <<"config_error">>;
exit_code_to_error(130) ->
    <<"cancelled">>;
exit_code_to_error(N) ->
    iolist_to_binary(io_lib:format("unknown_error: ~p", [N])).

-spec protocol_version() -> pos_integer().
protocol_version() ->
    1.

-spec initialize_params(map()) -> map().
initialize_params(Opts) when is_map(Opts) ->
    Params0 =
        #{<<"protocolVersion">> => protocol_version(),
          <<"clientCapabilities">> =>
              jsonify(
                  maps:get(client_capabilities,
                           Opts,
                           #{fs => #{<<"readTextFile">> => false,
                                     <<"writeTextFile">> => false},
                             terminal => false})),
          <<"clientInfo">> =>
              jsonify(
                  maps:get(client_info,
                           Opts,
                           #{name => <<"beam_agent">>,
                             version => <<"0.1.0">>}))},
    maybe_drop_nulls(Params0).

-spec should_authenticate(map()) -> boolean().
should_authenticate(Opts) when is_map(Opts) ->
    maps:get(authenticate, Opts, false)
    orelse maps:is_key(auth_method, Opts)
    orelse maps:is_key(api_key, Opts).

-spec authenticate_params(map(), [map()]) -> map().
authenticate_params(Opts, Methods)
    when is_map(Opts), is_list(Methods) ->
    MethodId =
        case maps:get(auth_method, Opts, undefined) of
            undefined ->
                case maps:get(api_key, Opts, undefined) of
                    undefined ->
                        default_auth_method(Methods);
                    _ ->
                        <<"gemini-api-key">>
                end;
            Method ->
                ensure_binary(Method)
        end,
    ApiKey = maps:get(api_key, Opts, undefined),
    Base = #{<<"methodId">> => MethodId},
    case ApiKey of
        undefined ->
            Base;
        _ ->
            Base#{<<"_meta">> => #{<<"api-key">> => ensure_binary(ApiKey)}}
    end.

-spec start_session_method(map()) -> binary().
start_session_method(Opts) when is_map(Opts) ->
    case session_selector(Opts) of
        undefined ->
            <<"session/new">>;
        _ ->
            <<"session/load">>
    end.

-spec start_session_params(map()) -> map().
start_session_params(Opts) when is_map(Opts) ->
    Base =
        #{<<"cwd">> => session_cwd(Opts),
          <<"mcpServers">> =>
              jsonify(maps:get(acp_mcp_servers, Opts, []))},
    case session_selector(Opts) of
        undefined ->
            Base;
        SessionId ->
            Base#{<<"sessionId">> => SessionId}
    end.

-spec prompt_request(binary(), binary() | [map()]) -> map().
prompt_request(SessionId, Prompt)
    when is_binary(SessionId), is_binary(Prompt) ->
    #{<<"sessionId">> => SessionId,
      <<"prompt">> => [#{<<"type">> => <<"text">>, <<"text">> => Prompt}]};
prompt_request(SessionId, Blocks)
    when is_binary(SessionId), is_list(Blocks) ->
    #{<<"sessionId">> => SessionId,
      <<"prompt">> => jsonify(Blocks)}.

-spec set_mode_params(binary(), binary()) -> map().
set_mode_params(SessionId, ModeId)
    when is_binary(SessionId), is_binary(ModeId) ->
    #{<<"sessionId">> => SessionId, <<"modeId">> => ModeId}.

-spec cancel_params(binary()) -> map().
cancel_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

-spec decode_frame(map()) -> beam_agent_jsonrpc:jsonrpc_msg().
decode_frame(Map) when is_map(Map) ->
    beam_agent_jsonrpc:decode(Map).

-spec approval_response([map()], accept | accept_for_session | decline | cancel) ->
                           map().
approval_response(Options, Decision) when is_list(Options) ->
    case Decision of
        accept ->
            selected_outcome(select_option(Options, [<<"allow_once">>,
                                                    <<"allow_always">>]));
        accept_for_session ->
            selected_outcome(select_option(Options, [<<"allow_always">>,
                                                    <<"allow_once">>]));
        decline ->
            case select_option(Options, [<<"reject_once">>,
                                         <<"reject_always">>]) of
                undefined ->
                    cancelled_outcome();
                OptionId ->
                    selected_outcome(OptionId)
            end;
        cancel ->
            cancelled_outcome()
    end.

selected_outcome(undefined) ->
    cancelled_outcome();
selected_outcome(OptionId) ->
    #{<<"outcome">> =>
          #{<<"outcome">> => <<"selected">>,
            <<"optionId">> => OptionId}}.

cancelled_outcome() ->
    #{<<"outcome">> => #{<<"outcome">> => <<"cancelled">>}}.

select_option([], _Kinds) ->
    undefined;
select_option([Option | Rest], Kinds) ->
    Kind = normalize_option_kind(maps:get(<<"kind">>, Option,
                                          maps:get(kind, Option, undefined))),
    case lists:member(Kind, Kinds) of
        true ->
            ensure_binary(
                maps:get(<<"optionId">>, Option,
                         maps:get(option_id, Option,
                                  maps:get(option_id, Option, <<>>))));
        false ->
            select_option(Rest, Kinds)
    end.

normalize_option_kind(Kind) when is_binary(Kind) ->
    Kind;
normalize_option_kind(Kind) when is_atom(Kind) ->
    atom_to_binary(Kind, utf8);
normalize_option_kind(_) ->
    <<>>.

default_auth_method([#{<<"id">> := Id} | _]) ->
    ensure_binary(Id);
default_auth_method([#{id := Id} | _]) ->
    ensure_binary(Id);
default_auth_method(_) ->
    <<"gemini-api-key">>.

session_selector(Opts) ->
    case maps:get(session_id, Opts, undefined) of
        SessionId when is_binary(SessionId), byte_size(SessionId) > 0 ->
            SessionId;
        SessionId when is_list(SessionId), SessionId =/= [] ->
            ensure_binary(SessionId);
        _ ->
            case maps:get(resume, Opts, undefined) of
                undefined ->
                    undefined;
                false ->
                    undefined;
                true ->
                    <<"latest">>;
                latest ->
                    <<"latest">>;
                <<"latest">> = Latest ->
                    Latest;
                ResumeId when is_binary(ResumeId), byte_size(ResumeId) > 0 ->
                    ResumeId;
                ResumeId when is_list(ResumeId), ResumeId =/= [] ->
                    ensure_binary(ResumeId);
                _ ->
                    undefined
            end
    end.

session_cwd(Opts) ->
    Candidate =
        case maps:get(work_dir, Opts, undefined) of
            undefined ->
                maps:get(cwd, Opts, undefined);
            Value ->
                Value
        end,
    ensure_absolute_path(Candidate).

ensure_absolute_path(undefined) ->
    case file:get_cwd() of
        {ok, Cwd} ->
            unicode:characters_to_binary(Cwd);
        _ ->
            <<".">>
    end;
ensure_absolute_path(Path) ->
    Bin = ensure_binary(Path),
    case filename:pathtype(binary_to_list(Bin)) of
        absolute ->
            Bin;
        _ ->
            case file:get_cwd() of
                {ok, Cwd} ->
                    unicode:characters_to_binary(
                        filename:absname(binary_to_list(Bin), Cwd));
                _ ->
                    Bin
            end
    end.

jsonify(Value) when is_map(Value) ->
    maps:from_list([{jsonify_key(Key), jsonify(Val)} || {Key, Val} <- maps:to_list(Value)]);
jsonify(Value) when is_list(Value) ->
    [jsonify(Item) || Item <- Value];
jsonify(true) ->
    true;
jsonify(false) ->
    false;
jsonify(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
jsonify(Value) ->
    Value.

jsonify_key(Key) when is_binary(Key) ->
    Key;
jsonify_key(Key) when is_atom(Key) ->
    atom_to_binary(Key, utf8);
jsonify_key(Key) when is_list(Key) ->
    unicode:characters_to_binary(Key);
jsonify_key(Key) ->
    ensure_binary(io_lib:format("~tp", [Key])).

maybe_drop_nulls(Map) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Map).

ensure_binary(Value) when is_binary(Value) ->
    Value;
ensure_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
ensure_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
ensure_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~tp", [Value])).
