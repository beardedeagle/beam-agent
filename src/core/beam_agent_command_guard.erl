-module(beam_agent_command_guard).
-moduledoc false.

%% Layer 3 of the BeamAgent command security architecture.
%%
%% Functional state machine that coordinates command security:
%% - Evaluates commands through policy (Layer 1) and validator (Layer 2)
%% - Enforces rate limits per-program, per-category, and globally
%% - Detects temporal patterns in command history
%% - Manages security state: active -> throttle -> lockdown
%%
%% Not a process.  State lives in ETS (shared mutable) and
%% persistent_term (read-heavy config).  Follows the same pattern
%% as beam_agent_mcp_dispatch: the caller owns the control flow,
%% ETS provides cross-session state sharing.
%%
%% Tables (created via beam_agent_ets:ensure_table):
%%   beam_agent_guard_state       (set)         - security state machine
%%   beam_agent_command_history    (ordered_set) - recent command records
%%   beam_agent_rate_limits        (set)         - rate limit counters
%%   beam_agent_active_commands    (set)         - tracked command ports

%% API
-export([
    init/0,
    init/1,
    teardown/0,
    evaluate/2,
    evaluate_default/2,
    record_execution/3,
    lockdown/1,
    reset/0,
    reload_policy/1,
    status/0,
    running/0,
    register_command/2,
    unregister_command/1
]).

-export_type([
    guard_result/0,
    evaluate_opts/0,
    rate_limit_config/0,
    temporal_rule/0,
    command_matcher/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type guard_result() :: allow | {deny, binary()} | {throttle, pos_integer()}.

-type evaluate_opts() :: #{
    agent => atom() | undefined,
    session_state => atom() | undefined,
    cwd => binary() | undefined,
    env => [{string(), string()}] | undefined,
    opts => map(),
    metadata => map()
}.

-type rate_limit_config() :: #{
    global => {pos_integer(), pos_integer()},
    per_program => {pos_integer(), pos_integer()},
    per_category => #{atom() => {pos_integer(), pos_integer()}}
}.

-type temporal_rule() :: #{
    name := binary(),
    description := binary(),
    pattern := [command_matcher()],
    window_ms := pos_integer(),
    action := throttle | lockdown | alert
}.

-type command_matcher() :: #{
    program => binary(),
    args_contain => binary(),
    exit_code => integer(),
    category => atom()
}.

-type security_state() :: active | throttle | lockdown.

-type table_name() :: beam_agent_guard_state
                    | beam_agent_command_history
                    | beam_agent_rate_limits
                    | beam_agent_active_commands.

-type rate_status() :: #{count := non_neg_integer(), window_start := integer()}.

-type status_map() :: #{
    state := security_state(),
    history_size := non_neg_integer(),
    active_commands := non_neg_integer(),
    rate_limits := #{term() => rate_status()},
    lockdown_reason => binary()
}.

-type default_rate_limit_config() :: #{
    global := {60, 60000},
    per_program := {20, 60000},
    per_category := #{
        destructive := {5, 60000},
        filesystem_write := {30, 60000},
        network := {10, 60000}
    }
}.

%%--------------------------------------------------------------------
%% Defines
%%--------------------------------------------------------------------

-define(STATE_TABLE, beam_agent_guard_state).
-define(HISTORY_TABLE, beam_agent_command_history).
-define(RATE_TABLE, beam_agent_rate_limits).
-define(DEFAULT_HISTORY_MAX, 100).
-define(LOCKDOWN_THRESHOLD, 10).
-define(COMMAND_TABLE, beam_agent_active_commands).
-define(CONTEXT_HISTORY_DEPTH, 10).

%% persistent_term keys
-define(PT_INIT, beam_agent_guard_initialized).
-define(PT_POLICY, beam_agent_guard_policy).
-define(PT_RATE_CONFIG, beam_agent_guard_rate_config).
-define(PT_TEMPORAL_RULES, beam_agent_guard_temporal_rules).
-define(PT_VALIDATOR_MOD, beam_agent_guard_validator_mod).
-define(PT_HISTORY_MAX, beam_agent_guard_history_max).

