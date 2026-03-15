%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_command_parser (Layer 0).
%%%
%%% Tests cover:
%%%   - parse/1: list-form, string-form, chains, pipelines, redirects
%%%   - Quoted strings, escaped characters, command substitution
%%%   - categorize/1: program-to-category mapping
%%%   - flatten_commands/1: leaf extraction from nested structures
%%%
%%% All tests are pure — no processes, no ETS, no mocks.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_command_parser_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% parse/1 — list-form (fast path)
%%====================================================================

parse_list_form_binary_test() ->
    Result = beam_agent_command_parser:parse([<<"echo">>, <<"hello">>]),
    ?assertEqual(simple, maps:get(type, Result)),
    ?assertEqual(<<"echo">>, maps:get(program, Result)),
    ?assertEqual([<<"hello">>], maps:get(args, Result)).

parse_list_form_single_element_test() ->
    Result = beam_agent_command_parser:parse([<<"ls">>]),
    ?assertEqual(simple, maps:get(type, Result)),
    ?assertEqual(<<"ls">>, maps:get(program, Result)),
    ?assertEqual([], maps:get(args, Result)).

parse_list_form_multiple_args_test() ->
    Result = beam_agent_command_parser:parse([<<"git">>, <<"commit">>, <<"-m">>, <<"msg">>]),
    ?assertEqual(<<"git">>, maps:get(program, Result)),
    ?assertEqual([<<"commit">>, <<"-m">>, <<"msg">>], maps:get(args, Result)).

parse_list_form_empty_test() ->
    Result = beam_agent_command_parser:parse([]),
    ?assertEqual(opaque, maps:get(type, Result)).

%%====================================================================
%% parse/1 — simple string commands
%%====================================================================

parse_simple_binary_test() ->
    Result = beam_agent_command_parser:parse(<<"echo hello">>),
    ?assertEqual(simple, maps:get(type, Result)),
    ?assertEqual(<<"echo">>, maps:get(program, Result)).

parse_simple_string_test() ->
    Result = beam_agent_command_parser:parse("echo hello"),
    ?assertEqual(simple, maps:get(type, Result)),
    ?assertEqual(<<"echo">>, maps:get(program, Result)).

parse_program_only_test() ->
    Result = beam_agent_command_parser:parse(<<"ls">>),
    ?assertEqual(simple, maps:get(type, Result)),
    ?assertEqual(<<"ls">>, maps:get(program, Result)),
    ?assertEqual([], maps:get(args, Result)).

parse_whitespace_handling_test() ->
    Result = beam_agent_command_parser:parse(<<"  echo   hello  ">>),
    ?assertEqual(simple, maps:get(type, Result)),
    ?assertEqual(<<"echo">>, maps:get(program, Result)).

%%====================================================================
%% parse/1 — chain operators
%%====================================================================

parse_semicolon_chain_test() ->
    Result = beam_agent_command_parser:parse(<<"echo a; echo b">>),
    ?assertEqual(chain, maps:get(type, Result)),
    ?assertEqual(';', maps:get(operator, Result)),
    Cmds = maps:get(commands, Result),
    ?assertEqual(2, length(Cmds)).

parse_and_chain_test() ->
    Result = beam_agent_command_parser:parse(<<"make && make install">>),
    ?assertEqual(chain, maps:get(type, Result)),
    ?assertEqual('&&', maps:get(operator, Result)),
    Cmds = maps:get(commands, Result),
    ?assertEqual(2, length(Cmds)).

parse_or_chain_test() ->
    Result = beam_agent_command_parser:parse(<<"test -f x || echo missing">>),
    ?assertEqual(chain, maps:get(type, Result)),
    ?assertEqual('||', maps:get(operator, Result)).

%%====================================================================
%% parse/1 — pipelines
%%====================================================================

