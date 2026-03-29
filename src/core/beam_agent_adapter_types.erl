-module(beam_agent_adapter_types).
-moduledoc """
Shared type definitions for backend adapter facade modules.

Centralizes types that were previously duplicated across multiple backend
facades (claude_agent_sdk, copilot_client, gemini_cli_client,
opencode_client). Each facade retains local aliases to these types so
that existing -spec annotations remain unchanged.

Backend-specific types (e.g., adapter_status/session_view with hardcoded
backend atoms) remain in their respective facade modules.
""".

-export_type([
    session_meta/0,
    session_share/0,
    session_summary/0,
    thread_meta/0,
    thread_read_result/0,
    thread_resume_result/0,
    init_response_key/0,
    system_info_key/0,
    init_default/0,
    session_health/0,
    %% Re-exports for backend package extraction — backends depend on
    %% these types but should not need a direct dependency on beam_agent_core.
    session_opts/0,
    query_opts/0,
    message/0,
    message_type/0,
    backend_type/0,
    capability/0
]).

%%--------------------------------------------------------------------
%% Re-exported Core Types
%%--------------------------------------------------------------------

-doc "Session metadata — see beam_agent_session_store_core for the canonical definition.".
-type session_meta() :: beam_agent_session_store_core:session_meta().

-doc "Session share record — see beam_agent_session_store_core for the canonical definition.".
-type session_share() :: beam_agent_session_store_core:session_share().

-doc "Session summary — see beam_agent_session_store_core for the canonical definition.".
-type session_summary() :: beam_agent_session_store_core:session_summary().

-doc "Thread metadata — see beam_agent_threads_core for the canonical definition.".
-type thread_meta() :: beam_agent_threads_core:thread_meta().

%%--------------------------------------------------------------------
%% Shared Derived Types
%%--------------------------------------------------------------------

-doc "Result of reading a thread with its messages.".
-type thread_read_result() :: #{
    thread := thread_meta(),
    messages => [beam_agent_core:message()]
}.

-doc """
Result of resuming a thread. Contains thread metadata, messages, and
denormalized fields for direct access without nested lookups.
""".
-type thread_resume_result() :: #{
    archived => boolean(),
    archived_at => integer(),
    created_at => integer(),
    message_count => non_neg_integer(),
    messages => [map()],
    metadata => map(),
    name => binary(),
    parent_thread_id => binary(),
    session_id => binary(),
    status => active,
    summary => map(),
    thread => thread_meta(),
    thread_id => binary(),
    updated_at => integer(),
    visible_message_count => non_neg_integer()
}.

%%--------------------------------------------------------------------
%% Shared Enum / Union Types
%%--------------------------------------------------------------------

-doc "Keys returned in the initial backend handshake response.".
-type init_response_key() :: account | agents | commands | models.

-doc "Keys available via system_info queries.".
-type system_info_key() :: account | agents | models | slash_commands.

-doc "Default value for missing init response keys.".
-type init_default() :: [] | #{}.

-doc "Health states for a backend adapter session.".
-type session_health() ::
          ready | connecting | initializing | active_query | error.

%%--------------------------------------------------------------------
%% Re-exported Core Types (for backend package extraction)
%%--------------------------------------------------------------------

-doc "Session configuration options — see beam_agent_core for the canonical definition.".
-type session_opts() :: beam_agent_core:session_opts().

-doc "Per-query options — see beam_agent_core for the canonical definition.".
-type query_opts() :: beam_agent_core:query_opts().

-doc "Normalized message across all backends — see beam_agent_core for the canonical definition.".
-type message() :: beam_agent_core:message().

-doc "Message type discriminator — see beam_agent_core for the canonical definition.".
-type message_type() :: beam_agent_core:message_type().

%%--------------------------------------------------------------------
%% Re-exported Adapter Types (for backend package extraction)
%%--------------------------------------------------------------------

-doc "Backend category discriminator — see beam_agent_adapter for the canonical definition.".
-type backend_type() :: beam_agent_adapter:backend_type().

-doc "Capability atom — see beam_agent_adapter for the canonical definition.".
-type capability() :: beam_agent_adapter:capability().
