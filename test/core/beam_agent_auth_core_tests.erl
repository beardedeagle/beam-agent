%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_auth_core security functions.
%%%
%%% Tests cover:
%%%   - hash_executable/1 (streaming SHA-256)
%%%   - sanitize_for_agent/1 (strips raw_output, details, oauth_url)
%%%   - from_vault/1 (opaque constructor)
%%%   - validate_base_url/1 (SSRF — localhost-only)
%%%   - verify_executable_safety/1 (world-writable rejection, file type)
%%%   - resolve_symlinks/1 (follows links, detects loops)
%%%   - is_localhost/1 (allowlist)
%%%   - CLI command-shape regression coverage for auth backends
%%%
%%% All tests use real filesystem operations — no mocks.
%%%-------------------------------------------------------------------
-module(beam_agent_auth_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% hash_executable/1
%%====================================================================

hash_executable_returns_sha256_prefix_test() ->
    Exe = portable_exe(),
    Result = beam_agent_auth_core:hash_executable(Exe),
    ?assertMatch(<<"sha256:", _/binary>>, Result),
    %% Hex digest is 64 chars (256 bits)
    <<"sha256:", Hex/binary>> = Result,
    ?assertEqual(64, byte_size(Hex)).

hash_executable_deterministic_test() ->
    Exe = portable_exe(),
    A = beam_agent_auth_core:hash_executable(Exe),
    B = beam_agent_auth_core:hash_executable(Exe),
    ?assertEqual(A, B).

hash_executable_nonexistent_crashes_test() ->
    ?assertError({executable_not_found, _},
                 beam_agent_auth_core:hash_executable("no_such_binary_xyz")).

%% Test the raw streaming hasher directly on a regular file.
compute_file_hash_on_beam_test() ->
    Path = code:which(?MODULE),
    Result = beam_agent_auth_core:compute_file_hash(Path),
    ?assertMatch(<<"sha256:", _/binary>>, Result),
    <<"sha256:", Hex/binary>> = Result,
    ?assertEqual(64, byte_size(Hex)).

compute_file_hash_nonexistent_crashes_test() ->
    ?assertError({executable_read_failed, _},
                 beam_agent_auth_core:compute_file_hash("/no/such/file")).

%%====================================================================
%% sanitize_for_agent/1
%%====================================================================

sanitize_strips_raw_output_test() ->
    Input = #{backend => claude, authenticated => true,
              method => cli, raw_output => <<"secret output">>},
    Result = beam_agent_auth_core:sanitize_for_agent(Input),
    ?assertNot(maps:is_key(raw_output, Result)),
    ?assertEqual(true, maps:get(authenticated, Result)),
    ?assertEqual(claude, maps:get(backend, Result)).

sanitize_strips_details_test() ->
    Input = #{backend => gemini, outcome => authenticated,
              method => manual, details => #{token => <<"xyz">>}},
    Result = beam_agent_auth_core:sanitize_for_agent(Input),
    ?assertNot(maps:is_key(details, Result)),
    ?assertEqual(authenticated, maps:get(outcome, Result)).

sanitize_strips_oauth_url_test() ->
    Input = #{backend => copilot, outcome => pending,
              method => cli, oauth_url => <<"https://accounts.google.com/...">>},
    Result = beam_agent_auth_core:sanitize_for_agent(Input),
    ?assertNot(maps:is_key(oauth_url, Result)).

sanitize_preserves_safe_fields_test() ->
    Input = #{backend => codex, authenticated => true,
              method => api, account => <<"user@test">>},
    Result = beam_agent_auth_core:sanitize_for_agent(Input),
    ?assertEqual(Input, Result).

sanitize_strips_all_sensitive_fields_at_once_test() ->
    Input = #{backend => claude, authenticated => true,
              method => cli, account => <<"me">>,
              raw_output => <<"out">>, details => #{a => 1},
              oauth_url => <<"https://...">>},
    Result = beam_agent_auth_core:sanitize_for_agent(Input),
    ?assertEqual(#{backend => claude, authenticated => true,
                   method => cli, account => <<"me">>}, Result).

%%====================================================================
%% from_vault/1
%%====================================================================

