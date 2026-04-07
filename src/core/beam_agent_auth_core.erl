-module(beam_agent_auth_core).

-include_lib("kernel/include/file.hrl").

-moduledoc("""
Session-independent authentication for backend CLI tools.

Unlike `beam_agent_account_core`, which manages per-session auth state in
ETS, this module invokes real CLI commands to check, establish, or revoke
credentials with upstream providers.  Operations are one-shot — no running
session required.

Each backend dispatches to its native CLI or API:

  - **claude** — `claude auth status | login | logout`
  - **codex**  — `codex login status`, `codex login [--with-api-key KEY]`
  - **copilot** — `copilot auth status`, `copilot auth login | logout`
  - **opencode** — REST via `opencode_http` (`/auth` endpoints)
  - **gemini** — PTY-interactive; checks env keys / `~/.gemini/oauth_creds.json`

Two port strategies are available:

  - **Pipe-based** (`run_cli/4`) — `open_port({spawn_executable, ...})` with
    pipes.  Used for one-shot CLI commands (status, login, logout) where the
    process exits after completion.  No shell, no injection surface.
  - **PTY-based** (`open_pty_port/3`) — wraps any CLI in `script(1)` to
    allocate a pseudo-terminal.  Required for TUI applications that check
    `isatty()`.  Supports stdin injection via `port_command` for driving
    interactive flows.  Currently used by Gemini; available for any backend.

Security hardening:

  - **CLI path allowlist** — `resolve_cli/2` validates that any caller-supplied
    `cli_path` basename matches the canonical binary name for the backend.
  - **Environment allowlist** — The `env` option is not exposed in the public
    API.  Environment variables are constructed internally by per-backend
    functions.  Both port strategies enforce an allowlist of permitted vars
    (backend credential keys only) as defense-in-depth against internal bugs.
  - **Secret redaction** — API keys are passed via env vars, never CLI args.
    Log output is redacted via `args_summary/1`.

Both strategies follow the same `spawn_executable` pattern used by
`beam_agent_os_signal`.  Every CLI invocation is logged via `logger`
for operational visibility.

## Environment variable shortcuts

When an `api_key` option is provided, backends that support key-based auth
will inject the appropriate environment variable (e.g. `ANTHROPIC_API_KEY`
for Claude) rather than passing the secret on the command line — avoiding
`/proc` exposure on Linux.
""").

-export([status/2, login/2, login/3, logout/2, resolve_cli/2, strip_ansi/1,
         hash_executable/1, from_vault/1, sanitize_for_agent/1]).

    %% Utility — exposed for external callers (e.g. account_core fallback)

-export_type([auth_status/0, auth_result/0, auth_opts/0, vault_env/0]).

-ifdef(TEST).

-export([validate_base_url/1, verify_executable_safety/1, resolve_symlinks/1,
         compute_file_hash/1, is_localhost/1, scrub_env/1]).

-endif.

%%====================================================================
%% Types
%%====================================================================

-type auth_status() ::
    #{backend := beam_agent_backend:backend(),
      authenticated := boolean(),
      method := cli | api | env | manual | unknown,
      account => binary(),
      details => map(),
      raw_output => binary()}.
-type auth_result() ::
    #{backend := beam_agent_backend:backend(),
      outcome := authenticated | logged_out | pending | failed,
      method := cli | api | manual,
      message => binary(),
      raw_output => binary()}.
-type auth_opts() ::
    #{cli_path => string() | binary(),
      api_key => binary(),
      timeout => pos_integer(),
      base_url => string() | binary()}.

    %% OpenCode-specific

-type json_term() ::
    null | true | false | binary() | number() | [json_term()] | #{binary() => json_term()}.

%% Opaque wrapper for Vault-sourced environment variables.
%%
%% Only `from_vault/1` can construct this value — a bare proplist will
%% not type-check.  This prevents internal callers from accidentally
%% passing agent-supplied data as trusted environment variables.
%%
%% These variables bypass the internal allowlist because their intended
%% provenance is trusted: the user stored them in the Vault, not the agent.
-opaque vault_env() :: {vault_env, [{string(), string()}]}.

-doc("""
Construct a `vault_env()` from a list of environment variable tuples.

Internal callers should use `from_vault/1` to construct this value.
The `-opaque` type helps Dialyzer catch accidental misuse — a bare
proplist will not match `vault_env()` in type-checked code — but this
is a static guarantee only, not a runtime-enforced security boundary.

```erlang
VaultEnv = beam_agent_auth_core:from_vault([{\"ANTHROPIC_BASE_URL\", \"...\"}]),
beam_agent_auth_core:login(claude, #{}, VaultEnv).
```
""").

-spec from_vault([{string(), string()}]) -> vault_env() | no_return().
from_vault(Vars) when is_list(Vars) ->
    case lists:all(fun is_vault_env_entry/1, Vars) of
        true  -> {vault_env, Vars};
        false -> error({invalid_vault_env, Vars})
    end;
from_vault(Vars) ->
    error({invalid_vault_env, Vars}).

-spec is_vault_env_entry(term()) -> boolean().
is_vault_env_entry({Key, Value}) when is_list(Key), is_list(Value) -> true;
is_vault_env_entry(_) -> false.

%%--------------------------------------------------------------------
%% Default timeouts (milliseconds)
%%--------------------------------------------------------------------
-define(STATUS_TIMEOUT, 10_000).
-define(LOGIN_TIMEOUT, 300_000).  %% 5 min — generous for device flows
-define(LOGOUT_TIMEOUT, 10_000).
-define(LINE_LENGTH, 4096).

%%====================================================================
%% Status
%%====================================================================

-doc("Check the current authentication state for a backend.\n\nReturns `{ok, AuthStatus}` with `authenticated := true | false` and\nbackend-specific details, or `{error, Reason}` if the check fails.").

-spec status(beam_agent_backend:backend(), auth_opts()) ->
                {ok, auth_status()} | {error, term()}.
status(claude, Opts) ->
    claude_status(Opts);
status(codex, Opts) ->
    codex_status(Opts);
status(copilot, Opts) ->
    copilot_status(Opts);
status(opencode, Opts) ->
    opencode_status(Opts);
status(gemini, Opts) ->
    gemini_status(Opts).

%%====================================================================
%% Login
%%====================================================================

-doc("""
Establish credentials for a backend.

Options may include:
  - `api_key` — authenticate via API key (non-interactive)
  - `cli_path` — override the CLI binary location (basename must match
    the canonical binary name for the backend)
  - `timeout` — override the default login timeout

For backends that use device/OAuth flows (codex, copilot), the call
blocks until the user completes authentication in a browser or the
timeout expires.  The `raw_output` field in the result contains any
URLs or device codes emitted by the CLI.

Equivalent to `login(Backend, Opts, from_vault([]))`.
""").

-spec login(beam_agent_backend:backend(), auth_opts()) ->
               {ok, auth_result()} | {error, term()}.
login(Backend, Opts) ->
    login(Backend, Opts, from_vault([])).

-doc("""
Establish credentials for a backend with Vault-sourced environment.

The `VaultEnv` parameter is an opaque `vault_env()` constructed via
`from_vault/1`.  It carries environment variables from a trusted source
(e.g. the MonkeyClaw Vault).  These bypass the internal env-var allowlist
because their provenance is user-configured, not agent-supplied.

Only `from_vault/1` can construct a `vault_env()` — a bare proplist will
not match, preventing internal callers from accidentally passing agent
data through this channel.

Security model:
  - `Opts` — untrusted; validated, allowlisted, constrained
  - `VaultEnv` — trusted; opaque, user-configured, passed through
  - Internal env (e.g. `ANTHROPIC_API_KEY`) — constructed by per-backend
    functions, validated against the allowlist as defense-in-depth
""").