%% do_evaluate calls erlang:apply/3 with a validator module retrieved from
%% persistent_term, which dialyzer cannot resolve statically. This causes
%% it to infer that the dynamic call always crashes (catch-only path), so
%% it reports that 'allow' is never returned. Suppress the contract warning.
-dialyzer({no_contracts, [{do_evaluate, 2},
                          {handle_active_evaluate, 2},
                          {check_and_bump_rate_limits, 2},
                          {check_and_bump_program, 3},
                          {check_and_bump_category, 3}]}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Initialize the security guard with default configuration.".
-spec init() -> ok.
init() -> init(#{}).

-doc """
Initialize the security guard with custom configuration.

Creates ETS tables for state, history, and rate limits.  Stores
configuration in persistent_term for fast concurrent reads.

Options:
  - `policy` - policy config (default: `beam_agent_command_policy:default_policy()`)
  - `rate_limits` - rate limit config (default: sensible defaults)
  - `temporal_rules` - temporal pattern rules (default: built-in rules)
  - `validator` - validator module (default: `beam_agent_command_validator_default`)
  - `history_max` - max history entries (default: 100)
""".
-spec init(map()) -> ok.
init(Opts) ->
    %% Create tables -- idempotent via beam_agent_ets
    beam_agent_ets:ensure_table(?STATE_TABLE,
        [set, named_table,
         {read_concurrency, true}, {write_concurrency, true}]),
    beam_agent_ets:ensure_table(?HISTORY_TABLE,
        [ordered_set, named_table, {read_concurrency, true}]),
    beam_agent_ets:ensure_table(?RATE_TABLE,
        [set, named_table,
         {read_concurrency, true}, {write_concurrency, true}]),
    beam_agent_ets:ensure_table(?COMMAND_TABLE,
        [set, named_table, {write_concurrency, true}]),

    %% Store config in persistent_term (fast concurrent reads)
    Policy = maps:get(policy, Opts,
        app_config(command_policy,
            beam_agent_command_policy:default_policy())),
    RateConfig = maps:get(rate_limits, Opts,
        app_config(command_rate_limits, default_rate_limits())),
    TemporalRules = maps:get(temporal_rules, Opts,
        app_config(command_temporal_rules, default_temporal_rules())),
    ValidatorMod = maps:get(validator, Opts,
        app_config(command_validator,
            beam_agent_command_validator_default)),
    %% Ensure the validator module is loaded so that
    %% erlang:function_exported/3 works for optional callbacks
    %% (function_exported does not trigger auto-loading).
    _ = code:ensure_loaded(ValidatorMod),
    HistoryMax = maps:get(history_max, Opts, ?DEFAULT_HISTORY_MAX),

    persistent_term:put(?PT_POLICY, Policy),
    persistent_term:put(?PT_RATE_CONFIG, RateConfig),
    persistent_term:put(?PT_TEMPORAL_RULES, TemporalRules),
    persistent_term:put(?PT_VALIDATOR_MOD, ValidatorMod),
    persistent_term:put(?PT_HISTORY_MAX, HistoryMax),

    %% Initialize security state -- start active
    beam_agent_ets:insert(?STATE_TABLE, {security_state, active}),
    beam_agent_ets:insert(?STATE_TABLE, {throttle_until, 0}),
    beam_agent_ets:insert(?STATE_TABLE, {throttle_denied, 0}),
    beam_agent_ets:insert(?STATE_TABLE, {lockdown_reason, <<>>}),

    %% Clear any stale data from previous init
    beam_agent_ets:delete_all_objects(?HISTORY_TABLE),
    beam_agent_ets:delete_all_objects(?RATE_TABLE),

    persistent_term:put(?PT_INIT, true),
    ok.

-doc "Tear down the security guard, clearing all state.".
-spec teardown() -> ok.
teardown() ->
    _ = persistent_term:erase(?PT_INIT),
    _ = persistent_term:erase(?PT_POLICY),
    _ = persistent_term:erase(?PT_RATE_CONFIG),
    _ = persistent_term:erase(?PT_TEMPORAL_RULES),
    _ = persistent_term:erase(?PT_VALIDATOR_MOD),
    _ = persistent_term:erase(?PT_HISTORY_MAX),
    safe_delete_all(?STATE_TABLE),
    safe_delete_all(?HISTORY_TABLE),
    safe_delete_all(?RATE_TABLE),
    safe_delete_all(?COMMAND_TABLE),
    ok.

-doc "Check whether the security guard is initialized.".
-spec running() -> boolean().
running() ->
    persistent_term:get(?PT_INIT, false).

-doc "Submit a command for security evaluation.".
-spec evaluate(beam_agent_command_parser:command_struct(), evaluate_opts()) ->
    guard_result().
evaluate(CmdStruct, EvalOpts) ->
    case get_security_state() of
        lockdown ->
            Reason = get_lockdown_reason(),
            {deny, <<"Lockdown: ", Reason/binary>>};
        throttle ->
            handle_throttle_evaluate(CmdStruct, EvalOpts);
        active ->
            handle_active_evaluate(CmdStruct, EvalOpts)
    end.

-doc """
Evaluate a command against the default stateless security baseline.

Used when the full guard state machine is not initialized. This still enforces
the default deny policy, but does not apply validator-specific state, rate
limits, or temporal history rules.
""".
-spec evaluate_default(beam_agent_command_parser:command_struct(), evaluate_opts()) ->
    allow | {deny, binary()}.
evaluate_default(CmdStruct, _EvalOpts) ->
    Policy = app_config(command_policy, beam_agent_command_policy:default_policy()),
    case beam_agent_command_policy:evaluate(CmdStruct, Policy) of
        {deny, Reason} ->
            {deny, Reason};
        _ ->
            allow
    end.

-doc "Record a command execution result for history and temporal detection.".
-spec record_execution(beam_agent_command_parser:command_struct(),
                       evaluate_opts(),
                       {ok, map()} | {error, term()}) -> ok.
record_execution(CmdStruct, EvalOpts, ExecResult) ->
    do_record_execution(CmdStruct, EvalOpts, ExecResult).

-doc "Force the guard into lockdown state.".
-spec lockdown(binary()) -> ok.
lockdown(Reason) ->
    enter_lockdown(Reason).

-doc "Reset the guard from lockdown or throttle to active state.".
-spec reset() -> ok.
reset() ->
    emit_event(reset, #{}),
    beam_agent_ets:delete_all_objects(?RATE_TABLE),
    beam_agent_ets:insert(?STATE_TABLE, {security_state, active}),
    beam_agent_ets:insert(?STATE_TABLE, {throttle_until, 0}),
    beam_agent_ets:insert(?STATE_TABLE, {throttle_denied, 0}),
    beam_agent_ets:insert(?STATE_TABLE, {lockdown_reason, <<>>}),
    ok.

-doc "Hot-reload the policy configuration.".
-spec reload_policy(beam_agent_command_policy:policy_config()) -> ok.
reload_policy(PolicyConfig) ->
    persistent_term:put(?PT_POLICY, PolicyConfig),
    emit_event(policy_reload, #{}),
    ok.

-doc "Get the current guard status.".
-spec status() -> status_map().
status() ->
    build_status().

%%--------------------------------------------------------------------
%% Command Port Tracking
%%--------------------------------------------------------------------

-doc """
Register a command port for tracking and cooperative lockdown.

The port is keyed in ETS; the calling process's pid is stored as
the owner so that lockdown can send it a shutdown message.
""".
-spec register_command(port(), binary()) -> ok.
register_command(Port, Command) ->
    beam_agent_ets:insert(?COMMAND_TABLE,
        {Port, self(), Command, erlang:monotonic_time()}),
    ok.

-doc "Unregister a command port (called on completion or cleanup).".
-spec unregister_command(port()) -> ok.
unregister_command(Port) ->
    try beam_agent_ets:delete(?COMMAND_TABLE, Port)
    catch _:_ -> ok
    end,
    ok.

%%--------------------------------------------------------------------
%% Internal: Active state evaluation
%%--------------------------------------------------------------------

-spec handle_active_evaluate(beam_agent_command_parser:command_struct(),
                             evaluate_opts()) -> guard_result().
handle_active_evaluate(CmdStruct, EvalOpts) ->
    RateConfig = persistent_term:get(?PT_RATE_CONFIG),
    case check_and_bump_rate_limits(CmdStruct, RateConfig) of
        ok ->
            case do_evaluate(CmdStruct, EvalOpts) of
                allow ->
                    apply_temporal_actions(CmdStruct, EvalOpts, allow);
                {deny, _} = Denial ->
                    Denial
            end;
        {exceeded, RetryMs} ->
            emit_event(throttled, #{retry_after_ms => RetryMs}),
            enter_throttle(RateConfig),
            {throttle, RetryMs}
    end.

%%--------------------------------------------------------------------
%% Internal: Throttle state evaluation (lazy recovery)
%%--------------------------------------------------------------------

-spec handle_throttle_evaluate(beam_agent_command_parser:command_struct(),
                               evaluate_opts()) -> guard_result().
handle_throttle_evaluate(CmdStruct, EvalOpts) ->
    ThrottleUntil = get_throttle_until(),
    Now = erlang:monotonic_time(millisecond),
    case Now >= ThrottleUntil of
        true ->
            %% Lazy recovery: throttle window expired, return to active.
            %% Two callers racing here both set active -- same outcome.
            beam_agent_ets:insert(?STATE_TABLE, {security_state, active}),
            beam_agent_ets:insert(?STATE_TABLE, {throttle_until, 0}),
            beam_agent_ets:insert(?STATE_TABLE, {throttle_denied, 0}),
            handle_active_evaluate(CmdStruct, EvalOpts);
        false ->
            %% Still throttled -- atomic increment, check lockdown
            NewCount = beam_agent_ets:update_counter(
                ?STATE_TABLE, throttle_denied, {2, 1},
                {throttle_denied, 0}),
            case NewCount >= ?LOCKDOWN_THRESHOLD of
                true ->
                    Reason = <<"Excessive commands during throttle">>,
                    emit_event(lockdown, #{reason => Reason,
                        denied_during_throttle => NewCount}),
                    enter_lockdown(Reason),
                    {deny, <<"Lockdown: ", Reason/binary>>};
                false ->
                    RetryMs = max(1, ThrottleUntil - Now),
                    {throttle, RetryMs}
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Command evaluation (policy + validator)
%%--------------------------------------------------------------------

-spec do_evaluate(beam_agent_command_parser:command_struct(),
                  evaluate_opts()) -> allow | {deny, binary()}.
do_evaluate(CmdStruct, EvalOpts) ->
    T0 = erlang:monotonic_time(),
    Policy = persistent_term:get(?PT_POLICY),
    PolicyResult = beam_agent_command_policy:evaluate(CmdStruct, Policy),
    case PolicyResult of
        {deny, Reason} ->
            emit_event(denied, #{layer => policy, reason => Reason,
                                 evaluation_time_us => eval_time_us(T0)}),
            {deny, Reason};
        _ ->
            Ctx = build_context(CmdStruct, EvalOpts, PolicyResult),
            ValidatorMod = persistent_term:get(?PT_VALIDATOR_MOD),
            try ValidatorMod:validate(CmdStruct, Ctx) of
                allow ->
                    emit_event(allowed, #{
                        agent => maps:get(agent, EvalOpts, undefined),
                        evaluation_time_us => eval_time_us(T0)}),
                    allow;
                {deny, Reason2} ->
                    emit_event(denied, #{
                        layer => validator, reason => Reason2,
                        evaluation_time_us => eval_time_us(T0)}),
                    {deny, Reason2};
                {deny, Reason2, _Details} ->
                    emit_event(denied, #{
                        layer => validator, reason => Reason2,
                        evaluation_time_us => eval_time_us(T0)}),
                    {deny, Reason2}
            catch
                Class:Err:Stack ->
                    logger:warning(
                        "beam_agent_command_guard: validator ~p crashed: "
                        "~p:~p~n~p",
                        [ValidatorMod, Class,
                         beam_agent_redaction:reason(Err),
                         beam_agent_redaction:stacktrace(Stack)]),
                    {deny, <<"Validator error (fail-safe deny)">>}
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Rate limiting
%%--------------------------------------------------------------------

