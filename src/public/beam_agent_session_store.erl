-module(beam_agent_session_store).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for the unified session history store inside `beam_agent`.".

-export([
    ensure_tables/0,
    clear/0,
    register_session/2,
    update_session/2,
    get_session/1,
    delete_session/1,
    list_sessions/0,
    list_sessions/1,
    fork_session/2,
    revert_session/2,
    unrevert_session/1,
    share_session/1,
    share_session/2,
    unshare_session/1,
    get_share/1,
    summarize_session/1,
    summarize_session/2,
    get_summary/1,
    record_message/2,
    record_messages/2,
    get_session_messages/1,
    get_session_messages/2,
    session_count/0,
    message_count/1
]).

-export_type([
    session_meta/0,
    list_opts/0,
    message_opts/0,
    session_share/0,
    session_summary/0
]).

-type session_meta() :: beam_agent_session_store_core:session_meta().
-type list_opts() :: beam_agent_session_store_core:list_opts().
-type message_opts() :: beam_agent_session_store_core:message_opts().
-type session_share() :: beam_agent_session_store_core:session_share().
-type session_summary() :: beam_agent_session_store_core:session_summary().

ensure_tables() -> beam_agent_session_store_core:ensure_tables().
clear() -> beam_agent_session_store_core:clear().
register_session(SessionId, Meta) -> beam_agent_session_store_core:register_session(SessionId, Meta).
update_session(SessionId, Patch) -> beam_agent_session_store_core:update_session(SessionId, Patch).
get_session(SessionId) -> beam_agent_session_store_core:get_session(SessionId).
delete_session(SessionId) -> beam_agent_session_store_core:delete_session(SessionId).
list_sessions() -> beam_agent_session_store_core:list_sessions().
list_sessions(Opts) -> beam_agent_session_store_core:list_sessions(Opts).
fork_session(SessionId, Opts) -> beam_agent_session_store_core:fork_session(SessionId, Opts).
revert_session(SessionId, Selector) -> beam_agent_session_store_core:revert_session(SessionId, Selector).
unrevert_session(SessionId) -> beam_agent_session_store_core:unrevert_session(SessionId).
share_session(SessionId) -> beam_agent_session_store_core:share_session(SessionId).
share_session(SessionId, Opts) -> beam_agent_session_store_core:share_session(SessionId, Opts).
unshare_session(SessionId) -> beam_agent_session_store_core:unshare_session(SessionId).
get_share(SessionId) -> beam_agent_session_store_core:get_share(SessionId).
summarize_session(SessionId) -> beam_agent_session_store_core:summarize_session(SessionId).
summarize_session(SessionId, Opts) -> beam_agent_session_store_core:summarize_session(SessionId, Opts).
get_summary(SessionId) -> beam_agent_session_store_core:get_summary(SessionId).
record_message(SessionId, Message) -> beam_agent_session_store_core:record_message(SessionId, Message).
record_messages(SessionId, Messages) -> beam_agent_session_store_core:record_messages(SessionId, Messages).
get_session_messages(SessionId) -> beam_agent_session_store_core:get_session_messages(SessionId).
get_session_messages(SessionId, Opts) -> beam_agent_session_store_core:get_session_messages(SessionId, Opts).
session_count() -> beam_agent_session_store_core:session_count().
message_count(SessionId) -> beam_agent_session_store_core:message_count(SessionId).
