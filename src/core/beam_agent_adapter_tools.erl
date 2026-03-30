-module(beam_agent_adapter_tools).
-moduledoc """
Sub-behaviour for tool-capable backends.

Backends that support native tool/function calling — whether agentic coders
or stateless inference APIs — implement this sub-behaviour in addition to
`beam_agent_adapter`.

The unified layer uses these callbacks to translate tool definitions into
each backend's wire format, extract tool call requests from responses, and
format tool results for the next turn.

All three callbacks are required: if a backend declares tool support, it
must handle the full round-trip.

> **Status:** No implementations yet. The current five backends handle
> tool management through their session handlers and the unified
> `beam_agent_tool_registry`. This behaviour is reserved for backends
> that need a distinct tool-formatting layer (e.g., stateless API
> backends that require tool definitions in their wire format).

See also: `beam_agent_adapter`, `beam_agent_adapter_session`,
`beam_agent_adapter_api`.
""".

-export_type([
    tool_def/0,
    tool_call/0,
    tool_result/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type tool_def() :: #{
    name := binary(),
    description => binary(),
    parameters => map(),
    atom() => term()
}.

-type tool_call() :: #{
    id := binary(),
    name := binary(),
    input := map()
}.

-type tool_result() :: #{
    id := binary(),
    content := binary() | map(),
    is_error => boolean()
}.

%%--------------------------------------------------------------------
%% Required Callbacks
%%--------------------------------------------------------------------

-doc "Translate generic tool definitions into this backend's wire format.".
-callback format_tools([tool_def()]) -> term().

-doc "Extract tool call requests from a backend response.".
-callback parse_tool_calls(Response :: term()) -> [tool_call()].

-doc "Format tool execution results for the next conversation turn.".
-callback format_tool_results([tool_result()]) -> term().
