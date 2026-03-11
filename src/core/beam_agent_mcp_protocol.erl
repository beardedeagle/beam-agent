-module(beam_agent_mcp_protocol).
-moduledoc """
MCP (Model Context Protocol) 2025-06-18 protocol types, message
constructors, capability negotiation, and validation.

This module is the protocol's pure-function layer. It owns:

  - Erlang types for every MCP primitive (Tool, Resource, Prompt,
    Root, SamplingMessage, etc.)
  - Message constructors that produce spec-compliant JSON-RPC 2.0 maps
  - Capability negotiation logic for the initialize/initialized handshake
  - Message validation for incoming JSON-RPC messages

It deliberately has **no side effects** — no processes, no ETS, no I/O.
The dispatch layer (`beam_agent_mcp_dispatch`, Phase 2) and the existing
`beam_agent_tool_registry` both consume this module.

## Protocol Version

This module targets MCP spec version `2025-06-18`. The protocol version
string is available via `protocol_version/0`.

## JSON-RPC 2.0 Compliance

Unlike `beam_agent_jsonrpc` (which is Codex-specific and omits the
`"jsonrpc"` field), this module always includes `"jsonrpc": "2.0"` in
all constructed messages, as required by the MCP specification.

## Capability Families

Server-side: tools, resources, prompts, completions, logging
Client-side: roots, sampling, elicitation

Each capability may declare sub-features (e.g., `listChanged` for tools,
`subscribe` for resources). The `negotiate_capabilities/2` function
resolves advertised capabilities into a session capability set.
""".

%%--------------------------------------------------------------------
%% Exports
%%--------------------------------------------------------------------

-export([
    %% Protocol metadata
    protocol_version/0,

    %% JSON-RPC 2.0 envelope constructors
    request/3,
    request/4,
    response/2,
    error_response/3,
    error_response/4,
    notification/1,
    notification/2,

    %% Lifecycle messages
    initialize_request/3,
    initialize_response/3,
    initialized_notification/0,
    ping_request/1,
    ping_response/1,

    %% Tool messages
    tools_list_request/1,
    tools_list_request/2,
    tools_list_response/2,
    tools_list_response/3,
    tools_call_request/3,
    tools_call_request/4,
    tools_call_response/2,
    tools_call_response/3,
    tools_list_changed_notification/0,

    %% Resource messages
    resources_list_request/1,
    resources_list_request/2,
    resources_list_response/2,
    resources_list_response/3,
    resources_read_request/2,
    resources_read_response/2,
    resources_templates_list_request/1,
    resources_templates_list_request/2,
    resources_templates_list_response/2,
    resources_templates_list_response/3,
    resources_subscribe_request/2,
    resources_unsubscribe_request/2,
    resources_list_changed_notification/0,
    resource_updated_notification/1,

    %% Prompt messages
    prompts_list_request/1,
    prompts_list_request/2,
    prompts_list_response/2,
    prompts_list_response/3,
    prompts_get_request/2,
    prompts_get_request/3,
    prompts_get_response/2,
    prompts_get_response/3,
    prompts_list_changed_notification/0,

    %% Completion messages
    completion_complete_request/3,
    completion_complete_request/4,
    completion_complete_response/2,

    %% Logging messages
    logging_set_level_request/2,
    logging_set_level_response/1,
    logging_message_notification/3,

    %% Sampling messages (server → client)
    sampling_create_message_request/2,
    sampling_create_message_response/2,

    %% Elicitation messages (server → client)
    elicitation_create_request/3,
    elicitation_create_response/2,

    %% Roots messages (server → client)
    roots_list_request/1,
    roots_list_response/2,
    roots_list_changed_notification/0,

    %% Progress & cancellation notifications
    progress_notification/2,
    progress_notification/3,
    progress_notification/4,
    cancelled_notification/1,
    cancelled_notification/2,

    %% Capability negotiation
    negotiate_capabilities/2,
    default_server_capabilities/0,
    default_client_capabilities/0,
    capability_supported/2,

    %% Validation
    validate_message/1,
    validate_tool/1,
    validate_resource/1,
    validate_prompt/1,

    %% Content constructors
    text_content/1,
    image_content/2,
    audio_content/2,
    resource_content/1,
    resource_link_content/2,
    resource_link_content/3,

    %% Type constructors
    implementation_info/2,
    implementation_info/3,
    tool_annotation/0,
    tool_annotation/1,
    resource_annotation/0,
    resource_annotation/1,
    model_preferences/0,
    model_preferences/1,

    %% Error codes
    error_parse/0,
    error_invalid_request/0,
    error_method_not_found/0,
    error_invalid_params/0,
    error_internal/0,
    error_resource_not_found/0,

    %% Wire-format capability decoding (shared by server + client dispatch)
    decode_wire_capabilities/1,
    safe_capability_atom/1
]).

-export_type([
    request_id/0,
    progress_token/0,
    cursor/0,
    protocol_version/0,
    %% JSON-RPC envelope return types
    jsonrpc_id_msg/0,
    jsonrpc_notif/0,
    jsonrpc_notif_params/0,
    %% Capability types
    server_capabilities/0,
    client_capabilities/0,
    session_capabilities/0,
    implementation_info/0,
    %% Content types
    content/0,
    text_content/0,
    image_content/0,
    audio_content/0,
    resource_content/0,
    resource_link_content/0,
    %% Tool types
    tool/0,
    tool_annotation/0,
    call_tool_result/0,
    %% Resource types
    resource/0,
    resource_template/0,
    resource_contents/0,
    resource_annotation/0,
    %% Prompt types
    prompt/0,
    prompt_argument/0,
    prompt_message/0,
    %% Root types
    root/0,
    %% Sampling types
    sampling_message/0,
    model_preferences/0,
    model_hint/0,
    create_message_result/0,
    %% Elicitation types
    elicitation_result/0,
    elicitation_action/0,
    %% Completion types
    completion_ref/0,
    completion_result/0,
    %% Logging types
    log_level/0,
    %% Notification types
    jsonrpc_message/0
]).

%%--------------------------------------------------------------------
%% Types — Protocol Primitives
%%--------------------------------------------------------------------

-type request_id() :: binary() | integer() | null.
-type progress_token() :: binary() | integer().
-type cursor() :: binary().
-type protocol_version() :: <<_:80>>.

%%--------------------------------------------------------------------
%% Types — JSON-RPC Envelope Return Types
%%--------------------------------------------------------------------

%% Return type for JSON-RPC messages containing an <<"id">> field
%% (requests, responses, error responses). The 16-bit minimum key size
%% reflects <<"id">> being the shortest key at 2 bytes.
-type jsonrpc_id_msg() :: #{<<_:16, _:_*8>> => term()}.

%% Return type for JSON-RPC notifications (no <<"id">> field).
%% The 48-bit minimum reflects <<"method">> being the shortest key at 6 bytes.
-type jsonrpc_notif() :: #{<<_:48, _:_*8>> => binary()}.

%% Return type for JSON-RPC notifications carrying a params map.
-type jsonrpc_notif_params() :: #{<<_:48, _:_*8>> => binary() | map()}.

