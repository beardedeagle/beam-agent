%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for beam_agent_ws_frame.
%%%
%%% Fuzz-tests the WebSocket frame codec with random inputs to verify
%%% robustness and round-trip properties per RFC 6455.
%%%
%%% Properties (200 test cases each):
%%%   1. mask/2 is its own inverse (XOR self-cancellation)
%%%   2. Encoded payloads are recoverable via unmasking
%%%   3. Valid unmasked text frames decode correctly
%%%   4. Valid unmasked binary frames decode correctly
%%%   5. Close frames preserve status code and reason
%%%   6. Masked server frames are rejected
%%%   7. Random binary input never crashes decode
%%% @end
%%%-------------------------------------------------------------------
-module(prop_beam_agent_ws_frame).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

mask_self_inverse_test() ->
    ?assert(proper:quickcheck(prop_mask_self_inverse(),
        [{numtests, 200}, {to_file, user}])).

encode_payload_recoverable_test() ->
    ?assert(proper:quickcheck(prop_encode_payload_recoverable(),
        [{numtests, 200}, {to_file, user}])).

decode_valid_text_frame_test() ->
    ?assert(proper:quickcheck(prop_decode_valid_text_frame(),
        [{numtests, 200}, {to_file, user}])).

decode_valid_binary_frame_test() ->
    ?assert(proper:quickcheck(prop_decode_valid_binary_frame(),
        [{numtests, 200}, {to_file, user}])).

decode_close_preserves_code_test() ->
    ?assert(proper:quickcheck(prop_decode_close_preserves_code(),
        [{numtests, 200}, {to_file, user}])).

decode_rejects_masked_server_test() ->
    ?assert(proper:quickcheck(prop_decode_rejects_masked_server(),
        [{numtests, 200}, {to_file, user}])).

decode_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_decode_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: XOR masking is its own inverse
prop_mask_self_inverse() ->
    ?FORALL({Data, Key}, {binary(), binary(4)},
        beam_agent_ws_frame:mask(
            beam_agent_ws_frame:mask(Data, Key), Key) =:= Data).

%% Property 2: Encoded payload is recoverable by unmasking with the embedded key
prop_encode_payload_recoverable() ->
    ?FORALL({Type, Payload}, {gen_frame_type(), gen_bounded_payload()},
        begin
            [_Header, MaskKey, Masked] =
                beam_agent_ws_frame:encode(Type, Payload),
            beam_agent_ws_frame:mask(Masked, MaskKey) =:= Payload
        end).

%% Property 3: Decoding a valid unmasked text frame yields {text, Payload}
prop_decode_valid_text_frame() ->
    ?FORALL(Payload, gen_short_payload(),
        begin
            Frame = build_server_frame(1, Payload),
            {ok, [{text, Payload}], <<>>, undefined} =:=
                beam_agent_ws_frame:decode(Frame, 65536)
        end).

%% Property 4: Decoding a valid unmasked binary frame yields {binary, Payload}
prop_decode_valid_binary_frame() ->
    ?FORALL(Payload, gen_short_payload(),
        begin
            Frame = build_server_frame(2, Payload),
            {ok, [{binary, Payload}], <<>>, undefined} =:=
                beam_agent_ws_frame:decode(Frame, 65536)
        end).

%% Property 5: Close frames preserve status code and reason
prop_decode_close_preserves_code() ->
    ?FORALL({Code, Reason}, {integer(0, 4999), gen_close_reason()},
        begin
            ClosePayload = <<Code:16, Reason/binary>>,
            Frame = build_server_frame(8, ClosePayload),
            {ok, [{close, Code, Reason}], <<>>, undefined} =:=
                beam_agent_ws_frame:decode(Frame, 65536)
        end).

%% Property 6: Server frames with mask bit set are rejected
prop_decode_rejects_masked_server() ->
    ?FORALL(Payload, gen_short_payload(),
        begin
            Len = byte_size(Payload),
            Frame = <<1:1, 0:3, 1:4, 1:1, Len:7, 0:32, Payload/binary>>,
            {error, server_frame_masked} =:=
                beam_agent_ws_frame:decode(Frame, 65536)
        end).

%% Property 7: decode/2 never crashes on arbitrary binary input
prop_decode_never_crashes() ->
    ?FORALL(Buffer, binary(),
        begin
            case beam_agent_ws_frame:decode(Buffer, 65536) of
                {ok, Frames, _Rest, _Frag} -> is_list(Frames);
                {error, _Reason} -> true
            end
        end).

%%====================================================================
%% Generators
%%====================================================================

gen_frame_type() ->
    oneof([text, binary, ping, pong, close]).

%% Payload bounded to 125 bytes (safe for all frame types including control).
gen_bounded_payload() ->
    ?LET(Size, integer(0, 125),
        binary(Size)).

%% Short payload for 7-bit length encoding (< 126 bytes).
gen_short_payload() ->
    ?LET(Size, integer(0, 120),
        binary(Size)).

%% Close reason text (fits in control frame with 2-byte code overhead).
gen_close_reason() ->
    ?LET(Size, integer(0, 100),
        binary(Size)).

%%====================================================================
%% Helpers
%%====================================================================

%% Build an unmasked server frame (Fin=1, Rsv=0, Mask=0, 7-bit length).
-spec build_server_frame(non_neg_integer(), binary()) -> binary().
build_server_frame(Opcode, Payload) ->
    Len = byte_size(Payload),
    <<1:1, 0:3, Opcode:4, 0:1, Len:7, Payload/binary>>.
