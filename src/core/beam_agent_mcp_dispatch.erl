-module(beam_agent_mcp_dispatch).
-moduledoc """
MCP method dispatch, lifecycle state machine, and provider behaviour.

This module routes incoming MCP JSON-RPC messages to the correct handler
based on the negotiated session capabilities and current lifecycle state.
It is a pure-function dispatch layer — **not** a process. The caller
(typically `beam_agent_tool_registry` or a session handler) owns the state
and passes it through on each call.

## Lifecycle

The MCP session progresses through three states:

  1. `uninitialized` — only `initialize` and `ping` are accepted
  2. `initializing`  — waiting for `notifications/initialized`
  3. `ready`         — all capability-gated methods available

The `handle_message/2` function enforces these rules.

## Provider Behaviour

Resource, prompt, completion, and logging operations delegate to a
**provider** callback module implementing `beam_agent_mcp_provider`.
If no provider is configured, those methods return `-32601` (method
not found). Tool operations still route through `beam_agent_tool_registry`.

## Usage

```erlang
%% Create a dispatch state during session init
State = beam_agent_mcp_dispatch:new(ServerInfo, ServerCaps, #{
    tool_registry => Registry,
    provider => my_mcp_provider,
    provider_state => ProviderState
}),

%% On each incoming message:
{Response, NewState} = beam_agent_mcp_dispatch:handle_message(Msg, State)
```
""".

-export([
    %% State management
    new/3,
    lifecycle_state/1,
    session_capabilities/1,

    %% Message dispatch
    handle_message/2
]).

-export_type([
    dispatch_state/0,
    dispatch_result/0
]).

%%--------------------------------------------------------------------
%% Provider Behaviour
%%--------------------------------------------------------------------

-doc """
Callback behaviour for MCP capability providers.

Implement this behaviour to supply resources, prompts, completions,
and logging to the MCP dispatch layer. Tool dispatch is handled
separately via `beam_agent_tool_registry`.

All callbacks receive the provider state and return
`{ok, Result, NewProviderState}` or `{error, ErrorCode, ErrorMsg}`.

Only implement the callbacks for capabilities your server advertises.
The dispatch layer checks capabilities before calling a provider
callback, so unimplemented callbacks for unadvertised capabilities
will never be called.
""".

-callback handle_resources_list(Cursor :: binary() | undefined,
                                ProviderState :: term()) ->
    {ok, {[beam_agent_mcp_protocol:resource()],
          NextCursor :: binary() | undefined}, term()}
  | {error, integer(), binary()}.

-callback handle_resources_read(Uri :: binary(),
                                ProviderState :: term()) ->
    {ok, [beam_agent_mcp_protocol:resource_contents()], term()}
  | {error, integer(), binary()}.

-callback handle_resources_templates_list(Cursor :: binary() | undefined,
                                          ProviderState :: term()) ->
    {ok, {[beam_agent_mcp_protocol:resource_template()],
          NextCursor :: binary() | undefined}, term()}
  | {error, integer(), binary()}.

-callback handle_prompts_list(Cursor :: binary() | undefined,
                              ProviderState :: term()) ->
    {ok, {[beam_agent_mcp_protocol:prompt()],
          NextCursor :: binary() | undefined}, term()}
  | {error, integer(), binary()}.

-callback handle_prompts_get(Name :: binary(),
                             Arguments :: map(),
                             ProviderState :: term()) ->
    {ok, {[beam_agent_mcp_protocol:prompt_message()],
          Description :: binary() | undefined}, term()}
  | {error, integer(), binary()}.

-callback handle_completion_complete(
    Ref :: beam_agent_mcp_protocol:completion_ref(),
    Argument :: map(),
    Context :: map() | undefined,
    ProviderState :: term()) ->
    {ok, beam_agent_mcp_protocol:completion_result(), term()}
  | {error, integer(), binary()}.

-callback handle_logging_set_level(Level :: beam_agent_mcp_protocol:log_level(),
                                   ProviderState :: term()) ->
    {ok, term()} | {error, integer(), binary()}.

