-module(beam_agent_cassette_core).
-moduledoc """
Recording and replay engine for CLI interactions.

VCR-style cassette recording — captures query/response pairs for
deterministic replay without CLI calls.  Designed for dev/test/CI
workflows: record a session once, replay it in tests to avoid
flaky network dependencies and token costs.

Process-free.  ETS-backed recording state with dual-format file
export/import for portable test fixtures.

## Recording

Start recording for a session, then all query results captured via
`record_entry/5` are stored in order.  Stop recording to seal the
cassette.

## Replay

Load a cassette and start replay for a session.  Calls to
`replay_next/1` return entries in order.  When all entries are
exhausted, returns `done`.

## Disk Formats

### JSONL (Canonical)

Human-readable, one JSON object per line.  First line is a header
with cassette metadata; subsequent lines are entries with prompt,
result, backend, model, and timestamp.  Inspectable, diffable, and
version-control friendly.

Results that are JSON-encodable (maps, lists, binaries, numbers) are
stored natively for readability.  Non-JSON terms (pids, references,
funs) are automatically wrapped in a BERT envelope
(`{"_format":"bert","_data":"<base64>"}`) for lossless
round-tripping.

### BERT (Derived)

Binary ERlang Term format via `term_to_binary/2` with `[compressed]`.
Exact Erlang term preservation with fast loading.  Derived from the
canonical JSONL format or directly from the in-memory cassette.

Use `compile_cassette/2` to convert a JSONL file into BERT for
production replay performance.
""".

-export([
    ensure_tables/0,
    %% Recording
    start_recording/1,
    record_entry/5,
    stop_recording/1,
    is_recording/1,
    %% Replay
    start_replay/2,
    replay_next/1,
    stop_replay/1,
    is_replaying/1,
    %% Disk I/O — JSONL (canonical)
    export_jsonl/2,
    import_jsonl/1,
    %% Disk I/O — BERT (derived)
    export_bert/2,
    import_bert/1,
    %% Convenience
    export_cassette/2,
    import_cassette/1,
    compile_cassette/2,
    %% Lifecycle
    clear/0
]).

-export_type([
    cassette/0,
    cassette_entry/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type cassette_entry() :: #{
    prompt := binary(),
    result := term(),
    backend := binary(),
    model := binary(),
    recorded_at := integer()
}.

-type cassette() :: #{
    version := 1,
    entries := [cassette_entry()],
    created_at := integer(),
    entry_count := non_neg_integer(),
    metadata := map()
}.

%%--------------------------------------------------------------------
%% Tables
%%--------------------------------------------------------------------

%% Recording state: {SessionId, recording, [entries_reversed]}
%% Replay state:    {SessionId, replaying, [remaining_entries]}
-define(STATE_TABLE, beam_agent_cassette_state).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the cassette ETS table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?STATE_TABLE,
        [set, named_table, {read_concurrency, true}]),
    ok.

-doc "Clear all recording and replay state.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?STATE_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Recording
%%--------------------------------------------------------------------

-doc "Start recording for a session. Returns error if already recording.".
-spec start_recording(term()) -> ok | {error, already_recording}.
start_recording(SessionId) ->
    ensure_tables(),
    case beam_agent_ets:insert_new(?STATE_TABLE, {SessionId, recording, []}) of
        true -> ok;
        false ->
            case beam_agent_ets:lookup(?STATE_TABLE, SessionId) of
                [{_, recording, _}] -> {error, already_recording};
                _ ->
                    %% Was replaying or stale — overwrite
                    beam_agent_ets:insert(?STATE_TABLE, {SessionId, recording, []}),
                    ok
            end
    end.

-doc """
Record a query/response entry for a session.

Recording is single-writer per session.  Concurrent calls for the
same session are not supported and may lose entries.
""".
-spec record_entry(term(), binary(), term(), binary(), binary()) -> ok | {error, not_recording}.
record_entry(SessionId, Prompt, Result, Backend, Model) ->
    ensure_tables(),
    case beam_agent_ets:lookup(?STATE_TABLE, SessionId) of
        [{SessionId, recording, Entries}] ->
            Entry = #{
                prompt => Prompt,
                result => Result,
                backend => Backend,
                model => Model,
                recorded_at => erlang:system_time(millisecond)
            },
            beam_agent_ets:insert(?STATE_TABLE,
                {SessionId, recording, [Entry | Entries]}),
            ok;
        _ ->
            {error, not_recording}
    end.

-doc """
Stop recording and return the sealed cassette.

Entries are returned in the order they were recorded.
""".
-spec stop_recording(term()) -> {ok, cassette()} | {error, not_recording}.
stop_recording(SessionId) ->
    ensure_tables(),
    case beam_agent_ets:lookup(?STATE_TABLE, SessionId) of
        [{SessionId, recording, ReversedEntries}] ->
            beam_agent_ets:delete(?STATE_TABLE, SessionId),
            Entries = lists:reverse(ReversedEntries),
            Cassette = #{
                version => 1,
                entries => Entries,
                created_at => erlang:system_time(millisecond),
                entry_count => length(Entries),
                metadata => #{}
            },
            {ok, Cassette};
        _ ->
            {error, not_recording}
    end.

