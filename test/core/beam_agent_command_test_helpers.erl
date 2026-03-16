-module(beam_agent_command_test_helpers).

-export([
    cwd_command/0,
    cwd_fixture/0,
    echo_command/1,
    echo_segments/1,
    env_echo_command/1,
    exit_command/1,
    failure_command/0,
    sleep_command/1,
    stderr_command/1,
    success_command/0,
    trim_output/1
]).

echo_command(Text) ->
    iolist_to_binary([<<"echo ">>, Text]).

stderr_command(Text) ->
    iolist_to_binary([<<"echo ">>, Text, <<" 1>&2">>]).

success_command() ->
    case os:type() of
        {win32, _} -> <<"ver > nul">>;
        _ -> <<"true">>
    end.

failure_command() ->
    exit_command(1).

exit_command(Code) ->
    CodeBin = integer_to_binary(Code),
    case os:type() of
        {win32, _} -> iolist_to_binary([<<"exit /b ">>, CodeBin]);
        _ -> iolist_to_binary([<<"exit ">>, CodeBin])
    end.

sleep_command(Seconds) ->
    case os:type() of
        {win32, _} ->
            Count = integer_to_binary(Seconds + 1),
            iolist_to_binary([<<"ping -n ">>, Count, <<" 127.0.0.1 > nul">>]);
        _ ->
            iolist_to_binary([<<"sleep ">>, integer_to_binary(Seconds)])
    end.

cwd_command() ->
    case os:type() of
        {win32, _} -> <<"cd">>;
        _ -> <<"pwd">>
    end.

cwd_fixture() ->
    case os:type() of
        {win32, _} -> {<<"C:/">>, <<"C:">>};
        _ -> {<<"/tmp">>, <<"tmp">>}
    end.

env_echo_command(Name) ->
    case os:type() of
        {win32, _} -> iolist_to_binary([<<"echo %">>, Name, <<"%">>]);
        _ -> iolist_to_binary([<<"echo $">>, Name])
    end.

echo_segments(Text) ->
    Eval = iolist_to_binary(io_lib:format("io:put_chars(~p), halt().", [Text])),
    [<<"erl">>, <<"-noshell">>, <<"-eval">>, Eval].

trim_output(<<>>) ->
    <<>>;
trim_output(Output) ->
    case binary:last(Output) of
        $\n -> trim_output(binary:part(Output, 0, byte_size(Output) - 1));
        $\r -> trim_output(binary:part(Output, 0, byte_size(Output) - 1));
        _ -> Output
    end.
