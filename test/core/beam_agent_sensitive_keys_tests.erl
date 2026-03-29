%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_sensitive_keys.
%%%
%%% Tests cover:
%%%   - Registry completeness and type validity
%%%   - Credential match key generation (atom + camelCase + snake_case)
%%%   - Redaction match key generation (canonical lowercase binaries)
%%%   - is_sensitive/1 across all key formats
%%%   - Superset property: every credential key also appears in redaction
%%%   - No duplicates in generated lists
%%%   - Backward compatibility with former inline lists
%%%   - snake_to_camel and canonical_form helpers
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_sensitive_keys_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Registry completeness
%%====================================================================

all_returns_18_entries_test() ->
    ?assertEqual(18, length(beam_agent_sensitive_keys:all())).

all_entries_have_valid_types_test() ->
    ValidCategories = [credential, auth, session, oauth],
    ValidHandlings = [encrypt_and_redact, redact_only],
    lists:foreach(fun({Name, Cat, Handling}) ->
        ?assert(is_atom(Name)),
        ?assert(lists:member(Cat, ValidCategories)),
        ?assert(lists:member(Handling, ValidHandlings))
    end, beam_agent_sensitive_keys:all()).

no_duplicate_canonical_names_test() ->
    Names = [Name || {Name, _, _} <- beam_agent_sensitive_keys:all()],
    ?assertEqual(length(Names), length(lists:usort(Names))).

nine_encrypt_and_redact_entries_test() ->
    EncryptKeys = [Name || {Name, _, encrypt_and_redact} <- beam_agent_sensitive_keys:all()],
    ?assertEqual(9, length(EncryptKeys)),
    Expected = [api_key, token, access_token, refresh_token,
                client_secret, secret, password, private_key, github_token],
    ?assertEqual(lists:sort(Expected), lists:sort(EncryptKeys)).

nine_redact_only_entries_test() ->
    RedactKeys = [Name || {Name, _, redact_only} <- beam_agent_sensitive_keys:all()],
    ?assertEqual(9, length(RedactKeys)),
    Expected = [authorization, authorization_code, bearer_token, code_verifier,
                credential_key, id_token, oauth_token, personal_token, session_token],
    ?assertEqual(lists:sort(Expected), lists:sort(RedactKeys)).

%%====================================================================
%% Credential match keys
%%====================================================================

credential_keys_excludes_redact_only_test() ->
    CredKeys = beam_agent_sensitive_keys:credential_match_keys(),
    %% None of the redact_only canonical atoms should appear
    RedactOnlyAtoms = [Name || {Name, _, redact_only} <- beam_agent_sensitive_keys:all()],
    lists:foreach(fun(Name) ->
        ?assertNot(lists:member(Name, CredKeys))
    end, RedactOnlyAtoms).

credential_keys_multi_word_have_three_variants_test() ->
    CredKeys = beam_agent_sensitive_keys:credential_match_keys(),
    %% api_key should produce [api_key, <<"apiKey">>, <<"api_key">>]
    ?assert(lists:member(api_key, CredKeys)),
    ?assert(lists:member(<<"apiKey">>, CredKeys)),
    ?assert(lists:member(<<"api_key">>, CredKeys)).

credential_keys_single_word_have_two_variants_test() ->
    CredKeys = beam_agent_sensitive_keys:credential_match_keys(),
    %% token should produce [token, <<"token">>]
    ?assert(lists:member(token, CredKeys)),
    ?assert(lists:member(<<"token">>, CredKeys)).

credential_keys_no_duplicates_test() ->
    CredKeys = beam_agent_sensitive_keys:credential_match_keys(),
    ?assertEqual(length(CredKeys), length(lists:usort(CredKeys))).

%% Backward compatibility: the generated list must contain every
%% element that the former ?SENSITIVE_KEYS macro contained.
credential_keys_backward_compatible_test() ->
    OldMacro = [api_key, <<"apiKey">>, <<"api_key">>,
                token, <<"token">>,
                access_token, <<"accessToken">>, <<"access_token">>,
                refresh_token, <<"refreshToken">>, <<"refresh_token">>,
                client_secret, <<"clientSecret">>, <<"client_secret">>,
                secret, <<"secret">>,
                password, <<"password">>,
                private_key, <<"privateKey">>, <<"private_key">>,
                github_token, <<"githubToken">>, <<"github_token">>],
    CredKeys = beam_agent_sensitive_keys:credential_match_keys(),
    lists:foreach(fun(Key) ->
        ?assert(lists:member(Key, CredKeys),
                io_lib:format("Missing from credential_match_keys: ~p", [Key]))
    end, OldMacro).

%%====================================================================
%% Redaction match keys
%%====================================================================

redaction_keys_contains_all_18_canonical_forms_test() ->
    RedactKeys = beam_agent_sensitive_keys:redaction_match_keys(),
    ?assertEqual(18, length(RedactKeys)).

redaction_keys_all_lowercase_no_separators_test() ->
    RedactKeys = beam_agent_sensitive_keys:redaction_match_keys(),
    lists:foreach(fun(Key) ->
        ?assert(is_binary(Key)),
        ?assertEqual(nomatch, binary:match(Key, <<"_">>)),
        ?assertEqual(Key, string:lowercase(Key))
    end, RedactKeys).