%% Atomically check and bump rate limits for a command.
%%
%% Replaces the former check_rate_limits/2 + update_rate_limits/2 two-step
%% sequence, which had a TOCTOU race: concurrent callers could both pass
%% the read-only check before either bumped the counter.
%%
%% Each bucket (global, per-program, per-category) is bumped atomically
%% via ets:update_counter/4 with a default tuple.  If a bucket is exceeded
%% after the atomic bump, the bump stays — it represents a denied attempt
%% and prevents concurrent callers from sneaking through the window.
-spec check_and_bump_rate_limits(beam_agent_command_parser:command_struct(),
                                 rate_limit_config()) ->
    ok | {exceeded, pos_integer()}.
check_and_bump_rate_limits(CmdStruct, RC) ->
    Now = erlang:monotonic_time(millisecond),
    case check_and_bump_one({global, global}, Now,
                            maps:get(global, RC, undefined)) of
        {exceeded, Ms} -> {exceeded, Ms};
        ok ->
            Program = maps:get(program, CmdStruct, undefined),
            case check_and_bump_program(Program, Now, RC) of
                {exceeded, Ms} -> {exceeded, Ms};
                ok ->
                    ProgramBin = case Program of
                        undefined -> <<>>;
                        P -> P
                    end,
                    Category = beam_agent_command_parser:categorize(ProgramBin),
                    check_and_bump_category(Category, Now, RC)
            end
    end.

