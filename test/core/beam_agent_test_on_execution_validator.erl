-module(beam_agent_test_on_execution_validator).
-moduledoc false.

%% Test-only validator that records on_execution calls to ETS.
%% Used by beam_agent_command_guard_tests to verify post-execution
%% notification.  The test creates a named ETS table
%% (test_on_execution_log) before init; on_execution/3 writes there.

-behaviour(beam_agent_command_validator).

-export([validate/2, on_execution/3]).

-spec validate(beam_agent_command_parser:command_struct(),
               beam_agent_command_validator:validation_context()) -> allow.
validate(_Command, _Context) ->
    allow.

-spec on_execution(beam_agent_command_parser:command_struct(),
                   beam_agent_command_validator:execution_context(),
                   {ok, map()} | {error, term()}) -> ok.
on_execution(Command, _Context, ExecResult) ->
    ets:insert(test_on_execution_log,
               {erlang:monotonic_time(), Command, ExecResult}),
    ok.