-optional_callbacks([
    handle_resources_list/2,
    handle_resources_read/2,
    handle_resources_templates_list/2,
    handle_prompts_list/2,
    handle_prompts_get/3,
    handle_completion_complete/4,
    handle_logging_set_level/2
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type lifecycle() :: uninitialized | initializing | ready.

-type dispatch_state() :: #{
    lifecycle := lifecycle(),
    server_info := beam_agent_mcp_protocol:implementation_info(),
    server_capabilities := beam_agent_mcp_protocol:server_capabilities(),
    session_capabilities => beam_agent_mcp_protocol:session_capabilities(),
    tool_registry => beam_agent_tool_registry:mcp_registry(),
    handler_timeout => pos_integer(),
    provider => module(),
    provider_state => term()
}.

-type dispatch_result() :: {map() | noreply, dispatch_state()}.

%% Default tool handler timeout (30 seconds).
-define(DEFAULT_HANDLER_TIMEOUT, 30000).

%%====================================================================
%% State Management
%%====================================================================

-doc """
Create a new dispatch state.

`ServerInfo` is the server's implementation info for the initialize
response. `ServerCaps` declares which capabilities this server supports.

Options:
  - `tool_registry` — `beam_agent_tool_registry:mcp_registry()` for tool dispatch
  - `handler_timeout` — timeout in ms for tool handlers (default: 30000)
  - `provider` — callback module implementing `beam_agent_mcp_provider`
  - `provider_state` — opaque state passed to provider callbacks
""".
-spec new(beam_agent_mcp_protocol:implementation_info(),
          beam_agent_mcp_protocol:server_capabilities(),
          map()) -> dispatch_state().
new(ServerInfo, ServerCaps, Opts)
  when is_map(ServerInfo), is_map(ServerCaps), is_map(Opts) ->
    Base = #{
        lifecycle => uninitialized,
        server_info => ServerInfo,
        server_capabilities => ServerCaps
    },
    MergeKeys = [tool_registry, handler_timeout, provider, provider_state],
    lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Opts) of
            {ok, Val} -> Acc#{Key => Val};
            error -> Acc
        end
    end, Base, MergeKeys).

