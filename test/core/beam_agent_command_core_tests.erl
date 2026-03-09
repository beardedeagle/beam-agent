%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_command_core (shell command execution).
%%%
%%% Tests cover:
%%%   - run/1: basic command execution, binary and string inputs
%%%   - run/2: timeout option, cwd option, max_output truncation
%%%   - Non-zero exit codes
%%%   - Output capture correctness
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_command_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Basic run/1 tests
%%====================================================================

run_echo_binary_command_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"echo hello">>),
    ?assertEqual(0, maps:get(exit_code, Result)),
    Output = maps:get(output, Result),
    ?assert(is_binary(Output)),
    ?assert(binary:match(Output, <<"hello">>) =/= nomatch).

run_echo_string_command_test() ->
    {ok, Result} = beam_agent_command_core:run("echo world"),
    ?assertEqual(0, maps:get(exit_code, Result)),
    Output = maps:get(output, Result),
    ?assert(binary:match(Output, <<"world">>) =/= nomatch).

run_segmented_binary_command_test() ->
    {ok, Result} = beam_agent_command_core:run([<<"printf">>, <<"beam-agent">>]),
    ?assertEqual(0, maps:get(exit_code, Result)),
    ?assertEqual(<<"beam-agent">>, maps:get(output, Result)).

run_segmented_command_escapes_arguments_test() ->
    {ok, Result} = beam_agent_command_core:run([<<"printf">>, <<"hello world">>]),
    ?assertEqual(0, maps:get(exit_code, Result)),
    ?assertEqual(<<"hello world">>, maps:get(output, Result)).

run_true_command_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"true">>),
    ?assertEqual(0, maps:get(exit_code, Result)).

%%====================================================================
%% Non-zero exit code tests
%%====================================================================

run_false_command_nonzero_exit_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"false">>),
    ?assertNotEqual(0, maps:get(exit_code, Result)).

run_exit_code_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"exit 42">>),
    ?assertEqual(42, maps:get(exit_code, Result)).

%%====================================================================
%% Output capture tests
%%====================================================================

run_captures_output_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"echo captured">>),
    Output = maps:get(output, Result),
    ?assert(binary:match(Output, <<"captured">>) =/= nomatch).

run_captures_stderr_test() ->
    %% stderr_to_stdout is set, so stderr appears in output
    {ok, Result} = beam_agent_command_core:run(<<"echo errline 1>&2">>),
    Output = maps:get(output, Result),
    ?assert(binary:match(Output, <<"errline">>) =/= nomatch).

run_empty_output_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"true">>),
    Output = maps:get(output, Result),
    ?assert(is_binary(Output)).

%%====================================================================
%% run/2 with timeout option
%%====================================================================

run_timeout_test() ->
    Result = beam_agent_command_core:run(<<"sleep 10">>, #{timeout => 100}),
    ?assertEqual({error, {timeout, 100}}, Result).

run_completes_within_timeout_test() ->
    {ok, R} = beam_agent_command_core:run(<<"echo fast">>, #{timeout => 5000}),
    ?assertEqual(0, maps:get(exit_code, R)).

%%====================================================================
%% run/2 with cwd option
%%====================================================================

run_cwd_binary_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"pwd">>, #{cwd => <<"/tmp">>}),
    ?assertEqual(0, maps:get(exit_code, Result)),
    Output = maps:get(output, Result),
    ?assert(binary:match(Output, <<"tmp">>) =/= nomatch).

run_cwd_string_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"pwd">>, #{cwd => "/tmp"}),
    ?assertEqual(0, maps:get(exit_code, Result)),
    Output = maps:get(output, Result),
    ?assert(binary:match(Output, <<"tmp">>) =/= nomatch).

%%====================================================================
%% run/2 with max_output option
%%====================================================================

run_max_output_truncates_test() ->
    %% Generate ~100 bytes of output, cap at 10 bytes
    {ok, Result} = beam_agent_command_core:run(
        <<"printf '%0.s1234567890' 1 2 3 4 5 6 7 8 9 10">>,
        #{max_output => 10}
    ),
    Output = maps:get(output, Result),
    ?assertEqual(10, byte_size(Output)).

run_max_output_not_exceeded_test() ->
    %% Output is smaller than cap — no truncation
    {ok, Result} = beam_agent_command_core:run(
        <<"echo hi">>,
        #{max_output => 1048576}
    ),
    Output = maps:get(output, Result),
    ?assert(byte_size(Output) < 1048576),
    ?assert(binary:match(Output, <<"hi">>) =/= nomatch).

%%====================================================================
%% run/2 with env option
%%====================================================================

run_env_variable_test() ->
    {ok, Result} = beam_agent_command_core:run(
        <<"echo $MY_TEST_VAR">>,
        #{env => [{"MY_TEST_VAR", "env_value"}]}
    ),
    ?assertEqual(0, maps:get(exit_code, Result)),
    Output = maps:get(output, Result),
    ?assert(binary:match(Output, <<"env_value">>) =/= nomatch).

%%====================================================================
%% Result map structure tests
%%====================================================================

result_has_required_keys_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"echo keys">>),
    ?assert(maps:is_key(exit_code, Result)),
    ?assert(maps:is_key(output, Result)).

result_output_is_binary_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"echo binary">>),
    ?assert(is_binary(maps:get(output, Result))).

result_exit_code_is_integer_test() ->
    {ok, Result} = beam_agent_command_core:run(<<"echo int">>),
    ?assert(is_integer(maps:get(exit_code, Result))).
