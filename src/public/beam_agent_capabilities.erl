-module(beam_agent_capabilities).
-moduledoc """
Canonical capability metadata for `beam_agent`.

The public model is expressed in three orthogonal dimensions:

  - `support_level`: `missing`, `partial`, `baseline`, or `full`
  - `implementation`: `direct_backend`, `universal`, or
    `direct_backend_and_universal`
  - `fidelity`: `exact` or `validated_equivalent`

All 22 capabilities are at `full` parity across all 5 backends. Every
capability/backend pair has a universal fallback, ensuring full availability
regardless of backend choice. The `implementation` and `fidelity` fields record
whether the supported route is a direct backend path, a universal BeamAgent
path, or a hybrid of the two.

`beam_agent_capabilities` is the sole capability registry for the project and
the source for the `docs/architecture/*matrix*.md` artifacts.
""".

-export([
    all/0,
    backends/0,
    capability_ids/0,
    for_backend/1,
    for_session/1,
    status/2,
    supports/2
]).

-export_type([
    capability/0,
    capability_info/0,
    support_info/0,
    support_level/0,
    implementation/0,
    fidelity/0
]).

-type capability() ::
    session_lifecycle
  | session_info
  | runtime_model_switch
  | interrupt
  | permission_mode
  | session_history
  | session_mutation
  | thread_management
  | metadata_accessors
  | in_process_mcp
  | mcp_management
  | hooks
  | checkpointing
  | thinking_budget
  | task_stop
  | command_execution
  | approval_callbacks
  | user_input_callbacks
  | realtime_review
  | config_management
  | provider_management
  | attachments
  | event_streaming.

-type support_level() :: missing | partial | baseline | full.
-type implementation() :: direct_backend | universal | direct_backend_and_universal.
-type fidelity() :: exact | validated_equivalent.

-type support_info() :: #{
    support_level := support_level(),
    implementation := implementation(),
    fidelity := fidelity(),
    available_paths => [implementation()],
    notes => binary()
}.

-type capability_error() :: {unknown_capability, capability()}.
-type backend_lookup_error() ::
    backend_not_present |
    {unknown_backend, term()} |
    {invalid_session_info, term()} |
    {session_backend_lookup_failed, term()}.
-type status_error() :: capability_error() | {unknown_backend, term()}.
-type support_entry_info() :: #{
    support_level := support_level(),
    implementation := implementation(),
    fidelity := fidelity(),
    available_paths => [implementation()],
    notes => binary()
}.

-dialyzer({no_underspecs, [support/3, support/4]}).

-type capability_info() :: #{
    id := capability(),
    title := binary(),
    support := #{beam_agent_backend:backend() => support_info()}
}.