-spec login(beam_agent_backend:backend(), auth_opts(), vault_env()) ->
               {ok, auth_result()} | {error, term()}.
login(claude, Opts, VaultEnv) ->
    claude_login(Opts, VaultEnv);
login(codex, Opts, VaultEnv) ->
    codex_login(Opts, VaultEnv);
login(copilot, Opts, VaultEnv) ->
    copilot_login(Opts, VaultEnv);
login(opencode, Opts, VaultEnv) ->
    opencode_login(Opts, VaultEnv);
login(gemini, Opts, VaultEnv) ->
    gemini_login(Opts, VaultEnv).

%%====================================================================
%% Logout
%%====================================================================

-doc("Revoke or clear credentials for a backend.").

-spec logout(beam_agent_backend:backend(), auth_opts()) -> ok | {error, term()}.
logout(claude, Opts) ->
    claude_logout(Opts);
logout(codex, Opts) ->
    codex_logout(Opts);
logout(copilot, Opts) ->
    copilot_logout(Opts);
logout(opencode, Opts) ->
    opencode_logout(Opts);
logout(gemini, Opts) ->
    gemini_logout(Opts).

%%====================================================================
%% Claude — `claude auth status|login|logout`
%%====================================================================

claude_status(Opts) ->
    Cli = resolve_cli(claude, Opts),
    Args = ["auth", "status", "--output", "json"],
    Timeout = maps:get(timeout, Opts, ?STATUS_TIMEOUT),
    case run_cli(Cli, Args, [], Timeout) of
        {ok, 0, Lines} ->
            Details = parse_json_output(Lines),
            {ok,
             #{backend => claude,
               authenticated => true,
               method => cli,
               details => Details,
               raw_output => join_lines(Lines)}};
        {ok, _N, Lines} ->
            {ok,
             #{backend => claude,
               authenticated => false,
               method => cli,
               raw_output => join_lines(Lines)}};
        {error, _} = Err ->
            Err
    end.

claude_login(Opts, VaultEnv) ->
    Cli = resolve_cli(claude, Opts),
    Timeout = maps:get(timeout, Opts, ?LOGIN_TIMEOUT),
    {Args, Env} =
        case maps:get(api_key, Opts, undefined) of
            undefined ->
                {["auth", "login"], []};
            Key when is_binary(Key) ->
                {["auth", "login"], [{"ANTHROPIC_API_KEY", binary_to_list(Key)}]}
        end,
    case run_cli(Cli, Args, Env, VaultEnv, Timeout) of
        {ok, 0, Lines} ->
            {ok,
             #{backend => claude,
               outcome => authenticated,
               method => cli,
               raw_output => join_lines(Lines)}};
        {ok, _N, Lines} ->
            {ok,
             #{backend => claude,
               outcome => failed,
               method => cli,
               message => join_lines(Lines),
               raw_output => join_lines(Lines)}};
        {error, _} = Err ->
            Err
    end.

claude_logout(Opts) ->
    Cli = resolve_cli(claude, Opts),
    Args = ["auth", "logout"],
    Timeout = maps:get(timeout, Opts, ?LOGOUT_TIMEOUT),
    case run_cli(Cli, Args, [], Timeout) of
        {ok, 0, _Lines} ->
            ok;
        {ok, _N, Lines} ->
            {error, {logout_failed, join_lines(Lines)}};
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Codex — `codex login status`, `codex login [--with-api-key KEY]`
%%====================================================================

codex_status(Opts) ->
    Cli = resolve_cli(codex, Opts),
    Args = ["login", "status"],
    Timeout = maps:get(timeout, Opts, ?STATUS_TIMEOUT),
    case run_cli(Cli, Args, [], Timeout) of
        {ok, 0, Lines} ->
            {ok,
             #{backend => codex,
               authenticated => true,
               method => cli,
               raw_output => join_lines(Lines)}};
        {ok, _N, Lines} ->
            {ok,
             #{backend => codex,
               authenticated => false,
               method => cli,
               raw_output => join_lines(Lines)}};
        {error, _} = Err ->
            Err
    end.

codex_login(Opts, VaultEnv) ->
    Cli = resolve_cli(codex, Opts),
    Timeout = maps:get(timeout, Opts, ?LOGIN_TIMEOUT),
    {Args, Env} =
        case maps:get(api_key, Opts, undefined) of
            undefined ->
                %% Device auth flow — blocks until user completes in browser
                {["login"], []};
            Key when is_binary(Key) ->
                %% Pass key via env var — never on the command line.
                %% CLI args are visible in /proc/<pid>/cmdline on Linux.
                {["login"], [{"OPENAI_API_KEY", binary_to_list(Key)}]}
        end,
    case run_cli(Cli, Args, Env, VaultEnv, Timeout) of
        {ok, 0, Lines} ->
            {ok,
             #{backend => codex,
               outcome => authenticated,
               method => cli,
               raw_output => join_lines(Lines)}};
        {ok, _N, Lines} ->
            {ok,
             #{backend => codex,
               outcome => failed,
               method => cli,
               message => join_lines(Lines),
               raw_output => join_lines(Lines)}};
        {error, _} = Err ->
            Err
    end.

codex_logout(Opts) ->
    Cli = resolve_cli(codex, Opts),
    Args = ["login", "--revoke"],
    Timeout = maps:get(timeout, Opts, ?LOGOUT_TIMEOUT),
    case run_cli(Cli, Args, [], Timeout) of
        {ok, 0, _Lines} ->
            ok;
        {ok, _N, Lines} ->
            {error, {logout_failed, join_lines(Lines)}};
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Copilot — `copilot auth status`, `copilot auth login|logout`
%%====================================================================

copilot_status(Opts) ->
    Cli = resolve_cli(copilot, Opts),
    Args = ["auth", "status"],
    Timeout = maps:get(timeout, Opts, ?STATUS_TIMEOUT),
    case run_cli(Cli, Args, [], Timeout) of
        {ok, 0, Lines} ->
            {ok,
             #{backend => copilot,
               authenticated => true,
               method => cli,
               raw_output => join_lines(Lines)}};
        {ok, _N, Lines} ->
            {ok,
             #{backend => copilot,
               authenticated => false,
               method => cli,
               raw_output => join_lines(Lines)}};
        {error, _} = Err ->
            Err
    end.

copilot_login(Opts, VaultEnv) ->
    Cli = resolve_cli(copilot, Opts),
    Args = ["auth", "login"],
    Timeout = maps:get(timeout, Opts, ?LOGIN_TIMEOUT),
    case run_cli(Cli, Args, [], VaultEnv, Timeout) of
        {ok, 0, Lines} ->
            {ok,
             #{backend => copilot,
               outcome => authenticated,
               method => cli,
               raw_output => join_lines(Lines)}};
        {ok, _N, Lines} ->
            {ok,
             #{backend => copilot,
               outcome => failed,
               method => cli,
               message => join_lines(Lines),
               raw_output => join_lines(Lines)}};
        {error, _} = Err ->
            Err
    end.

copilot_logout(Opts) ->
    Cli = resolve_cli(copilot, Opts),
    Args = ["auth", "logout"],
    Timeout = maps:get(timeout, Opts, ?LOGOUT_TIMEOUT),
    case run_cli(Cli, Args, [], Timeout) of
        {ok, 0, _Lines} ->
            ok;
        {ok, _N, Lines} ->
            {error, {logout_failed, join_lines(Lines)}};
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% OpenCode — REST API via httpc + env fallback
%%====================================================================

