-module(beam_agent_adapter_api).
-moduledoc """
Sub-behaviour for stateless inference API backends.

Backends that make direct HTTP request/response calls to inference provider
APIs (Anthropic Messages API, OpenAI Chat Completions, Google AI, Mistral,
etc.) implement this sub-behaviour in addition to `beam_agent_adapter`.

API backends have no persistent process, no transport, and no session engine.
The unified `beam_agent_core` dispatcher routes to the stateless path when
`backend_type/0` returns `api`.

Required callbacks handle synchronous and streaming chat completions.
Optional callbacks cover embeddings, model listing, and request cancellation.

> **Status:** No implementations yet. All five current backends are
> session-based agentic coders (`backend_type/0` returns `agentic`) and
> implement `beam_agent_adapter_session` instead. This behaviour is
> reserved for future stateless inference API backends (e.g., direct
> Anthropic Messages API, OpenAI Chat Completions).

See also: `beam_agent_adapter`, `beam_agent_adapter_tools`.
""".

-export_type([
    messages/0,
    api_opts/0,
    api_response/0,
    model_info/0,
    vector/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type messages() :: [#{role := binary(), content := binary()}].

-type api_opts() :: #{
    model := binary(),
    max_tokens => pos_integer(),
    temperature => float(),
    tools => [map()],
    api_key => binary(),
    base_url => binary(),
    atom() => term()
}.

-type api_response() :: #{
    content := binary(),
    model := binary(),
    usage := #{
        prompt_tokens := non_neg_integer(),
        completion_tokens := non_neg_integer()
    },
    stop_reason => binary(),
    tool_calls => [map()]
}.

-type model_info() :: #{
    id := binary(),
    name => binary(),
    context_window => pos_integer(),
    max_output_tokens => pos_integer(),
    atom() => term()
}.

-type vector() :: [float()].

%%--------------------------------------------------------------------
%% Required Callbacks
%%--------------------------------------------------------------------

-doc "Send a synchronous chat completion request.".
-callback chat(messages(), api_opts()) ->
    {ok, api_response()} | {error, term()}.

-doc "Send a streaming chat completion request.".
-callback chat_stream(messages(), api_opts()) ->
    {ok, pid()} | {error, term()}.

%%--------------------------------------------------------------------
%% Optional Callbacks
%%--------------------------------------------------------------------

-doc "Generate embeddings for the given input.".
-callback embeddings(Input :: binary() | [binary()], api_opts()) ->
    {ok, [vector()]} | {error, term()}.

-doc "List available models from the provider.".
-callback models(api_opts()) ->
    {ok, [model_info()]} | {error, term()}.

-doc "Cancel an in-flight request by ID.".
-callback cancel(RequestId :: binary()) -> ok | {error, term()}.

-optional_callbacks([
    embeddings/2,
    models/1,
    cancel/1
]).