-spec check_and_bump_program(binary() | undefined, integer(),
                             rate_limit_config()) ->
    ok | {exceeded, pos_integer()}.
check_and_bump_program(undefined, _Now, _RC) -> ok;
check_and_bump_program(Program, Now, RC) ->
    check_and_bump_one({per_program, Program}, Now,
                       maps:get(per_program, RC, undefined)).

-spec check_and_bump_category(atom(), integer(), rate_limit_config()) ->
    ok | {exceeded, pos_integer()}.
check_and_bump_category(unknown, _Now, _RC) -> ok;
check_and_bump_category(Category, Now, RC) ->
    CategoryLimits = maps:get(per_category, RC, #{}),
    check_and_bump_one({per_category, Category}, Now,
                       maps:get(Category, CategoryLimits, undefined)).

%% Atomically bump a single rate-limit bucket and check the result.
%%
%% Uses ets:update_counter/4 with a default tuple so the increment is
%% a single atomic ETS operation.  After the bump:
%%   - If the window has expired, reset to a fresh 1-count window.
%%   - If the new count exceeds the limit, report exceeded (the bump
%%     stays as a record of the denied attempt — safe direction).
%%   - Otherwise, the bump counts a successful check.
-spec check_and_bump_one({atom(), atom()} | {binary(), binary()} | binary(), integer(),
                         {pos_integer(), pos_integer()} | undefined) ->
    ok | {exceeded, pos_integer()}.
check_and_bump_one(_Key, _Now, undefined) -> ok;
check_and_bump_one(Key, Now, {MaxCount, WindowMs}) ->
    do_check_and_bump(Key, Now, MaxCount, WindowMs, 1).

%% @private Atomic check-and-bump with bounded retry on CAS contention.
%% Retries tracks remaining attempts after a failed compare-and-swap at
%% window rollover.  One retry suffices: the CAS loser re-bumps into
%% the window the winner just opened, so a second CAS race is
%% astronomically unlikely.
do_check_and_bump(_Key, _Now, _MaxCount, _WindowMs, Retries)
  when Retries < 0 ->
    %% Retry exhausted — concurrent CAS contention persisted.
    %% Fail-open: allow the request rather than crash the caller.
    ok;
do_check_and_bump(Key, Now, MaxCount, WindowMs, Retries) ->
    Default = {Key, 0, Now},
    NewCount = beam_agent_ets:update_counter(
        ?RATE_TABLE, Key, {2, 1}, Default),
    case beam_agent_ets:lookup(?RATE_TABLE, Key) of
        [{_, _, WindowStart}] ->
            WindowEnd = WindowStart + WindowMs,
            if
                Now >= WindowEnd ->
                    %% Window expired — atomic compare-and-swap reset.
                    %% Only resets if WindowStart still matches the
                    %% stale value this caller observed.
                    case beam_agent_ets:select_replace(?RATE_TABLE,
                            [{{Key, '_', WindowStart}, [],
                              [{{const, {Key, 1, Now}}}]}]) of
                        1 ->
                            %% CAS succeeded — we reset the window and
                            %% are counted as request 1.
                            ok;
                        0 ->
                            %% CAS failed — another caller already
                            %% reset the window.  Our bump went into
                            %% the old (now-replaced) window.  Retry
                            %% so this request is counted in the
                            %% current window.
                            do_check_and_bump(Key, Now, MaxCount,
                                             WindowMs, Retries - 1)
                    end;
                NewCount > MaxCount ->
                    %% Over limit.  The bump stays as a record of the
                    %% denied attempt — prevents concurrent callers
                    %% from sneaking in.
                    {exceeded, WindowEnd - Now};
                true ->
                    ok
            end;
        [] ->
            %% Row deleted between bump and lookup (concurrent reset/0).
            %% The counter was just wiped — treat as a fresh window.
            ok
    end.

%%--------------------------------------------------------------------
%% Internal: Temporal pattern detection
%%--------------------------------------------------------------------

-spec apply_temporal_actions(beam_agent_command_parser:command_struct(),
                             evaluate_opts(), allow) ->
    allow.
apply_temporal_actions(CmdStruct, EvalOpts, Result) ->
    TemporalRules = persistent_term:get(?PT_TEMPORAL_RULES),
    CurrentEntry = cmd_to_entry(CmdStruct, EvalOpts),
    case check_temporal(CurrentEntry, TemporalRules) of
        ok ->
            Result;
        {action, throttle, RuleName} ->
            emit_event(pattern_detected,
                       #{rule => RuleName, action => throttle}),
            RateConfig = persistent_term:get(?PT_RATE_CONFIG),
            enter_throttle(RateConfig),
            Result;
        {action, lockdown, RuleName} ->
            Reason = <<"Temporal pattern: ", RuleName/binary>>,
            emit_event(pattern_detected,
                       #{rule => RuleName, action => lockdown}),
            enter_lockdown(Reason),
            Result;
        {action, alert, RuleName} ->
            emit_event(pattern_detected,
                       #{rule => RuleName, action => alert}),
            Result
    end.

-spec check_temporal(map(), [temporal_rule()]) ->
    ok | {action, atom(), binary()}.
check_temporal(_Entry, []) -> ok;
check_temporal(Entry, [#{pattern := Pattern, window_ms := WindowMs,
                         name := Name, action := Action} | Rest]) ->
    Now = erlang:monotonic_time(millisecond),
    History = get_history_since(Now - WindowMs),
    AllEntries = History ++ [Entry],
    case match_pattern_seq(Pattern, AllEntries) of
        true  -> {action, Action, Name};
        false -> check_temporal(Entry, Rest)
    end.

-spec match_pattern_seq([command_matcher()], [map()]) -> boolean().
match_pattern_seq([], _History) -> true;
match_pattern_seq(_Matchers, []) -> false;
match_pattern_seq([M | Ms], [E | Es]) ->
    case match_entry(M, E) of
        true  -> match_pattern_seq(Ms, Es);
        false -> match_pattern_seq([M | Ms], Es)
    end.

-spec match_entry(command_matcher(), map()) -> boolean().
match_entry(Matcher, Entry) ->
    check_field(program, Matcher, Entry) andalso
    check_field_contains(args_contain, Matcher, Entry) andalso
    check_field(exit_code, Matcher, Entry) andalso
    check_field(category, Matcher, Entry).

-spec check_field(program | exit_code | category, map(), map()) -> boolean().
check_field(Key, Matcher, Entry) ->
    case maps:get(Key, Matcher, undefined) of
        undefined -> true;
        Val       -> maps:get(Key, Entry, undefined) =:= Val
    end.

-spec check_field_contains(args_contain, map(), map()) -> boolean().
check_field_contains(Key, Matcher, Entry) ->
    case maps:get(Key, Matcher, undefined) of
        undefined -> true;
        Pattern   ->
            Raw = maps:get(raw, Entry, <<>>),
            binary:match(Raw, Pattern) =/= nomatch
    end.

%%--------------------------------------------------------------------
%% Internal: History management
%%--------------------------------------------------------------------

-spec do_record_execution(beam_agent_command_parser:command_struct(),
                          evaluate_opts(),
                          {ok, map()} | {error, term()}) -> ok.
do_record_execution(CmdStruct, EvalOpts, ExecResult) ->
    Now = erlang:monotonic_time(millisecond),
    ExitCode = case ExecResult of
        {ok, #{exit_code := EC}} -> EC;
        _ -> undefined
    end,
    Entry = (cmd_to_entry(CmdStruct, EvalOpts))#{exit_code => ExitCode},
    beam_agent_ets:insert(?HISTORY_TABLE, {{Now, make_ref()}, Entry}),
    HistoryMax = persistent_term:get(?PT_HISTORY_MAX),
    prune_history(HistoryMax),
    notify_validator(CmdStruct, EvalOpts, ExecResult),
    ok.

-spec cmd_to_entry(beam_agent_command_parser:command_struct(),
                   evaluate_opts()) -> map().
cmd_to_entry(CmdStruct, EvalOpts) ->
    #{
        program  => maps:get(program, CmdStruct, undefined),
        raw      => maps:get(raw, CmdStruct, <<>>),
        category => beam_agent_command_parser:categorize(
            maps:get(program, CmdStruct, <<>>)),
        agent    => maps:get(agent, EvalOpts, undefined)
    }.

-spec prune_history(pos_integer()) -> ok.
prune_history(Max) ->
    Size = beam_agent_ets:info(?HISTORY_TABLE, size),
    drop_oldest(max(0, Size - Max)).

-spec drop_oldest(non_neg_integer()) -> ok.
drop_oldest(0) -> ok;
drop_oldest(N) ->
    case ets:first(?HISTORY_TABLE) of
        '$end_of_table' -> ok;
        Key ->
            beam_agent_ets:delete(?HISTORY_TABLE, Key),
            drop_oldest(N - 1)
    end.

-spec get_history_since(integer()) -> [map()].
get_history_since(CutoffTime) ->
    MS = [{{{'$1', '_'}, '$2'}, [{'>=', '$1', CutoffTime}], ['$2']}],
    beam_agent_ets:select(?HISTORY_TABLE, MS).

-spec get_recent_history(?CONTEXT_HISTORY_DEPTH) -> [map()].
get_recent_history(N) ->
    collect_last(?HISTORY_TABLE, ets:last(?HISTORY_TABLE), N, []).

-spec collect_last(atom(), '$end_of_table' | integer(), non_neg_integer(), [map()]) -> [map()].
collect_last(_T, '$end_of_table', _N, Acc) -> Acc;
collect_last(_T, _Key, 0, Acc) -> Acc;
collect_last(T, Key, N, Acc) ->
    [{_, Entry}] = beam_agent_ets:lookup(T, Key),
    collect_last(T, ets:prev(T, Key), N - 1, [Entry | Acc]).

%%--------------------------------------------------------------------
%% Internal: State helpers
%%--------------------------------------------------------------------

-spec get_security_state() -> security_state().
get_security_state() ->
    case beam_agent_ets:lookup(?STATE_TABLE, security_state) of
        [{_, State}] -> State;
        [] -> active
    end.

-spec get_throttle_until() -> integer().
get_throttle_until() ->
    case beam_agent_ets:lookup(?STATE_TABLE, throttle_until) of
        [{_, Until}] -> Until;
        [] -> 0
    end.

-spec get_lockdown_reason() -> binary().
get_lockdown_reason() ->
    case beam_agent_ets:lookup(?STATE_TABLE, lockdown_reason) of
        [{_, Reason}] -> Reason;
        [] -> <<"Security lockdown">>
    end.

-spec enter_throttle(rate_limit_config()) -> ok.
enter_throttle(RC) ->
    WindowMs = smallest_window(RC),
    Now = erlang:monotonic_time(millisecond),
    beam_agent_ets:insert(?STATE_TABLE, {security_state, throttle}),
    beam_agent_ets:insert(?STATE_TABLE, {throttle_until, Now + WindowMs}),
    beam_agent_ets:insert(?STATE_TABLE, {throttle_denied, 0}),
    ok.

-spec signal_active_commands(binary()) -> ok.
signal_active_commands(Reason) ->
    Commands = try beam_agent_ets:tab2list(?COMMAND_TABLE)
               catch _:_ -> []
               end,
    lists:foreach(fun({Port, OwnerPid, _Cmd, _Time}) ->
        OwnerPid ! {beam_agent_lockdown, Port, Reason}
    end, Commands),
    safe_delete_all(?COMMAND_TABLE).

-spec enter_lockdown(binary()) -> ok.
enter_lockdown(Reason) ->
    signal_active_commands(Reason),
    emit_event(lockdown, #{reason => Reason}),
    beam_agent_ets:insert(?STATE_TABLE, {security_state, lockdown}),
    beam_agent_ets:insert(?STATE_TABLE, {lockdown_reason, Reason}),
    ok.

-spec smallest_window(rate_limit_config()) -> pos_integer().
smallest_window(RC) ->
    Base = [W || {_, W} <- [maps:get(global, RC, {0, 60000}),
                            maps:get(per_program, RC, {0, 60000})]],
    Cat  = [W || {_, W} <- maps:values(maps:get(per_category, RC, #{}))],
    case Base ++ Cat of
        [] -> 60000;
        All -> lists:min(All)
    end.

-spec build_status() -> status_map().
build_status() ->
    State = get_security_state(),
    HistSize = beam_agent_ets:info(?HISTORY_TABLE, size),
    CmdCount = beam_agent_ets:info(?COMMAND_TABLE, size),
    Rates = beam_agent_ets:tab2list(?RATE_TABLE),
    Status = #{
        state            => State,
        history_size     => HistSize,
        active_commands => CmdCount,
        rate_limits  => maps:from_list(
            [{Key, #{count => C, window_start => WS}}
             || {Key, C, WS} <- Rates])
    },
    case State of
        lockdown -> Status#{lockdown_reason => get_lockdown_reason()};
        _        -> Status
    end.

-spec safe_delete_all(table_name()) -> ok.
safe_delete_all(Table) ->
    try beam_agent_ets:delete_all_objects(Table)
    catch _:_ -> ok
    end,
    ok.

%%--------------------------------------------------------------------
%% Internal: Validation context
%%--------------------------------------------------------------------

-spec build_context(beam_agent_command_parser:command_struct(),
                    evaluate_opts(),
                    beam_agent_command_policy:policy_result()) ->
    beam_agent_command_validator:validation_context().
build_context(CmdStruct, EvalOpts, PolicyResult) ->
    (base_context(CmdStruct, EvalOpts))#{
        command_struct => CmdStruct,
        policy_result  => PolicyResult
    }.

-spec build_execution_context(beam_agent_command_parser:command_struct(),
                              evaluate_opts()) ->
    beam_agent_command_validator:execution_context().
build_execution_context(CmdStruct, EvalOpts) ->
    base_context(CmdStruct, EvalOpts).

-spec base_context(beam_agent_command_parser:command_struct(), evaluate_opts()) ->
    beam_agent_command_validator:execution_context().
base_context(CmdStruct, EvalOpts) ->
    #{
        raw_command    => maps:get(raw, CmdStruct, <<>>),
        command_form   => maps:get(input_form, CmdStruct, string),
        session_state  => maps:get(session_state, EvalOpts, undefined),
        agent          => maps:get(agent, EvalOpts, undefined),
        opts           => maps:get(opts, EvalOpts, #{}),
        cwd            => maps:get(cwd, EvalOpts, undefined),
        env            => maps:get(env, EvalOpts, undefined),
        history        => maybe_recent_history(?CONTEXT_HISTORY_DEPTH),
        timestamp      => erlang:system_time(),
        metadata       => maps:get(metadata, EvalOpts, #{})
    }.

-spec maybe_recent_history(?CONTEXT_HISTORY_DEPTH) -> [map()].
maybe_recent_history(N) ->
    case running() of
        true ->
            try get_recent_history(N)
            catch _:_ -> []
            end;
        false ->
            []
    end.

%%--------------------------------------------------------------------
%% Internal: Post-execution notification
%%--------------------------------------------------------------------

-spec notify_validator(beam_agent_command_parser:command_struct(),
                       evaluate_opts(),
                       {ok, map()} | {error, term()}) -> ok.
notify_validator(CmdStruct, EvalOpts, ExecResult) ->
    Mod = persistent_term:get(?PT_VALIDATOR_MOD),
    case erlang:function_exported(Mod, on_execution, 3) of
        true ->
            Ctx = build_execution_context(CmdStruct, EvalOpts),
            try Mod:on_execution(CmdStruct, Ctx, ExecResult)
            catch Class:Err:Stack ->
                logger:warning(
                    "beam_agent_command_guard: on_execution ~p crashed: "
                    "~p:~p~n~p",
                    [Mod, Class,
                     beam_agent_redaction:reason(Err),
                     beam_agent_redaction:stacktrace(Stack)])
            end,
            ok;
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% Internal: Config
%%--------------------------------------------------------------------

-spec app_config(command_policy,
                 beam_agent_command_policy:policy_config()) ->
    beam_agent_command_policy:policy_config();
                (command_rate_limits, rate_limit_config()) ->
    rate_limit_config();
                (command_temporal_rules, [temporal_rule()]) ->
    [temporal_rule()];
                (command_validator, module()) ->
    module().
app_config(Key, Default) ->
    application:get_env(beam_agent, Key, Default).

-spec default_rate_limits() -> default_rate_limit_config().
default_rate_limits() ->
    #{
        global      => {60, 60000},
        per_program => {20, 60000},
        per_category => #{
            destructive      => {5, 60000},
            filesystem_write => {30, 60000},
            network          => {10, 60000}
        }
    }.

-spec default_temporal_rules() -> [temporal_rule()].
default_temporal_rules() ->
    [
        #{name        => <<"rapid_deletion">>,
          description => <<"Multiple file deletions in rapid succession">>,
          pattern     => [#{program => <<"rm">>},
                          #{program => <<"rm">>},
                          #{program => <<"rm">>}],
          window_ms   => 10000,
          action      => throttle},
        #{name        => <<"recon_then_destroy">>,
          description => <<"Directory listing followed by recursive deletion">>,
          pattern     => [#{program => <<"ls">>},
                          #{program => <<"rm">>, args_contain => <<"-r">>}],
          window_ms   => 30000,
          action      => alert},
        #{name        => <<"repeated_failures">>,
          description => <<"Multiple command failures may indicate probing">>,
          pattern     => [#{exit_code => 1}, #{exit_code => 1},
                          #{exit_code => 1}, #{exit_code => 1},
                          #{exit_code => 1}],
          window_ms   => 30000,
          action      => alert}
    ].

%%--------------------------------------------------------------------
%% Internal: Telemetry
%%--------------------------------------------------------------------

-spec eval_time_us(integer()) -> integer().
eval_time_us(T0) ->
    erlang:convert_time_unit(erlang:monotonic_time() - T0, native, microsecond).

-spec emit_event(atom(), map()) -> ok.
emit_event(EventSuffix, Metadata) ->
    case erlang:function_exported(telemetry, execute, 3) of
        true ->
            apply(telemetry, execute,
                  [[beam_agent, security, EventSuffix],
                   #{system_time => erlang:system_time()},
                   Metadata]);
        false -> ok
    end.
