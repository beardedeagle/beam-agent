-module(beam_agent_capabilities).
-moduledoc """
Pluggable capability registry for `beam_agent`.

This module is the single source of truth for which features each backend
supports and how. It answers questions like "can I use checkpointing with
Gemini?" or "does OpenCode have a direct implementation of thread management?"

## Capability model

Every capability/backend pair is described across three orthogonal dimensions:

  - `support_level` — `missing | partial | baseline | full`
  - `implementation` — `direct_backend | universal | direct_backend_and_universal`
  - `fidelity` — `exact | validated_equivalent`

All 24 built-in capabilities are at `full` support level across all 5 built-in
backends. The `implementation` field records whether the route is a direct backend
call, a BeamAgent universal path (OTP-layer shim), or a hybrid that exposes both.

## Pluggable Registration

The capability matrix is stored in ETS at runtime, seeded from built-in
defaults on first access. Additional backends can register capabilities
via `register_backend/2`, and individual capability entries can be
overridden via `register_capability/3`.

```erlang
%% Register a new backend with all 24 capabilities:
ok = beam_agent_capabilities:register_backend(my_backend, #{
    session_lifecycle => #{support_level => full,
                           implementation => direct_backend,
                           fidelity => exact},
    %% ... remaining 21 capabilities
}).

%% Override a single capability for an existing backend:
ok = beam_agent_capabilities:register_capability(gemini, checkpointing, #{
    support_level => full,
    implementation => direct_backend,
    fidelity => exact
}).
```

## The 24 capabilities

```
session_lifecycle       session_info            runtime_model_switch
interrupt               permission_mode         session_history
session_mutation        thread_management       metadata_accessors
in_process_mcp          mcp_management          hooks
checkpointing           thinking_budget         task_stop
command_execution       approval_callbacks      user_input_callbacks
realtime_review         config_management       provider_management
attachments             event_streaming         memory
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

## Architecture note

`beam_agent_capabilities` is the sole capability registry for the project and
the normative source for the `docs/architecture/*matrix*.md` artifacts.
Entries are ETS-backed runtime data seeded from compiled-in defaults.
""".

-export([
    all/0,
    capabilities/0,
    capabilities/1,
    backends/0,
    capability_ids/0,
    for_backend/1,
    for_session/1,
    status/2,
    supports/2,
    assert_capability/2,
    register_backend/2,
    register_capability/3,
    unregister_backend/1,
    reset/0,
    ensure_tables/0
]).