%% OpenCode connects to a running server via HTTP.  For session-independent
%% auth we probe the server health endpoint; if unreachable we check env.
-define(OPENCODE_DEFAULT_URL, "http://localhost:4096").

opencode_status(Opts) ->
    BaseUrl = validate_base_url(Opts),
    Url = BaseUrl ++ "/provider",
    Timeout = maps:get(timeout, Opts, ?STATUS_TIMEOUT),
    case http_get(Url, Timeout) of
        {ok, Code, Body} when Code >= 200, Code < 300 ->
            {ok,
             #{backend => opencode,
               authenticated => true,
               method => api,
               details => Body}};
        {ok, 401, Body} ->
            {ok,
             #{backend => opencode,
               authenticated => false,
               method => api,
               details => Body}};
        {ok, Code, Body} ->
            {error, {unexpected_status, Code, Body}};
        {error, _Reason} ->
            %% Server not reachable — check env vars
            opencode_env_status()
    end.

opencode_env_status() ->
    case os:getenv("OPENAI_API_KEY") of
        false ->
            {ok,
             #{backend => opencode,
               authenticated => false,
               method => env,
               details =>
                   #{hint =>
                         <<"OpenCode server unreachable and OPENAI_API_KEY "
                           "not set. Start the OpenCode server or set the "
                           "environment variable.">>}}};
        _Key ->
            {ok,
             #{backend => opencode,
               authenticated => true,
               method => env,
               details => #{source => <<"OPENAI_API_KEY env">>}}}
    end.

opencode_login(#{api_key := Key} = Opts, _VaultEnv) when is_binary(Key) ->
    BaseUrl = validate_base_url(Opts),
    Url = BaseUrl ++ "/auth",
    Timeout = maps:get(timeout, Opts, ?LOGIN_TIMEOUT),
    JsonBody = json:encode(#{<<"key">> => Key}),
    case http_post(Url, JsonBody, Timeout) of
        {ok, Code, RespBody} when Code >= 200, Code < 300 ->
            {ok,
             #{backend => opencode,
               outcome => authenticated,
               method => api,
               raw_output => format_term(RespBody)}};
        {ok, _Code, RespBody} ->
            {ok,
             #{backend => opencode,
               outcome => failed,
               method => api,
               message => format_term(RespBody),
               raw_output => format_term(RespBody)}};
        {error, Reason} ->
            {error, {opencode_unreachable, Reason}}
    end;
opencode_login(_Opts, _VaultEnv) ->
    logger:info("OpenCode login requires an api_key option. "
                "Pass #{api_key => <<\"sk-...\">>} or configure "
                "the key through the OpenCode server UI."),
    {error, {api_key_required, opencode}}.

opencode_logout(Opts) ->
    BaseUrl = validate_base_url(Opts),
    Url = BaseUrl ++ "/auth",
    Timeout = maps:get(timeout, Opts, ?LOGOUT_TIMEOUT),
    case http_delete(Url, Timeout) of
        {ok, Code, _Body} when Code >= 200, Code < 300 ->
            ok;
        {ok, Code, Body} ->
            {error, {logout_failed, {Code, Body}}};
        {error, Reason} ->
            {error, {opencode_unreachable, Reason}}
    end.

%%====================================================================
%% Gemini — PTY-interactive auth via `script` wrapper
%%====================================================================

gemini_status(Opts) ->
    %% Check for API key in environment first
    case os:getenv("GEMINI_API_KEY") of
        false ->
            case os:getenv("GOOGLE_API_KEY") of
                false ->
                    %% Check for Gemini CLI OAuth credentials
                    check_gemini_oauth_creds(Opts);
                _Key ->
                    {ok,
                     #{backend => gemini,
                       authenticated => true,
                       method => env,
                       details => #{source => <<"GOOGLE_API_KEY env">>}}}
            end;
        _Key ->
            {ok,
             #{backend => gemini,
               authenticated => true,
               method => env,
               details => #{source => <<"GEMINI_API_KEY env">>}}}
    end.

%% Check for Gemini CLI OAuth credentials at ~/.gemini/oauth_creds.json.
%% The gemini CLI stores its own OAuth tokens here — NOT interchangeable
%% with gcloud ADC.  Consumer Gemini subscription auth uses a dedicated
%% OAuth Client ID that gcloud tokens cannot satisfy.
check_gemini_oauth_creds(_Opts) ->
    Home = os:getenv("HOME", "/tmp"),
    CredsPath = filename:join([Home, ".gemini", "oauth_creds.json"]),
    case filelib:is_regular(CredsPath) of
        true ->
            {ok,
             #{backend => gemini,
               authenticated => true,
               method => manual,
               details => #{source => <<"Gemini CLI OAuth">>, path => list_to_binary(CredsPath)}}};
        false ->
            {ok,
             #{backend => gemini,
               authenticated => false,
               method => manual,
               details =>
                   #{hint =>
                         <<"No GEMINI_API_KEY, GOOGLE_API_KEY, or Gemini CLI "
                           "OAuth credentials found.  Run the gemini CLI to "
                           "authenticate via browser OAuth.">>}}}
    end.

%% Login via the `gemini` CLI's own OAuth flow.
%%
%% The consumer Gemini subscription uses a dedicated OAuth Client ID
%% that is NOT interchangeable with gcloud/GCP credentials.  A token
%% from `gcloud auth login` targets Vertex AI (pay-as-you-go) and will
%% be rejected by consumer Gemini endpoints.  We MUST use the `gemini`
%% binary itself to initiate the correct OAuth handshake.
%%
%% The gemini CLI is an Ink/React TUI that requires a pseudo-terminal
%% (isatty() must return true).  We use the `script` command as a PTY
%% wrapper to launch the CLI.  After a brief startup delay we send
%% `/auth login` via stdin to trigger the OAuth flow, then watch for
%% the OAuth URL and "Authentication succeeded" in stdout.
%%
%% The OAuth URL is extracted and returned in the `oauth_url` field so
%% the caller (e.g. MonkeyClaw) can present it to the user or open a
%% browser automatically.
gemini_login(Opts, _VaultEnv) ->
    Cli = resolve_cli(gemini, Opts),
    Timeout = maps:get(timeout, Opts, ?LOGIN_TIMEOUT),
    case os:find_executable(Cli) of
        false ->
            logger:info("Gemini CLI (~s) not found. Install it or set "
                        "GEMINI_API_KEY in the environment.", [Cli]),
            {error, {cli_not_found, Cli}};
        GeminiExe ->
            case run_gemini_auth(GeminiExe, Timeout) of
                {ok, authenticated, OAuthUrl, RawBuf} ->
                    Result =
                        #{backend => gemini,
                          outcome => authenticated,
                          method => manual,
                          raw_output => strip_ansi(RawBuf)},
                    {ok, maybe_put_oauth_url(Result, OAuthUrl)};
                {ok, pending, OAuthUrl, RawBuf} ->
                    Result =
                        #{backend => gemini,
                          outcome => pending,
                          method => manual,
                          message =>
                              <<"OAuth flow started. "
                                "Complete in browser.">>,
                          raw_output => strip_ansi(RawBuf)},
                    {ok, maybe_put_oauth_url(Result, OAuthUrl)};
                {error, {pty_not_found, _}} ->
                    {error,
                     {not_supported,
                      gemini,
                      login,
                      <<"PTY wrapper (script) not found. Cannot "
                        "launch Gemini CLI interactively.">>}};
                {error, _} = Err ->
                    Err
            end
    end.

