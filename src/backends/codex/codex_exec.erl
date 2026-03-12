-module(codex_exec).
-moduledoc false.
-behaviour(gen_statem).
-behaviour(beam_agent_behaviour).
-export([start_link/1,send_query/4,receive_message/3,health/1,stop/1]).
-export([send_control/3,
         interrupt/1,
         session_info/1,
         set_model/2,
         set_permission_mode/2]).
-export([callback_mode/0,init/1,terminate/3]).
-export([idle/3,active_query/3,error/3]).
-type state_name() :: idle | active_query | error.
-type state_callback_result() ::
          gen_statem:state_enter_result(state_name()) |
          gen_statem:event_handler_result(state_name()).
-export_type([state_name/0]).
-dialyzer({no_underspecs, [{build_exec_args, 2}, {build_port_opts, 3}]}).
-record(data,{port :: port() | undefined,
              buffer = <<>> :: binary(),
              buffer_max :: pos_integer(),
              consumer :: gen_statem:from() | undefined,
              query_ref :: reference() | undefined,
              msg_queue :: queue:queue() | undefined,
              query_start_time :: integer() | undefined,
              opts :: map(),
              cli_path :: string(),
              model :: binary() | undefined,
              approval_policy :: binary() | undefined,
              sdk_hook_registry ::
                  beam_agent_hooks_core:hook_registry() | undefined}).
-spec start_link(beam_agent_core:session_opts()) ->
                    {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(codex_exec, Opts, []).
-spec send_query(pid(), binary(), beam_agent_core:query_opts(), timeout()) ->
                    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).
-spec receive_message(pid(), reference(), timeout()) ->
                         {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).
-spec health(pid()) ->
                ready | connecting | initializing | active_query | error.
health(Pid) ->
    gen_statem:call(Pid, health, 5000).
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10000).
-spec send_control(pid(), binary(), map()) -> {error, not_supported}.
send_control(_Pid, _Method, _Params) ->
    {error, not_supported}.
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, interrupt, 5000).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5000).
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 5000).
-spec set_permission_mode(pid(), binary()) ->
                             {ok, term()} | {error, term()}.
set_permission_mode(Pid, Mode) ->
    gen_statem:call(Pid, {set_permission_mode, Mode}, 5000).
-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() ->
    [state_functions, state_enter].
-spec init(map()) -> gen_statem:init_result(idle) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    CliPath =
        maps:get(cli_path, Opts, os:getenv("CODEX_CLI_PATH", "codex")),
    BufferMax = maps:get(buffer_max, Opts, 2 * 1024 * 1024),
    Model = maps:get(model, Opts, undefined),
    ApprovalPolicy =
        case maps:get(approval_policy, Opts, undefined) of
            undefined ->
                undefined;
            AP when is_atom(AP) ->
                codex_protocol:encode_ask_for_approval(AP);
            AP when is_binary(AP) ->
                AP
        end,
    HookRegistry =
        beam_agent_hooks_core:build_registry(maps:get(sdk_hooks, Opts,
                                                 undefined)),
    Data =
        #data{opts = Opts,
              cli_path = CliPath,
              buffer_max = BufferMax,
              model = Model,
              approval_policy = ApprovalPolicy,
              sdk_hook_registry = HookRegistry},
    {ok, idle, Data}.
