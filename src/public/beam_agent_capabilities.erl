-module(beam_agent_capabilities).
-moduledoc """
Canonical capability metadata for `beam_agent`.

This module is the single source of truth for which features each backend
supports and how. It answers questions like "can I use checkpointing with
Gemini?" or "does OpenCode have a direct implementation of thread management?"

## Capability model

Every capability/backend pair is described across three orthogonal dimensions:

  - `support_level` — `missing | partial | baseline | full`
  - `implementation` — `direct_backend | universal | direct_backend_and_universal`
  - `fidelity` — `exact | validated_equivalent`

All 22 capabilities are at `full` support level across all 5 backends. The
`implementation` field records whether the route is a direct backend call, a
BeamAgent universal path (OTP-layer shim), or a hybrid that exposes both.

## The 22 capabilities

```
session_lifecycle       session_info            runtime_model_switch
interrupt               permission_mode         session_history
session_mutation        thread_management       metadata_accessors
in_process_mcp          mcp_management          hooks
checkpointing           thinking_budget         task_stop
command_execution       approval_callbacks      user_input_callbacks
realtime_review         config_management       provider_management
attachments             event_streaming
```

## Quick start

```erlang
%% Is checkpointing supported for codex?
{ok, true} = beam_agent_capabilities:supports(checkpointing, codex).

%% What implementation does gemini use for permission_mode?
{ok, #{implementation := universal}} =
    beam_agent_capabilities:status(permission_mode, gemini).

%% Full capability list for a live session:
{ok, Caps} = beam_agent_capabilities:for_session(SessionPid).
```

## Core concepts

Every capability/backend combination has three attributes: support level
(missing, partial, baseline, or full), implementation route (direct
backend call, universal OTP shim, or both), and fidelity (exact match
or validated equivalent behavior).

All 22 capabilities are at full support across all 5 backends. Use
supports/2 to check if a feature works with a backend, and status/2 to
see how it is implemented. for_session/1 returns the full capability map
for a live session.

This module is read-only metadata. It does not execute features -- it
tells you whether a feature is available and how it is wired.

## Architecture deep dive

beam_agent_capabilities is the sole capability registry for the project
and the normative source for docs/architecture matrix artifacts. All
entries are compiled-in static data -- there is no ETS or runtime state.

The implementation field distinguishes three routes: direct_backend
(the backend CLI handles it natively), universal (the OTP-layer shim
in a core module handles it), and direct_backend_and_universal (both
paths exist and the native_or pattern selects at runtime).

When adding a new backend, all 22 capabilities must be registered.
Missing entries cause for_session/1 to return incomplete maps, which
downstream code treats as unsupported.

## Architecture note

`beam_agent_capabilities` is the sole capability registry for the project and
the normative source for the `docs/architecture/*matrix*.md` artifacts.
All entries are compiled-in static data — there is no ETS or runtime state.

## Backend Integration

When adding a new backend, register all 22 capabilities with support level,
implementation route, and fidelity. See docs/guides/backend_integration_guide.md
for details.
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
-dialyzer({no_underspecs, [support/3, support/4]}).

-type capability_info() :: #{
    id := capability(),
    title := binary(),
    support := #{beam_agent_backend:backend() => support_info()}
}.

-doc """
Return the full capability matrix as a list of `capability_info()` maps.

Each entry contains the capability `id`, a human-readable `title`, and a
`support` map keyed by backend atom. The support map for each backend holds
`support_level`, `implementation`, `fidelity`, and optionally `available_paths`
and `notes`.

This is the master data source consulted by all other functions in this module.
Use `capability_ids/0` if you only need the atom list.

```erlang
AllCaps = beam_agent_capabilities:all(),
[#{id := session_lifecycle, title := <<"Session lifecycle">>, support := S} | _] = AllCaps.
```
""".
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

-doc """
Return the list of all supported backend atoms.

The five backends are: `claude`, `codex`, `gemini`, `opencode`, `copilot`.
This list is the authoritative enumeration used internally to build the
capability matrix. Use it when iterating over all backends programmatically.

