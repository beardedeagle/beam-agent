-module(beam_agent_threads).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for the unified thread store inside `beam_agent`.".

-export([
    ensure_table/0,
    clear/0,
    start_thread/2,
    fork_thread/3,
    resume_thread/2,
    list_threads/1,
    get_thread/2,
    read_thread/2,
    read_thread/3,
    delete_thread/2,
    archive_thread/2,
    unarchive_thread/2,
    rollback_thread/3,
    record_thread_message/3,
    get_thread_messages/2,
    thread_count/1,
    active_thread/1,
    set_active_thread/2,
    clear_active_thread/1
]).

-export_type([thread_meta/0, thread_opts/0]).

-type thread_meta() :: beam_agent_threads_core:thread_meta().
-type thread_opts() :: beam_agent_threads_core:thread_opts().

ensure_table() -> beam_agent_threads_core:ensure_table().
clear() -> beam_agent_threads_core:clear().
start_thread(SessionId, Opts) -> beam_agent_threads_core:start_thread(SessionId, Opts).
fork_thread(SessionId, ThreadId, Opts) -> beam_agent_threads_core:fork_thread(SessionId, ThreadId, Opts).
resume_thread(SessionId, ThreadId) -> beam_agent_threads_core:resume_thread(SessionId, ThreadId).
list_threads(SessionId) -> beam_agent_threads_core:list_threads(SessionId).
get_thread(SessionId, ThreadId) -> beam_agent_threads_core:get_thread(SessionId, ThreadId).
read_thread(SessionId, ThreadId) -> beam_agent_threads_core:read_thread(SessionId, ThreadId).
read_thread(SessionId, ThreadId, Opts) -> beam_agent_threads_core:read_thread(SessionId, ThreadId, Opts).
delete_thread(SessionId, ThreadId) -> beam_agent_threads_core:delete_thread(SessionId, ThreadId).
archive_thread(SessionId, ThreadId) -> beam_agent_threads_core:archive_thread(SessionId, ThreadId).
unarchive_thread(SessionId, ThreadId) -> beam_agent_threads_core:unarchive_thread(SessionId, ThreadId).
rollback_thread(SessionId, ThreadId, Selector) ->
    beam_agent_threads_core:rollback_thread(SessionId, ThreadId, Selector).
record_thread_message(SessionId, ThreadId, Message) ->
    beam_agent_threads_core:record_thread_message(SessionId, ThreadId, Message).
get_thread_messages(SessionId, ThreadId) ->
    beam_agent_threads_core:get_thread_messages(SessionId, ThreadId).
thread_count(SessionId) -> beam_agent_threads_core:thread_count(SessionId).
active_thread(SessionId) -> beam_agent_threads_core:active_thread(SessionId).
set_active_thread(SessionId, ThreadId) -> beam_agent_threads_core:set_active_thread(SessionId, ThreadId).
clear_active_thread(SessionId) -> beam_agent_threads_core:clear_active_thread(SessionId).
