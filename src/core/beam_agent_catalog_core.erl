-module(beam_agent_catalog_core).
-moduledoc false.

-export([
    list_tools/1,
    list_skills/1,
    list_plugins/1,
    list_mcp_servers/1,
    list_agents/1,
    get_tool/2,
    get_skill/2,
    get_plugin/2,
    get_agent/2,
    current_agent/1,
    set_default_agent/2,
    clear_default_agent/1
]).

-type catalog_entry() :: map().
-type catalog_entries() :: [catalog_entry()].
-type metadata_key() :: agents | mcp_servers | plugins | skills | tools.
-type native_metadata_function() :: list_server_agents | skills_list.

-doc "List tools for a session.".
-spec list_tools(pid()) -> {ok, catalog_entries()} | {error, term()}.
list_tools(Session) ->
    metadata_list(Session, tools).

-doc "List skills for a session.".
-spec list_skills(pid()) -> {ok, catalog_entries()} | {error, term()}.
list_skills(Session) ->
    case maybe_native_list(Session, skills_list) of
        {ok, Skills} when is_list(Skills) ->
            {ok, Skills};
        _ ->
            metadata_list(Session, skills)
    end.

-doc "List plugins for a session.".
-spec list_plugins(pid()) -> {ok, catalog_entries()} | {error, term()}.
list_plugins(Session) ->
    metadata_list(Session, plugins).

-doc "List MCP servers for a session.".
-spec list_mcp_servers(pid()) -> {ok, catalog_entries()} | {error, term()}.
list_mcp_servers(Session) ->
    metadata_list(Session, mcp_servers).

-doc "List agents for a session.".
-spec list_agents(pid()) -> {ok, catalog_entries()} | {error, term()}.
list_agents(Session) ->
    case maybe_native_list(Session, list_server_agents) of
        {ok, Agents} when is_list(Agents) ->
            {ok, Agents};
        _ ->
            metadata_list(Session, agents)
    end.

-doc "Look up a single tool by id/name/path.".
-spec get_tool(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_tool(Session, ToolId) when is_binary(ToolId) ->
    get_entry(fun list_tools/1, Session, ToolId).

-doc "Look up a single skill by id/name/path.".
-spec get_skill(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_skill(Session, SkillId) when is_binary(SkillId) ->
    get_entry(fun list_skills/1, Session, SkillId).

-doc "Look up a single plugin by id/name/path.".
-spec get_plugin(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_plugin(Session, PluginId) when is_binary(PluginId) ->
    get_entry(fun list_plugins/1, Session, PluginId).

-doc "Look up a single agent by id/name/path.".
-spec get_agent(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_agent(Session, AgentId) when is_binary(AgentId) ->
    get_entry(fun list_agents/1, Session, AgentId).

-doc "Return the currently selected default agent for a session.".
-spec current_agent(pid()) -> {ok, binary()} | {error, not_set}.
current_agent(Session) ->
    beam_agent_runtime_core:current_agent(Session).

-doc """
Set the default agent for future queries on this session.

This is a truthful shared mutation because `agent` is already part of the
unified query/session option shape and can be merged into future requests.
""".
-spec set_default_agent(pid(), binary()) -> ok.
set_default_agent(Session, AgentId) when is_binary(AgentId) ->
    beam_agent_runtime_core:set_agent(Session, AgentId).

-doc "Clear any default-agent override for this session.".
-spec clear_default_agent(pid()) -> ok.
clear_default_agent(Session) ->
    beam_agent_runtime_core:clear_agent(Session).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec metadata_list(pid(), metadata_key()) ->
    {ok, catalog_entries()} | {error, term()}.
metadata_list(Session, Key) ->
    case session_info(Session) of
        {ok, Info} ->
            {ok, extract_metadata_list(Info, Key)};
        {error, _} = Error ->
            Error
    end.

-spec maybe_native_list(pid(), native_metadata_function()) ->
    {ok, catalog_entries()} | {error, term()}.
maybe_native_list(Session, Function) ->
    case beam_agent_raw_core:call(Session, Function, []) of
        {ok, List} when is_list(List) ->
            {ok, normalize_entries(List)};
        {ok, Map} when is_map(Map) ->
            normalize_native_map(Map);
        {error, _} = Error ->
            Error;
        _ ->
            {error, unsupported}
    end.

-spec normalize_native_map(map()) -> {ok, catalog_entries()}.
normalize_native_map(#{skills := Skills}) when is_list(Skills) ->
    {ok, normalize_entries(Skills)};
normalize_native_map(#{agents := Agents}) when is_list(Agents) ->
    {ok, normalize_entries(Agents)};
normalize_native_map(#{<<"skills">> := Skills}) when is_list(Skills) ->
    {ok, normalize_entries(Skills)};
normalize_native_map(#{<<"agents">> := Agents}) when is_list(Agents) ->
    {ok, normalize_entries(Agents)};
normalize_native_map(#{items := Items}) when is_list(Items) ->
    {ok, normalize_entries(Items)};
normalize_native_map(#{<<"items">> := Items}) when is_list(Items) ->
    {ok, normalize_entries(Items)};
normalize_native_map(_Other) ->
    {ok, []}.

-spec get_entry(fun((pid()) -> {ok, catalog_entries()} | {error, term()}),
                pid(),
                binary()) ->
    {ok, catalog_entry()} | {error, not_found | term()}.
get_entry(Fun, Session, EntryId) ->
    case Fun(Session) of
        {ok, Entries} ->
            case find_entry(Entries, EntryId) of
                {ok, Entry} -> {ok, Entry};
                error -> {error, not_found}
            end;
        {error, _} = Error ->
            Error
    end.

-spec find_entry(catalog_entries(), binary()) -> {ok, catalog_entry()} | error.
find_entry([], _EntryId) ->
    error;
find_entry([Entry | Rest], EntryId) when is_map(Entry) ->
    case entry_matches(Entry, EntryId) of
        true -> {ok, Entry};
        false -> find_entry(Rest, EntryId)
    end;
find_entry([_Other | Rest], EntryId) ->
    find_entry(Rest, EntryId).

-spec entry_matches(map(), binary()) -> boolean().
entry_matches(Entry, EntryId) ->
    CandidateKeys = [id, name, path, <<"id">>, <<"name">>, <<"path">>],
    lists:any(fun(Key) ->
        case maps:get(Key, Entry, undefined) of
            EntryId -> true;
            _ -> false
        end
    end, CandidateKeys).

-spec extract_metadata_list(map(), metadata_key()) -> catalog_entries().
extract_metadata_list(Info, Key) ->
    SystemInfo = maps:get(system_info, Info, #{}),
    case maps:get(Key, SystemInfo,
           maps:get(atom_to_binary(Key), SystemInfo, [])) of
        List when is_list(List) ->
            normalize_entries(List);
        _ ->
            []
    end.

-spec normalize_entries(list()) -> catalog_entries().
normalize_entries(Entries) ->
    [normalize_entry(Entry) || Entry <- Entries].

-spec normalize_entry(term()) -> map().
normalize_entry(Entry) when is_map(Entry) ->
    Entry;
normalize_entry(Value) when is_binary(Value) ->
    #{id => Value, name => Value};
normalize_entry(Value) ->
    #{value => Value}.

-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    try gen_statem:call(Session, session_info, 5000) of
        {ok, Info} when is_map(Info) -> {ok, Info};
        Other -> {error, {invalid_session_info, Other}}
    catch
        exit:Reason -> {error, Reason}
    end.