-doc "Check if a session is currently recording.".
-spec is_recording(term()) -> boolean().
is_recording(SessionId) ->
    ensure_tables(),
    case beam_agent_ets:lookup(?STATE_TABLE, SessionId) of
        [{_, recording, _}] -> true;
        _ -> false
    end.

%%--------------------------------------------------------------------
%% Replay
%%--------------------------------------------------------------------

-doc "Load a cassette for replay on a session.".
-spec start_replay(term(), cassette()) -> ok | {error, term()}.
start_replay(SessionId, #{version := 1, entries := Entries})
  when is_list(Entries) ->
    ensure_tables(),
    beam_agent_ets:insert(?STATE_TABLE, {SessionId, replaying, Entries}),
    ok;
start_replay(_SessionId, _Invalid) ->
    {error, invalid_cassette}.

-doc """
Return the next recorded entry for replay.

Returns `{ok, Entry}` or `done` when the cassette is exhausted.
""".
-spec replay_next(term()) -> {ok, cassette_entry()} | done | {error, not_replaying}.
replay_next(SessionId) ->
    ensure_tables(),
    case beam_agent_ets:lookup(?STATE_TABLE, SessionId) of
        [{SessionId, replaying, [Entry | Rest]}] ->
            beam_agent_ets:insert(?STATE_TABLE,
                {SessionId, replaying, Rest}),
            {ok, Entry};
        [{SessionId, replaying, []}] ->
            done;
        _ ->
            {error, not_replaying}
    end.

-doc "Stop replay and remove the session's replay state.".
-spec stop_replay(term()) -> ok.
stop_replay(SessionId) ->
    ensure_tables(),
    beam_agent_ets:delete(?STATE_TABLE, SessionId),
    ok.

-doc "Check if a session is currently in replay mode.".
-spec is_replaying(term()) -> boolean().
is_replaying(SessionId) ->
    ensure_tables(),
    case beam_agent_ets:lookup(?STATE_TABLE, SessionId) of
        [{_, replaying, _}] -> true;
        _ -> false
    end.

%%--------------------------------------------------------------------
%% Disk I/O — JSONL (canonical)
%%--------------------------------------------------------------------

-doc """
Export a cassette as JSONL (one JSON object per line).

First line is the cassette header; subsequent lines are entries.
This is the canonical, human-readable format.
""".
-dialyzer({nowarn_function, export_jsonl/2}).
-spec export_jsonl(cassette(), file:filename_all()) -> ok | {error, term()}.
export_jsonl(#{version := 1, entries := Entries} = Cassette, FilePath) ->
    Header = header_to_json(Cassette),
    Lines = [beam_agent_jsonl:encode_line(Header)
             | [beam_agent_jsonl:encode_line(entry_to_json(E))
                || E <- Entries]],
    file:write_file(FilePath, Lines).

-doc """
Import a cassette from a JSONL file.

Reads the header line for metadata, then decodes each subsequent
line as a cassette entry.
""".
-spec import_jsonl(file:filename_all()) -> {ok, cassette()} | {error, term()}.
import_jsonl(FilePath) ->
    case file:read_file(FilePath) of
        {ok, Bin} ->
            parse_jsonl(Bin);
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Disk I/O — BERT (derived)
%%--------------------------------------------------------------------

-doc "Export a cassette to a BERT file (compressed binary term).".
-spec export_bert(cassette(), file:filename_all()) -> ok | {error, term()}.
export_bert(#{version := 1} = Cassette, FilePath) ->
    Bin = term_to_binary(Cassette, [compressed]),
    file:write_file(FilePath, Bin).

-doc "Import a cassette from a BERT file.".
-spec import_bert(file:filename_all()) -> {ok, cassette()} | {error, term()}.
import_bert(FilePath) ->
    case file:read_file(FilePath) of
        {ok, Bin} ->
            decode_bert(Bin);
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Convenience
%%--------------------------------------------------------------------

-doc "Export a cassette using the canonical JSONL format.".
-dialyzer({nowarn_function, export_cassette/2}).
-spec export_cassette(cassette(), file:filename_all()) -> ok | {error, term()}.
export_cassette(Cassette, FilePath) ->
    export_jsonl(Cassette, FilePath).

-doc """
Import a cassette, auto-detecting the format.

Tries JSONL first (checks for a leading `{`), falls back to BERT.
""".
-spec import_cassette(file:filename_all()) -> {ok, cassette()} | {error, term()}.
import_cassette(FilePath) ->
    case file:read_file(FilePath) of
        {ok, <<${, _/binary>> = Bin} ->
            %% Starts with '{' — JSONL
            parse_jsonl(Bin);
        {ok, Bin} ->
            %% Try BERT
            decode_bert(Bin);
        {error, _} = Error ->
            Error
    end.

-doc """
Compile a JSONL cassette file into BERT format.

Reads the JSONL file, reconstructs the cassette, and writes it as
a compressed BERT file for fast loading at replay time.
""".
-spec compile_cassette(file:filename_all(), file:filename_all()) ->
    ok | {error, term()}.
compile_cassette(JsonlPath, BertPath) ->
    case import_jsonl(JsonlPath) of
        {ok, Cassette} ->
            export_bert(Cassette, BertPath);
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internal — BERT decoding
%%--------------------------------------------------------------------

-spec decode_bert(binary()) -> {ok, cassette()} | {error, term()}.
decode_bert(Bin) ->
    try binary_to_term(Bin, [safe]) of
        #{version := 1, entries := Entries} = Cassette
          when is_list(Entries) ->
            {ok, Cassette};
        _ ->
            {error, invalid_cassette_format}
    catch
        error:badarg ->
            {error, corrupt_cassette_file}
    end.

%%--------------------------------------------------------------------
%% Internal — JSONL encoding
%%--------------------------------------------------------------------

-spec header_to_json(cassette()) -> map().
header_to_json(#{version := V, created_at := C,
                  entry_count := N, metadata := M}) ->
    #{<<"version">> => V,
      <<"created_at">> => C,
      <<"entry_count">> => N,
      <<"metadata">> => M}.

-spec entry_to_json(cassette_entry()) -> map().
entry_to_json(#{prompt := Prompt, result := Result, backend := Backend,
                model := Model, recorded_at := RecordedAt}) ->
    #{<<"prompt">> => Prompt,
      <<"result">> => result_to_json(Result),
      <<"backend">> => Backend,
      <<"model">> => Model,
      <<"recorded_at">> => RecordedAt}.