%% Gemini CLI has no CLI-argument logout.  Inside a running session
%% `/auth signout` clears cached credentials, but that requires an
%% interactive PTY session.  The effect is the same: delete the creds
%% file directly.
%% (Verified from gemini-cli source: GEMINI_DIR='.gemini', OAUTH_FILE='oauth_creds.json')
gemini_logout(_Opts) ->
    Home = os:getenv("HOME", "/tmp"),
    CredsPath = filename:join([Home, ".gemini", "oauth_creds.json"]),
    case file:delete(CredsPath) of
        ok ->
            logger:info("Gemini logout: removed ~s", [CredsPath]),
            ok;
        {error, enoent} ->
            logger:info("Gemini logout: no credential file at ~s", [CredsPath]),
            ok;
        {error, Reason} ->
            {error, {logout_failed, {CredsPath, Reason}}}
    end.

%%--------------------------------------------------------------------
%% Gemini PTY helpers
%%--------------------------------------------------------------------

%% Time (ms) to wait for the Gemini TUI to initialize before sending
%% the /auth login command.  The CLI is an Ink/React app that needs a
%% moment to render its initial UI.
-define(GEMINI_STARTUP_DELAY, 3000).

%% Launch the gemini CLI in a PTY and drive the OAuth flow.
%%
%% Uses `open_pty_port/3` to wrap the gemini binary in `script(1)`.
%% After GEMINI_STARTUP_DELAY ms, sends `/auth login\n` to stdin,
%% then watches stdout for the OAuth URL and auth completion signal.
-spec run_gemini_auth(string(), pos_integer()) ->
                         {ok, authenticated | pending, binary() | undefined, binary()} |
                         {error, term()}.
run_gemini_auth(GeminiExe, Timeout) ->
    case open_pty_port(GeminiExe, [], []) of
        {error, _} = Err ->
            Err;
        {ok, Port} ->
            Deadline = erlang:monotonic_time(millisecond) + Timeout,
            TRef = erlang:send_after(?GEMINI_STARTUP_DELAY, self(), {gemini_send_auth, Port}),
            Result = collect_gemini_auth(Port, <<>>, Deadline),
            %% Clean up the timer — prevent leaked messages
            _ = erlang:cancel_timer(TRef),
            receive
                {gemini_send_auth, Port} ->
                    ok
            after 0 ->
                ok
            end,
            Result
    end.

%% Collect PTY output from the Gemini CLI until auth completes or the
%% deadline passes.  Handles three message types:
%%
%%   {gemini_send_auth, Port} — scheduled timer; sends `/auth login`
%%   {Port, {data, Binary}}  — raw PTY output chunk (stream mode)
%%   {Port, {exit_status, N}} — process exited
%%
%% On each data arrival the accumulated buffer is stripped of ANSI
%% escape codes and scanned for auth-completion patterns.
-spec collect_gemini_auth(port(), binary(), integer()) ->
                             {ok, authenticated | pending, binary() | undefined, binary()}.
collect_gemini_auth(Port, Buffer, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {gemini_send_auth, Port} ->
            logger:info("Gemini auth: sending /auth login"),
            try
                port_command(Port, "/auth login\n")
            catch
                error:badarg ->
                    ok  %% Port already closed
            end,
            collect_gemini_auth(Port, Buffer, Deadline);
        {Port, {data, Data}} ->
            NewBuf = <<Buffer/binary, Data/binary>>,
            Clean = strip_ansi(NewBuf),
            case gemini_auth_complete(Clean) of
                true ->
                    OAuthUrl = extract_oauth_url(Clean),
                    catch port_close(Port),
                    flush_port(Port),
                    {ok, authenticated, OAuthUrl, NewBuf};
                false ->
                    collect_gemini_auth(Port, NewBuf, Deadline)
            end;
        {Port, {exit_status, 0}} ->
            flush_port(Port),
            Clean = strip_ansi(Buffer),
            OAuthUrl = extract_oauth_url(Clean),
            case gemini_auth_complete(Clean) of
                true ->
                    {ok, authenticated, OAuthUrl, Buffer};
                false ->
                    {ok, pending, OAuthUrl, Buffer}
            end;
        {Port, {exit_status, _N}} ->
            flush_port(Port),
            Clean = strip_ansi(Buffer),
            {ok, pending, extract_oauth_url(Clean), Buffer}
    after Remaining ->
        catch port_close(Port),
        flush_port(Port),
        Clean = strip_ansi(Buffer),
        {ok, pending, extract_oauth_url(Clean), Buffer}
    end.

%% Detect when the Gemini CLI has completed its OAuth flow.
%% Patterns verified from gemini-cli source:
%%   oauth2.ts:389  →  message: 'Authentication succeeded\n'
%% And from user-observed post-auth UI:
%%   "You've successfully signed in with Google"
-spec gemini_auth_complete(binary()) -> boolean().
gemini_auth_complete(Bin) ->
    Lower = string:lowercase(Bin),
    binary:match(Lower, [<<"authentication succeeded">>, <<"successfully signed in">>])
    =/= nomatch.

%% Extract the OAuth URL from output.
%% The Gemini CLI prints a Google OAuth URL for the user to visit
%% in their browser to complete the authorization code flow.
%%
%% Only matches accounts.google.com — no broad URL fallback to prevent
%% a compromised CLI from surfacing phishing URLs.  If the URL is not
%% from Google OAuth, the caller can inspect `raw_output` directly.
-spec extract_oauth_url(binary()) -> binary() | undefined.
extract_oauth_url(Bin) ->
    case re:run(Bin,
                "https://accounts\\.google\\.com/[^\\s\"'<>]+",
                [{capture, first, binary}])
    of
        {match, [Url]} ->
            Url;
        nomatch ->
            undefined
    end.

%% Add oauth_url to a result map when present.
-spec maybe_put_oauth_url(#{backend := gemini,
                            method := manual,
                            outcome := authenticated | pending,
                            raw_output := binary(),
                            message => <<_:320>>},
                          binary() | undefined) ->
                             #{backend := gemini,
                               method := manual,
                               outcome := authenticated | pending,
                               raw_output := binary(),
                               message => <<_:320>>,
                               oauth_url => binary()}.
maybe_put_oauth_url(Result, undefined) ->
    Result;
maybe_put_oauth_url(Result, Url) ->
    Result#{oauth_url => Url}.

%%====================================================================
%% CLI resolution
%%====================================================================

-doc("Resolve the CLI executable path for a backend.\n\nChecks `cli_path` in Opts first, then backend-specific environment\nvariables, then falls back to the default binary name.\n\n**Security**: When `cli_path` is provided, the basename of the path\nis validated against the canonical binary name for the backend.  This\nprevents an agent from executing arbitrary binaries via the options map.").

-spec resolve_cli(beam_agent_backend:backend(), auth_opts()) -> string() | no_return().
resolve_cli(Backend, Opts) ->
    case maps:get(cli_path, Opts, undefined) of
        undefined ->
            default_cli(Backend);
        P0 ->
            P = case P0 of
                    B when is_binary(B) ->
                        binary_to_list(B);
                    L when is_list(L) ->
                        L
                end,
            validate_cli_path(Backend, P),
            P
    end.

