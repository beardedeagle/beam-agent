-module(beam_agent_test_helpers).

-export([
    register_session/2,
    register_session/3,
    cleanup_session/1,
    reset_state/0
]).

-spec register_session(binary(), atom()) -> binary().
register_session(SessionId, Backend) ->
    register_session(SessionId, Backend, #{}).

-spec register_session(binary(), atom(), map()) -> binary().
register_session(SessionId, Backend, ExtraInfo)
  when is_binary(SessionId), is_atom(Backend), is_map(ExtraInfo) ->
    Meta = maps:merge(#{
        session_id => SessionId,
        backend => Backend,
        adapter => Backend
    }, ExtraInfo),
    ok = beam_agent_session_store_core:register_session(SessionId, Meta),
    SessionId.

-spec cleanup_session(binary()) -> ok.
cleanup_session(SessionId) when is_binary(SessionId) ->
    ok = beam_agent_runtime_core:clear_session(SessionId),
    ok = beam_agent_session_store_core:delete_session(SessionId),
    ok.

-spec reset_state() -> ok.
reset_state() ->
    ok = beam_agent_backend:clear(),
    ok = beam_agent_runtime_core:clear(),
    ok = beam_agent_control_core:clear(),
    ok = beam_agent_orchestrator_core:clear(),
    ok = beam_agent_session_store_core:clear(),
    ok = beam_agent_threads_core:clear(),
    ok = beam_agent_collaboration:clear(),
    ok = beam_agent_events:clear().