redaction_keys_no_duplicates_test() ->
    RedactKeys = beam_agent_sensitive_keys:redaction_match_keys(),
    ?assertEqual(length(RedactKeys), length(lists:usort(RedactKeys))).

%% Backward compatibility: the generated list must contain every
%% element that the former hardcoded list in redaction contained.
redaction_keys_backward_compatible_test() ->
    OldList = [<<"accesstoken">>, <<"apikey">>, <<"authorization">>,
               <<"authorizationcode">>, <<"bearertoken">>, <<"clientsecret">>,
               <<"codeverifier">>, <<"credentialkey">>, <<"githubtoken">>,
               <<"idtoken">>, <<"oauthtoken">>, <<"password">>,
               <<"personaltoken">>, <<"privatekey">>, <<"refreshtoken">>,
               <<"secret">>, <<"sessiontoken">>, <<"token">>],
    RedactKeys = beam_agent_sensitive_keys:redaction_match_keys(),
    lists:foreach(fun(Key) ->
        ?assert(lists:member(Key, RedactKeys),
                io_lib:format("Missing from redaction_match_keys: ~p", [Key]))
    end, OldList).

%%====================================================================
%% Superset property
%%====================================================================

every_credential_key_appears_in_redaction_test() ->
    CredNames = [Name || {Name, _, encrypt_and_redact} <- beam_agent_sensitive_keys:all()],
    RedactKeys = beam_agent_sensitive_keys:redaction_match_keys(),
    lists:foreach(fun(Name) ->
        Canonical = beam_agent_sensitive_keys:canonical_form(Name),
        ?assert(lists:member(Canonical, RedactKeys),
                io_lib:format("Credential key ~p missing from redaction: ~p", [Name, Canonical]))
    end, CredNames).

%%====================================================================
%% is_sensitive/1
%%====================================================================

is_sensitive_atom_key_test() ->
    ?assert(beam_agent_sensitive_keys:is_sensitive(api_key)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(token)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(password)).

is_sensitive_camel_case_binary_test() ->
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"apiKey">>)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"accessToken">>)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"refreshToken">>)).

is_sensitive_snake_case_binary_test() ->
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"api_key">>)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"access_token">>)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"private_key">>)).

is_sensitive_upper_case_binary_test() ->
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"API_KEY">>)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"GITHUB_TOKEN">>)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"PASSWORD">>)).

is_sensitive_redact_only_keys_test() ->
    ?assert(beam_agent_sensitive_keys:is_sensitive(authorization)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"bearerToken">>)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"session_token">>)),
    ?assert(beam_agent_sensitive_keys:is_sensitive(<<"CREDENTIAL_KEY">>)).

is_sensitive_non_sensitive_returns_false_test() ->
    ?assertNot(beam_agent_sensitive_keys:is_sensitive(username)),
    ?assertNot(beam_agent_sensitive_keys:is_sensitive(<<"model">>)),
    ?assertNot(beam_agent_sensitive_keys:is_sensitive(<<"baseUrl">>)),
    ?assertNot(beam_agent_sensitive_keys:is_sensitive(<<"ORGANIZATION">>)).

%%====================================================================
%% Helper: snake_to_camel
%%====================================================================

snake_to_camel_multi_word_test() ->
    ?assertEqual(<<"apiKey">>, beam_agent_sensitive_keys:snake_to_camel(<<"api_key">>)),
    ?assertEqual(<<"accessToken">>, beam_agent_sensitive_keys:snake_to_camel(<<"access_token">>)),
    ?assertEqual(<<"clientSecret">>, beam_agent_sensitive_keys:snake_to_camel(<<"client_secret">>)),
    ?assertEqual(<<"githubToken">>, beam_agent_sensitive_keys:snake_to_camel(<<"github_token">>)).

snake_to_camel_single_word_test() ->
    ?assertEqual(<<"token">>, beam_agent_sensitive_keys:snake_to_camel(<<"token">>)),
    ?assertEqual(<<"secret">>, beam_agent_sensitive_keys:snake_to_camel(<<"secret">>)).

%%====================================================================
%% Helper: canonical_form
%%====================================================================

canonical_form_strips_underscores_test() ->
    ?assertEqual(<<"apikey">>, beam_agent_sensitive_keys:canonical_form(api_key)),
    ?assertEqual(<<"accesstoken">>, beam_agent_sensitive_keys:canonical_form(access_token)),
    ?assertEqual(<<"authorizationcode">>, beam_agent_sensitive_keys:canonical_form(authorization_code)).

canonical_form_single_word_unchanged_test() ->
    ?assertEqual(<<"token">>, beam_agent_sensitive_keys:canonical_form(token)),
    ?assertEqual(<<"secret">>, beam_agent_sensitive_keys:canonical_form(secret)),
    ?assertEqual(<<"password">>, beam_agent_sensitive_keys:canonical_form(password)).

%%====================================================================
%% Helper: normalize_key
%%====================================================================

normalize_key_strips_and_lowercases_test() ->
    ?assertEqual(<<"apikey">>, beam_agent_sensitive_keys:normalize_key(<<"API_KEY">>)),
    ?assertEqual(<<"apikey">>, beam_agent_sensitive_keys:normalize_key(<<"apiKey">>)),
    ?assertEqual(<<"apikey">>, beam_agent_sensitive_keys:normalize_key(<<"api_key">>)),
    ?assertEqual(<<"apikey">>, beam_agent_sensitive_keys:normalize_key(<<"Api-Key">>)).