%% Verify that the basename of a caller-supplied cli_path matches the
%% canonical binary name for the backend.  Raises on mismatch — this
%% is a security boundary, not a soft check.
-spec validate_cli_path(beam_agent_backend:backend(), string()) -> ok | no_return().
validate_cli_path(Backend, Path) ->
    Expected = cli_binary_name(Backend),
    Basename = filename:basename(Path),
    %% On Windows, strip .exe/.cmd/.bat extensions before comparing
    %% so that "C:\...\claude.exe" matches the canonical name "claude".
    Actual = strip_exe_extension(Basename),
    case Actual of
        Expected ->
            ok;
        _ ->
            error({invalid_cli_path,
                   #{backend => Backend,
                     expected => Expected,
                     actual => Actual,
                     path => Path}})
    end.

-spec strip_exe_extension(string()) -> string().
strip_exe_extension(Basename) ->
    case filename:extension(Basename) of
        ".exe" -> filename:rootname(Basename);
        ".cmd" -> filename:rootname(Basename);
        ".bat" -> filename:rootname(Basename);
        _      -> Basename
    end.

%% Canonical binary name for each backend.  Used by validate_cli_path/2
%% to enforce that cli_path overrides do not change which program is run.
-spec cli_binary_name(beam_agent_backend:backend()) -> [1..255, ...].
cli_binary_name(claude) ->
    "claude";
cli_binary_name(codex) ->
    "codex";
cli_binary_name(copilot) ->
    "copilot";
cli_binary_name(opencode) ->
    "opencode";
cli_binary_name(gemini) ->
    "gemini".

-spec default_cli(beam_agent_backend:backend()) -> string().
default_cli(claude) ->
    "claude";
default_cli(codex) ->
    os:getenv("CODEX_CLI_PATH", "codex");
default_cli(copilot) ->
    "copilot";
default_cli(opencode) ->
    "opencode";
default_cli(gemini) ->
    os:getenv("GEMINI_CLI_PATH", "gemini").

%%====================================================================
%% Environment variable validation
%%====================================================================

%% Exhaustive allowlist of environment variables that may be set on
%% child processes.  Only backend-specific credential variables are
%% permitted — everything else is rejected.
%%
%% Design choice: allowlist, not deny-list.  A deny-list is an attack
%% roadmap — once a threat actor knows the list, they craft payloads
%% that avoid it.  An allowlist inverts the model: only explicitly
%% permitted variables pass, everything else is rejected by default.
%%
%% The `env` option has been removed from the public Opts API.  These
%% env vars are constructed internally by per-backend login functions.
%% This validation is defense-in-depth against internal bugs that might
%% accidentally forward external input to the port.
-spec allowed_env_vars() -> [[1..255, ...], ...].
allowed_env_vars() ->
    ["ANTHROPIC_API_KEY",   %% Claude
     "OPENAI_API_KEY",      %% Codex
     "GEMINI_API_KEY",      %% Gemini (env-based auth)
     "GOOGLE_API_KEY"].     %% Gemini (alternate env key)

%% Validate that every environment variable is on the allowlist.
%% Raises on violation — this is a security boundary.
-spec validate_env([{string(), string()}]) -> ok | no_return().
validate_env([]) ->
    ok;
validate_env(Env) ->
    Allowed = allowed_env_vars(),
    case [K || {K, _} <- Env, not lists:member(K, Allowed)] of
        [] ->
            ok;
        [Bad | _] ->
            error({disallowed_env_var,
                   Bad,
                   <<"Only backend-specific credential variables "
                     "are permitted.  The env option is not part "
                     "of the public API — environment variables "
                     "are set internally by per-backend functions.">>})
    end.

%% Merge caller-supplied env vars with explicit removal of dangerous
%% inherited variables.  open_port's {env, Env} merges with the parent
%% environment — setting a var to `false` removes it from the child.
%% This prevents LD_PRELOAD injection, PATH manipulation, and locale
%% tricks against the spawned CLI binary.
%%
%% IMPORTANT: Dangerous vars are stripped from CallerEnv first, then the
%% `{Var, false}` removals are appended LAST.  open_port processes the
%% list sequentially — later entries override earlier ones — so the false
%% entries must come after any caller values to guarantee removal.
-spec scrub_env([{string(), string()}]) -> [{string(), string() | false}].
scrub_env(CallerEnv) ->
    Dangerous = dangerous_env_vars(),
    SafeCallerEnv =
        [{K, V} || {K, V} <- CallerEnv, not lists:member(K, Dangerous)],
    Removals = [{Var, false} || Var <- Dangerous],
    SafeCallerEnv ++ Removals.

-spec dangerous_env_vars() -> [[1..255, ...], ...].
dangerous_env_vars() ->
    ["LD_PRELOAD",
     "LD_LIBRARY_PATH",
     "DYLD_INSERT_LIBRARIES",  %% macOS equivalent
     "DYLD_LIBRARY_PATH",      %% macOS
     "DYLD_FRAMEWORK_PATH",    %% macOS
     "LD_AUDIT",
     "LD_PROFILE"].

%%====================================================================
%% URL validation
%%====================================================================

%% Validate that base_url is localhost-only.  Prevents SSRF attacks where
%% the agent supplies a malicious base_url to exfiltrate API keys via the
%% POST to /auth, or to probe internal network endpoints.
%%
%% Only localhost (127.0.0.1, ::1, "localhost") is permitted.  OpenCode
%% runs as a local server — there is no legitimate reason for a remote URL.
%%
%% Raises on violation — this is a security boundary.
-spec validate_base_url(auth_opts()) -> string() | no_return().
validate_base_url(Opts) ->
    BaseUrl = to_list(maps:get(base_url, Opts, ?OPENCODE_DEFAULT_URL)),
    case uri_string:parse(list_to_binary(BaseUrl)) of
        #{scheme := Scheme, host := Host} ->
            case is_allowed_scheme(Scheme) of
                false ->
                    error({disallowed_base_url,
                           #{url => BaseUrl,
                             scheme => Scheme,
                             message =>
                                 <<"OpenCode base_url must use http or https. "
                                   "Other schemes are not permitted.">>}});
                true ->
                    case is_localhost(Host) of
                        true ->
                            BaseUrl;
                        false ->
                            error({disallowed_base_url,
                                   #{url => BaseUrl,
                                     host => Host,
                                     message =>
                                         <<"OpenCode base_url must be localhost. "
                                           "Remote URLs are not permitted — this "
                                           "prevents SSRF and API key exfiltration.">>}})
                    end
            end;
        _ ->
            error({invalid_base_url,
                   #{url => BaseUrl,
                     message =>
                         <<"Could not parse base_url. Expected a valid "
                           "URL with scheme and host.">>}})
    end.

-spec is_allowed_scheme(binary()) -> boolean().
is_allowed_scheme(<<"http">>) -> true;
is_allowed_scheme(<<"https">>) -> true;
is_allowed_scheme(_) -> false.

-spec is_localhost(binary()) -> boolean().
is_localhost(<<"localhost">>) ->
    true;
is_localhost(<<"127.0.0.1">>) ->
    true;
is_localhost(<<"::1">>) ->
    true;
is_localhost(<<"[::1]">>) ->
    true;
is_localhost(_) ->
    false.

%%====================================================================
%% Executable integrity verification
%%====================================================================

