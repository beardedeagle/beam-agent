-module(beam_agent_skills_core).
-moduledoc false.

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Skill registration
    register_skill/3,
    unregister_skill/2,
    %% Skill listing
    skills_list/1,
    skills_list/2,
    %% Remote skill listing
    skills_remote_list/1,
    skills_remote_list/2,
    %% Skill export
    skills_remote_export/2,
    %% Config management
    skills_config_write/3,
    skills_config_read/1,
    skills_config_read/2
]).

-export_type([
    skill_entry/0,
    skill_config/0,
    skill_source/0,
    list_opts/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Source of a registered skill.
-type skill_source() :: local | remote | builtin.

%% A single skill entry as stored and returned from this module.
-type skill_entry() :: #{
    id          := binary(),
    name        := binary(),
    description => binary(),
    enabled     := boolean(),
    source      := skill_source(),
    config      => map()
}.

%% A single skill configuration entry.
-type skill_config() :: #{
    path       := binary(),
    enabled    := boolean(),
    updated_at := integer()
}.

%% Options accepted by skills_list/2 and skills_remote_list/2.
-type list_opts() :: #{
    source  => skill_source(),
    enabled => boolean()
}.

%% ETS table backing all skill state.
-define(SKILLS_TABLE, beam_agent_skills).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the ETS table exists. Idempotent — safe to call multiple times.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?SKILLS_TABLE, [set, named_table,
        {read_concurrency, true}]).

-doc "Delete all skill and config data from the ETS table.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?SKILLS_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Skill Registration
%%--------------------------------------------------------------------

-doc """
Register a skill for a session.

`Opts` may include:
  - `name` (binary) — human-readable label; defaults to `SkillId`
  - `description` (binary) — optional free-text description
  - `source` (local | remote | builtin) — origin of the skill; defaults to `local`
  - `enabled` (boolean) — initial enabled state; defaults to `true`
  - `config` (map) — arbitrary skill-specific configuration

Returns `{ok, skill_entry()}` on success.
""".
-spec register_skill(pid() | binary(), binary(), map()) ->
    {ok, skill_entry()}.
register_skill(Session, SkillId, Opts)
  when (is_pid(Session) orelse is_binary(Session)),
       is_binary(SkillId), is_map(Opts) ->
    ensure_tables(),
    Key = session_key(Session),
    Entry = build_entry(SkillId, Opts),
    beam_agent_ets:insert(?SKILLS_TABLE, {{Key, skill, SkillId}, Entry}),
    {ok, Entry}.

-doc "Remove a skill from a session. Returns `ok` whether or not the skill existed.".
-spec unregister_skill(pid() | binary(), binary()) -> ok.
unregister_skill(Session, SkillId)
  when (is_pid(Session) orelse is_binary(Session)),
       is_binary(SkillId) ->
    ensure_tables(),
    Key = session_key(Session),
    beam_agent_ets:delete(?SKILLS_TABLE, {Key, skill, SkillId}),
    ok.

%%--------------------------------------------------------------------
%% Skill Listing
%%--------------------------------------------------------------------

