-module(beam_agent_error_core).
-moduledoc """
Structured error categorization for BeamAgent.

Provides two categorization mechanisms:

1. **Protocol-level** — Backend protocol modules set `category` directly
   when the wire format includes structured error data (HTTP status codes,
   typed error objects).  Protocol modules call `infer_category/1` on the
   error content, or set the category directly from structured data.

2. **Universal fallback** — `categorize/1` ensures every error message
   has a `category` field.  If the protocol module already set one, it
   passes through.  Otherwise, `infer_category/1` applies best-effort
   text pattern matching against the error content.

The `enrich/2` function is the integration point for
`beam_agent_core:add_fields(error, Raw, Base)`, extracting protocol-level
hints from the wire-format `Raw` map before applying the universal fallback.
""".

-export([
    categorize/1,
    infer_category/1,
    enrich/2,
    parse_retry_after/1
]).

-export_type([error_category/0]).

%%====================================================================
%% Types
%%====================================================================

-type error_category() ::
    rate_limit
  | subscription_exhausted
  | context_exceeded
  | auth_expired
  | server_error
  | unknown.

%%====================================================================
%% API
%%====================================================================

-doc """
Ensure an error message has a `category` field.

If the message already has a category (set by the protocol module),
it passes through unchanged.  Otherwise, `infer_category/1` is applied
to the `content` field.  Non-error messages are returned unchanged.
""".
-spec categorize(map()) -> map().
categorize(#{type := error, category := _} = Msg) ->
    Msg;
categorize(#{type := error, content := Content} = Msg) ->
    Msg#{category => infer_category(Content)};
categorize(#{type := error} = Msg) ->
    Msg#{category => unknown};
categorize(Msg) ->
    Msg.

-doc """
Enrich an error message from the `normalize_message/1` path.

Extracts protocol-level category and retry_after hints from the
wire-format `Raw` map (binary keys), then applies the universal
fallback via `categorize/1`.
""".
-spec enrich(map(), map()) -> map().
enrich(#{type := error} = Msg, Raw) ->
    Msg1 = apply_protocol_category(Msg, Raw),
    Msg2 = apply_retry_after(Msg1, Raw),
    categorize(Msg2);
enrich(Msg, _Raw) ->
    Msg.

-doc """
Infer an error category from the content text.

Uses case-insensitive substring matching against known error patterns.
Returns `unknown` if no pattern matches.  This is a pure function
suitable for use in protocol modules.
""".
-spec infer_category(binary() | term()) -> error_category().
infer_category(Content) when is_binary(Content) ->
    Lower = string:lowercase(Content),
    infer_from_text(Lower);
infer_category(_) ->
    unknown.

-doc """
Parse a retry-after value into seconds.

Accepts integers (pass-through), binaries of decimal digits,
or returns `undefined` for unparseable values.
""".
-spec parse_retry_after(term()) -> non_neg_integer() | undefined.
parse_retry_after(Seconds) when is_integer(Seconds), Seconds > 0 ->
    Seconds;
parse_retry_after(Bin) when is_binary(Bin) ->
    try binary_to_integer(Bin) of
        N when N > 0 -> N;
        _ -> undefined
    catch
        error:badarg -> undefined
    end;
parse_retry_after(N) when is_float(N), N > 0 ->
    ceil(N);
parse_retry_after(_) ->
    undefined.

%%====================================================================
%% Internal: text-based inference
%%====================================================================

-spec infer_from_text(binary()) -> error_category().
infer_from_text(Lower) ->
    Checks = [
        {fun matches_rate_limit/1,              rate_limit},
        {fun matches_subscription_exhausted/1,  subscription_exhausted},
        {fun matches_context_exceeded/1,        context_exceeded},
        {fun matches_auth_expired/1,            auth_expired},
        {fun matches_server_error/1,            server_error}
    ],
    first_match(Checks, Lower).

-spec first_match([{fun((binary()) -> boolean()), error_category()}],
                  binary()) -> error_category().
first_match([], _Lower) ->
    unknown;
first_match([{Pred, Category} | Rest], Lower) ->
    case Pred(Lower) of
        true  -> Category;
        false -> first_match(Rest, Lower)
    end.

-spec matches_rate_limit(binary()) -> boolean().
matches_rate_limit(T) ->
    has_any(T, [<<"rate limit">>, <<"rate_limit">>, <<"ratelimit">>,
                <<"too many requests">>, <<"429">>,
                <<"throttled">>, <<"throttling">>]).

-spec matches_subscription_exhausted(binary()) -> boolean().
matches_subscription_exhausted(T) ->
    has_any(T, [<<"quota exceeded">>, <<"quota_exceeded">>,
                <<"usage cap">>, <<"usage limit">>,
                <<"plan limit">>, <<"subscription limit">>,
                <<"billing">>, <<"credits exhausted">>,
                <<"tokens exhausted">>]).

-spec matches_context_exceeded(binary()) -> boolean().
matches_context_exceeded(T) ->
    has_any(T, [<<"context length">>, <<"context window">>,
                <<"context_length">>, <<"context_window">>,
                <<"token limit">>, <<"too many tokens">>,
                <<"maximum context">>, <<"max_tokens">>,
                <<"input too long">>]).

-spec matches_auth_expired(binary()) -> boolean().
matches_auth_expired(T) ->
    has_any(T, [<<"unauthorized">>, <<"unauthenticated">>,
                <<"invalid api key">>, <<"invalid_api_key">>,
                <<"api key expired">>, <<"token expired">>,
                <<"access denied">>, <<"forbidden">>,
                <<"401 ">>, <<"403 ">>]).

-spec matches_server_error(binary()) -> boolean().
matches_server_error(T) ->
    has_any(T, [<<"internal server error">>, <<"server error">>,
                <<"service unavailable">>, <<"bad gateway">>,
                <<"gateway timeout">>, <<"overloaded">>,
                <<"500 ">>, <<"502 ">>, <<"503 ">>, <<"504 ">>]).

-spec has_any(binary(), [binary()]) -> boolean().
has_any(Haystack, Needles) ->
    lists:any(fun(Needle) ->
        binary:match(Haystack, Needle) =/= nomatch
    end, Needles).

%%====================================================================
%% Internal: protocol-level extraction from Raw (binary keys)
%%====================================================================

-spec apply_protocol_category(#{type := error, _ => _}, map()) ->
    #{type := error, _ => _}.
apply_protocol_category(Msg, Raw) ->
    case maps:find(<<"category">>, Raw) of
        {ok, Cat} when is_binary(Cat) ->
            Msg#{category => parse_category_bin(Cat)};
        {ok, Cat} when is_atom(Cat), Cat =/= undefined ->
            Msg#{category => Cat};
        _ ->
            Msg
    end.

-spec apply_retry_after(#{type := error, _ => _}, map()) ->
    #{type := error, _ => _}.
apply_retry_after(Msg, Raw) ->
    case maps:find(<<"retry_after">>, Raw) of
        {ok, Val} ->
            case parse_retry_after(Val) of
                undefined -> Msg;
                Seconds   -> Msg#{retry_after => Seconds}
            end;
        error ->
            Msg
    end.

-spec parse_category_bin(binary()) -> error_category().
parse_category_bin(<<"rate_limit">>)              -> rate_limit;
parse_category_bin(<<"subscription_exhausted">>)  -> subscription_exhausted;
parse_category_bin(<<"context_exceeded">>)        -> context_exceeded;
parse_category_bin(<<"auth_expired">>)            -> auth_expired;
parse_category_bin(<<"server_error">>)            -> server_error;
parse_category_bin(_)                             -> unknown.
