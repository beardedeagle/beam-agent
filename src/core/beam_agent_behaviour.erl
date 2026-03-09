-module(beam_agent_behaviour).
-moduledoc """
Unified behaviour contract for all agent wire protocol adapters.

Every agent SDK (claude_agent_sdk, codex_app_server, opencode_client,
gemini_cli_client, copilot_client) implements this behaviour. Consumers — including
the coord orchestrator — program against this contract without
knowing which agent they're talking to.

Enhanced from initial version with:
  - Permission handler callback with input modification
  - Session info query callback
  - Runtime control method callbacks (set_model, set_permission_mode)
""".

%% Required callbacks — every adapter must implement these.

-callback start_link(Opts :: beam_agent_core:session_opts()) ->
    {ok, pid()} | {error, term()}.

-callback send_query(Pid :: pid(), Prompt :: binary(),
                     Params :: beam_agent_core:query_opts(),
                     Timeout :: timeout()) ->
    {ok, reference()} | {error, term()}.

-callback receive_message(Pid :: pid(), Ref :: reference(),
                          Timeout :: timeout()) ->
    {ok, beam_agent_core:message()} | {error, term()}.

-callback health(Pid :: pid()) ->
    ready | connecting | initializing | active_query | error.

-callback stop(Pid :: pid()) -> ok.

%% Optional callbacks — adapters with control protocols implement these.

-callback send_control(Pid :: pid(), Method :: binary(),
                       Params :: map()) ->
    {ok, term()} | {error, term()}.

-callback interrupt(Pid :: pid()) -> ok | {error, term()}.

-doc """
Handle an inbound control request from the CLI.

The CLI sends control_request messages (e.g., can_use_tool,
hook_callback, mcp_message) that require a control_response.

Return values follow the TS SDK PermissionResult pattern:
  `{allow, UpdatedInput}` — approve, optionally modifying tool input
  `{deny, Reason}` — deny with a reason message
  `{allow, UpdatedInput, RuleUpdate}` — approve with rule modification

The default in claude_agent_session auto-approves all requests.
""".
-callback handle_control_request(Subtype :: binary(), Request :: map()) ->
    beam_agent_core:permission_result().

-doc "Query session capabilities and initialization data.

Returns a map containing information from the system init message
and the initialize control response (available tools, model,
MCP servers, account info, etc.).
".
-callback session_info(Pid :: pid()) ->
    {ok, map()} | {error, term()}.

-doc "Change the model at runtime during a session.".
-callback set_model(Pid :: pid(), Model :: binary()) ->
    {ok, term()} | {error, term()}.

-doc "Change the permission mode at runtime.".
-callback set_permission_mode(Pid :: pid(), Mode :: binary()) ->
    {ok, term()} | {error, term()}.

-optional_callbacks([
    send_control/3,
    interrupt/1,
    handle_control_request/2,
    session_info/1,
    set_model/2,
    set_permission_mode/2
]).
