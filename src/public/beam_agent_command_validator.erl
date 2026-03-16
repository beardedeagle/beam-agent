-module(beam_agent_command_validator).
-moduledoc """
Behaviour for command execution validation (Layer 2).

Implement this behaviour to define custom security policies for command
execution. The validator is called after static policy evaluation (Layer 1)
and before the security guard (Layer 3) applies rate limits and temporal
pattern detection.

The default implementation (`beam_agent_command_validator_default`) defers
to the policy result. Replace it to implement deep inspection, intent-based
reasoning, or integration with external security systems (e.g., Citadel).

## Callbacks

- `validate/2` — **required**. Called for every command before execution.
  Must return quickly (the command blocks until validation completes).
- `on_execution/3` — **optional**. Called after command execution with the
  result.  Fire-and-forget: the guard does not use the return value and
  catches any crash.  Use this for auditing, learning, or adaptive security.

Validators that need internal state should manage it themselves (ETS,
persistent_term, or a dedicated process). The guard does not hold or
manage validator state.

## Validation Context

The validator receives comprehensive context — not just the command string:

```erlang
beam_agent_command_validator:validation_context()
```

Includes the parsed command structure, raw command, command form (list vs
string), session state, agent identity, working directory, environment
variables, command history, static policy result, and extensible metadata.

For post-execution notification, `on_execution/3` receives an
`execution_context()` — the same fields minus `policy_result` (a
pre-execution concern) and `command_struct` (passed as the first argument).

## Configuration

```erlang
%% In sys.config:
{beam_agent, [
    {command_validator, beam_agent_command_validator_default}
]}.
```

## Custom Validator Example

```erlang
-module(my_validator).
-behaviour(beam_agent_command_validator).
-export([validate/2, on_execution/3]).

validate(Command, #{agent := claude, policy_result := ask} = Ctx) ->
    %% Custom logic for Claude's ask-mode commands
    case maps:get(program, Command, undefined) of
        <<"npm">> -> allow;
        _ -> {deny, <<"Only npm allowed in ask mode">>}
    end;
validate(_Command, #{policy_result := allow}) -> allow;
validate(_Command, #{policy_result := {deny, R}}) -> {deny, R}.

on_execution(Command, _Ctx, {ok, #{exit_code := 0}}) ->
    %% Record successful commands for learning
    ok;
on_execution(_Command, _Ctx, _Result) ->
    ok.
```
""".

-export_type([
    validation_context/0,
    execution_context/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type execution_context() :: #{
    %% Raw command as provided by caller
    raw_command := binary() | string() | [binary()],

    %% Command form: list-form is inherently safer
    command_form := list | string,

    %% Session state from the backend gen_statem
    session_state := atom() | undefined,

    %% Agent identity
    agent := atom() | undefined,

    %% Command execution options
    opts := map(),

    %% Working directory (if specified)
    cwd := binary() | undefined,

    %% Environment variables being set
    env := [{string(), string()}] | undefined,

    %% Command history — last N command entries
    history := [map()],

    %% Timestamp
    timestamp := integer(),

    %% Custom metadata (extensible by Citadel)
    metadata := map()
}.

-type validation_context() :: #{
    %% The parsed command structure (from Layer 0)
    command_struct := beam_agent_command_parser:command_struct(),

    %% Raw command as provided by caller
    raw_command := binary() | string() | [binary()],

    %% Command form: list-form is inherently safer
    command_form := list | string,

    %% Session state from the backend gen_statem
    session_state := atom() | undefined,

    %% Agent identity
    agent := atom() | undefined,

    %% Command execution options
    opts := map(),

    %% Working directory (if specified)
    cwd := binary() | undefined,

    %% Environment variables being set
    env := [{string(), string()}] | undefined,

    %% Command history — last N command entries
    history := [map()],

    %% Timestamp
    timestamp := integer(),

    %% Static policy result (from Layer 1)
    policy_result := beam_agent_command_policy:policy_result(),

    %% Custom metadata (extensible by Citadel)
    metadata := map()
}.

%%--------------------------------------------------------------------
%% Callbacks
%%--------------------------------------------------------------------

-doc """
Validate a command before execution.

Called for every command after static policy evaluation. Must return one of:
- `allow` — command proceeds to Layer 3
- `{deny, Reason}` — command is blocked with the given reason
- `{deny, Reason, Details}` — command is blocked; Details map is included
  in telemetry metadata for observability
""".
-callback validate(Command, Context) -> Result when
    Command :: beam_agent_command_parser:command_struct(),
    Context :: validation_context(),
    Result  :: allow
             | {deny, Reason :: binary()}
             | {deny, Reason :: binary(), Details :: map()}.

-doc """
Called after command execution with the result.

Optional, fire-and-forget notification.  The guard does not use the return
value and wraps the call in a `try/catch` — a crash here is logged but
never breaks command recording.

Use this for auditing, adaptive security, or feeding execution data into
an external system.  If you need internal state, manage it yourself (ETS,
persistent_term, a dedicated process).  The guard does not hold or thread
validator state.
""".
-callback on_execution(Command, Context, ExecResult) -> ok when
    Command    :: beam_agent_command_parser:command_struct(),
    Context    :: execution_context(),
    ExecResult :: {ok, map()} | {error, term()}.

-optional_callbacks([on_execution/3]).