-doc "List all skills for a session. Equivalent to `skills_list(Session, #{})`.".
-spec skills_list(pid() | binary()) -> {ok, [skill_entry()]}.
skills_list(Session) ->
    skills_list(Session, #{}).

-doc """
List skills for a session with optional filters.

Filters (all optional):
  - `source` — only skills whose `source` field matches
  - `enabled` — only skills matching this enabled state

Returns `{ok, [skill_entry()]}`.
""".
-spec skills_list(pid() | binary(), list_opts()) -> {ok, [skill_entry()]}.
skills_list(Session, Opts)
  when (is_pid(Session) orelse is_binary(Session)), is_map(Opts) ->
    ensure_tables(),
    Skills = get_skills(Session),
    Filtered = apply_skill_filters(Skills, Opts),
    {ok, Filtered}.

%%--------------------------------------------------------------------
%% Remote Skill Listing
%%--------------------------------------------------------------------

-doc """
List remote skills for a session. Equivalent to `skills_remote_list(Session, #{})`.
""".
-spec skills_remote_list(pid() | binary()) -> {ok, [skill_entry()]}.
skills_remote_list(Session) ->
    skills_remote_list(Session, #{}).

-doc """
List skills from remote or registry sources.

In the universal fallback implementation, returns all skills whose
`source` is `remote`. Any `enabled` filter in `Opts` is also applied.

Returns `{ok, [skill_entry()]}`.
""".
-spec skills_remote_list(pid() | binary(), list_opts()) ->
    {ok, [skill_entry()]}.
skills_remote_list(Session, Opts)
  when (is_pid(Session) orelse is_binary(Session)), is_map(Opts) ->
    %% Force source=remote; merge with any caller-supplied enabled filter.
    RemoteOpts = Opts#{source => remote},
    skills_list(Session, RemoteOpts).

%%--------------------------------------------------------------------
%% Skill Export
%%--------------------------------------------------------------------

-doc """
Export all skills for a session as a serializable map.

Returns `{ok, #{skills => [skill_entry()], exported_at => integer()}}`.
The `exported_at` value is a Unix timestamp in milliseconds.
""".
-spec skills_remote_export(pid() | binary(), map()) ->
    {ok, #{skills := [skill_entry()], exported_at := integer()}}.
skills_remote_export(Session, _Opts)
  when is_pid(Session) orelse is_binary(Session) ->
    ensure_tables(),
    Skills = get_skills(Session),
    ExportedAt = erlang:system_time(millisecond),
    {ok, #{skills => Skills, exported_at => ExportedAt}}.

%%--------------------------------------------------------------------
%% Config Management
%%--------------------------------------------------------------------

-doc """
Write a skill config entry for a session.

`Path` is the skill path or identifier used as the config key.
`Enabled` is the boolean state to record. The entry is timestamped
with the current system time in milliseconds.

Returns `ok`.
""".
-spec skills_config_write(pid() | binary(), binary(), boolean()) -> ok.
skills_config_write(Session, Path, Enabled)
  when (is_pid(Session) orelse is_binary(Session)),
       is_binary(Path), is_boolean(Enabled) ->
    ensure_tables(),
    Key = session_key(Session),
    Now = erlang:system_time(millisecond),
    Config = #{path => Path, enabled => Enabled, updated_at => Now},
    beam_agent_ets:insert(?SKILLS_TABLE, {{Key, config, Path}, Config}),
    ok.

-doc "Read all skill config entries for a session. Equivalent to `skills_config_read(Session, #{})`.".
-spec skills_config_read(pid() | binary()) -> {ok, [skill_config()]}.
skills_config_read(Session) ->
    skills_config_read(Session, #{}).

-doc """
Read skill config entries for a session with optional filters.

Currently no filter keys are applied on the config namespace —
all stored config entries for the session are returned. The `Opts`
argument is accepted for future extensibility.

Returns `{ok, [skill_config()]}`.
""".
-spec skills_config_read(pid() | binary(), map()) ->
    {ok, [skill_config()]}.
skills_config_read(Session, _Opts)
  when is_pid(Session) orelse is_binary(Session) ->
    ensure_tables(),
    Configs = get_configs(Session),
    {ok, Configs}.

%%--------------------------------------------------------------------
%% Internal: Session Key
%%--------------------------------------------------------------------

%% Derive a stable ETS key from a session reference.
%% Pids are used as-is; binaries are passed through unchanged.
-spec session_key(pid() | binary()) -> pid() | binary().
session_key(Session) when is_pid(Session) -> Session;
session_key(Session) when is_binary(Session) -> Session.

%%--------------------------------------------------------------------
%% Internal: ETS Collectors
%%--------------------------------------------------------------------

%% Collect all skill entries for a session from ETS.
-spec get_skills(pid() | binary()) -> [skill_entry()].
get_skills(Session) ->
    Key = session_key(Session),
    %% Match all objects whose ETS key is {Key, skill, _}.
    Pattern = {{Key, skill, '_'}, '_'},
    Matches = ets:match_object(?SKILLS_TABLE, Pattern),
    [Entry || {_, Entry} <- Matches].

%% Collect all config entries for a session from ETS.
-spec get_configs(pid() | binary()) -> [skill_config()].
get_configs(Session) ->
    Key = session_key(Session),
    Pattern = {{Key, config, '_'}, '_'},
    Matches = ets:match_object(?SKILLS_TABLE, Pattern),
    [Config || {_, Config} <- Matches].

%%--------------------------------------------------------------------
%% Internal: Entry Construction
%%--------------------------------------------------------------------

%% Build a skill_entry() from a SkillId and caller-supplied options.
-spec build_entry(binary(), map()) -> skill_entry().
build_entry(SkillId, Opts) ->
    Base = #{
        id      => SkillId,
        name    => maps:get(name, Opts, SkillId),
        enabled => maps:get(enabled, Opts, true),
        source  => maps:get(source, Opts, local)
    },
    with_optional(description, Opts,
        with_optional(config, Opts, Base)).

%% Conditionally add an optional key from Opts into a map.
-spec with_optional(description | config, map(), skill_entry()) -> skill_entry().
with_optional(Key, Opts, Map) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> Map#{Key => Value};
        error       -> Map
    end.

%%--------------------------------------------------------------------
%% Internal: Filtering
%%--------------------------------------------------------------------

%% Apply source and enabled filters to a list of skill entries.
-spec apply_skill_filters([skill_entry()], list_opts()) -> [skill_entry()].
apply_skill_filters(Skills, Opts) ->
    lists:filter(fun(Entry) ->
        matches_source(Entry, Opts) andalso matches_enabled(Entry, Opts)
    end, Skills).

-spec matches_source(skill_entry(), list_opts()) -> boolean().
matches_source(Entry, #{source := Source}) ->
    maps:get(source, Entry, local) =:= Source;
matches_source(_, _) ->
    true.

-spec matches_enabled(skill_entry(), list_opts()) -> boolean().
matches_enabled(Entry, #{enabled := Enabled}) when is_boolean(Enabled) ->
    maps:get(enabled, Entry, true) =:= Enabled;
matches_enabled(_, _) ->
    true.
