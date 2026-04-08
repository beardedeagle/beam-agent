-module(copilot_model_discovery_tests).

-include_lib("eunit/include/eunit.hrl").

parse_prompt_model_lines_ignores_non_model_text_test() ->
    Models = copilot_client:parse_prompt_model_lines([
        "Here are the available models:",
        "- gpt-5.4",
        "claude-sonnet-4.6",
        "",
        "gpt 5 with spaces should be ignored"
    ]),
    ?assertEqual(
        [
            #{<<"modelId">> => <<"gpt-5.4">>,
              <<"name">> => <<"gpt-5.4">>},
            #{<<"modelId">> => <<"claude-sonnet-4.6">>,
              <<"name">> => <<"claude-sonnet-4.6">>}
        ],
        Models).

discover_prompt_models_uses_noninteractive_cli_prompt_test() ->
    TmpDir = make_tmp_dir(),
    try
        ArgsPath = filename:join(TmpDir, "copilot-model.args"),
        CliPath = write_fake_copilot(TmpDir, ArgsPath),
        {ok, Models} = copilot_client:discover_prompt_models(#{cli_path => CliPath}),
        ?assertEqual(
            [
                #{<<"modelId">> => <<"gpt-5.4">>,
                  <<"name">> => <<"gpt-5.4">>},
                #{<<"modelId">> => <<"claude-sonnet-4.6">>,
                  <<"name">> => <<"claude-sonnet-4.6">>}
            ],
            Models),
        ?assertEqual(
            ["--prompt",
             "List the available models only, one per line.",
             "--silent",
             "--allow-all-tools",
             "--no-custom-instructions"],
            read_lines(ArgsPath))
    after
        rm_rf(TmpDir)
    end.

write_fake_copilot(Dir, ArgsPath) ->
    Path = filename:join(Dir, "copilot"),
    ok = file:write_file(
        Path,
        iolist_to_binary([
            "#!/bin/sh\n",
            "printf '%s\\n' \"$@\" > ", sh_quote(ArgsPath), "\n",
            "printf '%s\\n' 'gpt-5.4'\n",
            "printf '%s\\n' 'claude-sonnet-4.6'\n"
        ])),
    ok = file:change_mode(Path, 8#755),
    Path.

make_tmp_dir() ->
    Base = filename:basedir(user_cache, "beam_agent_test"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, "copilot_model_test_" ++ Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
    _ = file:change_mode(Dir, 8#700),
    Dir.

read_lines(Path) ->
    {ok, Bin} = file:read_file(Path),
    [binary_to_list(Line)
     || Line <- binary:split(Bin, <<"\n">>, [global]),
        Line =/= <<>>].

sh_quote(Path) ->
    ["'", Path, "'"].

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
