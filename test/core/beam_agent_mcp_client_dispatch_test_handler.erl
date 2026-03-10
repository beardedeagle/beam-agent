%%%-------------------------------------------------------------------
%%% @doc Test handler for beam_agent_mcp_client_dispatch tests.
%%%
%%% Implements the beam_agent_mcp_client_dispatch handler callbacks
%%% with simple in-memory responses for testing client-side dispatch
%%% routing and handler state threading.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_client_dispatch_test_handler).

-behaviour(beam_agent_mcp_client_dispatch).

-export([
    handle_sampling_create_message/2,
    handle_elicitation_create/2,
    handle_roots_list/1
]).

%%--------------------------------------------------------------------
%% Sampling
%%--------------------------------------------------------------------

handle_sampling_create_message(Params, HState) ->
    Messages = maps:get(<<"messages">>, Params, []),
    Role = case Messages of
        [#{<<"role">> := R} | _] -> R;
        _ -> <<"assistant">>
    end,
    Result = #{
        role => Role,
        model => <<"test-model">>,
        content => #{type => text, text => <<"Test sampling response">>}
    },
    {ok, Result, HState#{sampling_called => true}}.

%%--------------------------------------------------------------------
%% Elicitation
%%--------------------------------------------------------------------

handle_elicitation_create(Params, HState) ->
    Message = maps:get(<<"message">>, Params, <<"Confirm?">>),
    Result = #{
        action => accept,
        content => #{confirmed => true, message => Message}
    },
    {ok, Result, HState#{elicitation_called => true}}.

%%--------------------------------------------------------------------
%% Roots
%%--------------------------------------------------------------------

handle_roots_list(HState) ->
    Roots = [
        #{uri => <<"file:///workspace">>, name => <<"workspace">>},
        #{uri => <<"file:///home">>, name => <<"home">>}
    ],
    {ok, Roots, HState#{roots_called => true}}.