-spec all() -> [capability_info()].
all() ->
    [
        capability(session_lifecycle, <<"Session lifecycle">>,
            all_backends(full, direct_backend, exact)),
        capability(session_info, <<"Session info">>,
            all_backends(full, direct_backend, exact)),
        capability(runtime_model_switch, <<"Runtime model switch">>,
            all_backends(full, direct_backend, exact)),
        capability(interrupt, <<"Interrupt active work">>,
            all_backends(full, direct_backend, exact)),
        capability(permission_mode, <<"Runtime permission mode change">>, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        capability(session_history, <<"Session history">>, #{
            claude => support(full, direct_backend, exact,
                #{available_paths => [direct_backend, direct_backend_and_universal],
                  notes => <<"Claude also retains a shared SDK session store view.">>}),
            codex => support(full, universal, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, direct_backend, exact,
                #{available_paths => [direct_backend, direct_backend_and_universal],
                  notes => <<"OpenCode exposes server-native history and shared store history.">>}),
            copilot => support(full, universal, validated_equivalent)
        }),
        capability(session_mutation, <<"Session fork, revert, share, summarize">>, #{
            claude => support(full, universal, validated_equivalent),
            codex => support(full, universal, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, direct_backend, exact,
                #{available_paths => [direct_backend, direct_backend_and_universal]}),
            copilot => support(full, universal, validated_equivalent)
        }),
        capability(thread_management, <<"Thread lifecycle and history">>, #{
            claude => support(full, universal, validated_equivalent),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        capability(metadata_accessors, <<"Catalog and metadata accessors">>,
            all_backends(full, universal, validated_equivalent)),
        capability(in_process_mcp, <<"In-process MCP servers and tools">>,
            all_backends(full, universal, exact)),
        capability(mcp_management, <<"MCP management">>, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, direct_backend, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, universal, validated_equivalent)
        }),
        capability(hooks, <<"SDK lifecycle hooks">>,
            all_backends(full, universal, exact)),
        capability(checkpointing, <<"File checkpointing">>, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, universal, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        capability(thinking_budget, <<"Thinking budget control">>, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, universal, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        capability(task_stop, <<"Stop task by id">>, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, universal, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        capability(command_execution, <<"Command execution and turn response">>, #{
            claude => support(full, universal, validated_equivalent),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        capability(approval_callbacks, <<"Approval and permission callbacks">>, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, exact,
                #{notes => <<"Native Gemini ACP reverse permission requests feed the universal callback broker for the canonical surface.">>}),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, direct_backend, exact)
        }),
        capability(user_input_callbacks, <<"User input callbacks">>, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, exact,
                #{notes => <<"Universal callback broker services canonical user-input requests for Gemini sessions.">>}),
            opencode => support(full, universal, exact,
                #{notes => <<"Universal callback broker services canonical user-input requests for OpenCode sessions.">>}),
            copilot => support(full, direct_backend, exact)
        }),
        capability(realtime_review, <<"Realtime, review, collaboration">>, #{
            claude => support(full, universal, exact,
                #{notes => <<"Universal collaboration layer provides canonical review and realtime participation.">>}),
            codex => support(full, direct_backend_and_universal, exact,
                #{available_paths => [direct_backend, universal],
                  notes => <<"Native Codex review/realtime APIs remain available while realtime transport bridges review and collaboration through the universal layer.">>}),
            gemini => support(full, universal, exact,
                #{notes => <<"Universal collaboration layer provides canonical review and realtime participation.">>}),
            opencode => support(full, direct_backend_and_universal, exact,
                #{available_paths => [direct_backend, universal],
                  notes => <<"Native OpenCode events remain available while the canonical review and realtime layer stays universal.">>}),
            copilot => support(full, universal, exact,
                #{notes => <<"Universal collaboration layer provides canonical review and realtime participation.">>})
        }),
        capability(config_management, <<"Config management">>, #{
            claude => support(full, universal, exact,
                #{notes => <<"Universal config layer persists canonical runtime and control state for Claude sessions.">>}),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, exact,
                #{notes => <<"Universal config layer persists canonical runtime and control state for Gemini sessions.">>}),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, direct_backend_and_universal, exact,
                #{available_paths => [direct_backend, universal],
                  notes => <<"Copilot keeps native session/admin config calls while the canonical config layer fills the shared surface.">>})
        }),
        capability(provider_management, <<"Provider and runtime management">>, #{
            claude => support(full, universal, exact,
                #{notes => <<"Universal runtime/provider layer exposes provider selection and auth metadata for Claude sessions.">>}),
            codex => support(full, direct_backend_and_universal, exact,
                #{available_paths => [direct_backend, universal],
                  notes => <<"Codex keeps native model/runtime controls while the universal provider layer exposes canonical provider management.">>}),
            gemini => support(full, universal, exact,
                #{notes => <<"Universal runtime/provider layer exposes provider selection and auth metadata for Gemini sessions.">>}),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, universal, exact)
        }),
        capability(attachments, <<"Attachments in query and send">>, #{
            claude => support(full, universal, exact,
                #{notes => <<"Universal attachment materialization renders canonical attachment blocks into backend-safe input for Claude sessions.">>}),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, exact,
                #{notes => <<"Universal attachment materialization renders canonical attachment blocks into backend-safe input for Gemini sessions.">>}),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, direct_backend, exact)
        }),
        capability(event_streaming, <<"Backend event streaming">>, #{
            claude => support(full, universal, exact,
                #{notes => <<"Universal event bus streams canonical session and control events for Claude sessions.">>}),
            codex => support(full, direct_backend_and_universal, exact,
                #{available_paths => [direct_backend, universal],
                  notes => <<"Codex keeps native control notifications while the canonical event bus provides a stable stream for every backend.">>}),
            gemini => support(full, universal, exact,
                #{notes => <<"Universal event bus streams canonical session and control events fed by Gemini ACP notifications.">>}),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, universal, exact,
                #{notes => <<"Universal event bus streams canonical session and control events for Copilot sessions.">>})
        })
    ].

