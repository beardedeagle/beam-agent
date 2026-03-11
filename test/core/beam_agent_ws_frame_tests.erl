%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_ws_frame — RFC 6455 frame codec.
%%%
%%% All tests exercise pure functions: no processes, no sockets, no
%%% mocks. Server frames are constructed as raw binaries (unmasked)
%%% and fed to decode/2,3.  Client frames produced by encode/2 are
%%% validated structurally (mask-bit set, correct opcode).
%%%
%%% Tests cover:
%%%   - XOR masking: roundtrip, alignment, empty input
%%%   - Text, binary, ping, pong, close frame decode
%%%   - Multi-frame buffer decode
%%%   - Incomplete frame / header handling
%%%   - Frame size limit enforcement
%%%   - Control frame constraints (≤125 bytes, no fragmentation)
%%%   - Reserved opcode rejection
%%%   - Server-masked frame rejection
%%%   - Fragmentation/continuation assembly
%%%   - Interleaved data frame during fragmentation
%%%   - Unexpected continuation frame
%%%   - 16-bit and 64-bit extended length
%%%   - encode/2 produces correctly masked client frames
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_ws_frame_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MAX, 67108864).  %% default 64 MB

%%====================================================================
%% Masking
%%====================================================================

mask_roundtrip_test() ->
    Key = <<1, 2, 3, 4>>,
    Data = <<"Hello, WebSocket!">>,
    Masked = beam_agent_ws_frame:mask(Data, Key),
    ?assertNotEqual(Data, Masked),
    ?assertEqual(Data, beam_agent_ws_frame:mask(Masked, Key)).

mask_empty_test() ->
    ?assertEqual(<<>>, beam_agent_ws_frame:mask(<<>>, <<1,2,3,4>>)).

mask_aligned_4_bytes_test() ->
    Key  = <<16#AA, 16#BB, 16#CC, 16#DD>>,
    Data = <<1, 2, 3, 4>>,
    ?assertEqual(Data, beam_agent_ws_frame:mask(
        beam_agent_ws_frame:mask(Data, Key), Key)).

mask_aligned_8_bytes_test() ->
    Key  = <<16#AA, 16#BB, 16#CC, 16#DD>>,
    Data = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    ?assertEqual(Data, beam_agent_ws_frame:mask(
        beam_agent_ws_frame:mask(Data, Key), Key)).

mask_unaligned_5_bytes_test() ->
    Key  = <<16#FF, 16#00, 16#FF, 16#00>>,
    Data = <<1, 2, 3, 4, 5>>,
    ?assertEqual(Data, beam_agent_ws_frame:mask(
        beam_agent_ws_frame:mask(Data, Key), Key)).

mask_single_byte_test() ->
    Key = <<10, 20, 30, 40>>,
    Data = <<99>>,
    ?assertEqual(Data, beam_agent_ws_frame:mask(
        beam_agent_ws_frame:mask(Data, Key), Key)).

mask_large_payload_test() ->
    Key  = crypto:strong_rand_bytes(4),
    Data = crypto:strong_rand_bytes(8192),
    ?assertEqual(Data, beam_agent_ws_frame:mask(
        beam_agent_ws_frame:mask(Data, Key), Key)).

%%====================================================================
%% Decode: standard frame types
%%====================================================================