```erlang
[claude, codex, gemini, opencode, copilot] = beam_agent_capabilities:backends().
```
""".
-spec backends() -> [beam_agent_backend:backend()].
backends() ->
    beam_agent_backend:available_backends().

-doc """
Return the flat list of all 22 capability atom identifiers.

Useful for iterating over capabilities without loading the full matrix.
The order matches the order of entries in `all/0`.

```erlang
Ids = beam_agent_capabilities:capability_ids(),
true = lists:member(checkpointing, Ids).
```
""".
-spec capability_ids() -> [capability()].
capability_ids() ->
    [maps:get(id, Capability) || Capability <- all()].

-doc """
Return the projected capability list for a specific backend.

`BackendLike` may be a backend atom (`claude`), a binary (`<<"codex">>`), or any
value accepted by `beam_agent_backend:normalize/1`.

Each entry in the returned list is a flat map with the fields `id`, `title`,
`backend`, `support_level`, `implementation`, and `fidelity`, plus optional
`available_paths` and `notes` where present. This is the per-backend projection
of the full matrix returned by `all/0`.

Returns `{error, {unknown_backend, Backend}}` for unrecognised backend values.

```erlang
{ok, Caps} = beam_agent_capabilities:for_backend(claude),
[#{id := session_lifecycle, support_level := full} | _] = Caps.
```
""".
-spec for_backend(beam_agent_backend:backend() | binary() | atom()) ->
    {ok, [map()]} | {error, term()}.
for_backend(BackendLike) ->
    case beam_agent_backend:normalize(BackendLike) of
        {ok, Backend} ->
            {ok, [project_capability(Capability, Backend) || Capability <- all()]};
        {error, _} = Error ->
            Error
    end.

-doc """
Return the projected capability list for the backend of a live session.

Resolves the backend from the running session process and delegates to
`for_backend/1`. This is the most convenient call during an active agent
session when you do not know — or do not want to hard-code — the backend.

Returns `{error, backend_not_present}` if the session process is not
registered, or `{error, {session_backend_lookup_failed, Reason}}` for other
lookup failures.

```erlang
{ok, SessionPid} = beam_agent:start_session(#{backend => gemini}),
{ok, Caps} = beam_agent_capabilities:for_session(SessionPid).
```
""".
-spec for_session(pid()) -> {ok, [map()]} | {error, backend_lookup_error()}.
for_session(Session) when is_pid(Session) ->
    case beam_agent_backend:session_backend(Session) of
        {ok, Backend} ->
            for_backend(Backend);
        {error, _} = Error ->
            Error
    end.

-doc """
Return the full `support_info()` map for a specific capability/backend pair.

The returned map always contains `support_level`, `implementation`, and
`fidelity`. It may also include `available_paths` (a list of implementation
atoms) and `notes` (a binary) where the capability has backend-specific detail.

Returns `{error, {unknown_capability, Cap}}` for an unrecognised capability
atom, or `{error, {unknown_backend, Backend}}` for an unrecognised backend.

```erlang
{ok, #{support_level := full,
       implementation := universal,
       fidelity := validated_equivalent}} =
    beam_agent_capabilities:status(permission_mode, gemini).
```
""".
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

-doc """
Check whether a capability is supported for a given backend.

This is a convenience wrapper around `status/2`. Because all 22 capabilities
are at `full` support level for all 5 backends, this function returns
`{ok, true}` for every valid capability/backend combination. It exists to make
guard-style checks readable and to surface `{error, ...}` for typos.

Returns `{error, {unknown_capability, Cap}}` or `{error, {unknown_backend, B}}`
for invalid inputs.

```erlang
{ok, true} = beam_agent_capabilities:supports(checkpointing, codex).
{ok, true} = beam_agent_capabilities:supports(in_process_mcp, <<"gemini">>).
{error, {unknown_capability, bogus}} = beam_agent_capabilities:supports(bogus, claude).
```
""".
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

-spec support(support_level(), implementation(), fidelity()) -> support_info().
support(SupportLevel, Implementation, Fidelity) ->
    #{support_level => SupportLevel, implementation => Implementation, fidelity => Fidelity}.

-spec support(support_level(), implementation(), fidelity(), map()) -> support_info().
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
