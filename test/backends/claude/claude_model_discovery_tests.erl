-module(claude_model_discovery_tests).

-include_lib("eunit/include/eunit.hrl").

discover_models_from_claude_config_test() ->
    TmpDir = make_tmp_dir(),
    try
        ConfigPath = filename:join(TmpDir, ".claude.json"),
        Config = #{
            <<"recentProject">> => #{
                <<"lastModelUsage">> => #{
                    <<"claude-sonnet-4-6">> => #{},
                    <<"claude-opus-4-6">> => #{}
                }
            },
            <<"workspace">> => #{
                <<"model">> => <<"claude-haiku-4-5-20251001[1m]">>
            }
        },
        ok = file:write_file(ConfigPath, json:encode(Config)),
        {ok, Models} = claude_agent_sdk:discover_models_from_claude_config(ConfigPath),
        ModelIds = ordsets:from_list([maps:get(<<"modelId">>, M) || M <- Models]),
        ?assertEqual(
            ordsets:from_list([
                <<"claude-haiku-4-5-20251001">>,
                <<"claude-opus-4-6">>,
                <<"claude-sonnet-4-6">>
            ]),
            ModelIds)
    after
        rm_rf(TmpDir)
    end.

normalize_claude_model_id_strips_context_suffix_test() ->
    ?assertEqual(<<"claude-sonnet-4-6">>,
                 claude_agent_sdk:normalize_claude_model_id(
                     <<"claude-sonnet-4-6[1m]">>)).

claude_config_path_without_home_returns_undefined_test() ->
    with_env_unset(
        "HOME",
        fun() ->
            ?assertEqual(undefined, claude_agent_sdk:claude_config_path()),
            ?assertEqual({ok, []}, claude_agent_sdk:discover_models_from_claude_config())
        end).

claude_config_path_empty_home_returns_undefined_test() ->
    with_env_value(
        "HOME",
        "",
        fun() ->
            ?assertEqual(undefined, claude_agent_sdk:claude_config_path()),
            ?assertEqual({ok, []}, claude_agent_sdk:discover_models_from_claude_config())
        end).

make_tmp_dir() ->
    Base = filename:basedir(user_cache, "beam_agent_test"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, "claude_model_test_" ++ Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
    _ = file:change_mode(Dir, 8#700),
    Dir.

rm_rf(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foreach(
                fun(F) ->
                    Path = filename:join(Dir, F),
                    case filelib:is_dir(Path) of
                        true  -> rm_rf(Path);
                        false -> file:delete(Path)
                    end
                end, Files),
            file:del_dir(Dir);
        {error, _} ->
            ok
    end.

with_env_unset(Name, Fun) ->
    Previous = os:getenv(Name),
    os:unsetenv(Name),
    try
        Fun()
    after
        case Previous of
            false -> os:unsetenv(Name);
            Value -> os:putenv(Name, Value)
        end
    end.

with_env_value(Name, Value, Fun) ->
    Previous = os:getenv(Name),
    os:putenv(Name, Value),
    try
        Fun()
    after
        case Previous of
            false -> os:unsetenv(Name);
            OldValue -> os:putenv(Name, OldValue)
        end
    end.
