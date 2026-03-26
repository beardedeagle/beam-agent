-module(beam_agent_hooks_core).
-moduledoc """
SDK-level lifecycle hooks for the BEAM Agent SDK.

Enables users to register in-process callback functions that fire
at key session lifecycle points. Cross-referenced against TS SDK
v0.2.66 SessionConfig.hooks and Python SDK hook support.

Two categories of hooks:
  - Blocking: pre_tool_use, user_prompt_submit, permission_request,
    subagent_start, pre_compact, config_change — callbacks return
    {ok, Ctx} to allow (with possibly modified context),
    {deny, Reason} to block, or {ask, Reason} to escalate to the
    caller for a decision.
  - Notification-only: post_tool_use, post_tool_use_failure, stop,
    session_start, session_end, subagent_stop, notification,
    task_completed, teammate_idle — {deny, _} and {ask, _} returns
    are ignored; context is still threaded through the chain.

Context threading: each hook in a chain receives the context as
modified by the previous hook. The final context flows back to
the handler via the {ok, FinalCtx} return from fire/3.

Matchers (optional) filter which tools a hook fires on:
  - Exact match: #{tool_name => <<"Bash">>}
  - Regex pattern: #{tool_name => <<"Read.*">>}

Global hooks (registered via `register_global/1`) apply to every session.
They fire before per-session hooks and participate in the same context-
threading chain. The global registry is backed by a `duplicate_bag` ETS
table (`beam_agent_global_hooks`), created on first use via
`ensure_global_table/0`. Changes to the global registry notify the
reload bus so live sessions can pick up updates.

Usage:
```erlang
Hook = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) ->
    case maps:get(tool_name, Ctx, <<>>) of
        <<"Bash">> -> {deny, <<"No shell access">>};
        _ -> {ok, Ctx}
    end
end),
%% Pass to session:
claude_agent_session:start_link(#{sdk_hooks => [Hook]})

%% Or register globally (fires for all sessions):
ok = beam_agent_hooks_core:ensure_global_table(),
ok = beam_agent_hooks_core:register_global(Hook).
```
""".

-export([
    %% Constructors
    hook/2,
    hook/3,
    %% Registry management
    new_registry/0,
    register_hook/2,
    register_hooks/2,
    %% Dispatch
    fire/3,
    %% Convenience: build registry from session opts
    build_registry/1,
    %% Global hooks
    ensure_global_table/0,
    register_global/1,
    unregister_global/1,
    global_registry/0
]).

-export_type([
    hook_event/0,
    hook_callback/0,
    hook_context/0,
    hook_matcher/0,
    hook_def/0,
    hook_registry/0
]).

%% new_registry/0 returns #{} typed as hook_registry() (intentional supertype).
-dialyzer({nowarn_function, [new_registry/0]}).

-define(GLOBAL_TABLE, beam_agent_global_hooks).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Hook events matching TS/Python SDKs exactly.
-type hook_event() :: pre_tool_use
                    | post_tool_use
                    | post_tool_use_failure
                    | stop
                    | session_start
                    | session_end
                    | user_prompt_submit
                    | subagent_start
                    | subagent_stop
                    | pre_compact
                    | notification
                    | permission_request
                    | config_change
                    | task_completed
                    | teammate_idle.

%% Hook callback receives an event context map and returns a three-way result:
%%   {ok, Ctx}       — allow, continue chain with (possibly modified) context
%%   {deny, Reason}  — block the action (blocking events only; ignored for notifications)
%%   {ask, Reason}   — escalate to caller for decision (blocking events only)
%% A hook that doesn't modify anything returns {ok, Context} as received.
-type hook_callback() :: fun((hook_context()) ->
    {ok, hook_context()}
  | {deny, binary()}
  | {ask, binary()}
).

