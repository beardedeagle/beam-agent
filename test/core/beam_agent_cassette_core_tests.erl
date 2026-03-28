%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_cassette_core.
%%%
%%% Tests the VCR-style recording/replay engine and dual-format
%%% (JSONL / BERT) disk serialization.  No mocks — real ETS tables
%%% and temp files.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_cassette_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

setup() ->
    beam_agent_cassette_core:ensure_tables(),
    beam_agent_cassette_core:clear(),
    ok.

%% Create a minimal cassette for disk I/O tests.
make_cassette(Entries) ->
    #{version => 1,
      entries => Entries,
      created_at => 1711612800000,
      entry_count => length(Entries),
      metadata => #{<<"source">> => <<"test">>}}.

make_entry(Prompt, Result) ->
    #{prompt => Prompt,
      result => Result,
      backend => <<"claude">>,
      model => <<"opus-4">>,
      recorded_at => 1711612800000}.

tmp_path(Suffix) ->
    Name = iolist_to_binary([
        <<"beam_agent_cassette_test_">>,
        integer_to_binary(erlang:unique_integer([positive])),
        <<"_">>, Suffix]),
    filename:join("/tmp", Name).

%%====================================================================
%% Recording — basic lifecycle
%%====================================================================

start_recording_returns_ok_test() ->
    setup(),
    ?assertEqual(ok, beam_agent_cassette_core:start_recording(sess1)).

start_recording_rejects_duplicate_test() ->
    setup(),
    ok = beam_agent_cassette_core:start_recording(sess2),
    ?assertEqual({error, already_recording},
        beam_agent_cassette_core:start_recording(sess2)).

is_recording_reflects_state_test() ->
    setup(),
    ?assertNot(beam_agent_cassette_core:is_recording(sess3)),
    ok = beam_agent_cassette_core:start_recording(sess3),
    ?assert(beam_agent_cassette_core:is_recording(sess3)).

record_entry_requires_active_session_test() ->
    setup(),
    ?assertEqual({error, not_recording},
        beam_agent_cassette_core:record_entry(
            no_sess, <<"p">>, ok, <<"b">>, <<"m">>)).

stop_recording_returns_sealed_cassette_test() ->
    setup(),
    ok = beam_agent_cassette_core:start_recording(sess4),
    ok = beam_agent_cassette_core:record_entry(
        sess4, <<"hello">>, [{text, <<"hi">>}], <<"claude">>, <<"opus">>),
    ok = beam_agent_cassette_core:record_entry(
        sess4, <<"bye">>, [{text, <<"cya">>}], <<"claude">>, <<"opus">>),
    {ok, Cassette} = beam_agent_cassette_core:stop_recording(sess4),
    ?assertEqual(1, maps:get(version, Cassette)),
    ?assertEqual(2, maps:get(entry_count, Cassette)),
    ?assert(is_integer(maps:get(created_at, Cassette))),
    [E1, E2] = maps:get(entries, Cassette),
    ?assertEqual(<<"hello">>, maps:get(prompt, E1)),
    ?assertEqual(<<"bye">>, maps:get(prompt, E2)).

