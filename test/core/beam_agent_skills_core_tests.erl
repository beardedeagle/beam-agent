%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_skills_core (universal skill management).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_tables, clear)
%%%   - Skill registration (register_skill) with defaults and custom opts
%%%   - Skill unregistration (unregister_skill) including idempotent removal
%%%   - Skill listing (skills_list) with source and enabled filters
%%%   - Remote skill listing (skills_remote_list) forced source=remote
%%%   - Skill export (skills_remote_export) with exported_at timestamp
%%%   - Config write/read (skills_config_write, skills_config_read)
%%%   - Register overwrites (re-registering same skill id updates entry)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_skills_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_table_idempotent_test() ->
    ok = beam_agent_skills_core:ensure_tables(),
    ok = beam_agent_skills_core:ensure_tables(),
    ok = beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear().

clear_removes_all_data_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_clear">>,
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"s1">>, #{}),
    ok = beam_agent_skills_core:skills_config_write(Session, <<"/p">>, true),
    {ok, [_]} = beam_agent_skills_core:skills_list(Session),
    {ok, [_]} = beam_agent_skills_core:skills_config_read(Session),
    ok = beam_agent_skills_core:clear(),
    {ok, []} = beam_agent_skills_core:skills_list(Session),
    {ok, []} = beam_agent_skills_core:skills_config_read(Session).

%%====================================================================
%% register_skill tests
%%====================================================================

register_skill_defaults_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_reg_def">>,
    {ok, Entry} = beam_agent_skills_core:register_skill(Session, <<"my_skill">>, #{}),
    ?assertEqual(<<"my_skill">>, maps:get(id, Entry)),
    ?assertEqual(<<"my_skill">>, maps:get(name, Entry)),
    ?assertEqual(true, maps:get(enabled, Entry)),
    ?assertEqual(local, maps:get(source, Entry)),
    ?assertEqual(error, maps:find(description, Entry)),
    ?assertEqual(error, maps:find(config, Entry)),
    beam_agent_skills_core:clear().

register_skill_custom_opts_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_reg_custom">>,
    Opts = #{
        name => <<"Custom Name">>,
        description => <<"A test skill">>,
        source => remote,
        enabled => false,
        config => #{timeout => 5000}
    },
    {ok, Entry} = beam_agent_skills_core:register_skill(Session, <<"cs1">>, Opts),
    ?assertEqual(<<"cs1">>, maps:get(id, Entry)),
    ?assertEqual(<<"Custom Name">>, maps:get(name, Entry)),
    ?assertEqual(<<"A test skill">>, maps:get(description, Entry)),
    ?assertEqual(remote, maps:get(source, Entry)),
    ?assertEqual(false, maps:get(enabled, Entry)),
    ?assertEqual(#{timeout => 5000}, maps:get(config, Entry)),
    beam_agent_skills_core:clear().

%%====================================================================
%% unregister_skill tests
%%====================================================================

unregister_skill_removes_skill_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_unreg">>,
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"to_remove">>, #{}),
    {ok, [_]} = beam_agent_skills_core:skills_list(Session),
    ok = beam_agent_skills_core:unregister_skill(Session, <<"to_remove">>),
    {ok, []} = beam_agent_skills_core:skills_list(Session),
    beam_agent_skills_core:clear().

unregister_skill_idempotent_on_missing_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_unreg_idem">>,
    ok = beam_agent_skills_core:unregister_skill(Session, <<"nonexistent">>),
    ok = beam_agent_skills_core:unregister_skill(Session, <<"nonexistent">>),
    beam_agent_skills_core:clear().

%%====================================================================
%% skills_list tests
%%====================================================================

skills_list_empty_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    {ok, List} = beam_agent_skills_core:skills_list(<<"skills_test_empty">>),
    ?assertEqual([], List),
    beam_agent_skills_core:clear().

skills_list_returns_all_registered_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_list_all">>,
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"a">>, #{}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"b">>, #{}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"c">>, #{}),
    {ok, List} = beam_agent_skills_core:skills_list(Session),
    ?assertEqual(3, length(List)),
    Ids = lists:sort([maps:get(id, E) || E <- List]),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], Ids),
    beam_agent_skills_core:clear().