decode_text_frame_test() ->
    Frame = server_frame(1, 1, <<"hello">>),
    ?assertMatch({ok, [{text, <<"hello">>}], <<>>, undefined},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

decode_binary_frame_test() ->
    Payload = <<0, 1, 255, 128>>,
    Frame = server_frame(2, 1, Payload),
    ?assertMatch({ok, [{binary, Payload}], <<>>, undefined},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

decode_ping_test() ->
    Frame = server_frame(9, 1, <<"hi">>),
    ?assertMatch({ok, [{ping, <<"hi">>}], <<>>, undefined},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

decode_pong_test() ->
    Frame = server_frame(16#A, 1, <<"ok">>),
    ?assertMatch({ok, [{pong, <<"ok">>}], <<>>, undefined},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

decode_close_with_code_test() ->
    Payload = <<1000:16, "normal">>,
    Frame = server_frame(8, 1, Payload),
    ?assertMatch({ok, [{close, 1000, <<"normal">>}], <<>>, undefined},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

decode_close_empty_body_test() ->
    Frame = server_frame(8, 1, <<>>),
    ?assertMatch({ok, [{close, 1000, <<>>}], <<>>, undefined},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

decode_close_one_byte_body_protocol_error_test() ->
    %% RFC 6455 Section 5.5.1: close body must be 0 or ≥2 bytes.
    %% A 1-byte payload is a protocol violation → status 1002.
    Frame = server_frame(8, 1, <<42>>),
    ?assertMatch({ok, [{close, 1002, <<>>}], <<>>, undefined},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

decode_empty_text_test() ->
    Frame = server_frame(1, 1, <<>>),
    ?assertMatch({ok, [{text, <<>>}], <<>>, undefined},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

%%====================================================================
%% Decode: multi-frame and partial buffers
%%====================================================================

decode_two_frames_in_buffer_test() ->
    F1 = server_frame(1, 1, <<"one">>),
    F2 = server_frame(1, 1, <<"two">>),
    Buf = <<F1/binary, F2/binary>>,
    {ok, Frames, <<>>, undefined} = beam_agent_ws_frame:decode(Buf, ?MAX),
    ?assertEqual([{text, <<"one">>}, {text, <<"two">>}], Frames).

remaining_data_preserved_test() ->
    Frame = server_frame(1, 1, <<"hi">>),
    %% Use a single byte as extra — too short to be a valid frame
    %% header, so the decoder returns it as remaining.
    Extra = <<16#81>>,
    Buf = <<Frame/binary, Extra/binary>>,
    {ok, [{text, <<"hi">>}], Extra, undefined} =
        beam_agent_ws_frame:decode(Buf, ?MAX).

incomplete_payload_test() ->
    %% Header claims 100 bytes, only 5 present
    Header = <<1:1, 0:3, 1:4, 0:1, 100:7>>,
    Buf = <<Header/binary, "hello">>,
    ?assertMatch({ok, [], Buf, undefined},
        beam_agent_ws_frame:decode(Buf, ?MAX)).

incomplete_header_test() ->
    ?assertMatch({ok, [], <<16#81>>, undefined},
        beam_agent_ws_frame:decode(<<16#81>>, ?MAX)).

empty_buffer_test() ->
    ?assertMatch({ok, [], <<>>, undefined},
        beam_agent_ws_frame:decode(<<>>, ?MAX)).

%%====================================================================
%% Decode: error conditions
%%====================================================================

frame_too_large_test() ->
    Payload = binary:copy(<<0>>, 1000),
    Frame = <<1:1, 0:3, 1:4, 0:1, 126:7, 1000:16, Payload/binary>>,
    ?assertEqual({error, frame_too_large},
        beam_agent_ws_frame:decode(Frame, 500)).

control_frame_too_large_test() ->
    %% Ping with 126-byte payload (exceeds 125-byte limit)
    Payload = binary:copy(<<0>>, 126),
    Frame = <<1:1, 0:3, 9:4, 0:1, 126:7, 126:16, Payload/binary>>,
    ?assertEqual({error, control_frame_too_large},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

fragmented_control_frame_test() ->
    %% Ping with FIN=0 (illegal)
    Frame = <<0:1, 0:3, 9:4, 0:1, 4:7, "ping">>,
    ?assertEqual({error, fragmented_control_frame},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

server_frame_masked_test() ->
    %% Mask bit = 1 on incoming frame (illegal for server → client)
    Frame = <<1:1, 0:3, 1:4, 1:1, 5:7, 1, 2, 3, 4, "hello">>,
    ?assertEqual({error, server_frame_masked},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

reserved_opcode_3_test() ->
    Frame = <<1:1, 0:3, 3:4, 0:1, 0:7>>,
    ?assertEqual({error, {reserved_opcode, 3}},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

reserved_opcode_5_test() ->
    Frame = <<1:1, 0:3, 5:4, 0:1, 0:7>>,
    ?assertEqual({error, {reserved_opcode, 5}},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

reserved_opcode_11_test() ->
    Frame = <<1:1, 0:3, 16#B:4, 0:1, 0:7>>,
    ?assertEqual({error, {reserved_opcode, 16#B}},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

%%====================================================================
%% Decode: fragmentation / continuation
%%====================================================================

fragmented_text_three_parts_test() ->
    %% Fragment 1: opcode=text, FIN=0
    F1 = <<0:1, 0:3, 1:4, 0:1, 3:7, "Hel">>,
    %% Fragment 2: continuation, FIN=0
    F2 = <<0:1, 0:3, 0:4, 0:1, 2:7, "lo">>,
    %% Fragment 3: continuation, FIN=1
    F3 = <<1:1, 0:3, 0:4, 0:1, 1:7, "!">>,

    {ok, [], <<>>, Frag1} =
        beam_agent_ws_frame:decode(F1, ?MAX, undefined),
    ?assertNotEqual(undefined, Frag1),

    {ok, [], <<>>, Frag2} =
        beam_agent_ws_frame:decode(F2, ?MAX, Frag1),

    {ok, [{text, <<"Hello!">>}], <<>>, undefined} =
        beam_agent_ws_frame:decode(F3, ?MAX, Frag2).

control_frame_during_fragmentation_test() ->
    %% Start text fragment
    F1 = <<0:1, 0:3, 1:4, 0:1, 3:7, "Hel">>,
    %% Interleaved ping (allowed — control frames don't affect frag state)
    Ping = <<1:1, 0:3, 9:4, 0:1, 4:7, "ping">>,
    %% Final continuation
    F2 = <<1:1, 0:3, 0:4, 0:1, 2:7, "lo">>,

    Buf = <<F1/binary, Ping/binary, F2/binary>>,
    {ok, Frames, <<>>, undefined} =
        beam_agent_ws_frame:decode(Buf, ?MAX, undefined),
    ?assertEqual([{ping, <<"ping">>}, {text, <<"Hello">>}], Frames).

unexpected_continuation_test() ->
    Frame = <<1:1, 0:3, 0:4, 0:1, 5:7, "hello">>,
    ?assertEqual({error, unexpected_continuation},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

interleaved_data_frame_test() ->
    %% Start text fragment
    F1 = <<0:1, 0:3, 1:4, 0:1, 3:7, "Hel">>,
    %% New binary frame (illegal during text fragmentation)
    F2 = <<1:1, 0:3, 2:4, 0:1, 3:7, "bad">>,
    Buf = <<F1/binary, F2/binary>>,
    ?assertEqual({error, interleaved_data_frame},
        beam_agent_ws_frame:decode(Buf, ?MAX)).

%%====================================================================
%% Decode: extended lengths
%%====================================================================

extended_length_16bit_test() ->
    Payload = binary:copy(<<$A>>, 200),
    Frame = <<1:1, 0:3, 1:4, 0:1, 126:7, 200:16, Payload/binary>>,
    {ok, [{text, Payload}], <<>>, undefined} =
        beam_agent_ws_frame:decode(Frame, ?MAX).

extended_length_64bit_test() ->
    Payload = binary:copy(<<$B>>, 70000),
    Frame = <<1:1, 0:3, 1:4, 0:1, 127:7, 70000:64, Payload/binary>>,
    {ok, [{text, Payload}], <<>>, undefined} =
        beam_agent_ws_frame:decode(Frame, ?MAX).

rsv_bits_nonzero_test() ->
    %% RSV1=1, opcode=text, FIN=1, no mask, 5-byte payload
    Frame = <<1:1, 1:1, 0:2, 1:4, 0:1, 5:7, "hello">>,
    ?assertMatch({error, {unexpected_rsv_bits, _}},
        beam_agent_ws_frame:decode(Frame, ?MAX)).

%%====================================================================
%% Encode: structural validation
%%====================================================================

encode_text_sets_mask_bit_test() ->
    Encoded = iolist_to_binary(beam_agent_ws_frame:encode(text, <<"hi">>)),
    <<1:1, 0:3, 1:4, 1:1, 2:7, _Key:4/binary, _Masked:2/binary>> = Encoded.

encode_binary_opcode_test() ->
    Encoded = iolist_to_binary(beam_agent_ws_frame:encode(binary, <<0>>)),
    <<1:1, 0:3, 2:4, 1:1, _:7, _/binary>> = Encoded.

encode_ping_opcode_test() ->
    Encoded = iolist_to_binary(beam_agent_ws_frame:encode(ping, <<>>)),
    <<1:1, 0:3, 9:4, 1:1, _:7, _/binary>> = Encoded.

encode_pong_opcode_test() ->
    Encoded = iolist_to_binary(beam_agent_ws_frame:encode(pong, <<>>)),
    <<1:1, 0:3, 16#A:4, 1:1, _:7, _/binary>> = Encoded.

encode_close_frame_test() ->
    Encoded = iolist_to_binary(
        beam_agent_ws_frame:encode_close(1001, <<"going away">>)),
    <<1:1, 0:3, 8:4, 1:1, _:7, _/binary>> = Encoded.

encode_16bit_length_test() ->
    Payload = binary:copy(<<$X>>, 200),
    Encoded = iolist_to_binary(beam_agent_ws_frame:encode(text, Payload)),
    <<1:1, 0:3, 1:4, 1:1, 126:7, 200:16, _/binary>> = Encoded.

encode_64bit_length_test() ->
    Payload = binary:copy(<<$Y>>, 70000),
    Encoded = iolist_to_binary(beam_agent_ws_frame:encode(text, Payload)),
    <<1:1, 0:3, 1:4, 1:1, 127:7, 70000:64, _/binary>> = Encoded.

%%====================================================================
%% Helper: build an unmasked server frame
%%====================================================================

-spec server_frame(non_neg_integer(), 0 | 1, binary()) -> binary().
server_frame(Opcode, Fin, Payload) ->
    Len = byte_size(Payload),
    Header = if
        Len < 126 ->
            <<Fin:1, 0:3, Opcode:4, 0:1, Len:7>>;
        Len < 65536 ->
            <<Fin:1, 0:3, Opcode:4, 0:1, 126:7, Len:16>>;
        true ->
            <<Fin:1, 0:3, Opcode:4, 0:1, 127:7, Len:64>>
    end,
    <<Header/binary, Payload/binary>>.
