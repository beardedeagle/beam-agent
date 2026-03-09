-module(beam_agent_runtime).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for runtime/provider state inside the consolidated package.".

-export([
    ensure_tables/0,
    clear/0,
    register_session/2,
    clear_session/1,
    get_state/1,
    current_provider/1,
    set_provider/2,
    clear_provider/1,
    get_provider_config/1,
    set_provider_config/2,
    current_agent/1,
    set_agent/2,
    clear_agent/1,
    list_providers/1,
    provider_status/1,
    provider_status/2,
    validate_provider_config/2,
    merge_query_opts/2
]).

ensure_tables() -> beam_agent_runtime_core:ensure_tables().
clear() -> beam_agent_runtime_core:clear().
register_session(Session, Opts) -> beam_agent_runtime_core:register_session(Session, Opts).
clear_session(Session) -> beam_agent_runtime_core:clear_session(Session).
get_state(Session) -> beam_agent_runtime_core:get_state(Session).
current_provider(Session) -> beam_agent_runtime_core:current_provider(Session).
set_provider(Session, ProviderId) -> beam_agent_runtime_core:set_provider(Session, ProviderId).
clear_provider(Session) -> beam_agent_runtime_core:clear_provider(Session).
get_provider_config(Session) -> beam_agent_runtime_core:get_provider_config(Session).
set_provider_config(Session, Config) -> beam_agent_runtime_core:set_provider_config(Session, Config).
current_agent(Session) -> beam_agent_runtime_core:current_agent(Session).
set_agent(Session, AgentId) -> beam_agent_runtime_core:set_agent(Session, AgentId).
clear_agent(Session) -> beam_agent_runtime_core:clear_agent(Session).
list_providers(Session) -> beam_agent_runtime_core:list_providers(Session).
provider_status(Session) -> beam_agent_runtime_core:provider_status(Session).
provider_status(Session, ProviderId) -> beam_agent_runtime_core:provider_status(Session, ProviderId).
validate_provider_config(ProviderId, Config) ->
    beam_agent_runtime_core:validate_provider_config(ProviderId, Config).
merge_query_opts(Session, Params) -> beam_agent_runtime_core:merge_query_opts(Session, Params).