%%--------------------------------------------------------------------
%% Types — JSON-RPC Message Classification
%%--------------------------------------------------------------------

-type jsonrpc_message() ::
    {request, request_id(), binary(), map()}
  | {notification, binary(), map()}
  | {response, request_id(), term()}
  | {error_response, request_id(), integer(), binary(), term()}
  | {invalid, term()}.

%%--------------------------------------------------------------------
%% Types — Implementation Info
%%--------------------------------------------------------------------

-type implementation_info() :: #{
    name := binary(),
    version := binary(),
    title => binary()
}.

%%--------------------------------------------------------------------
%% Types — Capabilities
%%--------------------------------------------------------------------

-type server_capabilities() :: #{
    tools => #{listChanged => boolean()},
    resources => #{subscribe => boolean(), listChanged => boolean()},
    prompts => #{listChanged => boolean()},
    completions => #{},
    logging => #{}
}.

-type client_capabilities() :: #{
    roots => #{listChanged => boolean()},
    sampling => #{},
    elicitation => #{}
}.

-type session_capabilities() :: #{
    server := server_capabilities(),
    client := client_capabilities(),
    protocol_version := protocol_version()
}.

%%--------------------------------------------------------------------
%% Types — Content
%%--------------------------------------------------------------------

-type text_content() :: #{
    type := text,
    text := binary(),
    annotations => resource_annotation()
}.

-type image_content() :: #{
    type := image,
    data := binary(),
    mimeType := binary(),
    annotations => resource_annotation()
}.

-type audio_content() :: #{
    type := audio,
    data := binary(),
    mimeType := binary(),
    annotations => resource_annotation()
}.

-type resource_content() :: #{
    type := resource,
    resource := resource_contents(),
    annotations => resource_annotation()
}.

-type resource_link_content() :: #{
    type := resource_link,
    uri := binary(),
    name => binary(),
    description => binary(),
    mimeType => binary(),
    annotations => resource_annotation()
}.

-type content() :: text_content()
                 | image_content()
                 | audio_content()
                 | resource_content()
                 | resource_link_content().

%%--------------------------------------------------------------------
%% Types — Tools
%%--------------------------------------------------------------------

-type tool_annotation() :: #{
    title => binary(),
    readOnlyHint => boolean(),
    destructiveHint => boolean(),
    idempotentHint => boolean(),
    openWorldHint => boolean()
}.

-type tool() :: #{
    name := binary(),
    title => binary(),
    description => binary(),
    inputSchema := map(),
    outputSchema => map(),
    annotations => tool_annotation()
}.

-type call_tool_result() :: #{
    content := [content()],
    isError => boolean(),
    structuredContent => map()
}.

%%--------------------------------------------------------------------
%% Types — Resources
%%--------------------------------------------------------------------

-type resource_annotation() :: #{
    audience => [binary()],
    priority => float(),
    lastModified => binary()
}.

-type resource() :: #{
    uri := binary(),
    name := binary(),
    title => binary(),
    description => binary(),
    mimeType => binary(),
    size => non_neg_integer(),
    annotations => resource_annotation()
}.

-type resource_template() :: #{
    uriTemplate := binary(),
    name := binary(),
    title => binary(),
    description => binary(),
    mimeType => binary(),
    annotations => resource_annotation()
}.

-type resource_contents() :: #{
    uri := binary(),
    mimeType => binary(),
    text => binary(),
    blob => binary()
}.

%%--------------------------------------------------------------------
%% Types — Prompts
%%--------------------------------------------------------------------

-type prompt_argument() :: #{
    name := binary(),
    description => binary(),
    required => boolean()
}.

-type prompt() :: #{
    name := binary(),
    title => binary(),
    description => binary(),
    arguments => [prompt_argument()]
}.

-type prompt_message() :: #{
    role := binary(),
    content := content()
}.

%%--------------------------------------------------------------------
%% Types — Roots
%%--------------------------------------------------------------------

-type root() :: #{
    uri := binary(),
    name => binary()
}.

%%--------------------------------------------------------------------
%% Types — Sampling
%%--------------------------------------------------------------------

-type model_hint() :: #{
    name => binary()
}.

-type model_preferences() :: #{
    hints => [model_hint()],
    costPriority => float(),
    speedPriority => float(),
    intelligencePriority => float()
}.

-type sampling_message() :: #{
    role := binary(),
    content := content()
}.

-type create_message_result() :: #{
    role := binary(),
    content := content(),
    model := binary(),
    stopReason => binary()
}.

%%--------------------------------------------------------------------
%% Types — Elicitation
%%--------------------------------------------------------------------

-type elicitation_action() :: accept | decline | cancel.

-type elicitation_result() :: #{
    action := elicitation_action(),
    content => map()
}.

%%--------------------------------------------------------------------
%% Types — Completion
%%--------------------------------------------------------------------

-type completion_ref() ::
    #{type := binary(), name := binary()}
  | #{type := binary(), uri := binary()}.

-type completion_result() :: #{
    values := [binary()],
    total => non_neg_integer(),
    hasMore => boolean()
}.

%%--------------------------------------------------------------------
%% Types — Logging
%%--------------------------------------------------------------------

-type log_level() :: debug | info | notice | warning
                   | error | critical | alert | emergency.

%%--------------------------------------------------------------------
%% Error Codes (MCP / JSON-RPC 2.0)
%%--------------------------------------------------------------------

-doc "JSON-RPC 2.0 parse error (-32700).".
-spec error_parse() -> -32700.
error_parse() -> -32700.

-doc "JSON-RPC 2.0 invalid request (-32600).".
-spec error_invalid_request() -> -32600.
error_invalid_request() -> -32600.

-doc "JSON-RPC 2.0 method not found (-32601).".
-spec error_method_not_found() -> -32601.
error_method_not_found() -> -32601.

-doc "JSON-RPC 2.0 invalid params (-32602).".
-spec error_invalid_params() -> -32602.
error_invalid_params() -> -32602.

-doc "JSON-RPC 2.0 internal error (-32603).".
-spec error_internal() -> -32603.
error_internal() -> -32603.

-doc "MCP resource not found (-32002).".
-spec error_resource_not_found() -> -32002.
error_resource_not_found() -> -32002.

%%--------------------------------------------------------------------
%% Protocol Metadata
%%--------------------------------------------------------------------

-doc "Return the MCP protocol version this module implements.".
-spec protocol_version() -> protocol_version().
protocol_version() -> <<"2025-06-18">>.

%%====================================================================
%% JSON-RPC 2.0 Envelope Constructors
%%====================================================================

-doc """
Construct a JSON-RPC 2.0 request (no params).

Always includes `"jsonrpc": "2.0"` as required by the MCP spec.
""".
-spec request(request_id(), binary(), map()) -> jsonrpc_id_msg().
request(Id, Method, Params) when is_map(Params) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"method">> => Method,
      <<"params">> => Params}.