-export_type([
    capability/0,
    capability_info/0,
    support_info/0,
    support_level/0,
    implementation/0,
    fidelity/0,
    capability_error/0,
    backend_lookup_error/0,
    status_error/0,
    assert_capability_error/0
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
  | event_streaming
  | memory.

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
-type assert_capability_error() ::
    {unsupported_capability, capability(), beam_agent_backend:backend()} |
    status_error().
%% Suppress underspec warnings for support/3,4: the return type is intentionally
%% broader than what Dialyzer infers because callers may extend the registry
%% with custom capability entries whose support_info() maps contain additional
%% optional keys (available_paths, notes).
-dialyzer({no_underspecs, [support/3, support/4]}).

-type capability_info() :: #{
    id := capability(),
    title := binary(),
    support := #{beam_agent_backend:backend() => support_info()}
}.

-define(REG_TABLE, beam_agent_registry).

%%--------------------------------------------------------------------
%% Table Management
%%--------------------------------------------------------------------

-doc "Ensure the capability registry ETS tables exist and are seeded.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    ok = beam_agent_registry:ensure_table(),
    %% Seed defaults on first call (check for a known seeded key).
    case ets:lookup(?REG_TABLE, {capability, claude, session_lifecycle}) of
        [_] -> ok;
        []  -> seed_defaults(), ok
    end.

-doc """
Clear the registry and re-seed from built-in defaults.

Removes all custom backend registrations and capability overrides.
""".
-spec reset() -> ok.
reset() ->
    ensure_tables(),
    beam_agent_ets:match_delete(?REG_TABLE, {{capability, '_', '_'}, '_'}),
    beam_agent_ets:match_delete(?REG_TABLE, {{cap_meta, '_'}, '_'}),
    seed_defaults(),
    ok.

%%--------------------------------------------------------------------
%% Registration API
%%--------------------------------------------------------------------

-doc """
Register a new backend with a full set of capability support entries.

`Capabilities` is a map from capability atom to `support_info()`. All
23 built-in capabilities should be present. Missing entries will be
treated as unsupported by `for_backend/1` and `status/2`.

```erlang
ok = beam_agent_capabilities:register_backend(my_backend, #{
    session_lifecycle => #{support_level => full,
                           implementation => direct_backend,
                           fidelity => exact},
    %% ... 22 more
}).
```
""".
-spec register_backend(atom(), #{capability() => support_info()}) -> ok.
register_backend(Backend, Capabilities) when is_atom(Backend), is_map(Capabilities) ->
    ensure_tables(),
    maps:foreach(fun(CapId, SupportInfo) ->
        true = beam_agent_ets:insert(?REG_TABLE, {{capability, Backend, CapId}, SupportInfo})
    end, Capabilities),
    %% Track this backend in the shared registry.
    true = beam_agent_ets:insert(?REG_TABLE, {{cap_meta, {backend, Backend}}, true}),
    ok.

-doc """
Register or override a single capability entry for a backend.

```erlang
ok = beam_agent_capabilities:register_capability(gemini, checkpointing, #{
    support_level => full,
    implementation => direct_backend,
    fidelity => exact
}).
```
""".
-spec register_capability(atom(), capability(), support_info()) -> ok.
register_capability(Backend, CapId, SupportInfo)
  when is_atom(Backend), is_atom(CapId), is_map(SupportInfo) ->
    ensure_tables(),
    true = beam_agent_ets:insert(?REG_TABLE, {{capability, Backend, CapId}, SupportInfo}),
    true = beam_agent_ets:insert(?REG_TABLE, {{cap_meta, {backend, Backend}}, true}),
    ok.

-doc """
Remove all capability entries for a backend.

Does not affect built-in backends — call `reset/0` to restore defaults.
""".
-spec unregister_backend(atom()) -> ok.
unregister_backend(Backend) when is_atom(Backend) ->
    ensure_tables(),
    CapIds = capability_ids(),
    lists:foreach(fun(CapId) ->
        beam_agent_ets:delete(?REG_TABLE, {capability, Backend, CapId})
    end, CapIds),
    beam_agent_ets:delete(?REG_TABLE, {cap_meta, {backend, Backend}}),
    ok.

%%--------------------------------------------------------------------
%% Query API
%%--------------------------------------------------------------------

-doc """
Return the full capability matrix as a list of `capability_info()` maps.

Each entry contains the capability `id`, a human-readable `title`, and a
`support` map keyed by backend atom. The support map includes all registered
backends (built-in and custom).
""".
-spec all() -> [capability_info()].
all() ->
    ensure_tables(),
    Backends = registered_backends(),
    [begin
        SupportMap = maps:from_list(
            [{B, lookup_support(B, Id)} || B <- Backends,
             lookup_support(B, Id) =/= undefined]),
        #{id => Id, title => Title, support => SupportMap}
    end || {Id, Title} <- capability_definitions()].

-doc """
Return the full capability matrix as a list of `capability_info()` maps.

Alias for `all/0`.
""".
-spec capabilities() -> [capability_info()].
capabilities() -> all().

-doc """
Return the projected capability list for a session pid or backend.
""".
-spec capabilities(pid() | beam_agent_backend:backend() | binary() | atom()) ->
    {ok, [map()]} | {error, backend_lookup_error()}.
capabilities(Session) when is_pid(Session) ->
    for_session(Session);
capabilities(BackendLike) ->
    for_backend(BackendLike).

-doc """
Return the list of all registered backend atoms.

Includes built-in backends and any custom-registered backends.
""".
-spec backends() -> [atom()].
backends() ->
    ensure_tables(),
    registered_backends().

-doc """
Return the flat list of all 24 capability atom identifiers.
""".
-spec capability_ids() -> [capability()].
capability_ids() ->
    [Id || {Id, _Title} <- capability_definitions()].

-doc """
Return the projected capability list for a specific backend.
""".
-spec for_backend(beam_agent_backend:backend() | binary() | atom()) ->
    {ok, [map()]} | {error, term()}.
for_backend(BackendLike) ->
    ensure_tables(),
    case normalize_backend(BackendLike) of
        {ok, Backend} ->
            Results = [project_capability_for(Backend, Id, Title)
                       || {Id, Title} <- capability_definitions()],
            case lists:keyfind(error, 1, Results) of
                {error, _} = Error -> Error;
                false ->
                    {ok, [Cap || {ok, Cap} <- Results]}
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
Return the projected capability list for the backend of a live session.
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
""".
-spec status(capability(), beam_agent_backend:backend() | binary() | atom()) ->
    {ok, support_info()} | {error, term()}.
status(Capability, BackendLike) ->
    ensure_tables(),
    case {is_known_capability(Capability), normalize_backend(BackendLike)} of
        {false, _} ->
            {error, {unknown_capability, Capability}};
        {true, {error, _} = Error} ->
            Error;
        {true, {ok, Backend}} ->
            case lookup_support(Backend, Capability) of
                undefined ->
                    {error, {unknown_backend, Backend}};
                SupportInfo ->
                    {ok, SupportInfo}
            end
    end.

-doc """
Check whether a capability is supported for a given backend.
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

-doc """
Assert that a capability is supported for a given backend.

Returns `ok` when supported, or an error tuple when not.
""".
-spec assert_capability(capability(), beam_agent_backend:backend() | binary() | atom()) ->
    ok | {error, assert_capability_error()}.
assert_capability(Capability, BackendLike) ->
    case normalize_backend(BackendLike) of
        {ok, Backend} ->
            case status(Capability, Backend) of
                {ok, #{support_level := missing}} ->
                    {error, {unsupported_capability, Capability, Backend}};
                {ok, _} ->
                    ok;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internal: ETS Lookups
%%--------------------------------------------------------------------

-spec lookup_support(atom(), capability()) -> support_info() | undefined.
lookup_support(Backend, CapId) ->
    case ets:lookup(?REG_TABLE, {capability, Backend, CapId}) of
        [{{capability, Backend, CapId}, SupportInfo}] -> SupportInfo;
        [] -> undefined
    end.

-spec registered_backends() -> [atom()].
registered_backends() ->
    Matches = ets:match_object(?REG_TABLE, {{cap_meta, {backend, '_'}}, '_'}),
    [B || {{cap_meta, {backend, B}}, _} <- Matches].

-spec is_known_capability(term()) -> boolean().
is_known_capability(Cap) ->
    lists:keymember(Cap, 1, capability_definitions()).

%%--------------------------------------------------------------------
%% Internal: Backend Normalization
%%--------------------------------------------------------------------

-spec normalize_backend(term()) -> {ok, atom()} | {error, {unknown_backend, term()}}.
normalize_backend(Backend) when is_atom(Backend) ->
    ensure_tables(),
    case ets:lookup(?REG_TABLE, {cap_meta, {backend, Backend}}) of
        [_] -> {ok, Backend};
        []  ->
            %% Try the standard beam_agent_backend normalization for
            %% built-in backends.
            beam_agent_backend:normalize(Backend)
    end;
normalize_backend(Backend) when is_binary(Backend) ->
    beam_agent_backend:normalize(Backend);
normalize_backend(Other) ->
    {error, {unknown_backend, Other}}.

%%--------------------------------------------------------------------
%% Internal: Projection
%%--------------------------------------------------------------------

-spec project_capability_for(atom(), capability(), binary()) ->
    {ok, #{id := capability(), title := binary(), backend := atom(),
           support_level := atom(), implementation := atom(),
           fidelity := atom(), atom() => term()}} |
    {error, {unknown_backend, atom()}}.
project_capability_for(Backend, Id, Title) ->
    case lookup_support(Backend, Id) of
        undefined ->
            {error, {unknown_backend, Backend}};
        #{support_level := SL, implementation := Impl,
          fidelity := Fid} = SupportInfo ->
            {ok, maps:merge(
                #{
                    id => Id,
                    title => Title,
                    backend => Backend,
                    support_level => SL,
                    implementation => Impl,
                    fidelity => Fid
                },
                maps:with([available_paths, notes], SupportInfo)
            )}
    end.