%% Verify that an executable and its parent directory are safe to run.
%%
%% Checks:
%%   1. Path must not be a symlink (resolve chain, check resolved target)
%%   2. Resolved target must be a regular file (not directory/device/pipe)
%%   3. File must not be world-writable (mode & 8#002 == 0)
%%   4. Parent directory of the *resolved* path must not be world-writable
%%
%% Symlink handling: if the input path is a symlink, we resolve the full
%% chain to the final regular file and run all checks against the resolved
%% target and its parent directory.  This prevents an attacker from placing
%% a symlink in a protected directory that points to a world-writable target.
%%
%% This is a basic sanity gate — it catches obvious misconfigurations
%% (world-writable binaries or directories) before execution.
%%
%% Raises on violation — writable executables are a security boundary.
-spec verify_executable_safety(string()) -> ok | no_return().
verify_executable_safety(Path) ->
    %% Resolve symlinks to get the actual target binary
    ResolvedPath = resolve_symlinks(Path),
    case file:read_file_info(ResolvedPath, [{time, posix}]) of
        {error, Reason} ->
            error({executable_stat_failed, ResolvedPath, Reason});
        {ok, #file_info{type = Type, mode = Mode}} ->
            %% Must be a regular file — not a directory, device, or pipe
            case Type of
                regular ->
                    ok;
                _ ->
                    error({not_regular_file,
                           #{path => ResolvedPath,
                             type => Type,
                             message =>
                                 <<"Path does not resolve to a regular "
                                   "file.  Directories, devices, and "
                                   "pipes are not valid executables.">>}})
            end,
            %% Reject world-writable executables
            case Mode band 8#002 of
                0 ->
                    ok;
                _ ->
                    error({world_writable_executable,
                           #{path => ResolvedPath,
                             mode => io_lib:format("~.8B", [Mode]),
                             message =>
                                 <<"Executable is world-writable. "
                                   "This allows any user to replace "
                                   "it with a malicious binary.">>}})
            end,
            %% Verify parent directory of the RESOLVED path is not
            %% world-writable.  Using the resolved path (not the original)
            %% prevents symlink-chain bypass of the directory check.
            DirPath = filename:dirname(ResolvedPath),
            case file:read_file_info(DirPath, [{time, posix}]) of
                {error, DirReason} ->
                    error({executable_dir_stat_failed, DirPath, DirReason});
                {ok, #file_info{mode = DirMode}} ->
                    case DirMode band 8#002 of
                        0 ->
                            ok;
                        _ ->
                            error({world_writable_executable_dir,
                                   #{path => DirPath,
                                     mode => io_lib:format("~.8B", [DirMode]),
                                     message =>
                                         <<"Executable directory is "
                                           "world-writable. Any user "
                                           "could replace the binary.">>}})
                    end
            end
    end.

%% Resolve a path through any symlink chain to the final target.
%% Uses file:read_link_info to detect symlinks, then file:read_link
%% to follow the chain.  Limits to 40 hops to prevent infinite loops
%% from circular symlinks (matches Linux kernel MAXSYMLINKS).
-spec resolve_symlinks(string()) -> string() | no_return().
resolve_symlinks(Path) ->
    resolve_symlinks(Path, 40).

-spec resolve_symlinks(string(), non_neg_integer()) -> string() | no_return().
resolve_symlinks(Path, 0) ->
    error({symlink_loop,
           #{path => Path,
             message =>
                 <<"Symlink chain exceeds 40 hops. "
                   "Possible circular symlink.">>}});