-doc "Construct a JSON-RPC 2.0 request with `_meta` progress token.".
-spec request(request_id(), binary(), map(), progress_token()) -> jsonrpc_id_msg().
request(Id, Method, Params, ProgressToken) when is_map(Params) ->
    Meta = #{<<"progressToken">> => ProgressToken},
    ParamsWithMeta = Params#{<<"_meta">> => Meta},
    request(Id, Method, ParamsWithMeta).

-doc "Construct a JSON-RPC 2.0 successful response.".
-spec response(request_id(), term()) -> jsonrpc_id_msg().
response(Id, Result) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"result">> => Result}.

-doc "Construct a JSON-RPC 2.0 error response (without data).".
-spec error_response(request_id(), integer(), binary()) -> jsonrpc_id_msg().
error_response(Id, Code, Message) when is_integer(Code), is_binary(Message) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code, <<"message">> => Message}}.

-doc "Construct a JSON-RPC 2.0 error response (with data).".
-spec error_response(request_id(), integer(), binary(), term()) -> jsonrpc_id_msg().
error_response(Id, Code, Message, Data)
  when is_integer(Code), is_binary(Message) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code,
                       <<"message">> => Message,
                       <<"data">> => Data}}.

-doc "Construct a JSON-RPC 2.0 notification (no params).".
-spec notification(binary()) -> jsonrpc_notif().
notification(Method) when is_binary(Method) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"method">> => Method}.

-doc "Construct a JSON-RPC 2.0 notification with params.".
-spec notification(binary(), map()) -> jsonrpc_notif_params().
notification(Method, Params) when is_binary(Method), is_map(Params) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"method">> => Method,
      <<"params">> => Params}.

%%====================================================================
%% Lifecycle Messages
%%====================================================================

-doc """
Construct an `initialize` request.

Sent by the client to begin the MCP session. Includes client capabilities,
implementation info, and the requested protocol version.
""".
-spec initialize_request(request_id(), implementation_info(),
                         client_capabilities()) -> jsonrpc_id_msg().
initialize_request(Id, ClientInfo, ClientCapabilities)
  when is_map(ClientInfo), is_map(ClientCapabilities) ->
    request(Id, <<"initialize">>, #{
        <<"protocolVersion">> => protocol_version(),
        <<"capabilities">> => encode_client_capabilities(ClientCapabilities),
        <<"clientInfo">> => encode_implementation_info(ClientInfo)
    }).

-doc """
Construct an `initialize` response.

Sent by the server after receiving an `initialize` request. Includes
server capabilities, implementation info, protocol version, and optional
instructions.
""".
-spec initialize_response(request_id(), implementation_info(),
                          server_capabilities()) -> jsonrpc_id_msg().
initialize_response(Id, ServerInfo, ServerCapabilities)
  when is_map(ServerInfo), is_map(ServerCapabilities) ->
    response(Id, #{
        <<"protocolVersion">> => protocol_version(),
        <<"capabilities">> => encode_server_capabilities(ServerCapabilities),
        <<"serverInfo">> => encode_implementation_info(ServerInfo)
    }).

-doc "Construct the `notifications/initialized` notification.".
-spec initialized_notification() -> jsonrpc_notif().
initialized_notification() ->
    notification(<<"notifications/initialized">>).

