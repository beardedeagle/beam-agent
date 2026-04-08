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
