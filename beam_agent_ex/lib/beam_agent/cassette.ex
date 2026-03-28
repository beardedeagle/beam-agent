defmodule BeamAgent.Cassette do
  @moduledoc """
  Elixir facade for VCR-style cassette recording and replay.

  Record CLI interactions for deterministic replay in tests without
  network dependencies or token costs.

  ## Quick Start

      {:ok, session} = BeamAgent.start_session(%{backend: :claude})
      :ok = BeamAgent.Cassette.start_recording(session)
      {:ok, _} = BeamAgent.query(session, "What is OTP?")
      {:ok, cassette} = BeamAgent.Cassette.stop_recording(session)

      # Save to disk (JSONL — human-readable, canonical)
      :ok = BeamAgent.Cassette.export(cassette, "test/fixtures/otp.jsonl")

      # Replay in tests
      {:ok, loaded} = BeamAgent.Cassette.import("test/fixtures/otp.jsonl")
      {:ok, session2} = BeamAgent.start_session(%{backend: :claude})
      :ok = BeamAgent.Cassette.start_replay(session2, loaded)
      {:ok, entry} = BeamAgent.Cassette.replay_next(session2)

  ## Disk Formats

  JSONL is the canonical format — human-readable, diffable, one JSON
  object per line.  BERT is a derived format for fast runtime loading.

      # Compile JSONL to BERT for production replay
      :ok = BeamAgent.Cassette.compile("fixtures/otp.jsonl", "fixtures/otp.bert")
  """

  @typedoc "A sealed cassette with version, entries, metadata."
  @type cassette :: :beam_agent_cassette.cassette()

  @typedoc "A single recorded entry (prompt, result, backend, model, timestamp)."
  @type cassette_entry :: :beam_agent_cassette.cassette_entry()

  # Recording

  @doc "Start recording for a session."
  @spec start_recording(term()) :: :ok | {:error, :already_recording}
  defdelegate start_recording(session_id), to: :beam_agent_cassette

  @doc "Record a query/response entry for a session."
  @spec record_entry(term(), binary(), term(), binary(), binary()) ::
          :ok | {:error, :not_recording}
  defdelegate record_entry(session_id, prompt, result, backend, model),
    to: :beam_agent_cassette

  @doc "Stop recording and return the sealed cassette."
  @spec stop_recording(term()) :: {:ok, cassette()} | {:error, :not_recording}
  defdelegate stop_recording(session_id), to: :beam_agent_cassette

  @doc "Check if a session is currently recording."
  @spec is_recording(term()) :: boolean()
  defdelegate is_recording(session_id), to: :beam_agent_cassette

  # Replay

  @doc "Load a cassette for replay on a session."
  @spec start_replay(term(), cassette()) :: :ok | {:error, term()}
  defdelegate start_replay(session_id, cassette), to: :beam_agent_cassette

  @doc "Return the next recorded entry, or `:done` when exhausted."
  @spec replay_next(term()) ::
          {:ok, cassette_entry()} | :done | {:error, :not_replaying}
  defdelegate replay_next(session_id), to: :beam_agent_cassette

  @doc "Stop replay and remove the session's replay state."
  @spec stop_replay(term()) :: :ok
  defdelegate stop_replay(session_id), to: :beam_agent_cassette

  @doc "Check if a session is currently in replay mode."
  @spec is_replaying(term()) :: boolean()
  defdelegate is_replaying(session_id), to: :beam_agent_cassette

  # Disk I/O — canonical (JSONL)

  @doc "Export a cassette using the canonical JSONL format."
  @spec export(cassette(), Path.t()) :: :ok | {:error, term()}
  defdelegate export(cassette, file_path), to: :beam_agent_cassette

  @doc "Import a cassette, auto-detecting the format (JSONL or BERT)."
  @spec import(Path.t()) :: {:ok, cassette()} | {:error, term()}
  # import is a special form in Elixir, so delegate explicitly
  def import(file_path) do
    :beam_agent_cassette.import(file_path)
  end

  # Disk I/O — explicit format

  @doc "Export a cassette as JSONL."
  @spec export_jsonl(cassette(), Path.t()) :: :ok | {:error, term()}
  defdelegate export_jsonl(cassette, file_path), to: :beam_agent_cassette

  @doc "Export a cassette as compressed BERT."
  @spec export_bert(cassette(), Path.t()) :: :ok | {:error, term()}
  defdelegate export_bert(cassette, file_path), to: :beam_agent_cassette

  @doc "Import a cassette from a JSONL file."
  @spec import_jsonl(Path.t()) :: {:ok, cassette()} | {:error, term()}
  defdelegate import_jsonl(file_path), to: :beam_agent_cassette

  @doc "Import a cassette from a BERT file."
  @spec import_bert(Path.t()) :: {:ok, cassette()} | {:error, term()}
  defdelegate import_bert(file_path), to: :beam_agent_cassette

  # Conversion

  @doc "Compile a JSONL cassette into BERT format for fast loading."
  @spec compile(Path.t(), Path.t()) :: :ok | {:error, term()}
  defdelegate compile(jsonl_path, bert_path), to: :beam_agent_cassette

  # Lifecycle

  @doc "Clear all recording and replay state."
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_cassette
end
