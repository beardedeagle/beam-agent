-module(opencode_model_discovery_tests).

-include_lib("eunit/include/eunit.hrl").

parse_cli_model_lines_test() ->
    Models = opencode_client:parse_cli_model_lines([
        "openai/gpt-5",
        "",
        "anthropic/claude-sonnet-4-6"
    ]),
    ?assertEqual(
        [
            #{<<"modelId">> => <<"openai/gpt-5">>,
              <<"name">> => <<"openai/gpt-5">>},
            #{<<"modelId">> => <<"anthropic/claude-sonnet-4-6">>,
              <<"name">> => <<"anthropic/claude-sonnet-4-6">>}
        ],
        Models).

discover_cli_models_uses_opencode_models_command_test() ->
    TmpDir = make_tmp_dir(),
    try
        CliPath = write_fake_opencode(TmpDir),
        {ok, Models} = opencode_client:discover_cli_models(#{cli_path => CliPath}),
        ?assertEqual(
            [
                #{<<"modelId">> => <<"openai/gpt-5">>,
                  <<"name">> => <<"openai/gpt-5">>},
                #{<<"modelId">> => <<"anthropic/claude-sonnet-4-6">>,
                  <<"name">> => <<"anthropic/claude-sonnet-4-6">>}
            ],
            Models)
    after
        rm_rf(TmpDir)
    end.

discover_cli_models_with_explicit_cli_path_does_not_require_login_shell_test() ->
    TmpDir = make_tmp_dir(),
    PreviousPath = os:getenv("PATH"),
    try
        CliPath = write_fake_opencode(TmpDir),
        os:putenv("PATH", ""),
        with_env_value(
            "SHELL",
            "definitely-not-a-shell",
            fun() ->
                {ok, Models} = opencode_client:discover_cli_models(#{cli_path => CliPath}),
                ?assertEqual(
                    [
                        #{<<"modelId">> => <<"openai/gpt-5">>,
                          <<"name">> => <<"openai/gpt-5">>},
                        #{<<"modelId">> => <<"anthropic/claude-sonnet-4-6">>,
                          <<"name">> => <<"anthropic/claude-sonnet-4-6">>}
                    ],
                    Models)
            end)
    after
        case PreviousPath of
            false -> os:unsetenv("PATH");
            Value -> os:putenv("PATH", Value)
        end,
        rm_rf(TmpDir)
    end.

discover_cli_models_uses_login_shell_first_for_default_bare_command_test() ->
    TmpDir = make_tmp_dir(),
    ShellBinDir = filename:join(TmpDir, "shell-bin"),
    PathBinDir = filename:join(TmpDir, "path-bin"),
    PreviousPath = os:getenv("PATH"),
    try
        ok = filelib:ensure_dir(filename:join(ShellBinDir, "placeholder")),
        ok = filelib:ensure_dir(filename:join(PathBinDir, "placeholder")),
        _ShellCli = write_fake_opencode_named(ShellBinDir, "opencode", "shell-first/good-model"),
        _PathCli = write_fake_opencode_named(PathBinDir, "opencode", "path-visible/wrong-model"),
        ShellPath = write_fake_shell_with_path(TmpDir, ShellBinDir),
        os:putenv("PATH", PathBinDir),
        with_env_value(
            "SHELL",
            ShellPath,
            fun() ->
                {ok, Models} =
                    opencode_client:discover_cli_models(
                        #{}),
                ?assertEqual(
                    [
                        #{<<"modelId">> => <<"shell-first/good-model">>,
                          <<"name">> => <<"shell-first/good-model">>}
                    ],
                    Models)
            end)
    after
        case PreviousPath of
            false -> os:unsetenv("PATH");
            Value -> os:putenv("PATH", Value)
        end,
        rm_rf(TmpDir)
    end.

write_fake_opencode(Dir) ->
    Path = filename:join(Dir, "opencode"),
    ok = file:write_file(
        Path,
        <<"#!/bin/sh\n"
          "if [ \"$1\" = \"models\" ]; then\n"
          "  printf '%s\\n' 'openai/gpt-5'\n"
          "  printf '%s\\n' 'anthropic/claude-sonnet-4-6'\n"
          "  exit 0\n"
          "fi\n"
          "exit 1\n">>),
    ok = file:change_mode(Path, 8#755),
    Path.

write_fake_opencode_named(Dir, Name, ModelId) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(
        Path,
        iolist_to_binary(
            ["#!/bin/sh\n",
             "if [ \"$1\" = \"models\" ]; then\n",
             "  printf '%s\\n' '", ModelId, "'\n",
             "  exit 0\n",
             "fi\n",
             "exit 1\n"])),
    ok = file:change_mode(Path, 8#755),
    Path.

write_fake_shell_with_path(Dir, ShellBinDir) ->
    Path = filename:join(Dir, "fake-shell"),
    ok = file:write_file(
        Path,
        <<"#!/bin/sh\n"
          "PATH=\"", (list_to_binary(ShellBinDir))/binary, ":$PATH\"\n"
          "export PATH\n"
          "while [ $# -gt 0 ]; do\n"
          "  if [ \"$1\" = \"-c\" ]; then\n"
          "    shift\n"
          "    exec /bin/sh -c \"$1\"\n"
          "  fi\n"
          "  shift\n"
          "done\n"
          "exit 1\n">>),
    ok = file:change_mode(Path, 8#755),
    Path.

make_tmp_dir() ->
    Base = filename:basedir(user_cache, "beam_agent_test"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, "opencode_model_test_" ++ Unique),
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
