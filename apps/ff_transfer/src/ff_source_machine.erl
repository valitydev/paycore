%%%
%%% Source machine — thin prg_machine client
%%%

-module(ff_source_machine).

%% API

-type id() :: prg_machine:id().
-type ctx() :: ff_entity_context:context().
-type source() :: ff_source:source_state().
-type change() :: ff_source:event().
-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.
-type event() :: {integer(), timestamped_event(change())}.
-type events() :: [event()].
-type event_range() :: {After :: non_neg_integer() | undefined, Limit :: non_neg_integer() | undefined}.

-type params() :: ff_source:params().
-type st() :: #{
    model := source(),
    ctx := ctx(),
    times => {timestamp() | undefined, timestamp() | undefined}
}.

-type repair_error() :: ff_repair:repair_error().
-type repair_response() :: ff_repair:repair_response().

-export_type([id/0]).
-export_type([st/0]).
-export_type([event/0]).
-export_type([repair_error/0]).
-export_type([repair_response/0]).
-export_type([params/0]).
-export_type([event_range/0]).

%% API

-export([create/2]).
-export([get/1]).
-export([get/2]).
-export([events/2]).

%% Accessors

-export([source/1]).
-export([ctx/1]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

-define(NS, 'ff/source_v1').

%% API

-spec create(params(), ctx()) ->
    ok
    | {error, ff_source:create_error() | exists}.
create(Params, Ctx) ->
    do(fun() ->
        #{id := ID} = Params,
        Events = unwrap(ff_source:create(Params)),
        unwrap(prg_machine:start(?NS, ID, {Events, Ctx}))
    end).

-spec get(id()) ->
    {ok, st()}
    | {error, notfound}.
get(ID) ->
    get(ID, {undefined, undefined}).

-spec get(id(), event_range()) ->
    {ok, st()}
    | {error, notfound}.
get(ID, {After, Limit}) ->
    case prg_machine:get(?NS, ID, prg_machine:history_range(After, Limit, forward)) of
        {ok, Machine} ->
            {ok, machine_to_st(Machine)};
        {error, notfound} ->
            {error, notfound}
    end.

-spec events(id(), event_range()) ->
    {ok, events()}
    | {error, notfound}.
events(ID, {After, Limit}) ->
    case prg_machine:get_history(?NS, ID, After, Limit, forward) of
        {ok, History} ->
            {ok, history_to_events(History)};
        {error, notfound} ->
            {error, notfound}
    end.

%% Accessors

-spec source(st()) -> source().
source(#{model := Model}) ->
    Model.

-spec ctx(st()) -> ctx().
ctx(#{ctx := Ctx}) ->
    Ctx.

%% Internals

-spec machine_to_st(prg_machine:machine()) -> st().
machine_to_st(#{history := History, aux_state := AuxState} = Machine) ->
    Model = prg_machine:collapse(ff_source, Machine),
    Ctx = maps:get(ctx, AuxState, #{}),
    #{
        model => Model,
        ctx => Ctx,
        times => history_times(History)
    }.

-spec history_to_events(prg_machine:history()) -> [event()].
history_to_events(History) ->
    [{EventID, {ev, codec_timestamp(Timestamp), Body}} || {EventID, Timestamp, Body} <- History].

-spec history_times(prg_machine:history()) -> {prg_machine:timestamp() | undefined, prg_machine:timestamp() | undefined}.
history_times([]) ->
    {undefined, undefined};
history_times(History) ->
    lists:foldl(
        fun({_EventID, Timestamp, _Body}, {Created, _Updated}) ->
            case Created of
                undefined -> {Timestamp, Timestamp};
                _ -> {Created, Timestamp}
            end
        end,
        {undefined, undefined},
        History
    ).

codec_timestamp({DateTime, USec} = Timestamp) when is_integer(USec) ->
    {DateTime, USec} = Timestamp;
codec_timestamp(DateTime) ->
    {DateTime, 0}.
