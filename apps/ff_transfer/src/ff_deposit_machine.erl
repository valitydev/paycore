%%%
%%% Deposit machine — thin prg_machine client
%%%

-module(ff_deposit_machine).

%% API

-type id() :: prg_machine:id().
-type change() :: ff_deposit:event().
-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.
-type event() :: {integer(), timestamped_event(change())}.
-type st() :: #{
    model := deposit(),
    ctx := ctx(),
    times => {timestamp() | undefined, timestamp() | undefined}
}.
-type deposit() :: ff_deposit:deposit_state().
-type external_id() :: id().
-type event_range() :: {After :: non_neg_integer() | undefined, Limit :: non_neg_integer() | undefined}.

-type params() :: ff_deposit:params().
-type create_error() ::
    ff_deposit:create_error()
    | exists.

-type repair_error() :: ff_repair:repair_error().
-type repair_response() :: ff_repair:repair_response().

-type unknown_deposit_error() ::
    {unknown_deposit, id()}.

-export_type([id/0]).
-export_type([st/0]).
-export_type([change/0]).
-export_type([event/0]).
-export_type([params/0]).
-export_type([deposit/0]).
-export_type([event_range/0]).
-export_type([external_id/0]).
-export_type([create_error/0]).
-export_type([repair_error/0]).

%% API

-export([create/2]).
-export([get/1]).
-export([get/2]).
-export([events/2]).
-export([repair/2]).

%% Accessors

-export([deposit/1]).
-export([ctx/1]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%% Internal types

-type ctx() :: ff_entity_context:context().

-define(NS, 'ff/deposit_v1').

%% API

-spec create(params(), ctx()) ->
    ok
    | {error, ff_deposit:create_error() | exists}.
create(Params, Ctx) ->
    do(fun() ->
        #{id := ID} = Params,
        Events = unwrap(ff_deposit:create(Params)),
        unwrap(prg_machine:start(?NS, ID, {Events, Ctx}))
    end).

-spec get(id()) ->
    {ok, st()}
    | {error, unknown_deposit_error()}.
get(ID) ->
    get(ID, {undefined, undefined}).

-spec get(id(), event_range()) ->
    {ok, st()}
    | {error, unknown_deposit_error()}.
get(ID, {After, Limit}) ->
    case prg_machine:get(?NS, ID, prg_machine:history_range(After, Limit, forward)) of
        {ok, Machine} ->
            {ok, machine_to_st(Machine)};
        {error, notfound} ->
            {error, {unknown_deposit, ID}}
    end.

-spec events(id(), event_range()) ->
    {ok, [event()]}
    | {error, unknown_deposit_error()}.
events(ID, {After, Limit}) ->
    case prg_machine:get_history(?NS, ID, After, Limit, forward) of
        {ok, History} ->
            {ok, history_to_events(History)};
        {error, notfound} ->
            {error, {unknown_deposit, ID}}
    end.

-spec repair(id(), ff_repair:scenario()) ->
    {ok, repair_response()} | {error, notfound | working | {failed, repair_error()}}.
repair(ID, Scenario) ->
    case prg_machine:repair(?NS, ID, Scenario) of
        {ok, Response} ->
            {ok, Response};
        {error, notfound} ->
            {error, notfound};
        {error, working} ->
            {error, working};
        {error, failed} ->
            {error, {failed, {invalid_result, unexpected_failure}}};
        {error, {repair, {failed, _Reason}}} = Error ->
            Error
    end.

%% Accessors

-spec deposit(st()) -> deposit().
deposit(#{model := Model}) ->
    Model.

-spec ctx(st()) -> ctx().
ctx(#{ctx := Ctx}) ->
    Ctx.

%% Internals

-spec machine_to_st(prg_machine:machine()) -> st().
machine_to_st(#{history := History, aux_state := AuxState} = Machine) ->
    Model = prg_machine:collapse(ff_deposit, Machine),
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