%%--------------------------------------------------------------------
%% Internal: Capability Definitions (static metadata)
%%--------------------------------------------------------------------

-spec capability_definitions() -> nonempty_list({capability(), <<_:64, _:_*8>>}).
capability_definitions() ->
    [{session_lifecycle, <<"Session lifecycle">>},
     {session_info, <<"Session info">>},
     {runtime_model_switch, <<"Runtime model switch">>},
     {interrupt, <<"Interrupt active work">>},
     {permission_mode, <<"Runtime permission mode change">>},
     {session_history, <<"Session history">>},
     {session_mutation, <<"Session fork, revert, share, summarize">>},
     {thread_management, <<"Thread lifecycle and history">>},
     {metadata_accessors, <<"Catalog and metadata accessors">>},
     {in_process_mcp, <<"In-process MCP servers and tools">>},
     {mcp_management, <<"MCP management">>},
     {hooks, <<"SDK lifecycle hooks">>},
     {checkpointing, <<"File checkpointing">>},
     {thinking_budget, <<"Thinking budget control">>},
     {task_stop, <<"Stop task by id">>},
     {command_execution, <<"Command execution and turn response">>},
     {approval_callbacks, <<"Approval and permission callbacks">>},
     {user_input_callbacks, <<"User input callbacks">>},
     {realtime_review, <<"Realtime, review, collaboration">>},
     {config_management, <<"Config management">>},
     {provider_management, <<"Provider and runtime management">>},
     {attachments, <<"Attachments in query and send (512 KB default size limit, configurable)">>},
     {event_streaming, <<"Backend event streaming">>},
     {memory, <<"Agent memory persistence">>}].