from_vault_wraps_in_tuple_test() ->
    Vars = [{"FOO", "bar"}],
    Wrapped = beam_agent_auth_core:from_vault(Vars),
    ?assertMatch({vault_env, _}, Wrapped).

from_vault_empty_list_test() ->
    Wrapped = beam_agent_auth_core:from_vault([]),
    ?assertMatch({vault_env, []}, Wrapped).

%%====================================================================
%% validate_base_url/1 — SSRF protection
%%====================================================================

validate_base_url_localhost_ok_test() ->
    ?assertEqual("http://localhost:4096",
                 beam_agent_auth_core:validate_base_url(
                     #{base_url => "http://localhost:4096"})).

validate_base_url_127_ok_test() ->
    ?assertEqual("http://127.0.0.1:8080",
                 beam_agent_auth_core:validate_base_url(
                     #{base_url => "http://127.0.0.1:8080"})).

validate_base_url_ipv6_ok_test() ->
    ?assertEqual("http://[::1]:4096",
                 beam_agent_auth_core:validate_base_url(
                     #{base_url => "http://[::1]:4096"})).

validate_base_url_rejects_remote_host_test() ->
    ?assertError({disallowed_base_url, _},
                 beam_agent_auth_core:validate_base_url(
                     #{base_url => "http://evil.com:4096"})).

validate_base_url_rejects_internal_host_test() ->
    ?assertError({disallowed_base_url, _},
                 beam_agent_auth_core:validate_base_url(
                     #{base_url => "http://10.0.0.1:4096"})).

validate_base_url_default_when_missing_test() ->
    %% Default is http://localhost:4096
    ?assertEqual("http://localhost:4096",
                 beam_agent_auth_core:validate_base_url(#{})).

%%====================================================================
%% is_localhost/1
%%====================================================================

is_localhost_true_cases_test_() ->
    [?_assert(beam_agent_auth_core:is_localhost(<<"localhost">>)),
     ?_assert(beam_agent_auth_core:is_localhost(<<"127.0.0.1">>)),
     ?_assert(beam_agent_auth_core:is_localhost(<<"::1">>)),
     ?_assert(beam_agent_auth_core:is_localhost(<<"[::1]">>))].

is_localhost_false_cases_test_() ->
    [?_assertNot(beam_agent_auth_core:is_localhost(<<"evil.com">>)),
     ?_assertNot(beam_agent_auth_core:is_localhost(<<"10.0.0.1">>)),
     ?_assertNot(beam_agent_auth_core:is_localhost(<<"192.168.1.1">>)),
     ?_assertNot(beam_agent_auth_core:is_localhost(<<>>))].

%%====================================================================
%% resolve_symlinks/1
%%====================================================================

resolve_symlinks_regular_file_test() ->
    %% A regular file resolves to itself.
    Path = code:which(?MODULE),
    ?assertEqual(Path, beam_agent_auth_core:resolve_symlinks(Path)).

resolve_symlinks_follows_link_test() ->
    TmpDir = make_tmp_dir(),
    try
        Target = filename:join(TmpDir, "target"),
        Link = filename:join(TmpDir, "link"),
        ok = file:write_file(Target, <<"data">>),
        case file:make_symlink(Target, Link) of
            ok ->
                Resolved = beam_agent_auth_core:resolve_symlinks(Link),
                ?assertEqual(Target, Resolved);
            {error, enotsup} ->
                ok;  %% Symlinks not supported on this platform
            {error, eperm} ->
                ok   %% Insufficient privileges (e.g. Windows without developer mode)
        end
    after
        rm_rf(TmpDir)
    end.

resolve_symlinks_nonexistent_crashes_test() ->
    ?assertError({executable_stat_failed, _, _},
                 beam_agent_auth_core:resolve_symlinks("/no/such/path")).

%%====================================================================
%% verify_executable_safety/1
%%====================================================================

verify_executable_safety_regular_file_ok_test() ->
    %% Our own beam file is a regular, non-world-writable file.
    Path = code:which(?MODULE),
    ?assertEqual(ok, beam_agent_auth_core:verify_executable_safety(Path)).

verify_executable_safety_world_writable_test() ->
    TmpDir = make_tmp_dir(),
    try
        WFile = filename:join(TmpDir, "world_writable"),
        ok = file:write_file(WFile, <<"#!/bin/sh">>),
        ok = file:change_mode(WFile, 8#100777),
        ?assertError({world_writable_executable, _},
                     beam_agent_auth_core:verify_executable_safety(WFile))
    after
        rm_rf(TmpDir)
    end.

verify_executable_safety_directory_rejected_test() ->
    TmpDir = make_tmp_dir(),
    try
        ?assertError({not_regular_file, _},
                     beam_agent_auth_core:verify_executable_safety(TmpDir))
    after
        rm_rf(TmpDir)
    end.

verify_executable_safety_nonexistent_crashes_test() ->
    ?assertError({executable_stat_failed, _, _},
                 beam_agent_auth_core:verify_executable_safety("/no/such/file")).

%%====================================================================
%% scrub_env/1
%%====================================================================

scrub_env_strips_ld_preload_test() ->
    Result = beam_agent_auth_core:scrub_env([]),
    ?assert(lists:member({"LD_PRELOAD", false}, Result)).

scrub_env_strips_dyld_insert_libraries_test() ->
    Result = beam_agent_auth_core:scrub_env([]),
    ?assert(lists:member({"DYLD_INSERT_LIBRARIES", false}, Result)).

scrub_env_strips_ld_library_path_test() ->
    Result = beam_agent_auth_core:scrub_env([]),
    ?assert(lists:member({"LD_LIBRARY_PATH", false}, Result)).

scrub_env_preserves_caller_vars_test() ->
    CallerEnv = [{"ANTHROPIC_API_KEY", "sk-test"}],
    Result = beam_agent_auth_core:scrub_env(CallerEnv),
    ?assert(lists:member({"ANTHROPIC_API_KEY", "sk-test"}, Result)).

scrub_env_caller_vars_override_strip_test() ->
    %% Dangerous vars in CallerEnv are stripped — false entry always wins.
    CallerEnv = [{"LD_PRELOAD", "/safe/lib.so"}],
    Result = beam_agent_auth_core:scrub_env(CallerEnv),
    %% Caller's LD_PRELOAD value must be removed.
    ?assertNot(lists:member({"LD_PRELOAD", "/safe/lib.so"}, Result)),
    %% The false removal entry must be present.
    ?assert(lists:member({"LD_PRELOAD", false}, Result)).

scrub_env_all_dangerous_vars_stripped_test() ->
    Result = beam_agent_auth_core:scrub_env([]),
    Dangerous = ["LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES",
                 "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
                 "LD_AUDIT", "LD_PROFILE"],
    lists:foreach(
        fun(Var) ->
            ?assert(lists:member({Var, false}, Result),
                    lists:flatten(io_lib:format("~s not stripped", [Var])))
        end, Dangerous).

%%====================================================================
%% CLI command-shape regression coverage
%%====================================================================

claude_status_uses_json_flag_test() ->
    TmpDir = make_tmp_dir(),
    try
        ArgsPath = filename:join(TmpDir, "claude.args"),
        CliPath = write_fake_cli(TmpDir, "claude",
            ["printf '%s\\n' \"$@\" > ", sh_quote(ArgsPath), "\n",
             "printf '%s\\n' '{\"loggedIn\":true}'\n"]),
        {ok, Status} = beam_agent_auth_core:status(claude, #{cli_path => CliPath}),
        ?assertEqual(true, maps:get(authenticated, Status)),
        ?assertEqual(["auth", "status", "--json"], read_lines(ArgsPath))
    after
        rm_rf(TmpDir)
    end.

copilot_login_prefers_top_level_command_test() ->
    TmpDir = make_tmp_dir(),
    try
        ArgsPath = filename:join(TmpDir, "copilot-login.args"),
        CliPath = write_fake_cli(TmpDir, "copilot",
            ["printf '%s\\n' \"$@\" > ", sh_quote(ArgsPath), "\n",
             "printf '%s\\n' 'login ok'\n"]),
        {ok, Result} = beam_agent_auth_core:login(copilot, #{cli_path => CliPath}),
        ?assertEqual(authenticated, maps:get(outcome, Result)),
        ?assertEqual(["login"], read_lines(ArgsPath))
    after
        rm_rf(TmpDir)
    end.

copilot_login_falls_back_to_legacy_auth_subcommand_test() ->
    TmpDir = make_tmp_dir(),
    try
        ArgsPath = filename:join(TmpDir, "copilot-fallback.args"),
        CliPath = write_fake_cli(TmpDir, "copilot",
            ["printf '%s\\n' \"$@\" >> ", sh_quote(ArgsPath), "\n",
             "printf '%s\\n' '--' >> ", sh_quote(ArgsPath), "\n",
             "if [ \"$1\" = \"login\" ]; then\n",
             "  printf '%s\\n' 'Usage: copilot [options] [command]'\n",
             "  exit 0\n",
             "fi\n",
             "printf '%s\\n' 'legacy login ok'\n"]),
        {ok, Result} = beam_agent_auth_core:login(copilot, #{cli_path => CliPath}),
        ?assertEqual(authenticated, maps:get(outcome, Result)),
        ?assertEqual(["login", "--", "auth", "login", "--"], read_lines(ArgsPath))
    after
        rm_rf(TmpDir)
    end.

copilot_logout_help_output_is_not_treated_as_success_test() ->
    TmpDir = make_tmp_dir(),
    try
        ArgsPath = filename:join(TmpDir, "copilot-logout.args"),
        CliPath = write_fake_cli(TmpDir, "copilot",
            ["printf '%s\\n' \"$@\" >> ", sh_quote(ArgsPath), "\n",
             "printf '%s\\n' '--' >> ", sh_quote(ArgsPath), "\n",
             "printf '%s\\n' 'Usage: copilot [options] [command]'\n"]),
        ?assertMatch({error, {not_supported, copilot, auth, _}},
                     beam_agent_auth_core:logout(copilot, #{cli_path => CliPath})),
        ?assertEqual(["logout", "--", "auth", "logout", "--"], read_lines(ArgsPath))
    after
        rm_rf(TmpDir)
    end.

home_dir_missing_returns_undefined_test() ->
    with_env_unset(
        "HOME",
        fun() ->
            ?assertEqual(undefined, beam_agent_auth_core:home_dir())
        end).

copilot_config_without_home_is_unauthenticated_test() ->
    with_env_unset(
        "HOME",
        fun() ->
            {ok, Status} = beam_agent_auth_core:check_copilot_config(),
            ?assertEqual(false, maps:get(authenticated, Status))
        end).

home_dir_empty_returns_undefined_test() ->
    with_env_value(
        "HOME",
        "",
        fun() ->
            ?assertEqual(undefined, beam_agent_auth_core:home_dir())
        end).

copilot_config_read_error_is_unauthenticated_test() ->
    TmpDir = make_tmp_dir(),
    try
        ok = file:write_file(filename:join(TmpDir, ".copilot"), <<"not a directory">>),
        with_env_value(
            "HOME",
            TmpDir,
            fun() ->
                {ok, Status} = beam_agent_auth_core:check_copilot_config(),
                ?assertEqual(false, maps:get(authenticated, Status))
            end)
    after
        rm_rf(TmpDir)
    end.

%%====================================================================
%% Helpers
%%====================================================================

%% Return a cross-platform executable name for hash tests.
%% Uses "erl" (available on all platforms with Erlang) instead of "sh".
portable_exe() ->
    case os:find_executable("erl") of
        false -> "escript";  %% fallback — also ships with OTP
        _     -> "erl"
    end.

make_tmp_dir() ->
    Base = filename:basedir(user_cache, "beam_agent_test"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, "auth_core_test_" ++ Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
    _ = file:change_mode(Dir, 8#700),
    Dir.

write_fake_cli(Dir, Name, BodyLines) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path,
                         iolist_to_binary(["#!/bin/sh\n" | BodyLines])),
    ok = file:change_mode(Path, 8#755),
    Path.

read_lines(Path) ->
    {ok, Bin} = file:read_file(Path),
    [binary_to_list(Line)
     || Line <- binary:split(Bin, <<"\n">>, [global]),
        Line =/= <<>>].

sh_quote(Path) ->
    ["'", Path, "'"].

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
