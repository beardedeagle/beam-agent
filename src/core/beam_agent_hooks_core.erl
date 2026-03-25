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
    build_registry/1
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
fire(_Event, Context, undefined) ->
    {ok, Context};
fire(Event, Context, Registry) when is_map(Registry) ->
    Hooks = lists:reverse(maps:get(Event, Registry, [])),
    case is_blocking_event(Event) of
        true  -> fire_blocking(Hooks, Context);
        false -> fire_notification(Hooks, Context)
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