%% Context map passed to hook callbacks (keys depend on event type).
-type hook_context() :: #{
    event := hook_event(),
    session_id => binary(),
    %% pre_tool_use / post_tool_use
    tool_name => binary(),
    tool_input => map(),
    tool_use_id => binary(),
    agent_id => binary(),
    agent_type => binary(),
    content => binary(),
    %% stop
    stop_reason => binary() | atom(),
    duration_ms => non_neg_integer(),
    stop_hook_active => boolean(),
    %% user_prompt_submit
    prompt => binary(),
    params => map(),
    %% permission_request
    permission_prompt_tool_name => binary(),
    permission_suggestions => list(),
    updated_permissions => map(),
    interrupt => boolean(),
    %% post_tool_use_failure
    category => atom(),
    %% permission path (OpenCode pre_tool_use)
    permission_id => binary(),
    metadata => map(),
    %% subagent lifecycle
    agent_transcript_path => binary(),
    %% session_start
    system_info => map(),
    %% session_end
    reason => term()
}.

%% Matcher for filtering which tools a hook fires on.
%% tool_name may be exact string or regex pattern.
-type hook_matcher() :: #{
    tool_name => binary()
}.

%% A single hook definition.
%% compiled_re is an internal optimization field — populated by hook/3
%% when a tool_name matcher is present, to avoid re-compiling on every fire.
-type hook_def() :: #{
    event := hook_event(),
    callback := hook_callback(),
    matcher => hook_matcher(),
    compiled_re => re:mp()
}.

%% Hook registry: event -> list of hook defs (in registration order).
-type hook_registry() :: #{hook_event() => [hook_def()]}.

%%--------------------------------------------------------------------
%% Constructors
%%--------------------------------------------------------------------

-doc "Create a hook that fires on all occurrences of an event.".
-spec hook(hook_event(), hook_callback()) -> hook_def().
hook(Event, Callback) when is_atom(Event), is_function(Callback, 1) ->
    #{event => Event, callback => Callback}.

-doc """
Create a hook with a matcher filter.
The matcher's `tool_name` (exact or regex) restricts which tools
trigger the hook. Only relevant for tool-related events.
The regex pattern is pre-compiled at registration time for
O(1) dispatch. Invalid patterns crash here (fail-fast).
""".
-spec hook(hook_event(), hook_callback(), hook_matcher()) -> hook_def().
hook(Event, Callback, #{tool_name := Pattern} = Matcher)
  when is_atom(Event), is_function(Callback, 1), is_map(Matcher) ->
    {ok, CompiledRe} = re:compile(Pattern),
    #{event => Event, callback => Callback,
      matcher => Matcher, compiled_re => CompiledRe};
hook(Event, Callback, Matcher)
  when is_atom(Event), is_function(Callback, 1), is_map(Matcher) ->
    #{event => Event, callback => Callback, matcher => Matcher}.

%%--------------------------------------------------------------------
%% Registry Management
%%--------------------------------------------------------------------

-doc "Create an empty hook registry.".
-spec new_registry() -> hook_registry().
new_registry() -> #{}.