resolve_symlinks(Path, Remaining) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {error, Reason} ->
            error({executable_stat_failed, Path, Reason});
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Path) of
                {ok, Target} ->
                    %% Resolve relative targets against the symlink's dir
                    Resolved =
                        case filename:pathtype(Target) of
                            absolute ->
                                Target;
                            _Relative ->
                                filename:join(
                                    filename:dirname(Path), Target)
                        end,
                    resolve_symlinks(Resolved, Remaining - 1);
                {error, Reason} ->
                    error({symlink_read_failed, #{path => Path, reason => Reason}})
            end;
        {ok, _Info} ->
            %% Not a symlink — return as-is
            Path
    end.

%% Streaming SHA-256 hash computation for executables.
%%

%% Compute the SHA-256 hash of a file, returned in registry format.
%% Uses streaming reads (64 KB chunks) to keep memory constant regardless
%% of file size — CLI binaries can be 50-200 MB.
-spec compute_file_hash(string()) -> <<_:56, _:_*8>>.
compute_file_hash(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                stream_hash(Fd, crypto:hash_init(sha256))
            after
                file:close(Fd)
            end;
        {error, Reason} ->
            error({executable_read_failed, #{path => Path, reason => Reason}})
    end.

-spec stream_hash(file:fd(), crypto:hash_state()) -> binary().
stream_hash(Fd, Ctx) ->
    case file:read(Fd, 65536) of
        {ok, Chunk} ->
            stream_hash(Fd, crypto:hash_update(Ctx, Chunk));
        eof ->
            Digest = crypto:hash_final(Ctx),
            HexDigest = binary:encode_hex(Digest, lowercase),
            <<"sha256:", HexDigest/binary>>
    end.

-doc("Compute the SHA-256 hash of an executable.\n\nReturns a binary in the format `<<\"sha256:hexdigest\">>`.  Useful for\nout-of-band integrity verification (startup checks, monitoring,\ndeployment validation).\n\n```erlang\nHash = beam_agent_auth_core:hash_executable(\"/usr/local/bin/claude\"),\n%% => <<\"sha256:a1b2c3d4e5f6...\">>\n```").

-spec hash_executable(string() | binary()) -> <<_:56, _:_*8>>.
hash_executable(Path) when is_binary(Path) ->
    hash_executable(binary_to_list(Path));
hash_executable(Path) when is_list(Path) ->
    case os:find_executable(Path) of
        false ->
            error({executable_not_found, Path});
        ExePath ->
            compute_file_hash(ExePath)
    end.

%%====================================================================
%% One-shot port runner
%%====================================================================

-doc("""
Execute a CLI command and collect its output.

Uses `open_port/2` with `spawn_executable` — no shell, no injection.
Resolves the executable via `os:find_executable/1`.

Returns `{ok, ExitCode, OutputLines}` on completion, or
`{error, Reason}` on failure.

All invocations are logged for operational visibility.

**Security**:
  - Environment variables are validated against an allowlist
  - Dangerous inherited env vars (LD_PRELOAD, DYLD_INSERT_LIBRARIES, etc.) are scrubbed
  - Executable permissions are verified (not world-writable)
""").

-spec run_cli(string(), [string()], [{string(), string()}], pos_integer()) ->
                 {ok, non_neg_integer(), [string()]} | {error, term()}.
run_cli(Program, Args, InternalEnv, Timeout) ->
    validate_env(InternalEnv),
    case os:find_executable(Program) of
        false ->
            logger:warning("Auth CLI not found: ~s", [Program]),
            {error, {cli_not_found, Program}};
        ExePath ->
            verify_executable_safety(ExePath),
            logger:info("Auth CLI exec: ~s ~s", [Program, args_summary(Args)]),
            run_port(ExePath, Args, InternalEnv, Timeout)
    end.

%% Internal: run_cli with merged VaultEnv from Vault.
%% InternalEnv is validated against the allowlist; VaultEnv is unwrapped
%% from its opaque wrapper and merged — bypasses the allowlist.
-spec run_cli(string(), [string()], [{string(), string()}], vault_env(), pos_integer()) ->
                 {ok, non_neg_integer(), [string()]} | {error, term()}.
run_cli(Program, Args, InternalEnv, {vault_env, VaultVars}, Timeout) ->
    validate_env(InternalEnv),
    case os:find_executable(Program) of
        false ->
            logger:warning("Auth CLI not found: ~s", [Program]),
            {error, {cli_not_found, Program}};
        ExePath ->
            verify_executable_safety(ExePath),
            logger:info("Auth CLI exec: ~s ~s", [Program, args_summary(Args)]),
            run_port(ExePath, Args, InternalEnv ++ VaultVars, Timeout)
    end.

-spec run_port(string(), [string()], [{string(), string()}], pos_integer()) ->
                  {ok, non_neg_integer(), [string()]} | {error, term()}.
run_port(ExePath, Args, AllEnv, Timeout) ->
    PortOpts =
        [{args, Args},
         {env, scrub_env(AllEnv)},
         exit_status,
         stderr_to_stdout,
         {line, ?LINE_LENGTH},
         hide],
    try
        Port = open_port({spawn_executable, ExePath}, PortOpts),
        collect_output(Port, [], Timeout)
    catch
        Class:Reason:Stack ->
            logger:warning("Auth port error: ~p:~tp~n~p", [Class, Reason, Stack]),
            {error, {port_error, {Class, Reason}}}
    end.

-spec collect_output(port(), [], pos_integer()) ->
                        {ok, non_neg_integer(), [string()]} | {error, timeout}.
collect_output(Port, Acc, Timeout) ->
    collect_output(Port, Acc, [], Timeout).

%% Accumulate output with a line buffer for noeol fragments.
%% In {line, N} mode, lines exceeding N bytes arrive as {noeol, Chunk}
%% fragments followed by a final {eol, Tail}.  We buffer noeol chunks
%% and flush on eol to preserve long lines (e.g. JSON) intact.
-spec collect_output(port(), [string()], string(), pos_integer()) ->
                        {ok, non_neg_integer(), [string()]} | {error, timeout}.
collect_output(Port, Acc, LineBuf, Timeout) ->
    receive
        {Port, {data, {eol, Line}}} ->
            CompletedLine = LineBuf ++ Line,
            collect_output(Port, [CompletedLine | Acc], [], Timeout);
        {Port, {data, {noeol, Line}}} ->
            collect_output(Port, Acc, LineBuf ++ Line, Timeout);
        {Port, {exit_status, ExitCode}} ->
            flush_port(Port),
            FinalAcc = case LineBuf of
                [] -> Acc;
                _  -> [LineBuf | Acc]
            end,
            Lines = lists:reverse(FinalAcc),
            log_cli_result(ExitCode, Lines),
            {ok, ExitCode, Lines}
    after Timeout ->
        catch port_close(Port),
        flush_port(Port),
        logger:warning("Auth CLI timed out after ~bms", [Timeout]),
        {error, timeout}
    end.

%% Drain any pending messages from a closed port.
-spec flush_port(port()) -> ok.
flush_port(Port) ->
    receive
        {Port, _} ->
            flush_port(Port)
    after 0 ->
        ok
    end.

%%====================================================================
%% PTY port runner
%%====================================================================

-doc("""
Open a pseudo-terminal port for an interactive CLI.

Wraps the target executable in `script(1)` so that `isatty()` returns
true inside the child process — required for TUI applications (Ink/React,
curses, etc.).  The port uses binary stream mode; the caller drives I/O
via `port_command/2` and `receive`.

Platform behavior:
  - macOS / BSD — `script -q /dev/null exe arg1 arg2` (direct exec)
  - Linux — `script -q -c 'exe arg1 arg2' /dev/null` (via `sh -c`)

Returns `{ok, Port}` on success.  The caller is responsible for closing
the port and draining messages via `flush_port/1`.

**Security**:
  - Environment variables are validated against an allowlist
  - Executable permissions are verified (not world-writable)
  - `script` wrapper is also permission-verified
  - Dangerous inherited env vars (LD_PRELOAD, DYLD_INSERT_LIBRARIES, etc.) are scrubbed
""").

-dialyzer({nowarn_function, open_pty_port/3}).

-spec open_pty_port(string(), [string()], [{string(), string()}]) ->
                       {ok, port()} |
                       {error,
                        {cli_not_found, string()} |
                        {port_error, term()} |
                        {pty_not_found, nonempty_string()}}.
open_pty_port(Program, Args, InternalEnv) ->
    validate_env(InternalEnv),
    case os:find_executable(Program) of
        false ->
            {error, {cli_not_found, Program}};
        ExePath ->
            verify_executable_safety(ExePath),
            case find_pty_wrapper() of
                {error, _} = Err ->
                    Err;
                {ok, ScriptExe, MakeArgs} ->
                    ScriptArgs = MakeArgs(ExePath, Args),
                    logger:info("PTY port: ~s ~s via ~s", [Program, args_summary(Args), ScriptExe]),
                    PortOpts =
                        [{args, ScriptArgs},
                         {env, scrub_env(InternalEnv)},
                         binary,
                         exit_status,
                         stderr_to_stdout,
                         use_stdio,
                         stream,
                         hide],
                    try
                        Port = open_port({spawn_executable, ScriptExe}, PortOpts),
                        {ok, Port}
                    catch
                        error:Reason ->
                            {error, {port_error, Reason}}
                    end
            end
    end.

%% Find the `script` command for PTY allocation.
%% `script` is part of macOS base system and Linux util-linux — nearly
%% universal on Unix.  Returns the executable path and a function that
%% builds the correct argument list for the detected platform.
-spec find_pty_wrapper() ->
                          {ok, string(), fun((string(), [string()]) -> [string()])} |
                          {error, {pty_not_found, string()}}.
find_pty_wrapper() ->
    case os:find_executable("script") of
        false ->
            {error, {pty_not_found, "script"}};
        ScriptExe ->
            verify_executable_safety(ScriptExe),
            ArgsFun =
                case os:type() of
                    {unix, linux} ->
                        %% Linux `script -c` passes the arg through sh -c,
                        %% so we shell-escape the command string.
                        fun(Exe, Args) ->
                           CmdStr = pty_command_string(Exe, Args),
                           ["-q", "-c", CmdStr, "/dev/null"]
                        end;
                    {unix, _} ->
                        %% macOS, FreeBSD — direct exec, no shell involved
                        fun(Exe, Args) -> ["-q", "/dev/null", Exe | Args] end
                end,
            {ok, ScriptExe, ArgsFun}
    end.

%% Build a shell-escaped command string for Linux `script -c`.
-spec pty_command_string(string(), [string()]) -> string().
pty_command_string(Exe, Args) ->
    Parts = [shell_escape(Exe) | [shell_escape(A) || A <- Args]],
    string:join(Parts, " ").

%% Shell-escape a string for safe inclusion in `sh -c '...'`.
%% Uses POSIX single-quoting with escaped embedded single-quotes.
-spec shell_escape(string()) -> string().
shell_escape(Str) ->
    "'"
    ++ lists:flatmap(fun ($') ->
                             "'\\''";
                         (C) ->
                             [C]
                     end,
                     Str)
    ++ "'".

-doc("""
Strip ANSI escape sequences and carriage returns from PTY output.

Handles all standard escape sequence families:

  - **CSI** (`\\\\e[...X`) — cursor, color, erase
  - **OSC** (`\\\\e]...BEL|ST`) — title, hyperlink
  - **DCS** (`\\\\eP...BEL|ST`) — device control strings
  - **APC** (`\\\\e_...BEL|ST`) — application program commands
  - **PM**  (`\\\\e^...BEL|ST`) — privacy messages
  - **SOS** (`\\\\eX...BEL|ST`) — start of string
  - Simple two-byte (`\\\\eX`) — mode switches, charset

ST (String Terminator) is `\\\\e\\\\\\\\`; BEL (`\\\\x07`) is also accepted.

**Security**: A compromised CLI could inject escape sequences designed
to leave misleading text in the \"cleaned\" output.  This function strips
all known sequence families to minimize that attack surface.

Useful for extracting clean text from interactive TUI output captured
via `open_pty_port/3`.
""").

-spec strip_ansi(binary()) -> binary().
strip_ansi(Bin) ->
    re:replace(Bin,
               %% CSI: \e[ params final-byte
               "\\x1b\\[[0-9;]*[A-Za-z]"
               "|\\x1b\\][^\\x07\\x1b]*(?:\\x1b\\\\|\\x07)"
               "|\\x1b[P_^X][^\\x07\\x1b]*(?:\\x1b\\\\|\\x07)?"
               "|\\x1b."
               "|\\r",
               %% OSC: \e] ... (BEL or ST)
               %% DCS/APC/PM/SOS: \eP|\e_|\e^|\eX ... (BEL or ST)
               %% Simple two-byte escapes (must be AFTER multi-byte patterns)
               %% Carriage return
               <<>>,
               [global, {return, binary}]).

%% Strips fields that must not flow to the agent: raw CLI output
%% (may contain OAuth URLs, device codes, or session tokens), internal
%% details maps, and extracted OAuth URLs.  The result retains only the
%% structured fields the agent needs to act on (backend, authenticated,
%% outcome, method, account, message).
-spec sanitize_for_agent(map()) -> map().
sanitize_for_agent(Result) when is_map(Result) ->
    maps:without([raw_output, details, oauth_url], Result).

%%====================================================================
%% Output helpers
%%====================================================================

-spec join_lines([string()]) -> binary().
join_lines([]) ->
    <<>>;
join_lines(Lines) ->
    list_to_binary(string:join(Lines, "\n")).

-spec parse_json_output([string()]) ->
    #{binary() => json_term()} | #{raw := binary()}.
parse_json_output(Lines) ->
    Raw = join_lines(Lines),
    case beam_agent_json:safe_decode(Raw) of
        {ok, Map} when is_map(Map) ->
            Map;
        _Other ->
            #{raw => Raw}
    end.

-spec format_term(json_term()) -> binary().
format_term(Term) when is_map(Term) ->
    try
        iolist_to_binary(json:encode(Term))
    catch
        _:_ ->
            iolist_to_binary(io_lib:format("~tp", [Term]))
    end;
format_term(Term) when is_binary(Term) ->
    Term;
format_term(Term) ->
    iolist_to_binary(io_lib:format("~tp", [Term])).

-spec to_list(binary() | string()) -> string().
to_list(B) when is_binary(B) ->
    binary_to_list(B);
to_list(L) when is_list(L) ->
    L.

%%====================================================================
%% HTTP helpers (for OpenCode REST calls)
%%====================================================================

%% Lightweight wrappers around httpc for session-independent REST calls.
%% These ensure inets/ssl are started, enforce TLS certificate verification,
%% and handle JSON decode of response bodies.

-spec http_get(string(), pos_integer()) -> {ok, pos_integer(), term()} | {error, term()}.
http_get(Url, Timeout) ->
    ensure_inets(),
    Headers = [{"accept", "application/json"}],
    case httpc:request(get, {Url, Headers}, http_opts(Timeout), [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, _RespHeaders, Body}} ->
            {ok, StatusCode, decode_body(Body)};
        {error, Reason} ->
            {error, Reason}
    end.

-spec http_post(string(), iodata(), pos_integer()) ->
                   {ok, pos_integer(), term()} | {error, term()}.
http_post(Url, JsonBody, Timeout) ->
    ensure_inets(),
    Headers = [{"accept", "application/json"}],
    ContentType = "application/json",
    case httpc:request(post,
                       {Url, Headers, ContentType, JsonBody},
                       http_opts(Timeout),
                       [{body_format, binary}])
    of
        {ok, {{_, StatusCode, _}, _RespHeaders, Body}} ->
            {ok, StatusCode, decode_body(Body)};
        {error, Reason} ->
            {error, Reason}
    end.

-spec http_delete(string(), pos_integer()) ->
                     {ok, pos_integer(), term()} | {error, term()}.
http_delete(Url, Timeout) ->
    ensure_inets(),
    Headers = [{"accept", "application/json"}],
    case httpc:request(delete, {Url, Headers}, http_opts(Timeout), [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, _RespHeaders, Body}} ->
            {ok, StatusCode, decode_body(Body)};
        {error, Reason} ->
            {error, Reason}
    end.

%% Shared HTTP options with TLS certificate verification.
%% Even though the default base_url is http://localhost, users may configure
%% https:// — and we must verify certificates when they do.
-spec http_opts(pos_integer()) -> list().
http_opts(Timeout) ->
    SslOpts = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 3}],
    [{timeout, Timeout}, {connect_timeout, 5000}, {ssl, SslOpts}].

-spec ensure_inets() -> ok.
ensure_inets() ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    ok.

-spec decode_body(binary()) -> json_term().
decode_body(<<>>) ->
    #{};
decode_body(Body) ->
    case beam_agent_json:safe_decode(Body) of
        {ok, Decoded} ->
            Decoded;
        {error, _} ->
            #{raw => Body}
    end.

%% Summarise args for logging without leaking secrets.
%% Redacts common API key formats: OpenAI (sk-), Anthropic (sk-ant-),
%% Google (AIza), GitHub (ghp_, gho_, ghs_, ghr_), generic (key-),
%% and any arg following a key-flag like --with-api-key.
-spec args_summary([[1..255, ...]]) -> string().
args_summary(Args) ->
    redact_args(Args, false, []).

-spec redact_args([[1..255, ...]], boolean(), [[1..255, ...]]) -> string().
redact_args([], _RedactNext, Acc) ->
    string:join(
        lists:reverse(Acc), " ");
redact_args([_Secret | Rest], true, Acc) ->
    %% Previous arg was a key-flag — redact this value
    redact_args(Rest, false, ["***" | Acc]);
redact_args(["--with-api-key" | Rest], _RedactNext, Acc) ->
    redact_args(Rest, true, ["--with-api-key" | Acc]);
redact_args(["--api-key" | Rest], _RedactNext, Acc) ->
    redact_args(Rest, true, ["--api-key" | Acc]);
redact_args([A | Rest], false, Acc) ->
    Safe =
        case looks_like_secret(A) of
            true ->
                "***";
            false ->
                A
        end,
    redact_args(Rest, false, [Safe | Acc]).

-spec looks_like_secret([1..255, ...]) -> boolean().
looks_like_secret(A) ->
    lists:any(fun(Prefix) -> lists:prefix(Prefix, A) end,
              ["sk-",      %% OpenAI / Anthropic
               "key-",     %% Generic
               "AIza",     %% Google API keys
               "ghp_",     %% GitHub personal access token
               "gho_",     %% GitHub OAuth token
               "ghs_",     %% GitHub server token
               "ghr_"]).      %% GitHub refresh token

-spec log_cli_result(non_neg_integer(), [string()]) -> ok.
log_cli_result(0, _Lines) ->
    logger:info("Auth CLI completed successfully"),
    ok;
log_cli_result(ExitCode, Lines) ->
    Preview =
        case Lines of
            [] ->
                "(no output)";
            [First | _] ->
                First
        end,
    logger:warning("Auth CLI exited ~b: ~s", [ExitCode, Preview]),
    ok.