-doc "Construct a `ping` request.".
-spec ping_request(request_id()) -> jsonrpc_id_msg().
ping_request(Id) ->
    request(Id, <<"ping">>, #{}).

-doc "Construct a `ping` response (empty result).".
-spec ping_response(request_id()) -> jsonrpc_id_msg().
ping_response(Id) ->
    response(Id, #{}).

%%====================================================================
%% Tool Messages
%%====================================================================

-doc "Construct a `tools/list` request (no cursor).".
-spec tools_list_request(request_id()) -> jsonrpc_id_msg().
tools_list_request(Id) ->
    request(Id, <<"tools/list">>, #{}).

-doc "Construct a `tools/list` request with pagination cursor.".
-spec tools_list_request(request_id(), cursor()) -> jsonrpc_id_msg().
tools_list_request(Id, Cursor) when is_binary(Cursor) ->
    request(Id, <<"tools/list">>, #{<<"cursor">> => Cursor}).

-doc "Construct a `tools/list` response (no pagination).".
-spec tools_list_response(request_id(), [tool()]) -> jsonrpc_id_msg().
tools_list_response(Id, Tools) when is_list(Tools) ->
    response(Id, #{<<"tools">> => [encode_tool(T) || T <- Tools]}).

-doc "Construct a `tools/list` response with next cursor.".
-spec tools_list_response(request_id(), [tool()], cursor()) -> jsonrpc_id_msg().
tools_list_response(Id, Tools, NextCursor)
  when is_list(Tools), is_binary(NextCursor) ->
    response(Id, #{
        <<"tools">> => [encode_tool(T) || T <- Tools],
        <<"nextCursor">> => NextCursor
    }).

-doc "Construct a `tools/call` request.".
-spec tools_call_request(request_id(), binary(), map()) -> jsonrpc_id_msg().
tools_call_request(Id, ToolName, Arguments)
  when is_binary(ToolName), is_map(Arguments) ->
    request(Id, <<"tools/call">>, #{
        <<"name">> => ToolName,
        <<"arguments">> => Arguments
    }).

-doc "Construct a `tools/call` request with progress token.".
-spec tools_call_request(request_id(), binary(), map(),
                         progress_token()) -> jsonrpc_id_msg().
tools_call_request(Id, ToolName, Arguments, ProgressToken)
  when is_binary(ToolName), is_map(Arguments) ->
    request(Id, <<"tools/call">>, #{
        <<"name">> => ToolName,
        <<"arguments">> => Arguments
    }, ProgressToken).

-doc "Construct a `tools/call` response.".
-spec tools_call_response(request_id(), call_tool_result()) -> jsonrpc_id_msg().
tools_call_response(Id, Result) when is_map(Result) ->
    response(Id, encode_call_tool_result(Result)).

-doc "Construct a `tools/call` error response (isError=true).".
-spec tools_call_response(request_id(), [content()], boolean()) -> jsonrpc_id_msg().
tools_call_response(Id, Content, IsError)
  when is_list(Content), is_boolean(IsError) ->
    response(Id, #{
        <<"content">> => [encode_content(C) || C <- Content],
        <<"isError">> => IsError
    }).

-doc "Construct a `notifications/tools/list_changed` notification.".
-spec tools_list_changed_notification() -> jsonrpc_notif().
tools_list_changed_notification() ->
    notification(<<"notifications/tools/list_changed">>).

%%====================================================================
%% Resource Messages
%%====================================================================

-doc "Construct a `resources/list` request (no cursor).".
-spec resources_list_request(request_id()) -> jsonrpc_id_msg().
resources_list_request(Id) ->
    request(Id, <<"resources/list">>, #{}).

-doc "Construct a `resources/list` request with pagination cursor.".
-spec resources_list_request(request_id(), cursor()) -> jsonrpc_id_msg().
resources_list_request(Id, Cursor) when is_binary(Cursor) ->
    request(Id, <<"resources/list">>, #{<<"cursor">> => Cursor}).

-doc "Construct a `resources/list` response (no pagination).".
-spec resources_list_response(request_id(), [resource()]) -> jsonrpc_id_msg().
resources_list_response(Id, Resources) when is_list(Resources) ->
    response(Id, #{
        <<"resources">> => [encode_resource(R) || R <- Resources]
    }).

-doc "Construct a `resources/list` response with next cursor.".
-spec resources_list_response(request_id(), [resource()], cursor()) -> jsonrpc_id_msg().
resources_list_response(Id, Resources, NextCursor)
  when is_list(Resources), is_binary(NextCursor) ->
    response(Id, #{
        <<"resources">> => [encode_resource(R) || R <- Resources],
        <<"nextCursor">> => NextCursor
    }).

-doc "Construct a `resources/read` request.".
-spec resources_read_request(request_id(), binary()) -> jsonrpc_id_msg().
resources_read_request(Id, Uri) when is_binary(Uri) ->
    request(Id, <<"resources/read">>, #{<<"uri">> => Uri}).

-doc "Construct a `resources/read` response.".
-spec resources_read_response(request_id(), [resource_contents()]) -> jsonrpc_id_msg().
resources_read_response(Id, Contents) when is_list(Contents) ->
    response(Id, #{
        <<"contents">> => [encode_resource_contents(C) || C <- Contents]
    }).

-doc "Construct a `resources/templates/list` request (no cursor).".
-spec resources_templates_list_request(request_id()) -> jsonrpc_id_msg().
resources_templates_list_request(Id) ->
    request(Id, <<"resources/templates/list">>, #{}).

-doc "Construct a `resources/templates/list` request with cursor.".
-spec resources_templates_list_request(request_id(), cursor()) -> jsonrpc_id_msg().
resources_templates_list_request(Id, Cursor) when is_binary(Cursor) ->
    request(Id, <<"resources/templates/list">>,
            #{<<"cursor">> => Cursor}).

-doc "Construct a `resources/templates/list` response (no pagination).".
-spec resources_templates_list_response(request_id(),
                                        [resource_template()]) -> jsonrpc_id_msg().
resources_templates_list_response(Id, Templates)
  when is_list(Templates) ->
    response(Id, #{
        <<"resourceTemplates">> =>
            [encode_resource_template(T) || T <- Templates]
    }).

-doc "Construct a `resources/templates/list` response with next cursor.".
-spec resources_templates_list_response(request_id(),
                                        [resource_template()],
                                        cursor()) -> jsonrpc_id_msg().
resources_templates_list_response(Id, Templates, NextCursor)
  when is_list(Templates), is_binary(NextCursor) ->
    response(Id, #{
        <<"resourceTemplates">> =>
            [encode_resource_template(T) || T <- Templates],
        <<"nextCursor">> => NextCursor
    }).

-doc "Construct a `resources/subscribe` request.".
-spec resources_subscribe_request(request_id(), binary()) -> jsonrpc_id_msg().
resources_subscribe_request(Id, Uri) when is_binary(Uri) ->
    request(Id, <<"resources/subscribe">>, #{<<"uri">> => Uri}).

-doc "Construct a `resources/unsubscribe` request.".
-spec resources_unsubscribe_request(request_id(), binary()) -> jsonrpc_id_msg().
resources_unsubscribe_request(Id, Uri) when is_binary(Uri) ->
    request(Id, <<"resources/unsubscribe">>, #{<<"uri">> => Uri}).

-doc "Construct a `notifications/resources/list_changed` notification.".
-spec resources_list_changed_notification() -> jsonrpc_notif().
resources_list_changed_notification() ->
    notification(<<"notifications/resources/list_changed">>).

-doc "Construct a `notifications/resources/updated` notification.".
-spec resource_updated_notification(binary()) -> jsonrpc_notif_params().
resource_updated_notification(Uri) when is_binary(Uri) ->
    notification(<<"notifications/resources/updated">>,
                 #{<<"uri">> => Uri}).

%%====================================================================
%% Prompt Messages
%%====================================================================

-doc "Construct a `prompts/list` request (no cursor).".
-spec prompts_list_request(request_id()) -> jsonrpc_id_msg().
prompts_list_request(Id) ->
    request(Id, <<"prompts/list">>, #{}).

-doc "Construct a `prompts/list` request with pagination cursor.".
-spec prompts_list_request(request_id(), cursor()) -> jsonrpc_id_msg().
prompts_list_request(Id, Cursor) when is_binary(Cursor) ->
    request(Id, <<"prompts/list">>, #{<<"cursor">> => Cursor}).

-doc "Construct a `prompts/list` response (no pagination).".
-spec prompts_list_response(request_id(), [prompt()]) -> jsonrpc_id_msg().
prompts_list_response(Id, Prompts) when is_list(Prompts) ->
    response(Id, #{
        <<"prompts">> => [encode_prompt(P) || P <- Prompts]
    }).

-doc "Construct a `prompts/list` response with next cursor.".
-spec prompts_list_response(request_id(), [prompt()], cursor()) -> jsonrpc_id_msg().
prompts_list_response(Id, Prompts, NextCursor)
  when is_list(Prompts), is_binary(NextCursor) ->
    response(Id, #{
        <<"prompts">> => [encode_prompt(P) || P <- Prompts],
        <<"nextCursor">> => NextCursor
    }).

-doc "Construct a `prompts/get` request (no arguments).".
-spec prompts_get_request(request_id(), binary()) -> jsonrpc_id_msg().
prompts_get_request(Id, Name) when is_binary(Name) ->
    request(Id, <<"prompts/get">>, #{<<"name">> => Name}).

-doc "Construct a `prompts/get` request with arguments.".
-spec prompts_get_request(request_id(), binary(), map()) -> jsonrpc_id_msg().
prompts_get_request(Id, Name, Arguments)
  when is_binary(Name), is_map(Arguments) ->
    request(Id, <<"prompts/get">>, #{
        <<"name">> => Name,
        <<"arguments">> => Arguments
    }).

-doc "Construct a `prompts/get` response.".
-spec prompts_get_response(request_id(), [prompt_message()]) -> jsonrpc_id_msg().
prompts_get_response(Id, Messages) when is_list(Messages) ->
    response(Id, #{
        <<"messages">> => [encode_prompt_message(M) || M <- Messages]
    }).

-doc "Construct a `prompts/get` response with description.".
-spec prompts_get_response(request_id(), [prompt_message()],
                           binary()) -> jsonrpc_id_msg().
prompts_get_response(Id, Messages, Description)
  when is_list(Messages), is_binary(Description) ->
    response(Id, #{
        <<"description">> => Description,
        <<"messages">> => [encode_prompt_message(M) || M <- Messages]
    }).

-doc "Construct a `notifications/prompts/list_changed` notification.".
-spec prompts_list_changed_notification() -> jsonrpc_notif().
prompts_list_changed_notification() ->
    notification(<<"notifications/prompts/list_changed">>).

%%====================================================================
%% Completion Messages
%%====================================================================

-doc "Construct a `completion/complete` request.".
-spec completion_complete_request(request_id(), completion_ref(),
                                  map()) -> jsonrpc_id_msg().
completion_complete_request(Id, Ref, Argument)
  when is_map(Ref), is_map(Argument) ->
    request(Id, <<"completion/complete">>, #{
        <<"ref">> => Ref,
        <<"argument">> => Argument
    }).

-doc "Construct a `completion/complete` request with context.".
-spec completion_complete_request(request_id(), completion_ref(),
                                  map(), map()) -> jsonrpc_id_msg().
completion_complete_request(Id, Ref, Argument, Context)
  when is_map(Ref), is_map(Argument), is_map(Context) ->
    request(Id, <<"completion/complete">>, #{
        <<"ref">> => Ref,
        <<"argument">> => Argument,
        <<"context">> => Context
    }).

