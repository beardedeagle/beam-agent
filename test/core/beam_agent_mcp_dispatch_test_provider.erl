%%%-------------------------------------------------------------------
%%% @doc Test provider for beam_agent_mcp_dispatch tests.
%%%
%%% Implements the beam_agent_mcp_dispatch provider callbacks with
%%% simple in-memory responses for testing dispatch routing and
%%% provider state threading.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_dispatch_test_provider).

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

handle_resources_list(_Cursor, PState) ->
    Resources = [#{uri => <<"file:///test.txt">>,
                   name => <<"test.txt">>,
                   mimeType => <<"text/plain">>}],
    {ok, {Resources, undefined}, PState}.

handle_resources_read(Uri, PState) ->
    Contents = [#{uri => Uri,
                  mimeType => <<"text/plain">>,
                  text => <<"Test content for ", Uri/binary>>}],
    {ok, Contents, PState}.

handle_resources_templates_list(_Cursor, PState) ->
    Templates = [#{uriTemplate => <<"file:///{path}">>,
                   name => <<"file">>}],
    {ok, {Templates, undefined}, PState}.

%%--------------------------------------------------------------------
%% Prompts
%%--------------------------------------------------------------------

handle_prompts_list(_Cursor, PState) ->
    Prompts = [#{name => <<"greet">>,
                 description => <<"Greet a user">>,
                 arguments => [#{name => <<"user">>,
                                 required => true}]}],
    {ok, {Prompts, undefined}, PState}.

handle_prompts_get(<<"greet">>, Arguments, PState) ->
    User = maps:get(<<"user">>, Arguments, <<"world">>),
    Messages = [#{role => <<"user">>,
                  content => #{type => text,
                               text => <<"Hello, ", User/binary, "!">>}}],
    {ok, {Messages, <<"Greeting prompt">>}, PState};
handle_prompts_get(Name, _Arguments, _PState) ->
    {error, -32602, <<"Unknown prompt: ", Name/binary>>}.

%%--------------------------------------------------------------------
%% Completions
%%--------------------------------------------------------------------

handle_completion_complete(_Ref, #{<<"value">> := Prefix}, _Context,
                           PState) ->
    Values = [<<Prefix/binary, "-completion-1">>,
              <<Prefix/binary, "-completion-2">>],
    {ok, #{values => Values, hasMore => false}, PState};
handle_completion_complete(_Ref, _Argument, _Context, PState) ->
    {ok, #{values => [], hasMore => false}, PState}.

%%--------------------------------------------------------------------
%% Logging
%%--------------------------------------------------------------------

handle_logging_set_level(Level, PState) ->
    {ok, PState#{log_level => Level}}.
