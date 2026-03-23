-module(beam_agent_redaction_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% github_token variants
%% ---------------------------------------------------------------------------

github_token_atom_key_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{github_token => <<"ghp_secret">>}),
    ?assertEqual(redacted, maps:get(github_token, Result)).

github_token_binary_key_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"github_token">> => <<"ghp_secret">>}),
    ?assertEqual(redacted, maps:get(<<"github_token">>, Result)).

github_token_camel_case_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"githubToken">> => <<"ghp_secret">>}),
    ?assertEqual(redacted, maps:get(<<"githubToken">>, Result)).

github_token_upper_env_style_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"GITHUB_TOKEN">> => <<"ghp_secret">>}),
    ?assertEqual(redacted, maps:get(<<"GITHUB_TOKEN">>, Result)).

%% ---------------------------------------------------------------------------
%% Additional sensitive patterns
%% ---------------------------------------------------------------------------

personal_token_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"personalToken">> => <<"pat_secret">>}),
    ?assertEqual(redacted, maps:get(<<"personalToken">>, Result)).

personal_token_underscore_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"personal_token">> => <<"pat_secret">>}),
    ?assertEqual(redacted, maps:get(<<"personal_token">>, Result)).

private_key_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"private_key">> => <<"-----BEGIN RSA PRIVATE KEY-----">>}),
    ?assertEqual(redacted, maps:get(<<"private_key">>, Result)).

private_key_camel_case_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"privateKey">> => <<"-----BEGIN RSA PRIVATE KEY-----">>}),
    ?assertEqual(redacted, maps:get(<<"privateKey">>, Result)).

session_token_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"session_token">> => <<"sess_secret">>}),
    ?assertEqual(redacted, maps:get(<<"session_token">>, Result)).

session_token_camel_case_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"sessionToken">> => <<"sess_secret">>}),
    ?assertEqual(redacted, maps:get(<<"sessionToken">>, Result)).

credential_key_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"credential_key">> => <<"cred_secret">>}),
    ?assertEqual(redacted, maps:get(<<"credential_key">>, Result)).

credential_key_camel_case_is_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"credentialKey">> => <<"cred_secret">>}),
    ?assertEqual(redacted, maps:get(<<"credentialKey">>, Result)).

%% ---------------------------------------------------------------------------
%% Non-sensitive keys are NOT redacted
%% ---------------------------------------------------------------------------

username_is_not_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"username">> => <<"alice">>}),
    ?assertEqual(<<"alice">>, maps:get(<<"username">>, Result)).

model_is_not_redacted_test() ->
    Result = beam_agent_redaction:map(#{<<"model">> => <<"claude-3">>}),
    ?assertEqual(<<"claude-3">>, maps:get(<<"model">>, Result)).

%% ---------------------------------------------------------------------------
%% Nested map redaction
%% ---------------------------------------------------------------------------

github_token_nested_depth_2_is_redacted_test() ->
    Input = #{
        <<"config">> => #{
            <<"github_token">> => <<"ghp_deep_secret">>
        }
    },
    Result = beam_agent_redaction:map(Input),
    Inner = maps:get(<<"config">>, Result),
    ?assertEqual(redacted, maps:get(<<"github_token">>, Inner)).

github_token_nested_depth_3_is_redacted_test() ->
    Input = #{
        <<"provider">> => #{
            <<"auth">> => #{
                <<"github_token">> => <<"ghp_deep_secret">>
            }
        }
    },
    Result = beam_agent_redaction:map(Input),
    Auth = maps:get(<<"auth">>, maps:get(<<"provider">>, Result)),
    ?assertEqual(redacted, maps:get(<<"github_token">>, Auth)).

%% ---------------------------------------------------------------------------
%% map/1 with github_token
%% ---------------------------------------------------------------------------

map_redacts_github_token_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"github_token">> => <<"ghp_secret">>,
        <<"username">> => <<"alice">>
    },
    Result = beam_agent_redaction:map(Input),
    ?assertEqual(<<"claude-3">>, maps:get(<<"model">>, Result)),
    ?assertEqual(redacted, maps:get(<<"github_token">>, Result)),
    ?assertEqual(<<"alice">>, maps:get(<<"username">>, Result)).

%% ---------------------------------------------------------------------------
%% runtime_state/1 with github_token in provider
%% ---------------------------------------------------------------------------

runtime_state_redacts_github_token_in_provider_test() ->
    State = #{
        provider => #{
            <<"github_token">> => <<"ghp_secret">>,
            <<"model">> => <<"claude-3">>
        },
        session_id => <<"test">>
    },
    Result = beam_agent_redaction:runtime_state(State),
    Provider = maps:get(provider, Result),
    ?assertEqual(redacted, maps:get(<<"github_token">>, Provider)),
    ?assertEqual(<<"claude-3">>, maps:get(<<"model">>, Provider)),
    ?assertEqual(<<"test">>, maps:get(session_id, Result)).

%% ---------------------------------------------------------------------------
%% provider_config/1 with github_token
%% ---------------------------------------------------------------------------

provider_config_redacts_github_token_test() ->
    Config = #{
        <<"github_token">> => <<"ghp_secret">>,
        <<"endpoint">> => <<"https://api.example.com">>
    },
    Result = beam_agent_redaction:provider_config(Config),
    ?assertEqual(redacted, maps:get(<<"github_token">>, Result)),
    ?assertEqual(<<"https://api.example.com">>, maps:get(<<"endpoint">>, Result)).