%% Safely encode a result for JSON.  JSON-friendly terms are used
%% directly; non-JSON terms (pids, funs, references) are wrapped
%% in a BERT envelope for lossless round-tripping.
%% Dialyzer infers a narrower return type than term() because it
%% traces through json:encode/1 — the broad spec is intentional.
-dialyzer({nowarn_function, result_to_json/1}).
-spec result_to_json(term()) -> term().
result_to_json(Result) ->
    try
        _ = iolist_to_binary(json:encode(Result)),
        Result
    catch _:_ ->
        Bert = term_to_binary(Result, [compressed]),
        #{<<"_format">> => <<"bert">>,
          <<"_data">> => base64:encode(Bert)}
    end.

%%--------------------------------------------------------------------
%% Internal — JSONL decoding
%%--------------------------------------------------------------------

-spec parse_jsonl(binary()) -> {ok, cassette()} | {error, term()}.
parse_jsonl(Bin) ->
    {RawLines, Remaining} = beam_agent_jsonl:extract_lines(Bin),
    %% Include remaining partial line if non-empty (file without
    %% trailing newline is valid — defensive for hand-edited files)
    AllLines = case Remaining of
        <<>> -> RawLines;
        _ -> RawLines ++ [Remaining]
    end,
    case AllLines of
        [] ->
            {error, empty_cassette};
        [HeaderLine | EntryLines] ->
            case beam_agent_jsonl:decode_line(HeaderLine) of
                {ok, #{<<"version">> := 1} = Header} ->
                    decode_entries(Header, EntryLines);
                {ok, _} ->
                    {error, unsupported_cassette_version};
                {error, Reason} ->
                    {error, {invalid_header, Reason}}
            end
    end.

-spec decode_entries(map(), [binary()]) -> {ok, cassette()} | {error, term()}.
decode_entries(Header, Lines) ->
    try lists:map(fun decode_line_to_entry/1, Lines) of
        Entries ->
            Cassette = #{
                version => 1,
                entries => Entries,
                created_at => maps:get(<<"created_at">>, Header, 0),
                entry_count => length(Entries),
                metadata => maps:get(<<"metadata">>, Header, #{})
            },
            {ok, Cassette}
    catch
        throw:{bad_entry, Reason} ->
            {error, {invalid_entry, Reason}};
        error:Reason ->
            {error, {invalid_entry, Reason}}
    end.

-spec decode_line_to_entry(binary()) -> cassette_entry().
decode_line_to_entry(Line) ->
    case beam_agent_jsonl:decode_line(Line) of
        {ok, Map} -> json_to_entry(Map);
        {error, Reason} -> throw({bad_entry, Reason})
    end.

-spec json_to_entry(map()) -> cassette_entry().
json_to_entry(#{<<"prompt">> := Prompt, <<"result">> := ResultJson,
                <<"backend">> := Backend, <<"model">> := Model,
                <<"recorded_at">> := RecordedAt}) ->
    #{prompt => Prompt,
      result => json_to_result(ResultJson),
      backend => Backend,
      model => Model,
      recorded_at => RecordedAt};
json_to_entry(Map) when is_map(Map) ->
    throw({bad_entry, {missing_fields, maps:keys(Map)}}).

%% Decode a result from JSONL.  If the value is a BERT envelope,
%% decode the base64 payload.  Otherwise return the JSON value as-is.
-dialyzer({nowarn_function, json_to_result/1}).
-spec json_to_result(term()) -> term().
json_to_result(#{<<"_format">> := <<"bert">>, <<"_data">> := B64}) ->
    binary_to_term(base64:decode(B64), [safe]);
json_to_result(Result) ->
    Result.
