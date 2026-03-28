-module(beam_agent_cassette).
-moduledoc """
Public API for VCR-style cassette recording and replay.

Record CLI interactions for deterministic replay in tests without
network dependencies or token costs.

## Quick Start

```erlang
%% Record a session
{ok, Session} = beam_agent:start_session(#{backend => claude}),
ok = beam_agent_cassette:start_recording(Session),
{ok, _} = beam_agent:query(Session, <<"What is OTP?">>),
{ok, Cassette} = beam_agent_cassette:stop_recording(Session),

%% Save to disk (JSONL — human-readable, canonical)
ok = beam_agent_cassette:export(Cassette, "test/fixtures/otp.jsonl"),

%% Replay in tests
{ok, Loaded} = beam_agent_cassette:import("test/fixtures/otp.jsonl"),
{ok, Session2} = beam_agent:start_session(#{backend => claude}),
ok = beam_agent_cassette:start_replay(Session2, Loaded),
{ok, Entry} = beam_agent_cassette:replay_next(Session2),
done = beam_agent_cassette:replay_next(Session2),
```

## Disk Formats

JSONL is the canonical format — human-readable, diffable, one JSON
object per line.  BERT is a derived format for fast runtime loading.

```erlang
%% Compile JSONL to BERT for production replay
ok = beam_agent_cassette:compile("fixtures/otp.jsonl", "fixtures/otp.bert"),
```

## Format Details

Each JSONL file is structured as:
  - Line 1: header with `version`, `created_at`, `entry_count`,
    `metadata`
  - Lines 2..N: entries with `prompt`, `result`, `backend`, `model`,
    `recorded_at`

Results are encoded as native JSON when possible (maps, lists,
binaries, numbers).  Non-JSON-encodable terms are automatically
wrapped in a BERT envelope for lossless round-tripping.

The BERT format preserves exact Erlang term structure and loads
faster than JSONL.  Use `compile/2` to pre-compile JSONL cassettes
for production replay.
""".

-export([
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
    %% Disk I/O — canonical
    export/2,
    import/1,
    %% Disk I/O — explicit format
    export_jsonl/2,
    export_bert/2,
    import_jsonl/1,
    import_bert/1,
    %% Conversion
    compile/2,
    %% Lifecycle
    clear/0
]).

-export_type([
    cassette/0,
    cassette_entry/0
]).

%% Dialyzer narrows cassette() through delegates more than the type
%% alias allows — supertypes are intentional for the public API.
-dialyzer({nowarn_function, [start_replay/2, export/2,
    export_jsonl/2, export_bert/2, compile/2]}).

%%--------------------------------------------------------------------
%% Types (re-exported from core)
%%--------------------------------------------------------------------

-type cassette() :: beam_agent_cassette_core:cassette().
-type cassette_entry() :: beam_agent_cassette_core:cassette_entry().

%%--------------------------------------------------------------------
%% Recording
%%--------------------------------------------------------------------

-doc """
Start recording for a session.

All subsequent calls to `record_entry/5` for this session will be
captured in order.  Returns `{error, already_recording}` if
recording is already active.
""".
-spec start_recording(term()) -> ok | {error, already_recording}.
start_recording(SessionId) ->
    beam_agent_cassette_core:start_recording(SessionId).

-doc """
Record a query/response entry for a session.

Typically called after a successful `beam_agent:query/2,3` to
capture the interaction for later replay.
""".
-spec record_entry(term(), binary(), term(), binary(), binary()) ->
    ok | {error, not_recording}.
record_entry(SessionId, Prompt, Result, Backend, Model) ->
    beam_agent_cassette_core:record_entry(
        SessionId, Prompt, Result, Backend, Model).

-doc """
Stop recording and return the sealed cassette.

The cassette contains all entries in the order they were recorded,
ready for export or replay.
""".
-spec stop_recording(term()) ->
    {ok, cassette()} | {error, not_recording}.
stop_recording(SessionId) ->
    beam_agent_cassette_core:stop_recording(SessionId).

