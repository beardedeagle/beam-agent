-module(beam_agent_test_helpers).

-export([fake_session/2, fake_session/3, cleanup_session/1, reset_state/0]).

-spec fake_session(binary(), atom()) -> pid().
fake_session(SessionId, Backend) ->
    fake_session(SessionId, Backend, #{}).

-spec fake_session(binary(), atom(), map()) -> pid().
fake_session(SessionId, Backend, ExtraInfo) ->
    Session = spawn(fun() -> fake_session_loop(SessionId, Backend, ExtraInfo) end),
    {ok, Backend} = beam_agent_backend:register_session(Session, Backend),
    Session.

fake_session_loop(SessionId, Backend, ExtraInfo) ->
    receive
        {'$gen_call', From, session_info} ->
            BaseInfo = #{
                session_id => SessionId,
                backend => Backend,
                adapter => Backend
            },
            gen:reply(From, {ok, maps:merge(BaseInfo, ExtraInfo)}),
            fake_session_loop(SessionId, Backend, ExtraInfo);
        stop ->
            ok;
        _Other ->
            fake_session_loop(SessionId, Backend, ExtraInfo)
    end.

-spec cleanup_session(pid()) -> ok.
cleanup_session(Session) ->
    ok = beam_agent_backend:unregister_session(Session),
    Session ! stop,
    ok.

-spec reset_state() -> ok.
reset_state() ->
    ok = beam_agent_runtime_core:clear(),
    ok = beam_agent_control_core:clear(),
    ok = beam_agent_session_store_core:clear(),
    ok = beam_agent_threads_core:clear(),
    ok = beam_agent_collaboration:clear(),
    ok = beam_agent_events:clear().
