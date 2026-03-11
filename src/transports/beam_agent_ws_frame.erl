-module(beam_agent_ws_frame).
-moduledoc """
RFC 6455 WebSocket frame codec — pure functions only.

Encodes client frames with required masking (Section 5.3), decodes
server frames (unmasked), and handles all standard opcodes:

  0x0 — continuation
  0x1 — text
  0x2 — binary
  0x8 — close
  0x9 — ping
  0xA — pong

## Frame Size Limits

The `decode/2` and `decode/3` functions accept a `MaxFrameSize`
parameter to prevent OOM from oversized frames. Frames exceeding
this limit are rejected with `{error, frame_too_large}`.

## Continuation Frames

Continuation frames are tracked via the `frag_state()` accumulator.
Pass the returned state through successive `decode/3` calls to
reassemble fragmented messages automatically.

## Performance

Masking XOR operates on 32-bit aligned words for bulk data,
falling back to byte-wise XOR for the 0–3 byte tail. On OTP 27+
the JIT compiles these binary operations to native SIMD-capable
instructions.
""".

-export([
    encode/2,
    encode_close/2,
    decode/2,
    decode/3,
    mask/2
]).

-export_type([frame/0, frag_state/0]).

%%====================================================================
%% Types
%%====================================================================

-type frame() ::
    {text, binary()} |
    {binary, binary()} |
    {close, non_neg_integer(), binary()} |
    {ping, binary()} |
    {pong, binary()}.

-type frag_state() ::
    undefined |
    {non_neg_integer(), [binary()]}.

%%====================================================================
%% Opcodes
%%====================================================================

