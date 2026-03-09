-module(beam_agent_checkpoint).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for checkpoint and rewind support inside `beam_agent`.".

-export([
    ensure_table/0,
    clear/0,
    snapshot/3,
    rewind/2,
    list_checkpoints/1,
    get_checkpoint/2,
    delete_checkpoint/2,
    extract_file_paths/2
]).

-export_type([checkpoint/0, file_snapshot/0]).

-type checkpoint() :: beam_agent_checkpoint_core:checkpoint().
-type file_snapshot() :: beam_agent_checkpoint_core:file_snapshot().

ensure_table() -> beam_agent_checkpoint_core:ensure_table().
clear() -> beam_agent_checkpoint_core:clear().
snapshot(SessionId, UUID, Paths) -> beam_agent_checkpoint_core:snapshot(SessionId, UUID, Paths).
rewind(SessionId, UUID) -> beam_agent_checkpoint_core:rewind(SessionId, UUID).
list_checkpoints(SessionId) -> beam_agent_checkpoint_core:list_checkpoints(SessionId).
get_checkpoint(SessionId, UUID) -> beam_agent_checkpoint_core:get_checkpoint(SessionId, UUID).
delete_checkpoint(SessionId, UUID) -> beam_agent_checkpoint_core:delete_checkpoint(SessionId, UUID).
extract_file_paths(ToolName, ToolInput) -> beam_agent_checkpoint_core:extract_file_paths(ToolName, ToolInput).
