-module(beam_agent_adapter).
-moduledoc """
Base behaviour for all BeamAgent backend adapters.

Every backend — whether an agentic coder (Claude, Codex, Gemini, OpenCode,
Copilot) or a stateless inference API (Anthropic API, OpenAI API, etc.) —
implements this behaviour. The three required callbacks declare the backend's
identity and native capability set.

Agentic backends additionally implement `beam_agent_adapter_session`.
Stateless API backends additionally implement `beam_agent_adapter_api`.
Either category may implement `beam_agent_adapter_tools` if they support
native tool/function calling.

The `backend_type/0` callback is the routing discriminator used by
`beam_agent_core` to select the session-based or stateless dispatch path.

See also: `beam_agent_adapter_session`, `beam_agent_adapter_api`,
`beam_agent_adapter_tools`.
""".

-export_type([
    backend_type/0,
    capability/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type backend_type() :: agentic | api.

-type capability() :: atom().

%%--------------------------------------------------------------------
%% Required Callbacks — every backend MUST implement these
%%--------------------------------------------------------------------

-doc "Canonical backend name atom (e.g. `claude`, `codex`, `anthropic_api`).".
-callback backend_name() -> atom().

-doc """
Backend category: `agentic` for session-based coder backends that use the
session engine + transport stack, `api` for stateless inference API backends
that make direct HTTP calls.
""".
-callback backend_type() -> backend_type().

-doc """
List of capabilities this backend natively supports. Used by
`beam_agent_capabilities` and the `native_or` routing logic.
""".
-callback capabilities() -> [capability()].
