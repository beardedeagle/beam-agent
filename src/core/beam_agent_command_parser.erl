-module(beam_agent_command_parser).
-moduledoc """
Structural command parser for the BeamAgent command security architecture (Layer 0).

Parses shell command strings into structured representations that expose
composition operators, making them visible to subsequent security layers
instead of hiding them inside flat strings.

List-form commands bypass parsing entirely — they are inherently structured
and cannot be shell-injected.

This is intentionally a shallow parser. It detects top-level composition
operators and common shell metacharacters but does not attempt to fully
parse shell grammar. The goal is to surface structure, not to implement a
complete shell parser (which would itself be a security liability — parser
bugs become bypasses).

Unparseable input is classified as `opaque` with the highest risk level.

## Command Forms

**List-form** (safe by default — cannot be shell-injected):

```erlang
beam_agent_command_parser:parse([<<"git">>, <<"status">>]).
%% => #{type => simple, program => <<"git">>, args => [<<"status">>], ...}
```

**String-form** (requires security evaluation):

```erlang
beam_agent_command_parser:parse(<<"git status && rm -rf /">>).
%% => #{type => chain, operator => '&&', commands => [...]}
```
""".

-export([parse/1, categorize/1, flatten_commands/1]).
-export_type([command_struct/0, redirect_spec/0, command_category/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type command_struct() ::
    #{type := simple,
      program := binary(),
      args := [binary()],
      raw := binary(),
      input_form => list | string} |
    #{type := chain,
      operator := '&&' | '||' | ';',
      commands := [command_struct()],
      input_form => list | string} |
    #{type := pipeline,
      commands := [command_struct()],
      input_form => list | string} |
    #{type := subshell,
      form := '$()' | backtick,
      inner := binary(),
      input_form => list | string} |
    #{type := redirect,
      command := command_struct(),
      redirects := [redirect_spec()],
      input_form => list | string} |
    #{type := opaque,
      raw := binary(),
      input_form => list | string}.

-type redirect_spec() ::
    #{direction := in | out | append,
      target := binary()}.

-type command_category() ::
    destructive | filesystem_write | filesystem_read |
    network | process_control | package | vcs | build | unknown.

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-doc """
Parse a command into a structured representation.

Accepts three input forms:
- Binary: `<<"git status && ls">>` — parsed structurally
- String: `"git status"` — converted to binary, then parsed
- List of segments: `[<<"git">>, <<"status">>]` — fast path, inherently safe

Returns a `command_struct()` map tagged by structure type.
""".
-spec parse(binary() | string() | [binary() | string()]) -> command_struct().
%% List-form fast path: a non-empty list whose head is not an integer (i.e. not
%% a character-code string) is treated as a segment list and cannot be
%% shell-injected.  The `not is_integer(hd(Segments))` guard distinguishes a
%% flat char-list string like "git status" (where hd/1 returns a code-point
%% integer) from a binary-segment list like [<<"git">>, <<"status">>] (where
%% hd/1 returns a binary).  An empty list falls through to the string clause,
%% which produces #{type => opaque} for the empty-command edge case.
parse(Segments) when is_list(Segments), Segments =/= [], not is_integer(hd(Segments)) ->
    (parse_list_form(Segments))#{input_form => list};
parse(Str) when is_list(Str) ->
    (parse_string(to_binary(Str)))#{input_form => string};
parse(Bin) when is_binary(Bin) ->
    (parse_string(Bin))#{input_form => string}.

-doc """
Categorize a program name into a security-relevant category.

Categories affect rate limiting and temporal pattern detection in the
security guard (Layer 3). Paths are stripped — `/usr/bin/rm` categorizes
the same as `rm`.
""".
-spec categorize(binary()) -> command_category().
categorize(Program) when is_binary(Program) ->
    BaseName = list_to_binary(filename:basename(binary_to_list(Program))),
    categorize_program(BaseName).

