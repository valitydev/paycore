%%%
%%% Withdrawal machine — thin prg_machine client
%%%

-module(ff_withdrawal_machine).

%% API

-type id() :: prg_machine:id().
-type change() :: ff_withdrawal:event().
-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.
-type event() :: {integer(), timestamped_event(change())}.
-type st() :: #{
    model := withdrawal(),
    ctx := ctx(),
    times => {timestamp() | undefined, timestamp() | undefined}
}.
-type withdrawal() :: ff_withdrawal:withdrawal_state().
-type external_id() :: id().
-type event_range() :: {After :: non_neg_integer() | undefined, Limit :: non_neg_integer() | undefined}.

-type params() :: ff_withdrawal:params().
-type create_error() ::
    ff_withdrawal:create_error()
    | exists.

-type repair_error() :: ff_repair:repair_error().
-type repair_response() :: ff_repair:repair_response().

-type unknown_withdrawal_error() ::
    {unknown_withdrawal, id()}.

-type action() ::
    continue
    | sleep
    | undefined.

-type adjustment_params() :: ff_withdrawal:adjustment_params().

-type start_adjustment_error() ::
    ff_withdrawal:start_adjustment_error()
    | unknown_withdrawal_error().

-type notify_args() :: {session_finished, session_id(), session_result()}.

-type session_id() :: ff_withdrawal_session:id().
-type session_result() :: ff_withdrawal_session:session_result().

-export_type([id/0]).
-export_type([st/0]).
-export_type([action/0]).
-export_type([change/0]).
-export_type([event/0]).
-export_type([params/0]).
-export_type([withdrawal/0]).
-export_type([event_range/0]).
-export_type([external_id/0]).
-export_type([create_error/0]).
-export_type([repair_error/0]).
-export_type([repair_response/0]).
-export_type([start_adjustment_error/0]).

%% API

-export([create/2]).
-export([get/1]).
-export([get/2]).
-export([events/2]).
-export([repair/2]).
-export([notify/2]).
-export([start_adjustment/2]).

%% Accessors

-export([withdrawal/1]).
-export([ctx/1]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%% Internal types

-type ctx() :: ff_entity_context:context().

-define(NS, 'ff/withdrawal_v2').

%% API

-spec create(params(), ctx()) ->
    ok
    | {error, ff_withdrawal:create_error() | exists}.
create(Params, Ctx) ->
    do(fun() ->
        #{id := ID} = Params,
        Events = unwrap(ff_withdrawal:create(Params)),
        unwrap(prg_machine:start(?NS, ID, {Events, Ctx}))
    end).

-spec get(id()) ->
    {ok, st()}
    | {error, unknown_withdrawal_error()}.
get(ID) ->
    get(ID, {undefined, undefined}).

-spec get(id(), event_range()) ->
    {ok, st()}
    | {error, unknown_withdrawal_error()}.
get(ID, {After, Limit}) ->
    case prg_machine:get(?NS, ID, {After, Limit, forward}) of
        {ok, Machine} ->
            {ok, machine_to_st(Machine)};
        {error, notfound} ->
            {error, {unknown_withdrawal, ID}}
    end.

-spec events(id(), event_range()) ->
    {ok, [event()]}
    | {error, unknown_withdrawal_error()}.
events(ID, {After, Limit}) ->
    case prg_machine:get_history(?NS, ID, After, Limit, forward) of
        {ok, History} ->
            {ok, history_to_events(History)};
        {error, notfound} ->
            {error, {unknown_withdrawal, ID}}
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

-spec start_adjustment(id(), adjustment_params()) ->
    ok
    | {error, start_adjustment_error()}.
start_adjustment(WithdrawalID, Params) ->
    call(WithdrawalID, {start_adjustment, Params}).

-spec notify(id(), notify_args()) ->
    ok | {error, notfound} | no_return().
notify(ID, Args) ->
    prg_machine:notify(?NS, ID, Args).

%% Accessors

-spec withdrawal(st()) -> withdrawal().
withdrawal(#{model := Model}) ->
    Model.

-spec ctx(st()) -> ctx().
ctx(#{ctx := Ctx}) ->
    Ctx.

%% Internals

-spec machine_to_st(prg_machine:machine()) -> st().
machine_to_st(#{history := History, aux_state := AuxState} = Machine) ->
    Model = prg_machine:collapse(ff_withdrawal, Machine),
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

call(ID, Call) ->
    case prg_machine:call(?NS, ID, Call) of
        {ok, Reply} ->
            Reply;
        {error, notfound} ->
            {error, {unknown_withdrawal, ID}}
    end.

codec_timestamp({DateTime, USec} = Timestamp) when is_integer(USec) ->
    {DateTime, USec} = Timestamp;
codec_timestamp(DateTime) ->
    {DateTime, 0}.
