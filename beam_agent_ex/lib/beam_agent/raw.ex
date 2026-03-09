defmodule BeamAgent.Raw do
  @moduledoc """
  Minimal escape-hatch namespace for transport/debug access only.

  All user-visible features (threads, turns, skills, apps, files, MCP, accounts,
  fuzzy search, etc.) are available through the canonical `BeamAgent` module with
  universal fallbacks across all backends.

  This module exposes only the low-level primitives needed when callers must
  bypass the canonical routing layer entirely:
  - Transport identity inspection (`backend/1`, `adapter_module/1`)
  - Generic escape hatches (`call/3`, `call_backend/3`)
  - Native session access at the transport level
  - Transport-level health, status, and auth probes
  """

  defdelegate backend(session), to: :beam_agent_raw
  defdelegate adapter_module(session), to: :beam_agent_raw
  defdelegate call(session, function, args), to: :beam_agent_raw
  defdelegate call_backend(backend, function, args), to: :beam_agent_raw

  defdelegate list_native_sessions(), to: :beam_agent_raw
  defdelegate list_native_sessions(opts), to: :beam_agent_raw
  defdelegate get_native_session_messages(session_id), to: :beam_agent_raw
  defdelegate get_native_session_messages(session_id, opts), to: :beam_agent_raw

  defdelegate session_destroy(session), to: :beam_agent_raw
  defdelegate session_destroy(session, session_id), to: :beam_agent_raw
  defdelegate server_health(session), to: :beam_agent_raw
  defdelegate get_status(session), to: :beam_agent_raw
  defdelegate get_auth_status(session), to: :beam_agent_raw
  defdelegate get_last_session_id(session), to: :beam_agent_raw
end