-doc """
Register a single hook in the registry.
Hooks are prepended (O(1)) and reversed at fire time to
preserve registration order without O(n) append per call.
""".
-spec register_hook(hook_def(), hook_registry()) -> hook_registry().
register_hook(#{event := Event} = HookDef, Registry) ->
    Existing = maps:get(Event, Registry, []),
    Registry#{Event => [HookDef | Existing]}.

-doc "Register multiple hooks in the registry.".
-spec register_hooks([hook_def()], hook_registry()) -> hook_registry().
register_hooks(Hooks, Registry) when is_list(Hooks) ->
    lists:foldl(fun register_hook/2, Registry, Hooks).

%%--------------------------------------------------------------------
%% Convenience: Build Registry from Session Opts
%%--------------------------------------------------------------------

-doc """
Build a hook registry from a list of hook definitions.
Returns `undefined` when no hooks are configured (empty list
or `undefined`). Used by all adapter session modules during init.
""".
-spec build_registry([hook_def()] | undefined) ->
    hook_registry() | undefined.
build_registry(undefined) -> undefined;
build_registry([]) -> undefined;
build_registry(Hooks) when is_list(Hooks) ->
    register_hooks(Hooks, new_registry()).

%%--------------------------------------------------------------------
%% Dispatch
%%--------------------------------------------------------------------

-doc """
Fire all hooks registered for an event.

Context is threaded through the hook chain: each hook receives
the context as modified by the previous hook. The final context
flows back to the caller via `{ok, FinalCtx}`.

For blocking events (`pre_tool_use`, `user_prompt_submit`,
`permission_request`, `subagent_start`, `pre_compact`,
`config_change`):
- Returns `{ok, FinalCtx}` if all hooks allow.
- Returns `{deny, Reason}` on first deny, stopping the chain.
- Returns `{ask, Reason}` on first ask, stopping the chain.

For notification-only events:
- Always returns `{ok, FinalCtx}` regardless of callback returns.
- `{deny, _}` and `{ask, _}` from callbacks are ignored; context
  passes through unmodified from those hooks.

Handles `undefined` registry (no hooks configured) gracefully.
Each callback is wrapped in try/catch for crash protection.
""".
-spec fire(hook_event(), hook_context(), hook_registry() | undefined) ->
    {ok, hook_context()} | {deny, binary()} | {ask, binary()}.
fire(Event, Context, undefined) ->
    %% No session registry — still fire global hooks if any exist.
    fire(Event, Context, #{});
fire(Event, Context, Registry) when is_map(Registry) ->
    SessionHooks = lists:reverse(maps:get(Event, Registry, [])),
    GlobalHooks = global_hooks_for_event(Event),
    AllHooks = GlobalHooks ++ SessionHooks,
    case AllHooks of
        [] ->
            {ok, Context};
        _ ->
            case is_blocking_event(Event) of
                true  -> fire_blocking(AllHooks, Context);
                false -> fire_notification(AllHooks, Context)
            end
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

%% Events where callbacks may block (deny/ask) the action.
-spec is_blocking_event(hook_event()) -> boolean().
is_blocking_event(pre_tool_use) -> true;
is_blocking_event(user_prompt_submit) -> true;
is_blocking_event(permission_request) -> true;
is_blocking_event(subagent_start) -> true;
is_blocking_event(pre_compact) -> true;
is_blocking_event(config_change) -> true;
is_blocking_event(_) -> false.

%% Fire hooks for blocking events -- thread context, stop on first deny/ask.
-spec fire_blocking([hook_def()], hook_context()) ->
    {ok, hook_context()} | {deny, binary()} | {ask, binary()}.
fire_blocking([], Context) ->
    {ok, Context};
fire_blocking([Hook | Rest], Context) ->
    case matches_context(Hook, Context) of
        false ->
            fire_blocking(Rest, Context);
        true ->
            case safe_call(Hook, Context) of
                {deny, Reason} ->
                    {deny, Reason};
                {ask, Reason} ->
                    {ask, Reason};
                {ok, Context1} ->
                    fire_blocking(Rest, Context1)
            end
    end.

%% Fire hooks for notification-only events -- thread context, ignore deny/ask.
-spec fire_notification([hook_def()], hook_context()) -> {ok, hook_context()}.
fire_notification([], Context) ->
    {ok, Context};
fire_notification([Hook | Rest], Context) ->
    case matches_context(Hook, Context) of
        false ->
            fire_notification(Rest, Context);
        true ->
            case safe_call(Hook, Context) of
                {ok, Context1} ->
                    fire_notification(Rest, Context1);
                {deny, _} ->
                    fire_notification(Rest, Context);
                {ask, _} ->
                    fire_notification(Rest, Context)
            end
    end.

%% Invoke a hook callback with crash protection.
%% Returns {ok, Context} on crash/throw/unexpected return (logged via logger).
-spec safe_call(hook_def(), hook_context()) ->
    {ok, hook_context()} | {deny, binary()} | {ask, binary()}.
safe_call(#{callback := Callback}, Context) ->
    try Callback(Context) of
        {ok, Ctx1} when is_map(Ctx1) ->
            {ok, Ctx1};
        {deny, Reason} when is_binary(Reason) ->
            {deny, Reason};
        {ask, Reason} when is_binary(Reason) ->
            {ask, Reason};
        Other ->
            logger:warning("SDK hook callback returned unexpected: ~tp",
                           [Other]),
            {ok, Context}
    catch
        Class:Reason:Stack ->
            logger:warning("SDK hook callback crashed: ~p:~p~n~p",
                           [Class,
                            beam_agent_redaction:reason(Reason),
                            beam_agent_redaction:stacktrace(Stack)]),
            {ok, Context}
    end.

%% Check if a hook's matcher allows it to fire for this context.
%% Uses pre-compiled regex when available (from hook/3).
%% Falls back to runtime compilation for externally-constructed defs.
%% No matcher means fire on everything.
-spec matches_context(hook_def(), hook_context()) -> boolean().
matches_context(#{compiled_re := CompiledRe}, Context) ->
    ToolName = maps:get(tool_name, Context, <<>>),
    re:run(ToolName, CompiledRe, [{capture, none}]) =:= match;
matches_context(#{matcher := #{tool_name := Pattern}}, Context) ->
    %% Fallback for hook defs constructed without hook/3
    ToolName = maps:get(tool_name, Context, <<>>),
    re:run(ToolName, Pattern, [{capture, none}]) =:= match;
matches_context(_, _) ->
    %% No matcher or empty matcher — always fires
    true.

%%--------------------------------------------------------------------
%% Global Hooks
%%--------------------------------------------------------------------

-doc """
Create the global hooks ETS table. Idempotent.

The table is an `ordered_set` keyed by `{hook_event(), Seq}` where
`Seq` is a monotonically increasing integer assigned at registration
time. This guarantees deterministic firing order across all OTP
versions — hooks fire in registration order regardless of ETS
implementation details.

Called from `beam_agent:init/0` during application startup.
Safe to call multiple times — subsequent calls are no-ops.
""".
-spec ensure_global_table() -> ok.
ensure_global_table() ->
    beam_agent_ets:ensure_table(?GLOBAL_TABLE,
        [ordered_set, named_table, {read_concurrency, true}]),
    ok.

-doc """
Register a hook globally (fires for every session).

Inserts the hook definition into the global ETS table and notifies
the reload bus so live sessions can pick up the change. The hook
definition must have been created via `hook/2` or `hook/3`.

Returns `ok`. Safe to call even if the global table does not exist
yet (creates it on first use).
""".
-spec register_global(hook_def()) -> ok.
register_global(#{event := Event} = HookDef) ->
    ok = ensure_global_table(),
    Seq = erlang:unique_integer([monotonic, positive]),
    beam_agent_ets:insert(?GLOBAL_TABLE, {{Event, Seq}, HookDef}),
    notify_reload_bus(),
    ok.

-doc """
Unregister a hook from the global registry.

Matches entries by `{Event, '_'}` key pattern and exact `HookDef`
value via `match_delete/2`. Only the specific hook is removed; other
hooks for the same event are unaffected.

Notifies the reload bus after removal. Returns `ok` even if the hook
was not found (idempotent).
""".
-spec unregister_global(hook_def()) -> ok.
unregister_global(#{event := Event} = HookDef) ->
    ok = ensure_global_table(),
    beam_agent_ets:match_delete(?GLOBAL_TABLE, {{Event, '_'}, HookDef}),
    notify_reload_bus(),
    ok.

-doc """
Read the entire global hook registry as a `hook_registry()` map.

Returns a map from event atoms to lists of hook definitions in
registration order, mirroring the shape of per-session registries.
Returns an empty map if the global table does not exist or is empty.
""".
-spec global_registry() -> hook_registry().
global_registry() ->
    ok = ensure_global_table(),
    Grouped = ets:foldl(fun({{Event, _Seq}, HookDef}, Acc) ->
        Existing = maps:get(Event, Acc, []),
        Acc#{Event => [HookDef | Existing]}
    end, #{}, ?GLOBAL_TABLE),
    maps:map(fun(_Event, Hooks) -> lists:reverse(Hooks) end, Grouped).

%% Retrieve global hooks for a specific event in registration order.
%% Uses ets:select on the ordered_set to return hooks sorted by their
%% monotonic sequence number.
%% Returns [] if the global table does not exist or has no hooks
%% for the event.
-spec global_hooks_for_event(hook_event()) -> [hook_def()].
global_hooks_for_event(Event) ->
    ok = ensure_global_table(),
    ets:select(?GLOBAL_TABLE, [{{{Event, '_'}, '$1'}, [], ['$1']}]).

%% Notify the reload bus that global hooks have changed.
%% No-op if the reload bus tables have not been created yet.
-spec notify_reload_bus() -> ok.
notify_reload_bus() ->
    beam_agent_reload_bus:notify(hooks).
