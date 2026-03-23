%%%-------------------------------------------------------------------
%%% @doc Crash-on-demand test provider for beam_agent_mcp_dispatch tests.
%%%
%%% All callbacks crash unconditionally by raising an error. Used to
%%% verify that safe_provider_call/4 isolates provider crashes and
%%% returns a JSON-RPC internal error instead of propagating the
%%% exception.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_dispatch_crash_provider).

-behaviour(beam_agent_mcp_dispatch).

-export([
    handle_resources_list/2,
    handle_resources_read/2,
    handle_resources_templates_list/2,
    handle_prompts_list/2,
    handle_prompts_get/3,
    handle_completion_complete/4,
    handle_logging_set_level/2
]).

%%--------------------------------------------------------------------
%% Resources
%%--------------------------------------------------------------------

handle_resources_list(_Cursor, _PState) ->
    error(simulated_crash).

handle_resources_read(_Uri, _PState) ->
    error(simulated_crash).

handle_resources_templates_list(_Cursor, _PState) ->
    error(simulated_crash).

%%--------------------------------------------------------------------
%% Prompts
%%--------------------------------------------------------------------

handle_prompts_list(_Cursor, _PState) ->
    error(simulated_crash).

handle_prompts_get(_Name, _Arguments, _PState) ->
    error(simulated_crash).

%%--------------------------------------------------------------------
%% Completions
%%--------------------------------------------------------------------

handle_completion_complete(_Ref, _Argument, _Context, _PState) ->
    error(simulated_crash).

%%--------------------------------------------------------------------
%% Logging
%%--------------------------------------------------------------------

handle_logging_set_level(_Level, _PState) ->
    error(simulated_crash).