-doc "Construct a `completion/complete` response.".
-spec completion_complete_response(request_id(),
                                   completion_result()) -> jsonrpc_id_msg().
completion_complete_response(Id, CompletionResult)
  when is_map(CompletionResult) ->
    response(Id, #{
        <<"completion">> => encode_completion_result(CompletionResult)
    }).

%%====================================================================
%% Logging Messages
%%====================================================================

-doc "Construct a `logging/setLevel` request.".
-spec logging_set_level_request(request_id(), log_level()) -> jsonrpc_id_msg().
logging_set_level_request(Id, Level)
  when Level =:= debug; Level =:= info; Level =:= notice;
       Level =:= warning; Level =:= error; Level =:= critical;
       Level =:= alert; Level =:= emergency ->
    request(Id, <<"logging/setLevel">>, #{
        <<"level">> => atom_to_binary(Level)
    }).

-doc "Construct a `logging/setLevel` response (empty result).".
-spec logging_set_level_response(request_id()) -> jsonrpc_id_msg().
logging_set_level_response(Id) ->
    response(Id, #{}).

-doc """
Construct a `notifications/message` logging notification.

`Data` is arbitrary JSON-serializable data.
""".
-spec logging_message_notification(log_level(), binary(), term()) -> jsonrpc_notif_params().
logging_message_notification(Level, Logger, Data)
  when is_atom(Level), is_binary(Logger) ->
    notification(<<"notifications/message">>, #{
        <<"level">> => atom_to_binary(Level),
        <<"logger">> => Logger,
        <<"data">> => Data
    }).

%%====================================================================
%% Sampling Messages (server → client)
%%====================================================================

-doc """
Construct a `sampling/createMessage` request.

Sent by a server to request LLM sampling from the client.
""".
-spec sampling_create_message_request(request_id(), map()) -> jsonrpc_id_msg().
sampling_create_message_request(Id, Params) when is_map(Params) ->
    request(Id, <<"sampling/createMessage">>, Params).

-doc "Construct a `sampling/createMessage` response.".
-spec sampling_create_message_response(request_id(),
                                       create_message_result()) -> jsonrpc_id_msg().
sampling_create_message_response(Id, Result) when is_map(Result) ->
    response(Id, encode_create_message_result(Result)).

%%====================================================================
%% Elicitation Messages (server → client)
%%====================================================================

-doc """
Construct an `elicitation/create` request.

Sent by a server to request structured user input from the client.
""".
-spec elicitation_create_request(request_id(), binary(), map()) -> jsonrpc_id_msg().
elicitation_create_request(Id, Message, RequestedSchema)
  when is_binary(Message), is_map(RequestedSchema) ->
    request(Id, <<"elicitation/create">>, #{
        <<"message">> => Message,
        <<"requestedSchema">> => RequestedSchema
    }).

-doc "Construct an `elicitation/create` response.".
-spec elicitation_create_response(request_id(),
                                  elicitation_result()) -> jsonrpc_id_msg().
elicitation_create_response(Id, Result) when is_map(Result) ->
    response(Id, encode_elicitation_result(Result)).

%%====================================================================
%% Roots Messages (server → client)
%%====================================================================

-doc "Construct a `roots/list` request.".
-spec roots_list_request(request_id()) -> jsonrpc_id_msg().
roots_list_request(Id) ->
    request(Id, <<"roots/list">>, #{}).

-doc "Construct a `roots/list` response.".
-spec roots_list_response(request_id(), [root()]) -> jsonrpc_id_msg().
roots_list_response(Id, Roots) when is_list(Roots) ->
    response(Id, #{<<"roots">> => [encode_root(R) || R <- Roots]}).

-doc "Construct a `notifications/roots/list_changed` notification.".
-spec roots_list_changed_notification() -> jsonrpc_notif().
roots_list_changed_notification() ->
    notification(<<"notifications/roots/list_changed">>).

%%====================================================================
%% Progress & Cancellation Notifications
%%====================================================================

-doc "Construct a `notifications/progress` notification (progress only).".
-spec progress_notification(progress_token(), number()) -> jsonrpc_notif_params().
progress_notification(Token, Progress) when is_number(Progress) ->
    notification(<<"notifications/progress">>, #{
        <<"progressToken">> => Token,
        <<"progress">> => Progress
    }).

-doc "Construct a `notifications/progress` notification with total.".
-spec progress_notification(progress_token(), number(), number()) -> jsonrpc_notif_params().
progress_notification(Token, Progress, Total)
  when is_number(Progress), is_number(Total) ->
    notification(<<"notifications/progress">>, #{
        <<"progressToken">> => Token,
        <<"progress">> => Progress,
        <<"total">> => Total
    }).

-doc "Construct a `notifications/progress` notification with total and message.".
-spec progress_notification(progress_token(), number(), number(),
                            binary()) -> jsonrpc_notif_params().
progress_notification(Token, Progress, Total, Message)
  when is_number(Progress), is_number(Total), is_binary(Message) ->
    notification(<<"notifications/progress">>, #{
        <<"progressToken">> => Token,
        <<"progress">> => Progress,
        <<"total">> => Total,
        <<"message">> => Message
    }).

-doc "Construct a `notifications/cancelled` notification (no reason).".
-spec cancelled_notification(request_id()) -> jsonrpc_notif_params().
cancelled_notification(RequestId) ->
    notification(<<"notifications/cancelled">>, #{
        <<"requestId">> => RequestId
    }).

-doc "Construct a `notifications/cancelled` notification with reason.".
-spec cancelled_notification(request_id(), binary()) -> jsonrpc_notif_params().
cancelled_notification(RequestId, Reason) when is_binary(Reason) ->
    notification(<<"notifications/cancelled">>, #{
        <<"requestId">> => RequestId,
        <<"reason">> => Reason
    }).

%%====================================================================
%% Content Constructors
%%====================================================================

-doc "Create a text content block.".
-spec text_content(binary()) -> #{type := text, text := binary()}.
text_content(Text) when is_binary(Text) ->
    #{type => text, text => Text}.

-doc "Create an image content block (base64-encoded data + MIME type).".
-spec image_content(binary(), binary()) -> #{type := image, data := binary(), mimeType := binary()}.
image_content(Data, MimeType)
  when is_binary(Data), is_binary(MimeType) ->
    #{type => image, data => Data, mimeType => MimeType}.