-doc "Check if a session is currently recording.".
-spec is_recording(term()) -> boolean().
is_recording(SessionId) ->
    beam_agent_cassette_core:is_recording(SessionId).

%%--------------------------------------------------------------------
%% Replay
%%--------------------------------------------------------------------

-doc """
Load a cassette for replay on a session.

After starting replay, calls to `replay_next/1` return entries in
the order they were originally recorded.
""".
-spec start_replay(term(), cassette()) -> ok | {error, term()}.
start_replay(SessionId, Cassette) ->
    beam_agent_cassette_core:start_replay(SessionId, Cassette).

-doc """
Return the next recorded entry for replay.

Returns `{ok, Entry}` for the next entry, or `done` when the
cassette is exhausted.
""".
-spec replay_next(term()) ->
    {ok, cassette_entry()} | done | {error, not_replaying}.
replay_next(SessionId) ->
    beam_agent_cassette_core:replay_next(SessionId).

-doc "Stop replay and remove the session's replay state.".
-spec stop_replay(term()) -> ok.
stop_replay(SessionId) ->
    beam_agent_cassette_core:stop_replay(SessionId).

-doc "Check if a session is currently in replay mode.".
-spec is_replaying(term()) -> boolean().
is_replaying(SessionId) ->
    beam_agent_cassette_core:is_replaying(SessionId).

%%--------------------------------------------------------------------
%% Disk I/O — Canonical (JSONL)
%%--------------------------------------------------------------------

-doc """
Export a cassette using the canonical JSONL format.

JSONL files are human-readable, diffable, and version-control
friendly.  Use `compile/2` to convert to BERT for fast loading.
""".
-spec export(cassette(), file:filename_all()) -> ok | {error, term()}.
export(Cassette, FilePath) ->
    beam_agent_cassette_core:export_cassette(Cassette, FilePath).

-doc """
Import a cassette, auto-detecting the format.

Tries JSONL first (checks for a leading `{`), falls back to BERT.
""".
-spec import(file:filename_all()) ->
    {ok, cassette()} | {error, term()}.
import(FilePath) ->
    beam_agent_cassette_core:import_cassette(FilePath).

%%--------------------------------------------------------------------
%% Disk I/O — Explicit Format
%%--------------------------------------------------------------------

-doc "Export a cassette as JSONL (one JSON object per line).".
-spec export_jsonl(cassette(), file:filename_all()) ->
    ok | {error, term()}.
export_jsonl(Cassette, FilePath) ->
    beam_agent_cassette_core:export_jsonl(Cassette, FilePath).

-doc "Export a cassette as compressed BERT (fast loading).".
-spec export_bert(cassette(), file:filename_all()) ->
    ok | {error, term()}.
export_bert(Cassette, FilePath) ->
    beam_agent_cassette_core:export_bert(Cassette, FilePath).

-doc "Import a cassette from a JSONL file.".
-spec import_jsonl(file:filename_all()) ->
    {ok, cassette()} | {error, term()}.
import_jsonl(FilePath) ->
    beam_agent_cassette_core:import_jsonl(FilePath).

-doc "Import a cassette from a BERT file.".
-spec import_bert(file:filename_all()) ->
    {ok, cassette()} | {error, term()}.
import_bert(FilePath) ->
    beam_agent_cassette_core:import_bert(FilePath).

%%--------------------------------------------------------------------
%% Conversion
%%--------------------------------------------------------------------

-doc """
Compile a JSONL cassette into BERT format.

Reads the JSONL file, reconstructs the cassette, and writes it as
a compressed BERT file for fast loading at replay time.
""".
-spec compile(file:filename_all(), file:filename_all()) ->
    ok | {error, term()}.
compile(JsonlPath, BertPath) ->
    beam_agent_cassette_core:compile_cassette(JsonlPath, BertPath).

%%--------------------------------------------------------------------
%% Lifecycle
%%--------------------------------------------------------------------

-doc "Clear all recording and replay state.".
-spec clear() -> ok.
clear() ->
    beam_agent_cassette_core:clear().
