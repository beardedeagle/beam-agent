%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_backend.
%%%-------------------------------------------------------------------
-module(beam_agent_backend_tests).

-include_lib("eunit/include/eunit.hrl").

normalize_aliases_test() ->
    ?assertEqual({ok, claude}, beam_agent_backend:normalize(<<"claude_agent_sdk">>)),
    ?assertEqual({ok, codex}, beam_agent_backend:normalize(codex_app_server)),
    ?assertEqual({ok, gemini}, beam_agent_backend:normalize("gemini_cli_client")),
    ?assertEqual({ok, opencode}, beam_agent_backend:normalize(<<"opencode">>)),
    ?assertEqual({ok, copilot}, beam_agent_backend:normalize(copilot)).

register_and_lookup_session_test() ->
    ok = beam_agent_backend:clear(),
    {ok, codex} = beam_agent_backend:register_session(self(), codex),
    ?assertEqual({ok, codex}, beam_agent_backend:session_backend(self())).

infer_backend_from_session_info_test() ->
    ok = beam_agent_backend:clear(),
    Session = spawn(fun() -> fake_session_loop(#{adapter => claude}) end),
    ?assertEqual({ok, claude}, beam_agent_backend:session_backend(Session)),
    Session ! stop.

copilot_terminal_error_semantics_test() ->
    ?assert(beam_agent_backend:is_terminal(copilot, #{type => result})),
    ?assertNot(beam_agent_backend:is_terminal(copilot, #{type => error})),
    ?assert(beam_agent_backend:is_terminal(copilot, #{type => error, is_error => true})),
    ?assert(beam_agent_backend:is_terminal(claude, #{type => error})).

fake_session_loop(Info) ->
    receive
        {'$gen_call', From, session_info} ->
            gen:reply(From, {ok, Info}),
            fake_session_loop(Info);
        stop ->
            ok;
        _Other ->
            fake_session_loop(Info)
    end.
