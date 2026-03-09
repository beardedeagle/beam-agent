-module(beam_agent_command).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for the consolidated command execution layer.".

-export([run/1, run/2]).
-export_type([command_opts/0, command_result/0]).

-type command_opts() :: beam_agent_command_core:command_opts().
-type command_result() :: beam_agent_command_core:command_result().

run(Command) -> beam_agent_command_core:run(Command).
run(Command, Opts) -> beam_agent_command_core:run(Command, Opts).