-spec backends() -> [beam_agent_backend:backend()].
backends() ->
    beam_agent_backend:available_backends().

-spec capability_ids() -> [capability()].
capability_ids() ->
    [maps:get(id, Capability) || Capability <- all()].

-spec for_backend(beam_agent_backend:backend() | binary() | atom()) ->
    {ok, [map()]} | {error, term()}.
for_backend(BackendLike) ->
    case beam_agent_backend:normalize(BackendLike) of
        {ok, Backend} ->
            {ok, [project_capability(Capability, Backend) || Capability <- all()]};
        {error, _} = Error ->
            Error
    end.

-spec for_session(pid()) -> {ok, [map()]} | {error, backend_lookup_error()}.
for_session(Session) when is_pid(Session) ->
    case beam_agent_backend:session_backend(Session) of
        {ok, Backend} ->
            for_backend(Backend);
        {error, _} = Error ->
            Error
    end.

-spec status(capability(), beam_agent_backend:backend() | binary() | atom()) ->
    {ok, support_info()} | {error, term()}.
status(Capability, BackendLike) ->
    case {lookup_capability(Capability), beam_agent_backend:normalize(BackendLike)} of
        {{ok, Info}, {ok, Backend}} ->
            {ok, maps:get(Backend, maps:get(support, Info))};
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

-spec supports(capability(), beam_agent_backend:backend() | binary() | atom()) ->
    {ok, true} | {error, status_error()}.
supports(Capability, BackendLike) ->
    case status(Capability, BackendLike) of
        {ok, _Support} ->
            {ok, true};
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec capability(capability(), binary(), #{beam_agent_backend:backend() => support_info()}) ->
    capability_info().
capability(Id, Title, Support) ->
    #{id => Id, title => Title, support => Support}.

-spec all_backends(support_level(), implementation(), fidelity()) ->
    #{beam_agent_backend:backend() => support_info()}.
all_backends(SupportLevel, Implementation, Fidelity) ->
    maps:from_list([{Backend, support(SupportLevel, Implementation, Fidelity)} || Backend <- backends()]).

-spec support(support_level(), implementation(), fidelity()) -> support_entry_info().
support(SupportLevel, Implementation, Fidelity) ->
    #{support_level => SupportLevel, implementation => Implementation, fidelity => Fidelity}.

-spec support(support_level(), implementation(), fidelity(), map()) -> support_entry_info().
support(SupportLevel, Implementation, Fidelity, Extra) ->
    maps:merge(support(SupportLevel, Implementation, Fidelity), Extra).

-spec project_capability(capability_info(), beam_agent_backend:backend()) -> map().
project_capability(Capability, Backend) ->
    SupportInfo = maps:get(Backend, maps:get(support, Capability)),
    maps:merge(
        #{
            id => maps:get(id, Capability),
            title => maps:get(title, Capability),
            backend => Backend,
            support_level => maps:get(support_level, SupportInfo),
            implementation => maps:get(implementation, SupportInfo),
            fidelity => maps:get(fidelity, SupportInfo)
        },
        extra_projection_fields(SupportInfo)
    ).

-spec extra_projection_fields(support_info()) -> map().
extra_projection_fields(SupportInfo) ->
    maps:with([available_paths, notes], SupportInfo).

-spec lookup_capability(capability()) -> {ok, capability_info()} | {error, term()}.
lookup_capability(Capability) ->
    case [Info || Info <- all(), maps:get(id, Info) =:= Capability] of
        [Info] -> {ok, Info};
        [] -> {error, {unknown_capability, Capability}}
    end.
