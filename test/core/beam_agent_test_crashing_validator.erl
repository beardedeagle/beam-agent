-module(beam_agent_test_crashing_validator).
-moduledoc false.

%% Test-only validator that always crashes.
%% Used by beam_agent_command_guard_tests to verify fail-safe deny.

-behaviour(beam_agent_command_validator).

-export([validate/2]).

-spec validate(beam_agent_command_parser:command_struct(),
               beam_agent_command_validator:validation_context()) -> no_return().
validate(_Command, _Context) ->
    error(intentional_crash).