-doc "Create an audio content block (base64-encoded data + MIME type).".
-spec audio_content(binary(), binary()) -> #{type := audio, data := binary(), mimeType := binary()}.
audio_content(Data, MimeType)
  when is_binary(Data), is_binary(MimeType) ->
    #{type => audio, data => Data, mimeType => MimeType}.

-doc "Create an embedded resource content block.".
-spec resource_content(resource_contents()) -> resource_content().
resource_content(Resource) when is_map(Resource) ->
    #{type => resource, resource => Resource}.

-doc "Create a resource link content block.".
-spec resource_link_content(binary(), binary()) -> #{type := resource_link, uri := binary(), mimeType := binary()}.
resource_link_content(Uri, MimeType)
  when is_binary(Uri), is_binary(MimeType) ->
    #{type => resource_link, uri => Uri, mimeType => MimeType}.

-doc """
Create a resource link content block with optional metadata.

Accepted keys in `Opts`: `name`, `description`, `annotations`.
Unknown keys are dropped.
""".
-spec resource_link_content(binary(), binary(), map()) -> resource_link_content().
resource_link_content(Uri, MimeType, Opts)
  when is_binary(Uri), is_binary(MimeType), is_map(Opts) ->
    Base = #{type => resource_link, uri => Uri, mimeType => MimeType},
    Allowed = maps:with([name, description, annotations], Opts),
    maps:merge(Base, Allowed).

%%====================================================================
%% Type Constructors
%%====================================================================

-doc "Create implementation info (name + version).".
-spec implementation_info(binary(), binary()) -> #{name := binary(), version := binary()}.
implementation_info(Name, Version)
  when is_binary(Name), is_binary(Version) ->
    #{name => Name, version => Version}.

-doc "Create implementation info (name + version + title).".
-spec implementation_info(binary(), binary(), binary()) ->
    #{name := binary(), version := binary(), title := binary()}.
implementation_info(Name, Version, Title)
  when is_binary(Name), is_binary(Version), is_binary(Title) ->
    #{name => Name, version => Version, title => Title}.

-doc "Create an empty tool annotation (all hints default to spec values).".
-spec tool_annotation() -> #{}.
tool_annotation() -> #{}.

-doc """
Create a tool annotation with specified hints.

Accepted keys: `readOnlyHint`, `destructiveHint`, `idempotentHint`,
`openWorldHint`, `title`. Unknown keys are dropped.
""".
-spec tool_annotation(map()) -> tool_annotation().
tool_annotation(Hints) when is_map(Hints) ->
    ValidKeys = [title, readOnlyHint, destructiveHint,
                 idempotentHint, openWorldHint],
    maps:with(ValidKeys, Hints).

-doc "Create an empty resource annotation.".
-spec resource_annotation() -> #{}.
resource_annotation() -> #{}.

-doc """
Create a resource annotation with specified fields.

Accepted keys: `audience`, `priority`, `lastModified`.
Unknown keys are dropped.
""".
-spec resource_annotation(map()) -> resource_annotation().
resource_annotation(Fields) when is_map(Fields) ->
    ValidKeys = [audience, priority, lastModified],
    maps:with(ValidKeys, Fields).

-doc "Create empty model preferences.".
-spec model_preferences() -> #{}.
model_preferences() -> #{}.

-doc """
Create model preferences from a map.

Accepted keys: `hints`, `costPriority`, `speedPriority`,
`intelligencePriority`. Unknown keys are dropped.
""".
-spec model_preferences(map()) -> model_preferences().
model_preferences(Prefs) when is_map(Prefs) ->
    ValidKeys = [hints, costPriority, speedPriority,
                 intelligencePriority],
    maps:with(ValidKeys, Prefs).

%%====================================================================
%% Capability Negotiation
%%====================================================================

-doc """
Negotiate session capabilities from server and client advertisements.

Called after the initialize/initialized handshake completes. Returns
a `session_capabilities()` map that records what both sides support.
The dispatch layer uses this to decide which methods to accept.
""".
-spec negotiate_capabilities(server_capabilities(),
                             client_capabilities()) ->
    session_capabilities().
negotiate_capabilities(ServerCaps, ClientCaps)
  when is_map(ServerCaps), is_map(ClientCaps) ->
    #{server => ServerCaps,
      client => ClientCaps,
      protocol_version => protocol_version()}.

-doc "Return default server capabilities (tools with listChanged).".
-spec default_server_capabilities() -> #{tools := #{listChanged := true}}.
default_server_capabilities() ->
    #{tools => #{listChanged => true}}.

-doc "Return default client capabilities (roots with listChanged).".
-spec default_client_capabilities() -> #{roots := #{listChanged := true}}.
default_client_capabilities() ->
    #{roots => #{listChanged => true}}.

