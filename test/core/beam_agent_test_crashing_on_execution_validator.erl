-module(beam_agent_test_crashing_on_execution_validator).
-moduledoc false.

%% Test-only validator that allows validation but crashes on on_execution.
%% Used by beam_agent_command_guard_tests to verify that a crashing
%% on_execution/3 callback does not break record_execution/3.

-behaviour(beam_agent_command_validator).

-export([validate/2, on_execution/3]).

-spec validate(beam_agent_command_parser:command_struct(),
               beam_agent_command_validator:validation_context()) -> allow.
validate(_Command, _Context) ->
    allow.

-spec on_execution(beam_agent_command_parser:command_struct(),
                   beam_agent_command_validator:execution_context(),
                   {ok, map()} | {error, term()}) -> no_return().
on_execution(_Command, _Context, _ExecResult) ->
    error(intentional_crash).