skills_list_filter_by_source_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_filter_src">>,
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"local1">>,
        #{source => local}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"remote1">>,
        #{source => remote}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"builtin1">>,
        #{source => builtin}),
    {ok, LocalOnly} = beam_agent_skills_core:skills_list(Session,
        #{source => local}),
    ?assertEqual(1, length(LocalOnly)),
    ?assertEqual(<<"local1">>, maps:get(id, hd(LocalOnly))),
    {ok, RemoteOnly} = beam_agent_skills_core:skills_list(Session,
        #{source => remote}),
    ?assertEqual(1, length(RemoteOnly)),
    ?assertEqual(<<"remote1">>, maps:get(id, hd(RemoteOnly))),
    beam_agent_skills_core:clear().

skills_list_filter_by_enabled_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_filter_en">>,
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"on1">>,
        #{enabled => true}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"off1">>,
        #{enabled => false}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"on2">>,
        #{enabled => true}),
    {ok, Enabled} = beam_agent_skills_core:skills_list(Session,
        #{enabled => true}),
    ?assertEqual(2, length(Enabled)),
    {ok, Disabled} = beam_agent_skills_core:skills_list(Session,
        #{enabled => false}),
    ?assertEqual(1, length(Disabled)),
    ?assertEqual(<<"off1">>, maps:get(id, hd(Disabled))),
    beam_agent_skills_core:clear().

%%====================================================================
%% skills_remote_list tests
%%====================================================================

skills_remote_list_only_remote_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_remote_list">>,
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"local1">>,
        #{source => local}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"remote1">>,
        #{source => remote}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"remote2">>,
        #{source => remote}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"builtin1">>,
        #{source => builtin}),
    {ok, RemoteList} = beam_agent_skills_core:skills_remote_list(Session),
    ?assertEqual(2, length(RemoteList)),
    Ids = lists:sort([maps:get(id, E) || E <- RemoteList]),
    ?assertEqual([<<"remote1">>, <<"remote2">>], Ids),
    beam_agent_skills_core:clear().

skills_remote_list_with_enabled_filter_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_remote_en">>,
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"r_on">>,
        #{source => remote, enabled => true}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"r_off">>,
        #{source => remote, enabled => false}),
    {ok, EnabledRemote} = beam_agent_skills_core:skills_remote_list(Session,
        #{enabled => true}),
    ?assertEqual(1, length(EnabledRemote)),
    ?assertEqual(<<"r_on">>, maps:get(id, hd(EnabledRemote))),
    beam_agent_skills_core:clear().

%%====================================================================
%% skills_remote_export tests
%%====================================================================

skills_remote_export_returns_skills_and_timestamp_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_export">>,
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"exp1">>, #{}),
    {ok, _} = beam_agent_skills_core:register_skill(Session, <<"exp2">>, #{}),
    Before = erlang:system_time(millisecond),
    {ok, Export} = beam_agent_skills_core:skills_remote_export(Session, #{}),
    After = erlang:system_time(millisecond),
    Skills = maps:get(skills, Export),
    ExportedAt = maps:get(exported_at, Export),
    ?assertEqual(2, length(Skills)),
    ?assert(is_integer(ExportedAt)),
    ?assert(ExportedAt >= Before),
    ?assert(ExportedAt =< After),
    beam_agent_skills_core:clear().

skills_remote_export_empty_session_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    {ok, Export} = beam_agent_skills_core:skills_remote_export(
        <<"skills_test_export_empty">>, #{}),
    ?assertEqual([], maps:get(skills, Export)),
    ?assert(is_integer(maps:get(exported_at, Export))),
    beam_agent_skills_core:clear().

%%====================================================================
%% skills_config_write / skills_config_read tests
%%====================================================================

skills_config_write_and_read_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_cfg_wr">>,
    ok = beam_agent_skills_core:skills_config_write(Session, <<"/path/a">>, true),
    {ok, Configs} = beam_agent_skills_core:skills_config_read(Session),
    ?assertEqual(1, length(Configs)),
    [Cfg] = Configs,
    ?assertEqual(<<"/path/a">>, maps:get(path, Cfg)),
    ?assertEqual(true, maps:get(enabled, Cfg)),
    ?assert(is_integer(maps:get(updated_at, Cfg))),
    beam_agent_skills_core:clear().

skills_config_multiple_per_session_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_cfg_multi">>,
    ok = beam_agent_skills_core:skills_config_write(Session, <<"/path/x">>, true),
    ok = beam_agent_skills_core:skills_config_write(Session, <<"/path/y">>, false),
    ok = beam_agent_skills_core:skills_config_write(Session, <<"/path/z">>, true),
    {ok, Configs} = beam_agent_skills_core:skills_config_read(Session),
    ?assertEqual(3, length(Configs)),
    Paths = lists:sort([maps:get(path, C) || C <- Configs]),
    ?assertEqual([<<"/path/x">>, <<"/path/y">>, <<"/path/z">>], Paths),
    beam_agent_skills_core:clear().

skills_config_read_empty_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    {ok, Configs} = beam_agent_skills_core:skills_config_read(
        <<"skills_test_cfg_empty">>),
    ?assertEqual([], Configs),
    beam_agent_skills_core:clear().

skills_config_overwrite_same_path_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_cfg_overwrite">>,
    ok = beam_agent_skills_core:skills_config_write(Session, <<"/path/ow">>, true),
    ok = beam_agent_skills_core:skills_config_write(Session, <<"/path/ow">>, false),
    {ok, Configs} = beam_agent_skills_core:skills_config_read(Session),
    ?assertEqual(1, length(Configs)),
    [Cfg] = Configs,
    ?assertEqual(false, maps:get(enabled, Cfg)),
    beam_agent_skills_core:clear().

%%====================================================================
%% Register overwrites tests
%%====================================================================

register_overwrites_existing_entry_test() ->
    beam_agent_skills_core:ensure_tables(),
    beam_agent_skills_core:clear(),
    Session = <<"skills_test_overwrite">>,
    {ok, First} = beam_agent_skills_core:register_skill(Session, <<"ow1">>,
        #{name => <<"Original">>, source => local}),
    ?assertEqual(<<"Original">>, maps:get(name, First)),
    ?assertEqual(local, maps:get(source, First)),
    {ok, Second} = beam_agent_skills_core:register_skill(Session, <<"ow1">>,
        #{name => <<"Updated">>, source => remote}),
    ?assertEqual(<<"Updated">>, maps:get(name, Second)),
    ?assertEqual(remote, maps:get(source, Second)),
    %% Only one entry exists for this skill id
    {ok, List} = beam_agent_skills_core:skills_list(Session),
    ?assertEqual(1, length(List)),
    ?assertEqual(<<"Updated">>, maps:get(name, hd(List))),
    beam_agent_skills_core:clear().