-doc """
Check whether a capability family is supported in session capabilities.

`Family` is an atom like `tools`, `resources`, `prompts`, `sampling`,
`elicitation`, `roots`, `completions`, or `logging`.

Returns `true` if the capability is present (server-side families
check `server`, client-side families check `client`).
""".
-spec capability_supported(atom(), session_capabilities()) -> boolean().
capability_supported(Family, #{server := ServerCaps})
  when Family =:= tools;
       Family =:= resources;
       Family =:= prompts;
       Family =:= completions;
       Family =:= logging ->
    maps:is_key(Family, ServerCaps);
capability_supported(Family, #{client := ClientCaps})
  when Family =:= roots;
       Family =:= sampling;
       Family =:= elicitation ->
    maps:is_key(Family, ClientCaps);
capability_supported(_Family, _Caps) ->
    false.

%%====================================================================
%% Validation
%%====================================================================

-doc """
Validate an incoming JSON-RPC 2.0 message and classify it.

Returns a tagged tuple identifying the message type, or
`{invalid, Reason}` for malformed messages.

Does NOT require `"jsonrpc": "2.0"` to be present — some transports
strip it. The presence of `method` + `id` (request), `method` only
(notification), or `id` + `result`/`error` (response) determines type.
""".
-spec validate_message(term()) -> jsonrpc_message().
validate_message(#{<<"method">> := Method, <<"id">> := Id} = Msg)
  when is_binary(Method) ->
    Params = maps:get(<<"params">>, Msg, #{}),
    case is_map(Params) of
        true -> {request, Id, Method, Params};
        false -> {invalid, {bad_params, Params}}
    end;
validate_message(#{<<"method">> := Method} = Msg)
  when is_binary(Method) ->
    Params = maps:get(<<"params">>, Msg, #{}),
    case is_map(Params) of
        true -> {notification, Method, Params};
        false -> {invalid, {bad_params, Params}}
    end;
validate_message(#{<<"id">> := Id, <<"error">> :=
                   #{<<"code">> := Code, <<"message">> := ErrMsg} = Err})
  when is_integer(Code), is_binary(ErrMsg) ->
    Data = maps:get(<<"data">>, Err, undefined),
    {error_response, Id, Code, ErrMsg, Data};
validate_message(#{<<"id">> := Id, <<"result">> := Result}) ->
    {response, Id, Result};
validate_message(Other) when is_map(Other) ->
    {invalid, {unrecognized_message, Other}};
validate_message(Other) ->
    {invalid, {not_a_map, Other}}.

-doc """
Validate a tool definition map.

Returns `ok` if the tool has required fields (`name`, `inputSchema`),
or `{error, Reason}` describing what is missing or invalid.
""".
-spec validate_tool(map()) -> ok | {error, term()}.
validate_tool(#{name := Name, inputSchema := Schema})
  when is_binary(Name), is_map(Schema) ->
    ok;
validate_tool(#{name := Name}) when is_binary(Name) ->
    {error, {missing_field, inputSchema}};
validate_tool(#{inputSchema := _}) ->
    {error, {missing_field, name}};
validate_tool(_) ->
    {error, {missing_fields, [name, inputSchema]}}.

-doc """
Validate a resource definition map.

Returns `ok` if the resource has required fields (`uri`, `name`),
or `{error, Reason}`.
""".
-spec validate_resource(map()) -> ok | {error, term()}.
validate_resource(#{uri := Uri, name := Name})
  when is_binary(Uri), is_binary(Name) ->
    ok;
validate_resource(#{uri := _}) ->
    {error, {missing_field, name}};
validate_resource(#{name := _}) ->
    {error, {missing_field, uri}};
validate_resource(_) ->
    {error, {missing_fields, [uri, name]}}.

-doc """
Validate a prompt definition map.

Returns `ok` if the prompt has the required `name` field,
or `{error, Reason}`.
""".
-spec validate_prompt(map()) -> ok | {error, term()}.
validate_prompt(#{name := Name}) when is_binary(Name) ->
    ok;
validate_prompt(_) ->
    {error, {missing_field, name}}.

%%====================================================================
%% Internal: Wire-Format Encoders
%%====================================================================

%% Encode implementation_info for the wire.
-spec encode_implementation_info(implementation_info()) -> map().
encode_implementation_info(#{name := Name, version := Version} = Info) ->
    Base = #{<<"name">> => Name, <<"version">> => Version},
    maybe_put(<<"title">>, maps:get(title, Info, undefined), Base).

%% Encode server capabilities for the wire.
-spec encode_server_capabilities(server_capabilities()) -> map().
encode_server_capabilities(Caps) ->
    maps:fold(fun(Key, Value, Acc) ->
        Acc#{atom_to_binary(Key) => encode_capability_opts(Value)}
    end, #{}, Caps).

%% Encode client capabilities for the wire.
-spec encode_client_capabilities(client_capabilities()) -> map().
encode_client_capabilities(Caps) ->
    maps:fold(fun(Key, Value, Acc) ->
        Acc#{atom_to_binary(Key) => encode_capability_opts(Value)}
    end, #{}, Caps).

%% Encode capability options (booleans to wire format).
-spec encode_capability_opts(map()) -> map().
encode_capability_opts(Opts) when is_map(Opts) ->
    maps:fold(fun(Key, Value, Acc) ->
        Acc#{atom_to_binary(Key) => Value}
    end, #{}, Opts).

%% Encode a tool for the wire (tools/list response).
-spec encode_tool(tool()) -> map().
encode_tool(#{name := Name, inputSchema := Schema} = Tool) ->
    Base = #{<<"name">> => Name, <<"inputSchema">> => Schema},
    B1 = maybe_put(<<"title">>, maps:get(title, Tool, undefined), Base),
    B2 = maybe_put(<<"description">>,
                   maps:get(description, Tool, undefined), B1),
    B3 = maybe_put(<<"outputSchema">>,
                   maps:get(outputSchema, Tool, undefined), B2),
    case maps:get(annotations, Tool, undefined) of
        undefined -> B3;
        Ann -> B3#{<<"annotations">> => encode_tool_annotation(Ann)}
    end.

%% Encode tool annotations for the wire.
-spec encode_tool_annotation(tool_annotation()) -> map().
encode_tool_annotation(Ann) ->
    maps:fold(fun(Key, Value, Acc) ->
        Acc#{atom_to_binary(Key) => Value}
    end, #{}, Ann).

%% Encode a call_tool_result for the wire.
-spec encode_call_tool_result(call_tool_result()) -> map().
encode_call_tool_result(#{content := Content} = Result) ->
    Base = #{<<"content">> => [encode_content(C) || C <- Content]},
    B1 = maybe_put(<<"isError">>,
                   maps:get(isError, Result, undefined), Base),
    maybe_put(<<"structuredContent">>,
              maps:get(structuredContent, Result, undefined), B1).

%% Encode content for the wire.
-spec encode_content(content()) -> #{<<_:24, _:_*8>> => _}.
encode_content(#{type := text, text := Text} = C) ->
    Base = #{<<"type">> => <<"text">>, <<"text">> => Text},
    maybe_encode_content_annotations(C, Base);
encode_content(#{type := image, data := Data, mimeType := Mime} = C) ->
    Base = #{<<"type">> => <<"image">>,
             <<"data">> => Data, <<"mimeType">> => Mime},
    maybe_encode_content_annotations(C, Base);
encode_content(#{type := audio, data := Data, mimeType := Mime} = C) ->
    Base = #{<<"type">> => <<"audio">>,
             <<"data">> => Data, <<"mimeType">> => Mime},
    maybe_encode_content_annotations(C, Base);
encode_content(#{type := resource, resource := Res} = C) ->
    Base = #{<<"type">> => <<"resource">>,
             <<"resource">> => encode_resource_contents(Res)},
    maybe_encode_content_annotations(C, Base);
encode_content(#{type := resource_link, uri := Uri} = C) ->
    Base = #{<<"type">> => <<"resource_link">>, <<"uri">> => Uri},
    B1 = maybe_put(<<"name">>, maps:get(name, C, undefined), Base),
    B2 = maybe_put(<<"description">>,
                   maps:get(description, C, undefined), B1),
    B3 = maybe_put(<<"mimeType">>,
                   maps:get(mimeType, C, undefined), B2),
    maybe_encode_content_annotations(C, B3).

%% Optionally add annotations to encoded content.
-spec maybe_encode_content_annotations(content(), map()) -> map().
maybe_encode_content_annotations(Content, Wire) ->
    case maps:get(annotations, Content, undefined) of
        undefined -> Wire;
        Ann -> Wire#{<<"annotations">> => encode_resource_annotation(Ann)}
    end.

%% Encode a resource for the wire (resources/list response).
-spec encode_resource(resource()) -> map().
encode_resource(#{uri := Uri, name := Name} = Res) ->
    Base = #{<<"uri">> => Uri, <<"name">> => Name},
    B1 = maybe_put(<<"title">>, maps:get(title, Res, undefined), Base),
    B2 = maybe_put(<<"description">>,
                   maps:get(description, Res, undefined), B1),
    B3 = maybe_put(<<"mimeType">>,
                   maps:get(mimeType, Res, undefined), B2),
    B4 = maybe_put(<<"size">>, maps:get(size, Res, undefined), B3),
    case maps:get(annotations, Res, undefined) of
        undefined -> B4;
        Ann -> B4#{<<"annotations">> => encode_resource_annotation(Ann)}
    end.

%% Encode a resource template for the wire.
-spec encode_resource_template(resource_template()) -> map().
encode_resource_template(#{uriTemplate := UriTpl, name := Name} = Tpl) ->
    Base = #{<<"uriTemplate">> => UriTpl, <<"name">> => Name},
    B1 = maybe_put(<<"title">>, maps:get(title, Tpl, undefined), Base),
    B2 = maybe_put(<<"description">>,
                   maps:get(description, Tpl, undefined), B1),
    B3 = maybe_put(<<"mimeType">>,
                   maps:get(mimeType, Tpl, undefined), B2),
    case maps:get(annotations, Tpl, undefined) of
        undefined -> B3;
        Ann -> B3#{<<"annotations">> => encode_resource_annotation(Ann)}
    end.

%% Encode resource contents for the wire.
-spec encode_resource_contents(resource_contents()) -> map().
encode_resource_contents(#{uri := Uri} = Contents) ->
    Base = #{<<"uri">> => Uri},
    B1 = maybe_put(<<"mimeType">>,
                   maps:get(mimeType, Contents, undefined), Base),
    B2 = maybe_put(<<"text">>,
                   maps:get(text, Contents, undefined), B1),
    maybe_put(<<"blob">>,
              maps:get(blob, Contents, undefined), B2).

%% Encode resource annotations for the wire.
-spec encode_resource_annotation(resource_annotation()) -> map().
encode_resource_annotation(Ann) ->
    Base = #{},
    B1 = maybe_put(<<"audience">>,
                   maps:get(audience, Ann, undefined), Base),
    B2 = maybe_put(<<"priority">>,
                   maps:get(priority, Ann, undefined), B1),
    maybe_put(<<"lastModified">>,
              maps:get(lastModified, Ann, undefined), B2).

%% Encode a prompt for the wire (prompts/list response).
-spec encode_prompt(prompt()) -> map().
encode_prompt(#{name := Name} = Prompt) ->
    Base = #{<<"name">> => Name},
    B1 = maybe_put(<<"title">>,
                   maps:get(title, Prompt, undefined), Base),
    B2 = maybe_put(<<"description">>,
                   maps:get(description, Prompt, undefined), B1),
    case maps:get(arguments, Prompt, undefined) of
        undefined -> B2;
        Args -> B2#{<<"arguments">> =>
                        [encode_prompt_argument(A) || A <- Args]}
    end.

%% Encode a prompt argument for the wire.
-spec encode_prompt_argument(prompt_argument()) -> map().
encode_prompt_argument(#{name := Name} = Arg) ->
    Base = #{<<"name">> => Name},
    B1 = maybe_put(<<"description">>,
                   maps:get(description, Arg, undefined), Base),
    maybe_put(<<"required">>,
              maps:get(required, Arg, undefined), B1).

%% Encode a prompt message for the wire.
-spec encode_prompt_message(prompt_message()) -> map().
encode_prompt_message(#{role := Role, content := Content}) ->
    #{<<"role">> => Role,
      <<"content">> => encode_content(Content)}.

%% Encode a root for the wire.
-spec encode_root(root()) -> map().
encode_root(#{uri := Uri} = Root) ->
    Base = #{<<"uri">> => Uri},
    maybe_put(<<"name">>, maps:get(name, Root, undefined), Base).

%% Encode a completion result for the wire.
-spec encode_completion_result(completion_result()) -> map().
encode_completion_result(#{values := Values} = Result) ->
    Base = #{<<"values">> => Values},
    B1 = maybe_put(<<"total">>,
                   maps:get(total, Result, undefined), Base),
    maybe_put(<<"hasMore">>,
              maps:get(hasMore, Result, undefined), B1).

%% Encode a create_message_result for the wire.
-spec encode_create_message_result(create_message_result()) -> map().
encode_create_message_result(#{role := Role, content := Content,
                               model := Model} = Result) ->
    Base = #{<<"role">> => Role,
             <<"content">> => encode_content(Content),
             <<"model">> => Model},
    maybe_put(<<"stopReason">>,
              maps:get(stopReason, Result, undefined), Base).

%% Encode an elicitation result for the wire.
-spec encode_elicitation_result(elicitation_result()) -> map().
encode_elicitation_result(#{action := Action} = Result)
  when Action =:= accept; Action =:= decline; Action =:= cancel ->
    ActionBin = atom_to_binary(Action),
    Base = #{<<"action">> => ActionBin},
    maybe_put(<<"content">>,
              maps:get(content, Result, undefined), Base).

%%--------------------------------------------------------------------
%% Internal: Utilities
%%--------------------------------------------------------------------

%% Add a key-value pair to a map only if Value is not `undefined`.
-spec maybe_put(<<_:32, _:_*8>>, term(), #{<<_:24, _:_*8>> => _}) -> #{<<_:24, _:_*8>> => _}.
maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

%%--------------------------------------------------------------------
%% Wire-Format Capability Decoding
%%--------------------------------------------------------------------

-doc """
Decode wire-format capabilities (binary keys) to Erlang atom keys.

Used by both server dispatch (decoding client capabilities) and client
dispatch (decoding server capabilities). Only known capability keys are
decoded; unknown keys are dropped to prevent atom table exhaustion.
""".
-spec decode_wire_capabilities(map()) -> map().
decode_wire_capabilities(WireCaps) when is_map(WireCaps) ->
    maps:fold(fun(Key, Value, Acc) when is_binary(Key), is_map(Value) ->
        case safe_capability_atom(Key) of
            undefined -> Acc;
            Atom -> Acc#{Atom => decode_capability_opts(Value)}
        end;
    (_Key, _Value, Acc) ->
        Acc
    end, #{}, WireCaps).

%% Decode sub-options within a capability (e.g., listChanged, subscribe).
-spec decode_capability_opts(map()) -> map().
decode_capability_opts(Opts) when is_map(Opts) ->
    maps:fold(fun(Key, Value, Acc) when is_binary(Key) ->
        case safe_capability_atom(Key) of
            undefined -> Acc;
            Atom -> Acc#{Atom => Value}
        end;
    (_Key, _Value, Acc) ->
        Acc
    end, #{}, Opts).

-doc """
Convert a known capability binary key to an atom, or `undefined` if
the key is not recognized. Prevents atom table exhaustion from
arbitrary input.
""".
-spec safe_capability_atom(binary()) -> atom() | undefined.
safe_capability_atom(<<"roots">>) -> roots;
safe_capability_atom(<<"sampling">>) -> sampling;
safe_capability_atom(<<"elicitation">>) -> elicitation;
safe_capability_atom(<<"tools">>) -> tools;
safe_capability_atom(<<"resources">>) -> resources;
safe_capability_atom(<<"prompts">>) -> prompts;
safe_capability_atom(<<"completions">>) -> completions;
safe_capability_atom(<<"logging">>) -> logging;
safe_capability_atom(<<"listChanged">>) -> listChanged;
safe_capability_atom(<<"subscribe">>) -> subscribe;
safe_capability_atom(_) -> undefined.