-define(OP_CONT,   16#0).
-define(OP_TEXT,    16#1).
-define(OP_BINARY, 16#2).
-define(OP_CLOSE,  16#8).
-define(OP_PING,   16#9).
-define(OP_PONG,   16#A).

%% RFC 6455 Section 5.5: control frame payloads ≤ 125 bytes.
-define(MAX_CONTROL_PAYLOAD, 125).

%% Default max frame payload: 64 MB.
-define(DEFAULT_MAX_FRAME, 67108864).

%%====================================================================
%% Encoding (client → server, MUST be masked per Section 5.3)
%%====================================================================

-doc "Encode a WebSocket frame with client masking.".
-spec encode(text | binary | close | ping | pong, binary()) -> iodata().
encode(Type, Payload) ->
    Opcode = type_to_opcode(Type),
    Len     = byte_size(Payload),
    IsControl = Opcode >= 8,
    IsControl andalso Len > ?MAX_CONTROL_PAYLOAD andalso
        error(control_frame_too_large),
    MaskKey = crypto:strong_rand_bytes(4),
    Masked  = mask(Payload, MaskKey),
    Header  = encode_header(Opcode, Len),
    [Header, MaskKey, Masked].

-doc "Encode a close frame with a status code and UTF-8 reason.".
-spec encode_close(non_neg_integer(), binary()) -> iodata().
encode_close(Code, Reason) ->
    encode(close, <<Code:16, Reason/binary>>).

%%====================================================================
%% Decoding (server → client, MUST NOT be masked)
%%====================================================================

-doc "Decode frames from a buffer. Shorthand for `decode/3` with no fragmentation state.".
-spec decode(binary(), pos_integer()) ->
    {ok, [frame()], binary(), frag_state()} | {error, term()}.
decode(Buffer, MaxFrameSize) ->
    decode(Buffer, MaxFrameSize, undefined).

-doc """
Decode frames from a buffer, carrying fragmentation state across calls.

Returns `{ok, Frames, Remaining, NewFragState}` on success, where
`Remaining` is unconsumed bytes and `NewFragState` tracks any
in-progress fragmented message.
""".
-spec decode(binary(), pos_integer(), frag_state()) ->
    {ok, [frame()], binary(), frag_state()} | {error, term()}.
decode(Buffer, MaxFrameSize, FragState) ->
    decode_loop(Buffer, MaxFrameSize, FragState, []).

%%====================================================================
%% Masking (Section 5.3)
%%====================================================================

-doc """
Apply XOR mask with a 4-byte key.

Processes 32 bits at a time for aligned data, falling back to
byte-wise XOR for the 0–3 byte tail. Masking is its own inverse:
`mask(mask(Data, Key), Key) =:= Data`.
""".
-spec mask(binary(), <<_:32>>) -> binary().
mask(Data, <<K1, K2, K3, K4>>) ->
    M32 = (K1 bsl 24) bor (K2 bsl 16) bor (K3 bsl 8) bor K4,
    AlignedSize = (byte_size(Data) div 4) * 4,
    <<Aligned:AlignedSize/binary, Tail/binary>> = Data,
    MaskedAligned = mask_words(Aligned, M32, <<>>),
    MaskedTail = mask_tail(Tail, K1, K2, K3, K4, 0, <<>>),
    <<MaskedAligned/binary, MaskedTail/binary>>.

%%====================================================================
%% Internal: encoding helpers
%%====================================================================

-spec encode_header(non_neg_integer(), non_neg_integer()) -> binary().
encode_header(Opcode, Len) when Len < 126 ->
    <<1:1, 0:3, Opcode:4, 1:1, Len:7>>;
encode_header(Opcode, Len) when Len < 65536 ->
    <<1:1, 0:3, Opcode:4, 1:1, 126:7, Len:16>>;
encode_header(Opcode, Len) ->
    <<1:1, 0:3, Opcode:4, 1:1, 127:7, Len:64>>.

-spec type_to_opcode(text | binary | close | ping | pong) ->
    non_neg_integer().
type_to_opcode(text)   -> ?OP_TEXT;
type_to_opcode(binary) -> ?OP_BINARY;
type_to_opcode(close)  -> ?OP_CLOSE;
type_to_opcode(ping)   -> ?OP_PING;
type_to_opcode(pong)   -> ?OP_PONG.

%%====================================================================
%% Internal: masking helpers
%%====================================================================

-spec mask_words(binary(), non_neg_integer(), binary()) -> binary().
mask_words(<<D:32, Rest/binary>>, M, Acc) ->
    mask_words(Rest, M, <<Acc/binary, (D bxor M):32>>);
mask_words(<<>>, _M, Acc) ->
    Acc.

-spec mask_tail(binary(), byte(), byte(), byte(), byte(),
                non_neg_integer(), binary()) -> binary().
mask_tail(<<B, Rest/binary>>, K1, K2, K3, K4, 0, Acc) ->
    mask_tail(Rest, K1, K2, K3, K4, 1, <<Acc/binary, (B bxor K1)>>);
mask_tail(<<B, Rest/binary>>, K1, K2, K3, K4, 1, Acc) ->
    mask_tail(Rest, K1, K2, K3, K4, 2, <<Acc/binary, (B bxor K2)>>);
mask_tail(<<B, Rest/binary>>, K1, K2, K3, K4, 2, Acc) ->
    mask_tail(Rest, K1, K2, K3, K4, 3, <<Acc/binary, (B bxor K3)>>);
mask_tail(<<B>>, _K1, _K2, _K3, K4, 3, Acc) ->
    <<Acc/binary, (B bxor K4)>>;
mask_tail(<<>>, _K1, _K2, _K3, _K4, _I, Acc) ->
    Acc.

%%====================================================================
%% Internal: decoding helpers
%%====================================================================

-spec decode_loop(binary(), pos_integer(), frag_state(), [frame()]) ->
    {ok, [frame()], binary(), frag_state()} | {error, term()}.
decode_loop(Buffer, MaxSize, FragState, Acc) ->
    case decode_one(Buffer, MaxSize) of
        {ok, {Fin, Opcode, Payload}, Rest} ->
            case assemble(Fin, Opcode, Payload, FragState) of
                {frame, Frame, NewFrag} ->
                    decode_loop(Rest, MaxSize, NewFrag, [Frame | Acc]);
                {continue, NewFrag} ->
                    decode_loop(Rest, MaxSize, NewFrag, Acc);
                {error, _} = Err ->
                    Err
            end;
        incomplete ->
            {ok, lists:reverse(Acc), Buffer, FragState};
        {error, _} = Err ->
            Err
    end.

-spec decode_one(binary(), pos_integer()) ->
    {ok, {0 | 1, non_neg_integer(), binary()}, binary()} |
    incomplete |
    {error, term()}.
%% 7-bit length (0–125)
decode_one(<<Fin:1, Rsv:3, Op:4, 0:1, Len:7, Rest/binary>>,
           MaxSize) when Len < 126 ->
    extract(Fin, Op, Len, Rest, MaxSize, Rsv);
%% 16-bit extended length
decode_one(<<Fin:1, Rsv:3, Op:4, 0:1, 126:7, Len:16, Rest/binary>>,
           MaxSize) ->
    extract(Fin, Op, Len, Rest, MaxSize, Rsv);
%% 64-bit extended length
decode_one(<<Fin:1, Rsv:3, Op:4, 0:1, 127:7, Len:64, Rest/binary>>,
           MaxSize) ->
    extract(Fin, Op, Len, Rest, MaxSize, Rsv);
%% Server frames MUST NOT be masked (consume full 2-byte header for alignment)
decode_one(<<_:1, _:3, _:4, 1:1, _:7, _/binary>>, _MaxSize) ->
    {error, server_frame_masked};
%% Not enough header bytes yet
decode_one(_, _) ->
    incomplete.

-spec extract(0 | 1, non_neg_integer(), non_neg_integer(),
              binary(), pos_integer(), non_neg_integer()) ->
    {ok, {0 | 1, non_neg_integer(), binary()}, binary()} |
    incomplete |
    {error, term()}.
extract(_Fin, _Op, _Len, _Rest, _MaxSize, Rsv) when Rsv =/= 0 ->
    {error, {unexpected_rsv_bits, Rsv}};
extract(Fin, Op, Len, Rest, MaxSize, _Rsv) ->
    IsControl = Op >= 8,
    if
        Len > MaxSize ->
            {error, frame_too_large};
        IsControl andalso Len > ?MAX_CONTROL_PAYLOAD ->
            {error, control_frame_too_large};
        IsControl andalso Fin =/= 1 ->
            {error, fragmented_control_frame};
        Op >= 3 andalso Op =< 7 ->
            {error, {reserved_opcode, Op}};
        Op >= 16#B ->
            {error, {reserved_opcode, Op}};
        byte_size(Rest) >= Len ->
            <<Payload:Len/binary, Remaining/binary>> = Rest,
            {ok, {Fin, Op, Payload}, Remaining};
        true ->
            incomplete
    end.

%%====================================================================
%% Internal: fragmentation assembly
%%====================================================================

-spec assemble(0 | 1, non_neg_integer(), binary(), frag_state()) ->
    {frame, frame(), frag_state()} |
    {continue, frag_state()} |
    {error, term()}.
%% Control frames — never fragmented, don't affect frag state.
assemble(1, Op, Payload, FragState) when Op >= 8 ->
    {frame, make_frame(Op, Payload), FragState};
%% Complete unfragmented data frame.
assemble(1, Op, Payload, undefined) when Op > 0, Op < 8 ->
    {frame, make_frame(Op, Payload), undefined};
%% Start of fragmented message.
assemble(0, Op, Payload, undefined) when Op > 0, Op < 8 ->
    {continue, {Op, [Payload]}};
%% Continuation frame (middle).
assemble(0, ?OP_CONT, Payload, {OrigOp, Acc}) ->
    {continue, {OrigOp, [Payload | Acc]}};
%% Final continuation frame.
assemble(1, ?OP_CONT, Payload, {OrigOp, Acc}) ->
    Complete = iolist_to_binary(lists:reverse([Payload | Acc])),
    {frame, make_frame(OrigOp, Complete), undefined};
%% New data frame while a fragmented message is in progress.
assemble(_, Op, _Payload, {_, _}) when Op > 0, Op < 8 ->
    {error, interleaved_data_frame};
%% Continuation frame with no fragmented message in progress.
assemble(_, ?OP_CONT, _Payload, undefined) ->
    {error, unexpected_continuation}.

-spec make_frame(non_neg_integer(), binary()) -> frame().
make_frame(?OP_TEXT, Payload) ->
    {text, Payload};
make_frame(?OP_BINARY, Payload) ->
    {binary, Payload};
make_frame(?OP_CLOSE, <<Code:16, Reason/binary>>) ->
    {close, Code, Reason};
make_frame(?OP_CLOSE, <<_:8>>) ->
    %% RFC 6455 Section 5.5.1: close body must be 0 or ≥2 bytes.
    %% A 1-byte payload is a protocol violation.
    {close, 1002, <<>>};
make_frame(?OP_CLOSE, <<>>) ->
    {close, 1000, <<>>};
make_frame(?OP_PING, Payload) ->
    {ping, Payload};
make_frame(?OP_PONG, Payload) ->
    {pong, Payload}.
