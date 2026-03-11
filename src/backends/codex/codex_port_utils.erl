-module(codex_port_utils).
-moduledoc false.
-export([buffer_line/3,
         append_buffer/3,
         check_buffer_overflow/2,
         close_port/1]).
-spec buffer_line(binary(), binary(), pos_integer()) -> binary().
buffer_line(Line, Buffer, BufferMax) ->
    check_buffer_overflow(<<Buffer/binary,Line/binary,"\n">>, BufferMax).
-spec append_buffer(binary(), binary(), pos_integer()) -> binary().
append_buffer(Partial, Buffer, BufferMax) ->
    check_buffer_overflow(<<Buffer/binary,Partial/binary>>, BufferMax).
-spec check_buffer_overflow(binary(), pos_integer()) -> binary().
check_buffer_overflow(Buffer, BufferMax) ->
    case byte_size(Buffer) > BufferMax of
        true ->
            beam_agent_telemetry_core:buffer_overflow(byte_size(Buffer),
                                                 BufferMax),
            logger:warning("Codex buffer overflow (~p bytes), truncatin"
                           "g",
                           [byte_size(Buffer)]),
            <<>>;
        false ->
            Buffer
    end.
-spec close_port(port() | undefined) -> ok.
close_port(undefined) ->
    ok;
close_port(Port) ->
    try
        port_close(Port)
    catch
        error:_ ->
            ok
    end,
    ok.

