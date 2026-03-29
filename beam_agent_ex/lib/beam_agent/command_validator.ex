defmodule BeamAgent.CommandValidator do
  @moduledoc """
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
    result. Fire-and-forget: the guard does not use the return value and
    catches any crash. Use this for auditing, learning, or adaptive security.

  Validators that need internal state should manage it themselves (ETS,
  persistent_term, or a dedicated process). The guard does not hold or
  manage validator state.

  ## Validation Context

  The validator receives comprehensive context — not just the command string.
  See `t:validation_context/0` for the full set of fields, which includes the
  parsed command structure, raw command, command form, session state, agent
  identity, working directory, environment variables, command history, static
  policy result, and extensible metadata.

  For post-execution notification, `on_execution/3` receives an
  `t:execution_context/0` — the same fields minus `policy_result` (a
  pre-execution concern) and `command_struct` (passed as the first argument).

  ## Configuration

  ```elixir
  # In config/config.exs:
  config :beam_agent, command_validator: :beam_agent_command_validator_default
  ```

  ## Custom Validator Example

  ```elixir
  defmodule MyValidator do
    @behaviour BeamAgent.CommandValidator

    @impl true
    def validate(%{program: "npm"}, %{agent: :claude, policy_result: :ask}), do: :allow
    def validate(_command, %{policy_result: :allow}), do: :allow
    def validate(_command, %{policy_result: {:deny, reason}}), do: {:deny, reason}

    @impl true
    def on_execution(_command, _ctx, {:ok, %{exit_code: 0}}), do: :ok
    def on_execution(_command, _ctx, _result), do: :ok
  end
  ```
  """

  @typedoc """
  Static policy evaluation result.

  - `:allow` — command passes static policy
  - `:ask` — command requires interactive confirmation
  - `{:deny, reason}` — command is blocked with a binary reason
  """
  @type policy_result() :: :allow | :ask | {:deny, binary()}

  @typedoc """
  Context passed to `on_execution/3` after command execution.

  Contains the raw command, command form, session state, agent identity,
  execution options, working directory, environment variables, command
  history, timestamp, and extensible metadata. Does not include
  `policy_result` or `command_struct` (those are pre-execution concerns).
  """
  @type execution_context() :: %{
          required(:raw_command) => binary() | String.t() | [binary()],
          required(:command_form) => :list | :string,
          required(:session_state) => atom() | nil,
          required(:agent) => atom() | nil,
          required(:opts) => map(),
          required(:cwd) => binary() | nil,
          required(:env) => [{String.t(), String.t()}] | nil,
          required(:history) => [map()],
          required(:timestamp) => integer(),
          required(:metadata) => map()
        }

  @typedoc """
  Context passed to `validate/2` before command execution.

  Extends `t:execution_context/0` with `:command_struct` (the parsed command
  structure from Layer 0) and `:policy_result` (the Layer 1 static policy
  evaluation result).
  """
  @type validation_context() :: %{
          required(:command_struct) => map(),
          required(:raw_command) => binary() | String.t() | [binary()],
          required(:command_form) => :list | :string,
          required(:session_state) => atom() | nil,
          required(:agent) => atom() | nil,
          required(:opts) => map(),
          required(:cwd) => binary() | nil,
          required(:env) => [{String.t(), String.t()}] | nil,
          required(:history) => [map()],
          required(:timestamp) => integer(),
          required(:policy_result) => policy_result(),
          required(:metadata) => map()
        }

  @doc """
  Validate a command before execution.

  Called for every command after static policy evaluation. Must return one of:

  - `:allow` — command proceeds to Layer 3
  - `{:deny, reason}` — command is blocked with the given binary reason
  - `{:deny, reason, details}` — command is blocked; `details` map is included
    in telemetry metadata for observability
  """
  @callback validate(command :: map(), context :: validation_context()) ::
              :allow
              | {:deny, reason :: binary()}
              | {:deny, reason :: binary(), details :: map()}

  @doc """
  Called after command execution with the result.

  Optional, fire-and-forget notification. The guard does not use the return
  value and wraps the call in a `try/catch` — a crash here is logged but
  never breaks command recording.

  Use this for auditing, adaptive security, or feeding execution data into
  an external system. If you need internal state, manage it yourself (ETS,
  persistent_term, a dedicated process). The guard does not hold or thread
  validator state.
  """
  @callback on_execution(
              command :: map(),
              context :: execution_context(),
              exec_result :: {:ok, map()} | {:error, any()}
            ) :: :ok

  @optional_callbacks on_execution: 3
end