%%--------------------------------------------------------------------
%% Internal: Built-in Default Seeding
%%--------------------------------------------------------------------

-spec seed_defaults() -> ok.
seed_defaults() ->
    BuiltinBackends = beam_agent_backend:available_backends(),
    DefaultMatrix = default_matrix(),
    lists:foreach(fun(#{id := CapId, support := SupportMap}) ->
        maps:foreach(fun(Backend, SupportInfo) ->
            true = beam_agent_ets:insert(?REG_TABLE, {{capability, Backend, CapId}, SupportInfo})
        end, SupportMap)
    end, DefaultMatrix),
    lists:foreach(fun(B) ->
        true = beam_agent_ets:insert(?REG_TABLE, {{cap_meta, {backend, B}}, true})
    end, BuiltinBackends),
    ok.

-spec default_matrix() -> [capability_info()].
default_matrix() ->
    [
        cap(session_lifecycle,
            all_backends(full, direct_backend, exact)),
        cap(session_info,
            all_backends(full, direct_backend, exact)),
        cap(runtime_model_switch,
            all_backends(full, direct_backend, exact)),
        cap(interrupt,
            all_backends(full, direct_backend, exact)),
        cap(permission_mode,
            all_backends(full, direct_backend, exact)),
        cap(session_history, #{
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
        cap(session_mutation, #{
            claude => support(full, universal, validated_equivalent),
            codex => support(full, universal, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, direct_backend, exact,
                #{available_paths => [direct_backend, direct_backend_and_universal]}),
            copilot => support(full, universal, validated_equivalent)
        }),
        cap(thread_management, #{
            claude => support(full, universal, validated_equivalent),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        cap(metadata_accessors,
            all_backends(full, universal, validated_equivalent)),
        cap(in_process_mcp,
            all_backends(full, universal, exact)),
        cap(mcp_management, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, direct_backend, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, direct_backend, validated_equivalent)
        }),
        cap(hooks,
            all_backends(full, universal, exact)),
        cap(checkpointing, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, universal, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        cap(thinking_budget, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, universal, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        cap(task_stop, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, universal, validated_equivalent),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        cap(command_execution, #{
            claude => support(full, universal, validated_equivalent),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, validated_equivalent),
            opencode => support(full, universal, validated_equivalent),
            copilot => support(full, universal, validated_equivalent)
        }),
        cap(approval_callbacks, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, direct_backend, exact),
            gemini => support(full, direct_backend, exact,
                #{notes => <<"Gemini ACP reverse permission requests are handled natively via approval_mode state and approval_response/2.">>}),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, direct_backend, exact)
        }),
        cap(user_input_callbacks, #{
            claude => support(full, direct_backend, exact),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, exact,
                #{notes => <<"Universal callback broker services canonical user-input requests for Gemini sessions.">>}),
            opencode => support(full, universal, exact,
                #{notes => <<"Universal callback broker services canonical user-input requests for OpenCode sessions.">>}),
            copilot => support(full, direct_backend, exact)
        }),
        cap(realtime_review, #{
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
        cap(config_management, #{
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
        cap(provider_management, #{
            claude => support(full, universal, exact,
                #{notes => <<"Universal runtime/provider layer exposes provider selection and auth metadata for Claude sessions.">>}),
            codex => support(full, direct_backend_and_universal, exact,
                #{available_paths => [direct_backend, universal],
                  notes => <<"Codex keeps native model/runtime controls while the universal provider layer exposes canonical provider management.">>}),
            gemini => support(full, universal, exact,
                #{notes => <<"Universal runtime/provider layer exposes provider selection and auth metadata for Gemini sessions.">>}),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, direct_backend, exact,
                #{notes => <<"Copilot protocol has native build_agent_list/select/deselect/reload_params for provider management.">>})
        }),
        cap(attachments, #{
            claude => support(full, direct_backend_and_universal, exact,
                #{available_paths => [direct_backend, universal],
                  notes => <<"Claude receives native content blocks (text + base64 image) matching the Claude Code wire protocol. Files and documents are inlined as text when decodable. Audio, mention, and skill attachments are rendered as text descriptions. Files exceeding the size limit (512 KB default) produce a rejection text block instead.">>}),
            codex => support(full, direct_backend, exact),
            gemini => support(full, universal, exact,
                #{notes => <<"Universal attachment materialization renders canonical attachment blocks into backend-safe input for Gemini sessions. Files exceeding the size limit (512 KB default) produce a rejection text block instead.">>}),
            opencode => support(full, direct_backend, exact),
            copilot => support(full, direct_backend, exact)
        }),
        cap(event_streaming, #{
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
        }),
        cap(memory,
            all_backends(full, universal, exact))
    ].

%%--------------------------------------------------------------------
%% Internal: Helpers
%%--------------------------------------------------------------------

-spec cap(capability(), #{atom() => support_info()}) -> capability_info().
cap(Id, Support) ->
    Title = proplists:get_value(Id, capability_definitions(), <<>>),
    #{id => Id, title => Title, support => Support}.

-spec all_backends(support_level(), implementation(), fidelity()) ->
    #{beam_agent_backend:backend() => support_info()}.
all_backends(SupportLevel, Implementation, Fidelity) ->
    maps:from_list([{Backend, support(SupportLevel, Implementation, Fidelity)}
                    || Backend <- beam_agent_backend:available_backends()]).

-spec support(support_level(), implementation(), fidelity()) -> support_info().
support(SupportLevel, Implementation, Fidelity) ->
    #{support_level => SupportLevel, implementation => Implementation, fidelity => Fidelity}.

-spec support(support_level(), implementation(), fidelity(), map()) -> support_info().
support(SupportLevel, Implementation, Fidelity, Extra) ->
    maps:merge(support(SupportLevel, Implementation, Fidelity), Extra).
