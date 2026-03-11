-module(beam_agent_queue).
-moduledoc false.

-export([
    new/0,
    new/1,
    push/2,
    pop/1,
    len/1,
    is_full/1,
    is_empty/1,
    to_list/1
]).

-export_type([queue/0]).

-record(awq, {
    q   :: queue:queue(),
    len :: non_neg_integer(),
    max :: pos_integer() | infinity
}).

-opaque queue() :: #awq{}.

%%%===================================================================
%%% API
%%%===================================================================

-doc "Create an unbounded queue.".
-spec new() -> queue().
new() ->
    new(infinity).

-doc "Create a queue with a maximum capacity.".
-spec new(pos_integer() | infinity) -> queue().
new(Max) ->
    #awq{q = queue:new(), len = 0, max = Max}.

-doc "Push an item onto the back of the queue. Returns `{error, queue_full}` if at capacity.".
-spec push(term(), queue()) -> {ok, queue()} | {error, queue_full}.
push(_Item, #awq{len = Len, max = Max}) when is_integer(Max), Len >= Max ->
    {error, queue_full};
push(Item, #awq{q = Q, len = Len} = AWQ) ->
    {ok, AWQ#awq{q = queue:in(Item, Q), len = Len + 1}}.

-doc "Pop an item from the front of the queue. Returns `empty` if the queue has no items.".
-spec pop(queue()) -> {ok, term(), queue()} | empty.
pop(#awq{len = 0}) ->
    empty;
pop(#awq{q = Q, len = Len} = AWQ) ->
    {{value, Item}, Q2} = queue:out(Q),
    {ok, Item, AWQ#awq{q = Q2, len = Len - 1}}.

-doc "Current number of items in the queue.".
-spec len(queue()) -> non_neg_integer().
len(#awq{len = Len}) ->
    Len.

-doc "Check whether the queue is at maximum capacity.".
-spec is_full(queue()) -> boolean().
is_full(#awq{max = infinity}) ->
    false;
is_full(#awq{len = Len, max = Max}) ->
    Len >= Max.

-doc "Check whether the queue is empty.".
-spec is_empty(queue()) -> boolean().
is_empty(#awq{len = 0}) ->
    true;
is_empty(_) ->
    false.

-doc "Convert the queue to a list (front to back). For debugging/testing.".
-spec to_list(queue()) -> [term()].
to_list(#awq{q = Q}) ->
    queue:to_list(Q).
