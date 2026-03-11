-module(beam_agent_raw_core).
-moduledoc false.

-export([
    backend/1,
    adapter_module/1,
    call/3,
    call_backend/3
]).

-type native_backend_error() :: beam_agent_backend:backend_lookup_error().
-type native_adapter_module() :: beam_agent_backend:adapter_module().

-doc "Resolve the backend for a live session pid.".
-spec backend(pid()) -> {ok, beam_agent_backend:backend()} | {error, native_backend_error()}.
backend(Session) when is_pid(Session) ->
    beam_agent_backend:session_backend(Session).

-doc "Resolve the adapter facade module for a live session pid.".
-spec adapter_module(pid()) -> {ok, native_adapter_module()} | {error, native_backend_error()}.
adapter_module(Session) when is_pid(Session) ->
    case backend(Session) of
        {ok, Backend} ->
            {ok, beam_agent_backend:adapter_module(Backend)};
        {error, _} = Error ->
            Error
    end.

-doc """
Call a backend-native function with the session pid prepended to the arg list.

Example:

```erlang
beam_agent_raw_core:call(Session, thread_realtime_start, [#{mode => <<"voice">>}]).
```
""".
-spec call(pid(), atom(), [term()]) -> {ok, term()} | {error, term()}.
call(Session, Function, Args)
  when is_pid(Session), is_atom(Function), is_list(Args) ->
    case adapter_module(Session) of
        {ok, Module} ->
            Arity = length(Args) + 1,
            case erlang:function_exported(Module, Function, Arity) of
                true ->
                    try apply(Module, Function, [Session | Args]) of
                        Result -> normalize_result(Result)
                    catch
                        error:undef ->
                            {error, {unsupported_native_call, Function}};
                        Class:Reason ->
                            {error, {native_call_failed, Class, Reason}}
                    end;
                false ->
                    {error, {unsupported_native_call, Function}}
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
Call a backend facade function directly without prepending a session pid.

This is useful for backend-scoped helpers that are not tied to an active
session, though the main unified path should prefer `call/3`.
""".
-spec call_backend(beam_agent_backend:backend() | binary() | atom(),
                   atom(), [term()]) -> {ok, term()} | {error, term()}.
call_backend(BackendLike, Function, Args)
  when is_atom(Function), is_list(Args) ->
    case beam_agent_backend:normalize(BackendLike) of
        {ok, Backend} ->
            Module = beam_agent_backend:adapter_module(Backend),
            Arity = length(Args),
            case erlang:function_exported(Module, Function, Arity) of
                true ->
                    try apply(Module, Function, Args) of
                        Result -> normalize_result(Result)
                    catch
                        error:undef ->
                            {error, {unsupported_native_call, Function}};
                        Class:Reason ->
                            {error, {native_call_failed, Class, Reason}}
                    end;
                false ->
                    {error, {unsupported_native_call, Function}}
            end;
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec normalize_result(term()) -> {ok, term()} | {error, term()}.
normalize_result({ok, _} = Ok) ->
    Ok;
normalize_result({error, _} = Error) ->
    Error;
normalize_result(Result) ->
    {ok, Result}.
