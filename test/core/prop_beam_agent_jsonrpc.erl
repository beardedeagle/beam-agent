%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for beam_agent_jsonrpc.
%%%
%%% Fuzz-tests the JSON-RPC 2.0 codec with random inputs to verify
%%% encoding/decoding round-trip properties.
%%%
%%% Properties (200 test cases each):
%%%   1. encode_request → json:decode → decode round-trips
%%%   2. encode_notification → json:decode → decode round-trips
%%%   3. encode_response → json:decode → decode round-trips
%%%   4. encode_error → json:decode → decode round-trips
%%%   5. All encode outputs are newline-terminated iodata
%%%   6. decode never crashes on any map input
%%%   7. Maps without method/id/result/error produce {unknown, _}
%%% @end
%%%-------------------------------------------------------------------
-module(prop_beam_agent_jsonrpc).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

request_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_request_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

notification_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_notification_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

response_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_response_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

error_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_error_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

encode_newline_terminated_test() ->
    ?assert(proper:quickcheck(prop_encode_newline_terminated(),
        [{numtests, 200}, {to_file, user}])).

decode_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_decode_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

unknown_map_returns_unknown_test() ->
    ?assert(proper:quickcheck(prop_unknown_map_returns_unknown(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: request encode → json:decode → decode round-trips
prop_request_roundtrip() ->
    ?FORALL({Id, Method, Params}, {gen_id(), gen_method(), gen_params()},
        begin
            IoData = beam_agent_jsonrpc:encode_request(Id, Method, Params),
            Map = json_decode_iodata(IoData),
            beam_agent_jsonrpc:decode(Map) =:= {request, Id, Method, Params}
        end).

%% Property 2: notification encode → json:decode → decode round-trips
prop_notification_roundtrip() ->
    ?FORALL({Method, Params}, {gen_method(), gen_params()},
        begin
            IoData = beam_agent_jsonrpc:encode_notification(Method, Params),
            Map = json_decode_iodata(IoData),
            beam_agent_jsonrpc:decode(Map) =:= {notification, Method, Params}
        end).

%% Property 3: response encode → json:decode → decode round-trips
prop_response_roundtrip() ->
    ?FORALL({Id, Result}, {gen_id(), gen_result()},
        begin
            IoData = beam_agent_jsonrpc:encode_response(Id, Result),
            Map = json_decode_iodata(IoData),
            beam_agent_jsonrpc:decode(Map) =:= {response, Id, Result}
        end).

%% Property 4: error encode → json:decode → decode round-trips
prop_error_roundtrip() ->
    ?FORALL({Id, Code, Message}, {gen_id(), integer(), gen_method()},
        begin
            IoData = beam_agent_jsonrpc:encode_error(Id, Code, Message),
            Map = json_decode_iodata(IoData),
            beam_agent_jsonrpc:decode(Map) =:=
                {error_response, Id, Code, Message, undefined}
        end).

%% Property 5: All encode functions produce newline-terminated output
prop_encode_newline_terminated() ->
    ?FORALL({Id, Method, Params}, {gen_id(), gen_method(), gen_params()},
        begin
            R = iolist_to_binary(
                beam_agent_jsonrpc:encode_request(Id, Method, Params)),
            N = iolist_to_binary(
                beam_agent_jsonrpc:encode_notification(Method, Params)),
            S = iolist_to_binary(
                beam_agent_jsonrpc:encode_response(Id, <<"ok">>)),
            E = iolist_to_binary(
                beam_agent_jsonrpc:encode_error(Id, -1, <<"err">>)),
            lists:all(fun(B) -> binary:last(B) =:= $\n end, [R, N, S, E])
        end).

%% Property 6: decode never crashes on any map input
prop_decode_never_crashes() ->
    ?FORALL(Map, gen_arbitrary_map(),
        begin
            Result = beam_agent_jsonrpc:decode(Map),
            is_tuple(Result)
        end).

%% Property 7: Maps without recognizable JSON-RPC keys produce {unknown, _}
prop_unknown_map_returns_unknown() ->
    ?FORALL(Map, map(gen_non_rpc_key(), binary()),
        {unknown, Map} =:= beam_agent_jsonrpc:decode(Map)).

%%====================================================================
%% Generators
%%====================================================================

gen_id() ->
    oneof([non_neg_integer(), gen_utf8_nonempty()]).

gen_method() ->
    gen_utf8_nonempty().

gen_params() ->
    oneof([
        return(undefined),
        map(gen_utf8_nonempty(), gen_utf8())
    ]).

gen_result() ->
    oneof([
        gen_utf8(),
        return(true),
        return(null),
        map(gen_utf8_nonempty(), gen_utf8())
    ]).

gen_arbitrary_map() ->
    ?LET(Pairs, list({gen_utf8(), oneof([gen_utf8(), integer(),
                                         return(true), return(null)])}),
        maps:from_list(Pairs)).

gen_non_rpc_key() ->
    ?SUCHTHAT(K, gen_utf8_nonempty(),
        K =/= <<"method">> andalso
        K =/= <<"id">> andalso
        K =/= <<"result">> andalso
        K =/= <<"error">> andalso
        K =/= <<"params">>).

%% Generate a valid UTF-8 binary (printable ASCII subset for JSON safety).
gen_utf8() ->
    ?LET(Chars, list(range(32, 126)), list_to_binary(Chars)).

gen_utf8_nonempty() ->
    ?LET(Chars, non_empty(list(range(32, 126))), list_to_binary(Chars)).

%%====================================================================
%% Helpers
%%====================================================================

%% Decode JSON from iodata, stripping trailing newline.
json_decode_iodata(IoData) ->
    Bin = iolist_to_binary(IoData),
    JsonBin = binary:part(Bin, 0, byte_size(Bin) - 1),
    json:decode(JsonBin).