-spec terminate(term(), atom(), #data{}) -> ok.
terminate(Reason, _State, #data{port = Port} = Data) ->
    _ = fire_hook(session_end,
                  #{event => session_end, reason => Reason},
                  Data),
    codex_port_utils:close_port(Port),
    ok.
-spec idle(gen_statem:event_type(), term(), #data{}) ->
              state_callback_result().
idle(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex_exec, OldState, idle),
    keep_state_and_data;
idle({call, From}, {send_query, Prompt, Params}, Data) ->
    HookCtx =
        #{event => user_prompt_submit,
          prompt => Prompt,
          params => Params},
    case
        beam_agent_hooks_core:fire(user_prompt_submit, HookCtx,
                              Data#data.sdk_hook_registry)
    of
        {deny, Reason} ->
            {keep_state_and_data,
             [{reply, From, {error, {hook_denied, Reason}}}]};
        ok ->
            do_exec_query(From, Prompt, Params, Data)
    end;
idle({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};
idle({call, From}, session_info, Data) ->
    Info =
        #{model => Data#data.model,
          approval_policy => Data#data.approval_policy,
          transport => exec},
    {keep_state_and_data, [{reply, From, {ok, Info}}]};
idle({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};
idle({call, From}, {set_permission_mode, Mode}, Data) ->
    {keep_state,
     Data#data{approval_policy = Mode},
     [{reply, From, {ok, Mode}}]};
idle(info, {'EXIT', _Port, _Reason}, _Data) ->
    keep_state_and_data;
idle({call, From}, {send_control, _Method, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_supported}}]};
idle({call, From}, interrupt, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};
idle({call, From},
     {receive_message, Ref},
     #data{query_ref = Ref, msg_queue = Q} = Data) ->
    case Q of
        undefined ->
            {keep_state,
             Data#data{query_ref = undefined},
             [{reply, From, {error, complete}}]};
        _ ->
            case queue:out(Q) of
                {{value, Msg}, Q1} ->
                    {keep_state,
                     Data#data{msg_queue = Q1},
                     [{reply, From, {ok, Msg}}]};
                {empty, _} ->
                    {keep_state,
                     Data#data{query_ref = undefined,
                               msg_queue = undefined},
                     [{reply, From, {error, complete}}]}
            end
    end;
idle({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
idle({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_request}}]}.
-spec active_query(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
active_query(enter, idle, _Data) ->
    beam_agent_telemetry_core:state_change(codex_exec, idle, active_query),
    keep_state_and_data;
active_query(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex_exec, OldState,
                                      active_query),
    keep_state_and_data;
active_query(info,
             {Port, {data, {eol, Line}}},
             #data{port = Port} = Data) ->
    Data1 = buffer_line(Line, Data),
    process_query_buffer(Data1);
active_query(info,
             {Port, {data, {noeol, Partial}}},
             #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};
active_query(info, {Port, {exit_status, 0}}, #data{port = Port} = Data) ->
    maybe_span_stop(Data),
    Data1 = Data#data{port = undefined, query_start_time = undefined},
    drain_and_complete(Data1);
active_query(info,
             {Port, {exit_status, Status}},
             #data{port = Port} = Data) ->
    maybe_span_exception(Data, {exit_status, Status}),
    Data1 = Data#data{port = undefined, query_start_time = undefined},
    ErrorMsg =
        #{type => error,
          content =>
              iolist_to_binary(io_lib:format("codex exec exited with st"
                                             "atus ~p",
                                             [Status])),
          timestamp => erlang:system_time(millisecond)},
    deliver_or_enqueue(ErrorMsg, Data1,
                       fun(D) ->
                              {next_state, idle,
                               D#data{consumer = undefined,
                                      query_ref = undefined}}
                       end);
active_query({call, From},
             {receive_message, Ref},
             #data{query_ref = Ref} = Data) ->
    try_deliver_message(From, Data);
active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};
active_query({call, From}, interrupt, Data) ->
    maybe_span_exception(Data, interrupted),
    codex_port_utils:close_port(Data#data.port),
    Data1 = Data#data{port = undefined, query_start_time = undefined},
    {next_state, idle,
     Data1#data{consumer = undefined, query_ref = undefined},
     [{reply, From, ok}]};
active_query(info, {'EXIT', _Port, _Reason}, _Data) ->
    keep_state_and_data;
active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};
active_query({call, From}, session_info, Data) ->
    Info =
        #{model => Data#data.model,
          approval_policy => Data#data.approval_policy,
          transport => exec},
    {keep_state_and_data, [{reply, From, {ok, Info}}]};
active_query({call, From}, {send_control, _Method, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_supported}}]};
active_query({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]}.
-spec error(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
error(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex_exec, OldState, error),
    keep_state_and_data;
error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};
error({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.
-spec do_exec_query(gen_statem:from(), binary(), map(), #data{}) ->
                       state_callback_result().
do_exec_query(From, Prompt, Params, Data) ->
    Ref = make_ref(),
    StartTime =
        beam_agent_telemetry_core:span_start(codex_exec, query,
                                        #{prompt_length => byte_size(Prompt)}),
    Model = maps:get(model, Params, Data#data.model),
    AP = maps:get(approval_policy, Params, Data#data.approval_policy),
    try
        {CliPath, PortOpts} =
            build_port_opts(Data#data.cli_path,
                            Prompt,
                            #{model => Model, approval_policy => AP}),
        Port = open_port({spawn_executable, CliPath}, PortOpts),
        Data1 =
            Data#data{port = Port,
                      buffer = <<>>,
                      consumer = From,
                      query_ref = Ref,
                      msg_queue = queue:new(),
                      query_start_time = StartTime},
        {next_state, active_query, Data1, [{reply, From, {ok, Ref}}]}
    catch
        error:Reason ->
            beam_agent_telemetry_core:span_exception(codex_exec, query,
                                                Reason),
            {keep_state_and_data,
             [{reply, From, {error, {open_port_failed, Reason}}}]}
    end.
-spec build_port_opts(string(), binary(), map()) -> {string(), list()}.
build_port_opts(CliPath, Prompt, Opts) ->
    Env = [{"CODEX_SDK_VERSION", "0.1.0"}],
    Args = build_exec_args(Prompt, Opts),
    {CliPath,
     [{args, Args},
      {line, 65536},
      binary, exit_status, use_stdio,
      {env, Env}]}.
-spec build_exec_args(binary(), map()) -> [string()].
build_exec_args(Prompt, Opts) ->
    Base = ["exec", "--output-format", "jsonl"],
    WithModel =
        case maps:get(model, Opts, undefined) of
            undefined ->
                Base;
            Model when is_binary(Model) ->
                Base ++ ["--model", binary_to_list(Model)]
        end,
    WithApproval =
        case maps:get(approval_policy, Opts, undefined) of
            undefined ->
                WithModel;
            Policy when is_binary(Policy) ->
                WithModel ++ ["--approval-mode", binary_to_list(Policy)]
        end,
    WithApproval ++ [binary_to_list(Prompt)].
-spec buffer_line(binary(), #data{}) -> #data{}.
buffer_line(Line, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer = codex_port_utils:buffer_line(Line, Buffer, Max)}.
-spec append_buffer(binary(), #data{}) -> #data{}.
append_buffer(Partial, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer =
                  codex_port_utils:append_buffer(Partial, Buffer, Max)}.
-spec process_query_buffer(#data{}) -> state_callback_result().
process_query_buffer(Data) ->
    case beam_agent_jsonl:extract_line(Data#data.buffer) of
        none ->
            {keep_state, Data};
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    Msg = beam_agent_core:normalize_message(Map),
                    deliver_or_enqueue(Msg, Data1,
                                       fun(D) ->
                                              process_query_buffer(D)
                                       end);
                {error, _} ->
                    process_query_buffer(Data1)
            end
    end.
-spec drain_and_complete(#data{}) -> state_callback_result().
drain_and_complete(Data) ->
    case beam_agent_jsonl:extract_line(Data#data.buffer) of
        none ->
            case Data#data.consumer of
                undefined ->
                    {next_state, idle, Data};
                From ->
                    {next_state, idle,
                     Data#data{consumer = undefined},
                     [{reply, From, {error, complete}}]}
            end;
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    Msg = beam_agent_core:normalize_message(Map),
                    deliver_or_enqueue(Msg, Data1,
                                       fun(D) ->
                                              drain_and_complete(D)
                                       end);
                {error, _} ->
                    drain_and_complete(Data1)
            end
    end.
-spec try_deliver_message(gen_statem:from(), #data{}) ->
                             state_callback_result().
try_deliver_message(From, #data{msg_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state,
             Data#data{msg_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            Data1 = Data#data{consumer = From},
            case Data1#data.port of
                undefined ->
                    {next_state, idle,
                     Data1#data{consumer = undefined,
                                query_ref = undefined},
                     [{reply, From, {error, complete}}]};
                _ ->
                    {keep_state, Data1}
            end
    end.
-spec deliver_or_enqueue(beam_agent_core:message(),
                         #data{},
                         fun((#data{}) -> state_callback_result())) ->
                            state_callback_result().
deliver_or_enqueue(Msg,
                   #data{consumer = undefined, msg_queue = Q} = Data,
                   Continue) ->
    Q1 = queue:in(Msg, Q),
    Continue(Data#data{msg_queue = Q1});
deliver_or_enqueue(Msg, #data{consumer = From} = Data, Continue) ->
    Data1 = Data#data{consumer = undefined},
    case Continue(Data1) of
        {next_state, NewState, NewData} ->
            {next_state, NewState, NewData, [{reply, From, {ok, Msg}}]};
        {next_state, NewState, NewData, Actions} ->
            {next_state, NewState, NewData,
             [{reply, From, {ok, Msg}} | Actions]};
        {keep_state, NewData} ->
            {keep_state, NewData, [{reply, From, {ok, Msg}}]};
        {keep_state, NewData, Actions} ->
            {keep_state, NewData, [{reply, From, {ok, Msg}} | Actions]}
    end.
-spec fire_hook(beam_agent_hooks_core:hook_event(),
                beam_agent_hooks_core:hook_context(),
                #data{}) ->
                   ok | {deny, binary()}.
fire_hook(Event, Context, #data{sdk_hook_registry = Registry}) ->
    beam_agent_hooks_core:fire(Event, Context, Registry).
-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) ->
    ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    beam_agent_telemetry_core:span_stop(codex_exec, query, StartTime).
-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) ->
    ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    beam_agent_telemetry_core:span_exception(codex_exec, query, Reason).