parse_simple_pipe_test() ->
    Result = beam_agent_command_parser:parse(<<"cat file | grep pattern">>),
    ?assertEqual(pipeline, maps:get(type, Result)),
    Cmds = maps:get(commands, Result),
    ?assertEqual(2, length(Cmds)),
    [Left, Right] = Cmds,
    ?assertMatch(#{program := <<"cat">>}, Left),
    ?assertMatch(#{program := <<"grep">>}, Right).

parse_multi_pipe_test() ->
    Result = beam_agent_command_parser:parse(<<"cat f | grep p | wc -l">>),
    ?assertEqual(pipeline, maps:get(type, Result)),
    Cmds = maps:get(commands, Result),
    ?assertEqual(3, length(Cmds)).

%%====================================================================
%% parse/1 — redirections
%%====================================================================

parse_output_redirect_test() ->
    Result = beam_agent_command_parser:parse(<<"echo hello > file.txt">>),
    ?assertEqual(redirect, maps:get(type, Result)),
    Redirects = maps:get(redirects, Result),
    ?assert(length(Redirects) > 0).

parse_append_redirect_test() ->
    Result = beam_agent_command_parser:parse(<<"echo hello >> file.txt">>),
    ?assertEqual(redirect, maps:get(type, Result)).

parse_input_redirect_test() ->
    Result = beam_agent_command_parser:parse(<<"sort < input.txt">>),
    ?assertEqual(redirect, maps:get(type, Result)).

%%====================================================================
%% parse/1 — quoted strings
%%====================================================================

parse_single_quoted_test() ->
    Result = beam_agent_command_parser:parse(<<"echo 'hello world'">>),
    ?assertEqual(simple, maps:get(type, Result)),
    ?assertEqual(<<"echo">>, maps:get(program, Result)).

parse_double_quoted_test() ->
    Result = beam_agent_command_parser:parse(<<"echo \"hello world\"">>),
    ?assertEqual(simple, maps:get(type, Result)),
    ?assertEqual(<<"echo">>, maps:get(program, Result)).

parse_quoted_preserves_operators_test() ->
    %% Operators inside quotes should NOT split the command
    Result = beam_agent_command_parser:parse(<<"echo 'a && b'">>),
    ?assertEqual(simple, maps:get(type, Result)).

parse_quoted_pipe_not_split_test() ->
    Result = beam_agent_command_parser:parse(<<"echo 'a | b'">>),
    ?assertEqual(simple, maps:get(type, Result)).

%%====================================================================
%% parse/1 — command substitution (opaque)
%%====================================================================

parse_dollar_paren_opaque_test() ->
    Result = beam_agent_command_parser:parse(<<"echo $(whoami)">>),
    ?assertEqual(opaque, maps:get(type, Result)).

parse_backtick_opaque_test() ->
    Result = beam_agent_command_parser:parse(<<"echo `whoami`">>),
    ?assertEqual(opaque, maps:get(type, Result)).

%%====================================================================
%% parse/1 — escaped characters
%%====================================================================

parse_escaped_space_test() ->
    Result = beam_agent_command_parser:parse(<<"echo hello\\ world">>),
    ?assertEqual(simple, maps:get(type, Result)).

parse_escaped_semicolon_test() ->
    %% Escaped semicolon should NOT split
    Result = beam_agent_command_parser:parse(<<"echo a\\; b">>),
    ?assertEqual(simple, maps:get(type, Result)).

%%====================================================================
%% parse/1 — raw field preservation
%%====================================================================

parse_preserves_raw_test() ->
    Input = <<"echo hello">>,
    Result = beam_agent_command_parser:parse(Input),
    ?assertEqual(Input, maps:get(raw, Result)).

parse_list_form_has_raw_test() ->
    Result = beam_agent_command_parser:parse([<<"echo">>, <<"hello">>]),
    Raw = maps:get(raw, Result),
    ?assert(is_binary(Raw)).

%%====================================================================
%% categorize/1 — takes a program name binary, not a command struct
%%====================================================================

categorize_destructive_test() ->
    ?assertEqual(destructive, beam_agent_command_parser:categorize(<<"rm">>)).

categorize_filesystem_write_test() ->
    ?assertEqual(filesystem_write, beam_agent_command_parser:categorize(<<"cp">>)).

categorize_filesystem_read_test() ->
    ?assertEqual(filesystem_read, beam_agent_command_parser:categorize(<<"cat">>)).

categorize_network_test() ->
    ?assertEqual(network, beam_agent_command_parser:categorize(<<"curl">>)).

categorize_vcs_test() ->
    ?assertEqual(vcs, beam_agent_command_parser:categorize(<<"git">>)).

categorize_build_test() ->
    ?assertEqual(build, beam_agent_command_parser:categorize(<<"make">>)).

categorize_package_test() ->
    ?assertEqual(package, beam_agent_command_parser:categorize(<<"npm">>)).

categorize_process_control_test() ->
    ?assertEqual(process_control, beam_agent_command_parser:categorize(<<"kill">>)).

categorize_unknown_test() ->
    ?assertEqual(unknown, beam_agent_command_parser:categorize(<<"myapp">>)).

categorize_strips_path_test() ->
    ?assertEqual(destructive, beam_agent_command_parser:categorize(<<"/usr/bin/rm">>)).

%%====================================================================
%% flatten_commands/1
%%====================================================================

flatten_simple_test() ->
    Cmd = beam_agent_command_parser:parse(<<"echo hello">>),
    Flat = beam_agent_command_parser:flatten_commands(Cmd),
    ?assertEqual(1, length(Flat)),
    [Only] = Flat,
    ?assertEqual(simple, maps:get(type, Only)).

flatten_chain_test() ->
    Cmd = beam_agent_command_parser:parse(<<"echo a; echo b; echo c">>),
    Flat = beam_agent_command_parser:flatten_commands(Cmd),
    ?assert(length(Flat) >= 2).

flatten_pipeline_test() ->
    Cmd = beam_agent_command_parser:parse(<<"cat f | grep p">>),
    Flat = beam_agent_command_parser:flatten_commands(Cmd),
    ?assertEqual(2, length(Flat)).

flatten_redirect_test() ->
    Cmd = beam_agent_command_parser:parse(<<"echo hello > file">>),
    Flat = beam_agent_command_parser:flatten_commands(Cmd),
    ?assert(length(Flat) >= 1).