-doc """
Extract all leaf commands from a parsed command structure.

Recursively flattens chains, pipelines, and redirects into a list of
leaf commands (simple, subshell, or opaque). Useful for security
evaluation where each leaf command must pass policy independently.
""".
-spec flatten_commands(command_struct()) -> [command_struct()].
flatten_commands(#{type := simple} = Cmd) ->
    [Cmd];
flatten_commands(#{type := chain, commands := Cmds}) ->
    lists:flatmap(fun flatten_commands/1, Cmds);
flatten_commands(#{type := pipeline, commands := Cmds}) ->
    lists:flatmap(fun flatten_commands/1, Cmds);
flatten_commands(#{type := redirect, command := Cmd}) ->
    flatten_commands(Cmd);
flatten_commands(#{type := subshell} = Cmd) ->
    [Cmd];
flatten_commands(#{type := opaque} = Cmd) ->
    [Cmd].

%%--------------------------------------------------------------------
%% Internal: List-form parsing (fast path)
%%--------------------------------------------------------------------

-spec parse_list_form([binary() | string()]) -> command_struct().
%% Guard against empty list: callers who bypass parse/1 and call this directly
%% receive a safe {error, empty_command} signal rather than a badmatch crash
%% on the [Program | Args] = Bins pattern match below.
parse_list_form([]) ->
    #{type => opaque, raw => <<>>, error => empty_command};
parse_list_form(Segments) ->
    Bins = [to_binary(S) || S <- Segments],
    [Program | Args] = Bins,
    Raw = iolist_to_binary(lists:join(<<" ">>, Bins)),
    #{type => simple, program => Program, args => Args, raw => Raw}.

%%--------------------------------------------------------------------
%% Internal: String-form parsing
%%--------------------------------------------------------------------

-spec parse_string(binary()) -> command_struct().
parse_string(Bin) ->
    Trimmed = string:trim(Bin),
    case Trimmed of
        <<>> -> #{type => opaque, raw => <<>>};
        _ ->
            Operators = scan_operators(Trimmed),
            build_from_operators(Trimmed, Operators)
    end.

%%--------------------------------------------------------------------
%% Internal: Operator Scanner
%%
%% Scans a binary for top-level shell operators while respecting
%% single-quote, double-quote, and parenthesis nesting. Returns a
%% list of {Position, Length, OperatorAtom} tuples in left-to-right
%% order.
%%--------------------------------------------------------------------

-type op_atom() :: '&&' | '||' | ';' | '|' | '$()' | backtick | '>' | '>>' | '<'.
-type op_info() :: {non_neg_integer(), pos_integer(), op_atom()}.

%% Suppress benign supertype warnings: specs are intentionally wider than
%% current call-site usage to permit future extension without spec churn.
-dialyzer({nowarn_function, [parse/1,
                             parse_list_form/1,
                             scan_operators/1,
                             scan/5,
                             build_pipeline/2,
                             extract_redirects/2,
                             split_at_operators/3,
                             parse_simple/1]}).

-spec scan_operators(binary()) -> [op_info()].
scan_operators(Bin) ->
    lists:reverse(scan(Bin, 0, none, 0, [])).

%% Base case: end of input
-spec scan(binary(), non_neg_integer(), none | single | double,
           non_neg_integer(), [op_info()]) -> [op_info()].
scan(<<>>, _Pos, _Quote, _Depth, Acc) ->
    Acc;

%% Inside single quotes — only closing ' matters
scan(<<$', Rest/binary>>, Pos, single, Depth, Acc) ->
    scan(Rest, Pos + 1, none, Depth, Acc);
scan(<<_, Rest/binary>>, Pos, single, Depth, Acc) ->
    scan(Rest, Pos + 1, single, Depth, Acc);

%% Inside double quotes — " ends, \ escapes next char
scan(<<$", Rest/binary>>, Pos, double, Depth, Acc) ->
    scan(Rest, Pos + 1, none, Depth, Acc);
scan(<<$\\, _, Rest/binary>>, Pos, double, Depth, Acc) ->
    scan(Rest, Pos + 2, double, Depth, Acc);
scan(<<_, Rest/binary>>, Pos, double, Depth, Acc) ->
    scan(Rest, Pos + 1, double, Depth, Acc);

%% Outside quotes — detect operators at depth 0
%% Multi-char patterns before single-char for same starting byte.

%% Quote entry
scan(<<$', Rest/binary>>, Pos, none, Depth, Acc) ->
    scan(Rest, Pos + 1, single, Depth, Acc);
scan(<<$", Rest/binary>>, Pos, none, Depth, Acc) ->
    scan(Rest, Pos + 1, double, Depth, Acc);

%% Backslash escape (consume 2 chars)
scan(<<$\\, _, Rest/binary>>, Pos, none, Depth, Acc) ->
    scan(Rest, Pos + 2, none, Depth, Acc);

%% Command substitution $(...) — flag at any depth
scan(<<$$, $(, Rest/binary>>, Pos, none, Depth, Acc) ->
    scan(Rest, Pos + 2, none, Depth + 1,
         [{Pos, 2, '$()'} | Acc]);

%% Backtick command substitution
scan(<<$`, Rest/binary>>, Pos, none, Depth, Acc) ->
    scan(Rest, Pos + 1, none, Depth,
         [{Pos, 1, backtick} | Acc]);

%% Two-char operators — only at depth 0
scan(<<$&, $&, Rest/binary>>, Pos, none, Depth, Acc) when Depth =:= 0 ->
    scan(Rest, Pos + 2, none, 0, [{Pos, 2, '&&'} | Acc]);
scan(<<$|, $|, Rest/binary>>, Pos, none, Depth, Acc) when Depth =:= 0 ->
    scan(Rest, Pos + 2, none, 0, [{Pos, 2, '||'} | Acc]);
scan(<<$>, $>, Rest/binary>>, Pos, none, Depth, Acc) when Depth =:= 0 ->
    scan(Rest, Pos + 2, none, 0, [{Pos, 2, '>>'} | Acc]);

%% Single-char operators — only at depth 0
scan(<<$;, Rest/binary>>, Pos, none, Depth, Acc) when Depth =:= 0 ->
    scan(Rest, Pos + 1, none, 0, [{Pos, 1, ';'} | Acc]);
scan(<<$|, Rest/binary>>, Pos, none, Depth, Acc) when Depth =:= 0 ->
    scan(Rest, Pos + 1, none, 0, [{Pos, 1, '|'} | Acc]);
scan(<<$>, Rest/binary>>, Pos, none, Depth, Acc) when Depth =:= 0 ->
    scan(Rest, Pos + 1, none, 0, [{Pos, 1, '>'} | Acc]);
scan(<<$<, Rest/binary>>, Pos, none, Depth, Acc) when Depth =:= 0 ->
    scan(Rest, Pos + 1, none, 0, [{Pos, 1, '<'} | Acc]);

%% Parenthesis nesting
scan(<<$(, Rest/binary>>, Pos, none, Depth, Acc) ->
    scan(Rest, Pos + 1, none, Depth + 1, Acc);
scan(<<$), Rest/binary>>, Pos, none, Depth, Acc) when Depth > 0 ->
    scan(Rest, Pos + 1, none, Depth - 1, Acc);

%% Any other character
scan(<<_, Rest/binary>>, Pos, none, Depth, Acc) ->
    scan(Rest, Pos + 1, none, Depth, Acc).

%%--------------------------------------------------------------------
%% Internal: Build command structure from scanned operators
%%--------------------------------------------------------------------

-spec build_from_operators(binary(), [op_info()]) -> command_struct().
build_from_operators(Bin, Operators) ->
    %% Partition operators by type, then process by precedence:
    %% chain (;, &&, ||) > pipeline (|) > redirect (>, >>, <) > subshell ($(), `)
    ChainOps = [O || {_, _, Op} = O <- Operators, is_chain_op(Op)],
    PipeOps  = [O || {_, _, '|'} = O <- Operators],
    SubOps   = [O || {_, _, Op} = O <- Operators, Op =:= '$()' orelse Op =:= backtick],
    RedirOps = [O || {_, _, Op} = O <- Operators, is_redirect_op(Op)],

    %% Process in precedence order: lowest-precedence operators first
    %% so they become the outermost structure
    case split_lowest_precedence_chain(ChainOps) of
        {found, {Pos, Len, Op}} ->
            build_chain(Bin, Pos, Len, Op);
        none ->
            case PipeOps of
                [_ | _] ->
                    build_pipeline(Bin, PipeOps);
                [] when SubOps =/= [] ->
                    %% Contains command substitution — opaque (high risk)
                    #{type => opaque, raw => Bin};
                [] ->
                    case RedirOps of
                        [_ | _] -> build_redirect(Bin, RedirOps);
                        []      -> parse_simple(Bin)
                    end
            end
    end.

%% Find the lowest-precedence chain operator (leftmost ; first, then leftmost && or ||)
-spec split_lowest_precedence_chain([op_info()]) -> {found, op_info()} | none.
split_lowest_precedence_chain([]) ->
    none;
split_lowest_precedence_chain(Ops) ->
    Semicolons = [O || {_, _, ';'} = O <- Ops],
    case Semicolons of
        [First | _] -> {found, First};
        [] ->
            %% && and || have equal precedence — take leftmost
            [{First, _, _} | _] = lists:sort(
                fun({P1, _, _}, {P2, _, _}) -> P1 =< P2 end, Ops),
            {found, lists:keyfind(First, 1, Ops)}
    end.

%% Split on a chain operator and recursively parse each half
-spec build_chain(binary(), non_neg_integer(), pos_integer(), atom()) -> command_struct().
build_chain(Bin, Pos, Len, Op) ->
    Left = string:trim(binary:part(Bin, 0, Pos)),
    RightStart = Pos + Len,
    Right = string:trim(binary:part(Bin, RightStart, byte_size(Bin) - RightStart)),
    LeftCmd = parse_string(Left),
    RightCmd = parse_string(Right),
    #{type => chain, operator => Op, commands => [LeftCmd, RightCmd]}.

%% Split on all pipe operators
-spec build_pipeline(binary(), [op_info()]) -> command_struct().
build_pipeline(Bin, PipeOps) ->
    Sorted = lists:sort(fun({P1, _, _}, {P2, _, _}) -> P1 =< P2 end, PipeOps),
    Segments = split_at_operators(Bin, Sorted, 0),
    Commands = [parse_segment_no_pipe(string:trim(S)) || S <- Segments],
    #{type => pipeline, commands => Commands}.

%% Parse a pipeline segment (no pipe operators, but may have redirects)
-spec parse_segment_no_pipe(binary()) -> command_struct().
parse_segment_no_pipe(<<>>) ->
    #{type => opaque, raw => <<>>};
parse_segment_no_pipe(Bin) ->
    Operators = scan_operators(Bin),
    SubOps   = [O || {_, _, Op} = O <- Operators, Op =:= '$()' orelse Op =:= backtick],
    RedirOps = [O || {_, _, Op} = O <- Operators, is_redirect_op(Op)],
    case SubOps of
        [_ | _] -> #{type => opaque, raw => Bin};
        [] ->
            case RedirOps of
                [_ | _] -> build_redirect(Bin, RedirOps);
                []      -> parse_simple(Bin)
            end
    end.

%% Build a redirect wrapper around the base command
-spec build_redirect(binary(), [op_info()]) -> command_struct().
build_redirect(Bin, RedirOps) ->
    %% Sort redirects by position
    Sorted = lists:sort(fun({P1, _, _}, {P2, _, _}) -> P1 =< P2 end, RedirOps),
    %% The command is everything before the first redirect
    {FirstPos, _, _} = hd(Sorted),
    CmdPart = string:trim(binary:part(Bin, 0, FirstPos)),
    Redirects = extract_redirects(Bin, Sorted),
    BaseCmd = case CmdPart of
        <<>> -> #{type => opaque, raw => Bin};
        _    -> parse_simple(CmdPart)
    end,
    #{type => redirect, command => BaseCmd, redirects => Redirects}.

%% Extract redirect specs from operator positions
-spec extract_redirects(binary(), [op_info()]) -> [redirect_spec()].
extract_redirects(Bin, Ops) ->
    extract_redirects(Bin, Ops, byte_size(Bin)).

-spec extract_redirects(binary(), [op_info()], non_neg_integer()) -> [redirect_spec()].
extract_redirects(_Bin, [], _Size) ->
    [];
extract_redirects(Bin, [{Pos, Len, Op} | Rest], Size) ->
    TargetStart = Pos + Len,
    %% Target extends to the next operator or end of string
    TargetEnd = case Rest of
        [{NextPos, _, _} | _] -> NextPos;
        [] -> Size
    end,
    Target = string:trim(binary:part(Bin, TargetStart, TargetEnd - TargetStart)),
    Direction = case Op of
        '>'  -> out;
        '>>' -> append;
        '<'  -> in
    end,
    [#{direction => Direction, target => Target}
     | extract_redirects(Bin, Rest, Size)].

%% Split binary at operator positions, producing segments between operators
-spec split_at_operators(binary(), [op_info()], non_neg_integer()) -> [binary()].
split_at_operators(Bin, [], Start) ->
    [binary:part(Bin, Start, byte_size(Bin) - Start)];
split_at_operators(Bin, [{Pos, Len, _} | Rest], Start) ->
    Segment = binary:part(Bin, Start, Pos - Start),
    [Segment | split_at_operators(Bin, Rest, Pos + Len)].

%%--------------------------------------------------------------------
%% Internal: Simple command parsing
%%--------------------------------------------------------------------

%% Parse a simple command (no composition operators) into program + args.
-spec parse_simple(binary()) -> command_struct().
parse_simple(Bin) ->
    case split_words(Bin) of
        [] ->
            #{type => opaque, raw => Bin};
        [Program | Args] ->
            #{type => simple,
              program => strip_outer_quotes(Program),
              args => Args,
              raw => Bin}
    end.

%% Split a command string into words, respecting single and double quotes.
%% Returns a list of binaries (quotes are preserved in args for policy
%% matching, stripped only from the program name).
-spec split_words(binary()) -> [binary()].
split_words(Bin) ->
    lists:reverse(split_words(Bin, byte_size(Bin), 0, none, 0, [])).

-spec split_words(binary(), non_neg_integer(), non_neg_integer(),
                  none | single | double, non_neg_integer(), [binary()]) -> [binary()].
split_words(_Bin, Size, Pos, _Quote, Start, Acc) when Pos >= Size ->
    add_word_if_nonempty(Acc, _Bin, Start, Size);

split_words(Bin, Size, Pos, single, Start, Acc) ->
    case binary:at(Bin, Pos) of
        $' -> split_words(Bin, Size, Pos + 1, none, Start, Acc);
        _  -> split_words(Bin, Size, Pos + 1, single, Start, Acc)
    end;

split_words(Bin, Size, Pos, double, Start, Acc) ->
    case binary:at(Bin, Pos) of
        $"                     -> split_words(Bin, Size, Pos + 1, none, Start, Acc);
        $\\ when Pos + 1 < Size -> split_words(Bin, Size, Pos + 2, double, Start, Acc);
        _                      -> split_words(Bin, Size, Pos + 1, double, Start, Acc)
    end;

split_words(Bin, Size, Pos, none, Start, Acc) ->
    case binary:at(Bin, Pos) of
        $' -> split_words(Bin, Size, Pos + 1, single, Start, Acc);
        $" -> split_words(Bin, Size, Pos + 1, double, Start, Acc);
        $\\ when Pos + 1 < Size -> split_words(Bin, Size, Pos + 2, none, Start, Acc);
        C when C =:= $\s; C =:= $\t; C =:= $\n ->
            NewAcc = add_word_if_nonempty(Acc, Bin, Start, Pos),
            split_words(Bin, Size, Pos + 1, none, Pos + 1, NewAcc);
        _ -> split_words(Bin, Size, Pos + 1, none, Start, Acc)
    end.

-spec add_word_if_nonempty([binary()], binary(), non_neg_integer(),
                           non_neg_integer()) -> [binary()].
add_word_if_nonempty(Acc, Bin, Start, End) when End > Start ->
    Word = binary:part(Bin, Start, End - Start),
    case string:trim(Word) of
        <<>> -> Acc;
        Trimmed -> [Trimmed | Acc]
    end;
add_word_if_nonempty(Acc, _Bin, _Start, _End) ->
    Acc.

%%--------------------------------------------------------------------
%% Internal: Categorization
%%--------------------------------------------------------------------

-spec categorize_program(binary()) -> command_category().
%% Destructive commands
categorize_program(<<"rm">>)       -> destructive;
categorize_program(<<"rmdir">>)    -> destructive;
categorize_program(<<"shred">>)    -> destructive;
categorize_program(<<"truncate">>) -> destructive;
categorize_program(<<"unlink">>)   -> destructive;
%% Filesystem write
categorize_program(<<"cp">>)       -> filesystem_write;
categorize_program(<<"mv">>)       -> filesystem_write;
categorize_program(<<"touch">>)    -> filesystem_write;
categorize_program(<<"mkdir">>)    -> filesystem_write;
categorize_program(<<"chmod">>)    -> filesystem_write;
categorize_program(<<"chown">>)    -> filesystem_write;
categorize_program(<<"chgrp">>)    -> filesystem_write;
categorize_program(<<"ln">>)       -> filesystem_write;
categorize_program(<<"install">>)  -> filesystem_write;
categorize_program(<<"tee">>)      -> filesystem_write;
categorize_program(<<"dd">>)       -> filesystem_write;
categorize_program(<<"mkfs">>)     -> filesystem_write;
%% Filesystem read
categorize_program(<<"ls">>)       -> filesystem_read;
categorize_program(<<"cat">>)      -> filesystem_read;
categorize_program(<<"head">>)     -> filesystem_read;
categorize_program(<<"tail">>)     -> filesystem_read;
categorize_program(<<"find">>)     -> filesystem_read;
categorize_program(<<"grep">>)     -> filesystem_read;
categorize_program(<<"rg">>)       -> filesystem_read;
categorize_program(<<"ag">>)       -> filesystem_read;
categorize_program(<<"fd">>)       -> filesystem_read;
categorize_program(<<"wc">>)       -> filesystem_read;
categorize_program(<<"du">>)       -> filesystem_read;
categorize_program(<<"df">>)       -> filesystem_read;
categorize_program(<<"stat">>)     -> filesystem_read;
categorize_program(<<"file">>)     -> filesystem_read;
categorize_program(<<"less">>)     -> filesystem_read;
categorize_program(<<"more">>)     -> filesystem_read;
categorize_program(<<"diff">>)     -> filesystem_read;
categorize_program(<<"tree">>)     -> filesystem_read;
categorize_program(<<"realpath">>) -> filesystem_read;
categorize_program(<<"readlink">>) -> filesystem_read;
categorize_program(<<"pwd">>)      -> filesystem_read;
categorize_program(<<"which">>)    -> filesystem_read;
categorize_program(<<"whereis">>)  -> filesystem_read;
categorize_program(<<"type">>)     -> filesystem_read;
%% Network
categorize_program(<<"curl">>)     -> network;
categorize_program(<<"wget">>)     -> network;
categorize_program(<<"ssh">>)      -> network;
categorize_program(<<"scp">>)      -> network;
categorize_program(<<"sftp">>)     -> network;
categorize_program(<<"rsync">>)    -> network;
categorize_program(<<"nc">>)       -> network;
categorize_program(<<"ncat">>)     -> network;
categorize_program(<<"nmap">>)     -> network;
categorize_program(<<"ping">>)     -> network;
categorize_program(<<"dig">>)      -> network;
categorize_program(<<"host">>)     -> network;
categorize_program(<<"nslookup">>) -> network;
categorize_program(<<"telnet">>)   -> network;
categorize_program(<<"ftp">>)      -> network;
%% Process control
categorize_program(<<"kill">>)     -> process_control;
categorize_program(<<"pkill">>)    -> process_control;
categorize_program(<<"killall">>)  -> process_control;
categorize_program(<<"ps">>)       -> process_control;
categorize_program(<<"top">>)      -> process_control;
categorize_program(<<"htop">>)     -> process_control;
categorize_program(<<"nice">>)     -> process_control;
categorize_program(<<"renice">>)   -> process_control;
categorize_program(<<"nohup">>)    -> process_control;
categorize_program(<<"timeout">>)  -> process_control;
%% Package managers
categorize_program(<<"apt">>)      -> package;
categorize_program(<<"apt-get">>)  -> package;
categorize_program(<<"yum">>)      -> package;
categorize_program(<<"dnf">>)      -> package;
categorize_program(<<"pacman">>)   -> package;
categorize_program(<<"brew">>)     -> package;
categorize_program(<<"npm">>)      -> package;
categorize_program(<<"yarn">>)     -> package;
categorize_program(<<"pnpm">>)     -> package;
categorize_program(<<"pip">>)      -> package;
categorize_program(<<"pip3">>)     -> package;
categorize_program(<<"cargo">>)    -> package;
categorize_program(<<"gem">>)      -> package;
categorize_program(<<"mix">>)      -> package;
categorize_program(<<"rebar3">>)   -> package;
categorize_program(<<"hex">>)      -> package;
%% Version control
categorize_program(<<"git">>)      -> vcs;
categorize_program(<<"hg">>)       -> vcs;
categorize_program(<<"svn">>)      -> vcs;
%% Build tools
categorize_program(<<"make">>)     -> build;
categorize_program(<<"cmake">>)    -> build;
categorize_program(<<"ninja">>)    -> build;
categorize_program(<<"gcc">>)      -> build;
categorize_program(<<"g++">>)      -> build;
categorize_program(<<"clang">>)    -> build;
categorize_program(<<"rustc">>)    -> build;
categorize_program(<<"erlc">>)     -> build;
categorize_program(<<"elixirc">>)  -> build;
categorize_program(<<"javac">>)    -> build;
categorize_program(<<"go">>)       -> build;
%% Fallback
categorize_program(_)              -> unknown.

%%--------------------------------------------------------------------
%% Internal: Helpers
%%--------------------------------------------------------------------

-spec is_chain_op(op_atom()) -> boolean().
is_chain_op('&&') -> true;
is_chain_op('||') -> true;
is_chain_op(';')  -> true;
is_chain_op(_)    -> false.

-spec is_redirect_op(op_atom()) -> boolean().
is_redirect_op('>')  -> true;
is_redirect_op('>>') -> true;
is_redirect_op('<')  -> true;
is_redirect_op(_)    -> false.

-spec strip_outer_quotes(binary()) -> binary().
strip_outer_quotes(<<$', Rest/binary>>) when byte_size(Rest) >= 1 ->
    case binary:last(Rest) of
        $' -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _  -> <<$', Rest/binary>>
    end;
strip_outer_quotes(<<$", Rest/binary>>) when byte_size(Rest) >= 1 ->
    case binary:last(Rest) of
        $" -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _  -> <<$", Rest/binary>>
    end;
strip_outer_quotes(Bin) ->
    Bin.

-spec to_binary(binary() | string()) -> binary().
to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(Str) when is_list(Str)   -> unicode:characters_to_binary(Str).
