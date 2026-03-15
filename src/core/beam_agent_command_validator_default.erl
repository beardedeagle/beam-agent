-module(beam_agent_command_validator_default).
-moduledoc false.

%% Default validator implementation for Layer 2.
%%
%% Defers entirely to the static policy result from Layer 1:
%% - allow  → allow
%% - deny   → pass through the denial reason
%% - ask    → allow for list-form, deny for string-form
%%
%% This validator is intentionally simple. For deep inspection,
%% intent-based reasoning, or external security integration,
%% implement the beam_agent_command_validator behaviour directly.

-behaviour(beam_agent_command_validator).

-export([validate/2]).

%%--------------------------------------------------------------------
%% beam_agent_command_validator callbacks
%%--------------------------------------------------------------------

-doc "Validate a command by deferring to the static policy result.".
-spec validate(beam_agent_command_parser:command_struct(),
               beam_agent_command_validator:validation_context()) ->
    allow | {deny, binary()}.
validate(_Command, #{policy_result := allow}) ->
    allow;
validate(_Command, #{policy_result := {deny, Reason}}) ->
    {deny, Reason};
validate(_Command, #{policy_result := ask, command_form := list}) ->
    allow;
validate(_Command, #{policy_result := ask}) ->
    {deny, <<"String-form command requires explicit allowlisting">>}.