-doc "Return the current lifecycle state.".
-spec lifecycle_state(dispatch_state()) -> lifecycle().
lifecycle_state(#{lifecycle := State}) -> State.

-doc """
Return the negotiated session capabilities.

Only available after the initialize handshake completes (lifecycle = ready).
Returns `undefined` if not yet negotiated.
""".
-spec session_capabilities(dispatch_state()) ->
    beam_agent_mcp_protocol:session_capabilities() | undefined.
session_capabilities(State) ->
    maps:get(session_capabilities, State, undefined).

%%====================================================================
%% Message Dispatch
%%====================================================================

-doc """
Dispatch an incoming MCP JSON-RPC message.

Validates the message, checks lifecycle state, and routes to the
appropriate handler. Returns a `{Response, NewState}` tuple.

`Response` is either a JSON-RPC response map (to send back to the
peer) or `noreply` for notifications that require no response.
""".
-spec handle_message(map(), dispatch_state()) -> dispatch_result().
handle_message(RawMsg, State) ->
    case beam_agent_mcp_protocol:validate_message(RawMsg) of
        {request, Id, Method, Params} ->
            dispatch_request(Id, Method, Params, State);
        {notification, Method, Params} ->
            dispatch_notification(Method, Params, State);
        {response, _Id, _Result} ->
            %% We are a server; responses from clients are unexpected
            %% in this dispatch path. Ignore silently.
            {noreply, State};
        {error_response, _Id, _Code, _Msg, _Data} ->
            %% Same — error responses from clients are not actionable here
            {noreply, State};
        {invalid, Reason} ->
            ErrMsg = iolist_to_binary(
                io_lib:format("Invalid message: ~p", [Reason])),
            %% No id available for invalid messages; use null
            Resp = beam_agent_mcp_protocol:error_response(
                       null,
                       beam_agent_mcp_protocol:error_invalid_request(),
                       ErrMsg),
            {Resp, State}
    end.

%%--------------------------------------------------------------------
%% Internal: Request Dispatch
%%--------------------------------------------------------------------

-spec dispatch_request(beam_agent_mcp_protocol:request_id(), binary(),
                       map(), dispatch_state()) -> dispatch_result().

%% -- ping: always allowed, any state --
dispatch_request(Id, <<"ping">>, _Params, State) ->
    {beam_agent_mcp_protocol:ping_response(Id), State};

%% -- initialize: only in uninitialized state --
dispatch_request(Id, <<"initialize">>, Params,
                 #{lifecycle := uninitialized} = State) ->
    handle_initialize(Id, Params, State);
dispatch_request(Id, <<"initialize">>, _Params, State) ->
    {method_error(Id, <<"initialize not allowed in current state">>), State};

%% -- All other requests require ready state --
dispatch_request(Id, _Method, _Params,
                 #{lifecycle := Lifecycle} = State)
  when Lifecycle =/= ready ->
    ErrMsg = <<"Server not ready; initialize handshake incomplete">>,
    {beam_agent_mcp_protocol:error_response(
         Id, beam_agent_mcp_protocol:error_invalid_request(), ErrMsg),
     State};

%% -- Tool methods --
dispatch_request(Id, <<"tools/list">>, Params, State) ->
    handle_tools_list(Id, Params, State);
dispatch_request(Id, <<"tools/call">>, Params, State) ->
    handle_tools_call(Id, Params, State);

%% -- Resource methods --
dispatch_request(Id, <<"resources/list">>, Params, State) ->
    dispatch_provider(Id, <<"resources/list">>, resources,
                      fun handle_resources_list/3, Params, State);
dispatch_request(Id, <<"resources/read">>, Params, State) ->
    dispatch_provider(Id, <<"resources/read">>, resources,
                      fun handle_resources_read/3, Params, State);
dispatch_request(Id, <<"resources/templates/list">>, Params, State) ->
    dispatch_provider(Id, <<"resources/templates/list">>, resources,
                      fun handle_resources_templates_list/3, Params, State);
dispatch_request(Id, <<"resources/subscribe">>, Params, State) ->
    handle_resources_subscribe(Id, Params, State);
dispatch_request(Id, <<"resources/unsubscribe">>, Params, State) ->
    handle_resources_unsubscribe(Id, Params, State);

%% -- Prompt methods --
dispatch_request(Id, <<"prompts/list">>, Params, State) ->
    dispatch_provider(Id, <<"prompts/list">>, prompts,
                      fun handle_prompts_list/3, Params, State);
dispatch_request(Id, <<"prompts/get">>, Params, State) ->
    dispatch_provider(Id, <<"prompts/get">>, prompts,
                      fun handle_prompts_get/3, Params, State);

%% -- Completion methods --
dispatch_request(Id, <<"completion/complete">>, Params, State) ->
    dispatch_provider(Id, <<"completion/complete">>, completions,
                      fun handle_completion_complete/3, Params, State);

%% -- Logging methods --
dispatch_request(Id, <<"logging/setLevel">>, Params, State) ->
    dispatch_provider(Id, <<"logging/setLevel">>, logging,
                      fun handle_logging_set_level/3, Params, State);

%% -- Unknown method --
dispatch_request(Id, Method, _Params, State) ->
    {method_not_found(Id, Method), State}.

%%--------------------------------------------------------------------
%% Internal: Notification Dispatch
%%--------------------------------------------------------------------

-spec dispatch_notification(binary(), map(), dispatch_state()) ->
    dispatch_result().

%% -- initialized: transition from initializing to ready --
dispatch_notification(<<"notifications/initialized">>, _Params,
                      #{lifecycle := initializing} = State) ->
    {noreply, State#{lifecycle => ready}};
dispatch_notification(<<"notifications/initialized">>, _Params, State) ->
    %% Ignore if not in initializing state (spec says no error for notifs)
    {noreply, State};

%% -- cancelled: acknowledge but no special handling in this layer --
dispatch_notification(<<"notifications/cancelled">>, _Params, State) ->
    {noreply, State};

%% -- progress: pass through (no server-side handling needed) --
dispatch_notification(<<"notifications/progress">>, _Params, State) ->
    {noreply, State};

%% -- roots/list_changed: acknowledge --
dispatch_notification(<<"notifications/roots/list_changed">>, _Params,
                      State) ->
    {noreply, State};

%% -- Unknown notification: ignore per spec --
dispatch_notification(_Method, _Params, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Internal: Lifecycle — Initialize
%%--------------------------------------------------------------------

-spec handle_initialize(beam_agent_mcp_protocol:request_id(), map(),
                        dispatch_state()) -> dispatch_result().
handle_initialize(Id, Params,
                  #{server_info := ServerInfo,
                    server_capabilities := ServerCaps} = State) ->
    %% Extract client info for capability negotiation
    ClientCaps = decode_client_capabilities(
                     maps:get(<<"capabilities">>, Params, #{})),
    SessionCaps = beam_agent_mcp_protocol:negotiate_capabilities(
                      ServerCaps, ClientCaps),

    Resp = beam_agent_mcp_protocol:initialize_response(
               Id, ServerInfo, ServerCaps),

    NewState = State#{
        lifecycle => initializing,
        session_capabilities => SessionCaps
    },
    {Resp, NewState}.

%%--------------------------------------------------------------------
%% Internal: Tool Handlers
%%--------------------------------------------------------------------

-spec handle_tools_list(beam_agent_mcp_protocol:request_id(), map(),
                        dispatch_state()) -> dispatch_result().
handle_tools_list(Id, _Params, State) ->
    case maps:get(tool_registry, State, undefined) of
        undefined ->
            Resp = beam_agent_mcp_protocol:tools_list_response(Id, []),
            {Resp, State};
        Registry ->
            ToolDefs = beam_agent_tool_registry:all_tool_definitions(Registry),
            %% Convert tool_registry tool_def() to mcp_protocol tool() format
            ProtoTools = [core_tool_to_proto(T) || T <- ToolDefs],
            Resp = beam_agent_mcp_protocol:tools_list_response(
                       Id, ProtoTools),
            {Resp, State}
    end.

-spec handle_tools_call(beam_agent_mcp_protocol:request_id(), map(),
                        dispatch_state()) -> dispatch_result().
handle_tools_call(Id, Params, State) ->
    case maps:get(<<"name">>, Params, <<>>) of
        <<>> ->
            ErrResp = beam_agent_mcp_protocol:error_response(
                          Id,
                          beam_agent_mcp_protocol:error_invalid_params(),
                          <<"Missing required parameter: name">>),
            {ErrResp, State};
        ToolName ->
            Arguments = maps:get(<<"arguments">>, Params, #{}),
            Timeout = maps:get(handler_timeout, State, ?DEFAULT_HANDLER_TIMEOUT),
            case maps:get(tool_registry, State, undefined) of
                undefined ->
                    Resp = beam_agent_mcp_protocol:error_response(
                               Id,
                               beam_agent_mcp_protocol:error_method_not_found(),
                               <<"No tool registry configured">>),
                    {Resp, State};
                Registry ->
                    case beam_agent_tool_registry:call_tool_by_name(
                             ToolName, Arguments, Registry,
                             #{handler_timeout => Timeout}) of
                        {ok, ContentResults} ->
                            ProtoContent = [core_content_to_proto(C)
                                            || C <- ContentResults],
                            Result = #{content => ProtoContent},
                            Resp = beam_agent_mcp_protocol:tools_call_response(
                                       Id, Result),
                            {Resp, State};
                        {error, Reason} ->
                            ErrContent = [beam_agent_mcp_protocol:text_content(
                                              Reason)],
                            Resp = beam_agent_mcp_protocol:tools_call_response(
                                       Id, ErrContent, true),
                            {Resp, State}
                    end
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Provider Dispatch Helper
%%--------------------------------------------------------------------

%% Route a request to a provider callback if the capability is advertised
%% and a provider is configured.
-spec dispatch_provider(beam_agent_mcp_protocol:request_id(), binary(),
                        atom(),
                        fun((beam_agent_mcp_protocol:request_id(), map(), dispatch_state()) -> dispatch_result()),
                        map(), dispatch_state()) ->
    dispatch_result().
dispatch_provider(Id, Method, Capability, HandlerFun, Params, State) ->
    ServerCaps = maps:get(server_capabilities, State),
    case maps:is_key(Capability, ServerCaps) of
        false ->
            {method_not_found(Id, Method), State};
        true ->
            case maps:get(provider, State, undefined) of
                undefined ->
                    {method_not_found(Id, Method), State};
                _Provider ->
                    HandlerFun(Id, Params, State)
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Resource Handlers (delegate to provider)
%%--------------------------------------------------------------------

-spec handle_resources_list(beam_agent_mcp_protocol:request_id(), map(),
                            dispatch_state()) -> dispatch_result().
handle_resources_list(Id, Params,
                      #{provider := Provider,
                        provider_state := PState} = State) ->
    Cursor = maps:get(<<"cursor">>, Params, undefined),
    case Provider:handle_resources_list(Cursor, PState) of
        {ok, {Resources, undefined}, NewPState} ->
            Resp = beam_agent_mcp_protocol:resources_list_response(
                       Id, Resources),
            {Resp, State#{provider_state => NewPState}};
        {ok, {Resources, NextCursor}, NewPState} ->
            Resp = beam_agent_mcp_protocol:resources_list_response(
                       Id, Resources, NextCursor),
            {Resp, State#{provider_state => NewPState}};
        {error, Code, Msg} ->
            {beam_agent_mcp_protocol:error_response(Id, Code, Msg), State}
    end.

-spec handle_resources_read(beam_agent_mcp_protocol:request_id(), map(),
                            dispatch_state()) -> dispatch_result().
handle_resources_read(Id, Params,
                      #{provider := Provider,
                        provider_state := PState} = State) ->
    Uri = maps:get(<<"uri">>, Params, <<>>),
    case Uri of
        <<>> ->
            ErrResp = beam_agent_mcp_protocol:error_response(
                          Id,
                          beam_agent_mcp_protocol:error_invalid_params(),
                          <<"Missing required parameter: uri">>),
            {ErrResp, State};
        _ ->
            case Provider:handle_resources_read(Uri, PState) of
                {ok, Contents, NewPState} ->
                    Resp = beam_agent_mcp_protocol:resources_read_response(
                               Id, Contents),
                    {Resp, State#{provider_state => NewPState}};
                {error, Code, Msg} ->
                    {beam_agent_mcp_protocol:error_response(Id, Code, Msg),
                     State}
            end
    end.

-spec handle_resources_templates_list(beam_agent_mcp_protocol:request_id(),
                                      map(), dispatch_state()) ->
    dispatch_result().
handle_resources_templates_list(Id, Params,
                                #{provider := Provider,
                                  provider_state := PState} = State) ->
    Cursor = maps:get(<<"cursor">>, Params, undefined),
    case Provider:handle_resources_templates_list(Cursor, PState) of
        {ok, {Templates, undefined}, NewPState} ->
            Resp = beam_agent_mcp_protocol:resources_templates_list_response(
                       Id, Templates),
            {Resp, State#{provider_state => NewPState}};
        {ok, {Templates, NextCursor}, NewPState} ->
            Resp = beam_agent_mcp_protocol:resources_templates_list_response(
                       Id, Templates, NextCursor),
            {Resp, State#{provider_state => NewPState}};
        {error, Code, Msg} ->
            {beam_agent_mcp_protocol:error_response(Id, Code, Msg), State}
    end.

%% Subscribe/unsubscribe — acknowledge with empty result.
%% Actual subscription tracking is the provider's responsibility.
-spec handle_resources_subscribe(beam_agent_mcp_protocol:request_id(),
                                 map(), dispatch_state()) ->
    dispatch_result().
handle_resources_subscribe(Id, _Params, State) ->
    ServerCaps = maps:get(server_capabilities, State),
    ResCaps = maps:get(resources, ServerCaps, #{}),
    case maps:get(subscribe, ResCaps, false) of
        true ->
            {beam_agent_mcp_protocol:response(Id, #{}), State};
        false ->
            {method_not_found(Id, <<"resources/subscribe">>), State}
    end.

-spec handle_resources_unsubscribe(beam_agent_mcp_protocol:request_id(),
                                   map(), dispatch_state()) ->
    dispatch_result().
handle_resources_unsubscribe(Id, _Params, State) ->
    ServerCaps = maps:get(server_capabilities, State),
    ResCaps = maps:get(resources, ServerCaps, #{}),
    case maps:get(subscribe, ResCaps, false) of
        true ->
            {beam_agent_mcp_protocol:response(Id, #{}), State};
        false ->
            {method_not_found(Id, <<"resources/unsubscribe">>), State}
    end.

%%--------------------------------------------------------------------
%% Internal: Prompt Handlers (delegate to provider)
%%--------------------------------------------------------------------

-spec handle_prompts_list(beam_agent_mcp_protocol:request_id(), map(),
                          dispatch_state()) -> dispatch_result().
handle_prompts_list(Id, Params,
                    #{provider := Provider,
                      provider_state := PState} = State) ->
    Cursor = maps:get(<<"cursor">>, Params, undefined),
    case Provider:handle_prompts_list(Cursor, PState) of
        {ok, {Prompts, undefined}, NewPState} ->
            Resp = beam_agent_mcp_protocol:prompts_list_response(
                       Id, Prompts),
            {Resp, State#{provider_state => NewPState}};
        {ok, {Prompts, NextCursor}, NewPState} ->
            Resp = beam_agent_mcp_protocol:prompts_list_response(
                       Id, Prompts, NextCursor),
            {Resp, State#{provider_state => NewPState}};
        {error, Code, Msg} ->
            {beam_agent_mcp_protocol:error_response(Id, Code, Msg), State}
    end.

-spec handle_prompts_get(beam_agent_mcp_protocol:request_id(), map(),
                         dispatch_state()) -> dispatch_result().
handle_prompts_get(Id, Params,
                   #{provider := Provider,
                     provider_state := PState} = State) ->
    Name = maps:get(<<"name">>, Params, <<>>),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    case Name of
        <<>> ->
            ErrResp = beam_agent_mcp_protocol:error_response(
                          Id,
                          beam_agent_mcp_protocol:error_invalid_params(),
                          <<"Missing required parameter: name">>),
            {ErrResp, State};
        _ ->
            case Provider:handle_prompts_get(Name, Arguments, PState) of
                {ok, {Messages, undefined}, NewPState} ->
                    Resp = beam_agent_mcp_protocol:prompts_get_response(
                               Id, Messages),
                    {Resp, State#{provider_state => NewPState}};
                {ok, {Messages, Description}, NewPState} ->
                    Resp = beam_agent_mcp_protocol:prompts_get_response(
                               Id, Messages, Description),
                    {Resp, State#{provider_state => NewPState}};
                {error, Code, Msg} ->
                    {beam_agent_mcp_protocol:error_response(Id, Code, Msg),
                     State}
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Completion Handler (delegate to provider)
%%--------------------------------------------------------------------

-spec handle_completion_complete(beam_agent_mcp_protocol:request_id(),
                                 map(), dispatch_state()) ->
    dispatch_result().
handle_completion_complete(Id, Params,
                           #{provider := Provider,
                             provider_state := PState} = State) ->
    Ref = maps:get(<<"ref">>, Params, #{}),
    Argument = maps:get(<<"argument">>, Params, #{}),
    Context = maps:get(<<"context">>, Params, undefined),
    case Provider:handle_completion_complete(Ref, Argument, Context,
                                             PState) of
        {ok, CompResult, NewPState} ->
            Resp = beam_agent_mcp_protocol:completion_complete_response(
                       Id, CompResult),
            {Resp, State#{provider_state => NewPState}};
        {error, Code, Msg} ->
            {beam_agent_mcp_protocol:error_response(Id, Code, Msg), State}
    end.

%%--------------------------------------------------------------------
%% Internal: Logging Handler (delegate to provider)
%%--------------------------------------------------------------------

-spec handle_logging_set_level(beam_agent_mcp_protocol:request_id(),
                               map(), dispatch_state()) ->
    dispatch_result().
handle_logging_set_level(Id, Params,
                         #{provider := Provider,
                           provider_state := PState} = State) ->
    LevelBin = maps:get(<<"level">>, Params, <<"info">>),
    Level = safe_log_level(LevelBin),
    case Provider:handle_logging_set_level(Level, PState) of
        {ok, NewPState} ->
            Resp = beam_agent_mcp_protocol:logging_set_level_response(Id),
            {Resp, State#{provider_state => NewPState}};
        {error, Code, Msg} ->
            {beam_agent_mcp_protocol:error_response(Id, Code, Msg), State}
    end.

%%--------------------------------------------------------------------
%% Internal: Conversions
%%--------------------------------------------------------------------

%% Convert a beam_agent_tool_registry tool_def() to a protocol tool().
-spec core_tool_to_proto(beam_agent_tool_registry:tool_def()) ->
    beam_agent_mcp_protocol:tool().
core_tool_to_proto(#{name := Name, input_schema := Schema} = Tool) ->
    Base = #{name => Name, inputSchema => Schema},
    maybe_put(description, maps:get(description, Tool, undefined), Base).

%% Convert a beam_agent_tool_registry content_result() to protocol content().
-spec core_content_to_proto(beam_agent_tool_registry:content_result()) ->
    beam_agent_mcp_protocol:content().
core_content_to_proto(#{type := text, text := Text}) ->
    #{type => text, text => Text};
core_content_to_proto(#{type := image, data := Data,
                        mime_type := MimeType}) ->
    #{type => image, data => Data, mimeType => MimeType}.

%%--------------------------------------------------------------------
%% Internal: Error Helpers
%%--------------------------------------------------------------------

-spec method_not_found(beam_agent_mcp_protocol:request_id(),
                       binary()) -> map().
method_not_found(Id, Method) ->
    beam_agent_mcp_protocol:error_response(
        Id,
        beam_agent_mcp_protocol:error_method_not_found(),
        <<"Method not found: ", Method/binary>>).

-spec method_error(beam_agent_mcp_protocol:request_id(),
                   binary()) -> map().
method_error(Id, Msg) ->
    beam_agent_mcp_protocol:error_response(
        Id,
        beam_agent_mcp_protocol:error_invalid_request(),
        Msg).

%%--------------------------------------------------------------------
%% Internal: Utilities
%%--------------------------------------------------------------------

%% Decode client capabilities from wire format to Erlang atoms.
%% Delegates to the shared protocol decoder.
-spec decode_client_capabilities(map()) ->
    beam_agent_mcp_protocol:client_capabilities().
decode_client_capabilities(WireCaps) ->
    beam_agent_mcp_protocol:decode_wire_capabilities(WireCaps).

%% Safe binary-to-atom for log levels.
-spec safe_log_level(binary()) -> beam_agent_mcp_protocol:log_level().
safe_log_level(<<"debug">>) -> debug;
safe_log_level(<<"info">>) -> info;
safe_log_level(<<"notice">>) -> notice;
safe_log_level(<<"warning">>) -> warning;
safe_log_level(<<"error">>) -> error;
safe_log_level(<<"critical">>) -> critical;
safe_log_level(<<"alert">>) -> alert;
safe_log_level(<<"emergency">>) -> emergency;
safe_log_level(_) -> info.

%% Add a key-value pair to a map only if Value is not `undefined`.
-spec maybe_put(atom(), term(), map()) -> map().
maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.