stop_recording_preserves_entry_order_test() ->
    setup(),
    ok = beam_agent_cassette_core:start_recording(sess5),
    lists:foreach(fun(I) ->
        Prompt = integer_to_binary(I),
        beam_agent_cassette_core:record_entry(
            sess5, Prompt, I, <<"b">>, <<"m">>)
    end, lists:seq(1, 5)),
    {ok, #{entries := Entries}} = beam_agent_cassette_core:stop_recording(sess5),
    Prompts = [maps:get(prompt, E) || E <- Entries],
    ?assertEqual([<<"1">>, <<"2">>, <<"3">>, <<"4">>, <<"5">>], Prompts).

stop_recording_clears_state_test() ->
    setup(),
    ok = beam_agent_cassette_core:start_recording(sess6),
    {ok, _} = beam_agent_cassette_core:stop_recording(sess6),
    ?assertNot(beam_agent_cassette_core:is_recording(sess6)).

stop_recording_on_non_recording_session_test() ->
    setup(),
    ?assertEqual({error, not_recording},
        beam_agent_cassette_core:stop_recording(ghost)).

%%====================================================================
%% Recording — overwrite stale replay state
%%====================================================================

start_recording_overwrites_replay_state_test() ->
    setup(),
    Cassette = make_cassette([make_entry(<<"p">>, ok)]),
    ok = beam_agent_cassette_core:start_replay(sess7, Cassette),
    ?assert(beam_agent_cassette_core:is_replaying(sess7)),
    ok = beam_agent_cassette_core:start_recording(sess7),
    ?assert(beam_agent_cassette_core:is_recording(sess7)),
    ?assertNot(beam_agent_cassette_core:is_replaying(sess7)).

%%====================================================================
%% Replay — basic lifecycle
%%====================================================================

start_replay_accepts_valid_cassette_test() ->
    setup(),
    Cassette = make_cassette([make_entry(<<"hello">>, <<"world">>)]),
    ?assertEqual(ok, beam_agent_cassette_core:start_replay(rp1, Cassette)).

start_replay_rejects_invalid_cassette_test() ->
    setup(),
    ?assertEqual({error, invalid_cassette},
        beam_agent_cassette_core:start_replay(rp2, #{bad => data})).

is_replaying_reflects_state_test() ->
    setup(),
    ?assertNot(beam_agent_cassette_core:is_replaying(rp3)),
    Cassette = make_cassette([make_entry(<<"p">>, ok)]),
    ok = beam_agent_cassette_core:start_replay(rp3, Cassette),
    ?assert(beam_agent_cassette_core:is_replaying(rp3)).

replay_next_returns_entries_in_order_test() ->
    setup(),
    E1 = make_entry(<<"first">>, 1),
    E2 = make_entry(<<"second">>, 2),
    E3 = make_entry(<<"third">>, 3),
    Cassette = make_cassette([E1, E2, E3]),
    ok = beam_agent_cassette_core:start_replay(rp4, Cassette),
    {ok, R1} = beam_agent_cassette_core:replay_next(rp4),
    {ok, R2} = beam_agent_cassette_core:replay_next(rp4),
    {ok, R3} = beam_agent_cassette_core:replay_next(rp4),
    ?assertEqual(<<"first">>, maps:get(prompt, R1)),
    ?assertEqual(<<"second">>, maps:get(prompt, R2)),
    ?assertEqual(<<"third">>, maps:get(prompt, R3)).

replay_next_returns_done_when_exhausted_test() ->
    setup(),
    Cassette = make_cassette([make_entry(<<"only">>, ok)]),
    ok = beam_agent_cassette_core:start_replay(rp5, Cassette),
    {ok, _} = beam_agent_cassette_core:replay_next(rp5),
    ?assertEqual(done, beam_agent_cassette_core:replay_next(rp5)).

replay_next_on_non_replaying_session_test() ->
    setup(),
    ?assertEqual({error, not_replaying},
        beam_agent_cassette_core:replay_next(ghost)).

stop_replay_clears_state_test() ->
    setup(),
    Cassette = make_cassette([make_entry(<<"p">>, ok)]),
    ok = beam_agent_cassette_core:start_replay(rp6, Cassette),
    ok = beam_agent_cassette_core:stop_replay(rp6),
    ?assertNot(beam_agent_cassette_core:is_replaying(rp6)).

replay_empty_cassette_returns_done_immediately_test() ->
    setup(),
    Cassette = make_cassette([]),
    ok = beam_agent_cassette_core:start_replay(rp7, Cassette),
    ?assertEqual(done, beam_agent_cassette_core:replay_next(rp7)).

%%====================================================================
%% JSONL export/import round-trip
%%====================================================================

jsonl_roundtrip_single_entry_test() ->
    setup(),
    E = make_entry(<<"What is OTP?">>,
        [#{type => text, content => <<"OTP is...">>}]),
    Cassette = make_cassette([E]),
    Path = tmp_path(<<"roundtrip.jsonl">>),
    ok = beam_agent_cassette_core:export_jsonl(Cassette, Path),
    {ok, Loaded} = beam_agent_cassette_core:import_jsonl(Path),
    ?assertEqual(1, maps:get(version, Loaded)),
    ?assertEqual(1, maps:get(entry_count, Loaded)),
    [LE] = maps:get(entries, Loaded),
    ?assertEqual(<<"What is OTP?">>, maps:get(prompt, LE)),
    file:delete(Path).

jsonl_roundtrip_multiple_entries_test() ->
    setup(),
    Entries = [make_entry(integer_to_binary(I),
        [#{content => integer_to_binary(I)}])
               || I <- lists:seq(1, 10)],
    Cassette = make_cassette(Entries),
    Path = tmp_path(<<"multi.jsonl">>),
    ok = beam_agent_cassette_core:export_jsonl(Cassette, Path),
    {ok, Loaded} = beam_agent_cassette_core:import_jsonl(Path),
    ?assertEqual(10, maps:get(entry_count, Loaded)),
    LoadedPrompts = [maps:get(prompt, E)
                     || E <- maps:get(entries, Loaded)],
    ExpectedPrompts = [integer_to_binary(I) || I <- lists:seq(1, 10)],
    ?assertEqual(ExpectedPrompts, LoadedPrompts),
    file:delete(Path).

jsonl_preserves_metadata_test() ->
    setup(),
    Cassette = (make_cassette([]))#{
        metadata => #{<<"env">> => <<"test">>, <<"run">> => 42}},
    Path = tmp_path(<<"meta.jsonl">>),
    ok = beam_agent_cassette_core:export_jsonl(Cassette, Path),
    {ok, Loaded} = beam_agent_cassette_core:import_jsonl(Path),
    Meta = maps:get(metadata, Loaded),
    ?assertEqual(<<"test">>, maps:get(<<"env">>, Meta)),
    ?assertEqual(42, maps:get(<<"run">>, Meta)),
    file:delete(Path).

jsonl_file_is_human_readable_test() ->
    setup(),
    E = make_entry(<<"hello">>, [#{type => text, content => <<"world">>}]),
    Cassette = make_cassette([E]),
    Path = tmp_path(<<"readable.jsonl">>),
    ok = beam_agent_cassette_core:export_jsonl(Cassette, Path),
    {ok, Bin} = file:read_file(Path),
    %% Must contain the prompt text literally (human-readable!)
    ?assertNotEqual(nomatch, binary:match(Bin, <<"hello">>)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"world">>)),
    %% Must contain the version header
    ?assertNotEqual(nomatch, binary:match(Bin, <<"\"version\"">>)),
    %% Two lines (header + 1 entry) each terminated by newline
    {Lines, _} = beam_agent_jsonl:extract_lines(Bin),
    ?assertEqual(2, length(Lines)),
    file:delete(Path).

%%====================================================================
%% BERT export/import round-trip
%%====================================================================

bert_roundtrip_test() ->
    setup(),
    E = make_entry(<<"prompt">>, {ok, [#{type => text}]}),
    Cassette = make_cassette([E]),
    Path = tmp_path(<<"roundtrip.bert">>),
    ok = beam_agent_cassette_core:export_bert(Cassette, Path),
    {ok, Loaded} = beam_agent_cassette_core:import_bert(Path),
    %% BERT preserves exact Erlang terms — atom keys, tuples, etc.
    ?assertEqual(Cassette, Loaded),
    file:delete(Path).

bert_exact_term_preservation_test() ->
    setup(),
    %% Tuples, atoms, nested terms — BERT preserves all
    Result = {ok, [#{type => text, meta => {nested, [1, 2, 3]}}]},
    E = make_entry(<<"complex">>, Result),
    Cassette = make_cassette([E]),
    Path = tmp_path(<<"exact.bert">>),
    ok = beam_agent_cassette_core:export_bert(Cassette, Path),
    {ok, Loaded} = beam_agent_cassette_core:import_bert(Path),
    [LoadedEntry] = maps:get(entries, Loaded),
    ?assertEqual(Result, maps:get(result, LoadedEntry)),
    file:delete(Path).

%%====================================================================
%% Auto-detect import
%%====================================================================

import_cassette_autodetects_jsonl_test() ->
    setup(),
    E = make_entry(<<"auto">>, <<"jsonl">>),
    Cassette = make_cassette([E]),
    Path = tmp_path(<<"auto.jsonl">>),
    ok = beam_agent_cassette_core:export_jsonl(Cassette, Path),
    {ok, Loaded} = beam_agent_cassette_core:import_cassette(Path),
    [LE] = maps:get(entries, Loaded),
    ?assertEqual(<<"auto">>, maps:get(prompt, LE)),
    file:delete(Path).

import_cassette_autodetects_bert_test() ->
    setup(),
    E = make_entry(<<"auto">>, <<"bert">>),
    Cassette = make_cassette([E]),
    Path = tmp_path(<<"auto.bert">>),
    ok = beam_agent_cassette_core:export_bert(Cassette, Path),
    {ok, Loaded} = beam_agent_cassette_core:import_cassette(Path),
    ?assertEqual(Cassette, Loaded),
    file:delete(Path).

%%====================================================================
%% Compile JSONL → BERT
%%====================================================================

compile_cassette_produces_valid_bert_test() ->
    setup(),
    E = make_entry(<<"compile">>, [#{content => <<"compiled">>}]),
    Cassette = make_cassette([E]),
    JsonlPath = tmp_path(<<"compile.jsonl">>),
    BertPath = tmp_path(<<"compile.bert">>),
    ok = beam_agent_cassette_core:export_jsonl(Cassette, JsonlPath),
    ok = beam_agent_cassette_core:compile_cassette(JsonlPath, BertPath),
    {ok, Loaded} = beam_agent_cassette_core:import_bert(BertPath),
    ?assertEqual(1, maps:get(version, Loaded)),
    ?assertEqual(1, maps:get(entry_count, Loaded)),
    [LE] = maps:get(entries, Loaded),
    ?assertEqual(<<"compile">>, maps:get(prompt, LE)),
    file:delete(JsonlPath),
    file:delete(BertPath).

%%====================================================================
%% BERT envelope for non-JSON results
%%====================================================================

non_json_result_survives_jsonl_roundtrip_test() ->
    setup(),
    %% Tuples are not JSON-encodable — should use BERT envelope
    Result = {ok, [{text, <<"hello">>}]},
    E = make_entry(<<"tuple-result">>, Result),
    Cassette = make_cassette([E]),
    Path = tmp_path(<<"bert_envelope.jsonl">>),
    ok = beam_agent_cassette_core:export_jsonl(Cassette, Path),
    %% Verify the BERT envelope marker is in the file
    {ok, Bin} = file:read_file(Path),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"_format">>)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"bert">>)),
    %% Round-trip preserves the original term
    {ok, Loaded} = beam_agent_cassette_core:import_jsonl(Path),
    [LE] = maps:get(entries, Loaded),
    ?assertEqual(Result, maps:get(result, LE)),
    file:delete(Path).

json_encodable_result_stored_natively_test() ->
    setup(),
    %% Maps with binary keys/values are JSON-native
    Result = [#{<<"type">> => <<"text">>, <<"content">> => <<"hi">>}],
    E = make_entry(<<"json-result">>, Result),
    Cassette = make_cassette([E]),
    Path = tmp_path(<<"native_json.jsonl">>),
    ok = beam_agent_cassette_core:export_jsonl(Cassette, Path),
    %% Verify NO BERT envelope — result is stored as native JSON
    {ok, Bin} = file:read_file(Path),
    ?assertEqual(nomatch, binary:match(Bin, <<"_format">>)),
    %% Content is directly visible
    ?assertNotEqual(nomatch, binary:match(Bin, <<"hi">>)),
    {ok, Loaded} = beam_agent_cassette_core:import_jsonl(Path),
    [LE] = maps:get(entries, Loaded),
    ?assertEqual(Result, maps:get(result, LE)),
    file:delete(Path).

%%====================================================================
%% Error cases
%%====================================================================

import_jsonl_nonexistent_file_test() ->
    ?assertMatch({error, enoent},
        beam_agent_cassette_core:import_jsonl("/tmp/no_such_cassette.jsonl")).

import_bert_nonexistent_file_test() ->
    ?assertMatch({error, enoent},
        beam_agent_cassette_core:import_bert("/tmp/no_such_cassette.bert")).

import_bert_corrupt_file_test() ->
    Path = tmp_path(<<"corrupt.bert">>),
    ok = file:write_file(Path, <<"not a valid BERT file">>),
    ?assertEqual({error, corrupt_cassette_file},
        beam_agent_cassette_core:import_bert(Path)),
    file:delete(Path).

import_bert_wrong_format_test() ->
    Path = tmp_path(<<"wrong.bert">>),
    ok = file:write_file(Path, term_to_binary(#{wrong => format})),
    ?assertEqual({error, invalid_cassette_format},
        beam_agent_cassette_core:import_bert(Path)),
    file:delete(Path).

import_jsonl_invalid_header_test() ->
    Path = tmp_path(<<"bad_header.jsonl">>),
    ok = file:write_file(Path, <<"{\"not_a_version\":true}\n">>),
    ?assertEqual({error, unsupported_cassette_version},
        beam_agent_cassette_core:import_jsonl(Path)),
    file:delete(Path).

import_jsonl_empty_file_test() ->
    Path = tmp_path(<<"empty.jsonl">>),
    ok = file:write_file(Path, <<>>),
    ?assertEqual({error, empty_cassette},
        beam_agent_cassette_core:import_jsonl(Path)),
    file:delete(Path).

compile_nonexistent_source_test() ->
    ?assertMatch({error, enoent},
        beam_agent_cassette_core:compile_cassette(
            "/tmp/no_such_source.jsonl", "/tmp/out.bert")).

%%====================================================================
%% Table lifecycle
%%====================================================================

ensure_tables_is_idempotent_test() ->
    ok = beam_agent_cassette_core:ensure_tables(),
    ok = beam_agent_cassette_core:ensure_tables(),
    ok = beam_agent_cassette_core:ensure_tables().

clear_wipes_all_state_test() ->
    setup(),
    ok = beam_agent_cassette_core:start_recording(clear_sess),
    ok = beam_agent_cassette_core:clear(),
    ?assertNot(beam_agent_cassette_core:is_recording(clear_sess)).

%%====================================================================
%% export_cassette/2 defaults to JSONL
%%====================================================================

export_cassette_defaults_to_jsonl_test() ->
    setup(),
    E = make_entry(<<"default">>, <<"format">>),
    Cassette = make_cassette([E]),
    Path = tmp_path(<<"default.cassette">>),
    ok = beam_agent_cassette_core:export_cassette(Cassette, Path),
    %% Should be JSONL — starts with '{'
    {ok, <<${, _/binary>>} = file:read_file(Path),
    {ok, Loaded} = beam_agent_cassette_core:import_jsonl(Path),
    ?assertEqual(1, maps:get(entry_count, Loaded)),
    file:delete(Path).
