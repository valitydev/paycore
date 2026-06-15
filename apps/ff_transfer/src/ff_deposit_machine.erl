%%%
%%% Deposit machine
%%%

-module(ff_deposit_machine).

-behaviour(prg_machine).

-define(EVENT_FORMAT_VERSION, 1).

%% API

-type id() :: prg_machine:id().
-type change() :: ff_deposit:event().
-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.
-type event() :: {integer(), timestamped_event(change())}.
-type st() :: #{
    model := deposit(),
    ctx := ctx()
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
-type repair_call_error() :: ff_machine_lib:repair_call_error().

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
-export_type([repair_call_error/0]).

%% API

-export([create/2]).
-export([get/1]).
-export([get/2]).
-export([events/2]).
-export([repair/2]).

%% Accessors

-export([deposit/1]).
-export([ctx/1]).

%% prg_machine

-export([namespace/0]).
-export([init/2]).
-export([process_signal/2]).
-export([process_call/2]).
-export([process_repair/2]).
-export([marshal_event_body/1]).
-export([unmarshal_event_body/2]).
-export([marshal_aux_state/1]).
-export([unmarshal_aux_state/1]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%% Internal types

-type ctx() :: ff_entity_context:context().
-type machine() :: prg_machine:machine().
-type prg_result() :: prg_machine:result().

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
            {error, {unknown_deposit, ID}};
        {error, {exception, Class, Reason}} ->
            erlang:error({process_exception, Class, Reason})
    end.

-spec events(id(), event_range()) ->
    {ok, [event()]}
    | {error, unknown_deposit_error()}.
events(ID, {After, Limit}) ->
    case prg_machine:get_history(?NS, ID, After, Limit, forward) of
        {ok, History} ->
            {ok, ff_machine_lib:history_to_events(History)};
        {error, notfound} ->
            {error, {unknown_deposit, ID}};
        {error, {exception, Class, Reason}} ->
            erlang:error({process_exception, Class, Reason})
    end.

-spec repair(id(), ff_repair:scenario()) ->
    {ok, repair_response()} | {error, repair_call_error()}.
repair(ID, Scenario) ->
    case prg_machine:repair(?NS, ID, Scenario) of
        {ok, Response} ->
            {ok, Response};
        {error, notfound} ->
            {error, notfound};
        {error, working} ->
            {error, working};
        {error, {repair, {failed, Reason}}} ->
            {error, {failed, Reason}};
        {error, failed} = Error ->
            Error;
        {error, {exception, _Class, _Reason} = Exception} ->
            {error, Exception}
    end.

%% Accessors

-spec deposit(st()) -> deposit().
deposit(#{model := Model}) ->
    Model.

-spec ctx(st()) -> ctx().
ctx(#{ctx := Ctx}) ->
    Ctx.

%% prg_machine

-spec namespace() -> prg_machine:namespace().
namespace() ->
    ?NS.

-spec init({[change()], ctx()}, machine()) -> prg_result().
init({Events, Ctx}, _Machine) ->
    #{
        events => Events,
        action => timeout,
        auxst => #{ctx => Ctx}
    }.

-spec process_signal(prg_machine:signal(), machine()) -> prg_result().
process_signal(timeout, Machine) ->
    Deposit = prg_machine:collapse(ff_deposit, Machine),
    process_transfer_result(ff_deposit:process_transfer(Deposit), Machine).

-spec process_call(term(), machine()) -> no_return().
process_call(CallArgs, _Machine) ->
    erlang:error({unexpected_call, CallArgs}).

-spec process_repair(ff_repair:scenario(), machine()) -> prg_result() | {error, term()}.
process_repair(Scenario, Machine) ->
    case ff_repair:apply_scenario(ff_deposit, ff_machine_lib:to_repair_machine(Machine), Scenario) of
        {ok, {_Response, Result}} ->
            ff_machine_lib:from_repair_result(Result, Machine);
        {error, Reason} ->
            {error, Reason}
    end.

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Body) ->
    Timestamped = {ev, prg_machine:timestamp(), Body},
    Encoded = ff_machine_codec:marshal_event(deposit, ?EVENT_FORMAT_VERSION, Timestamped),
    {?EVENT_FORMAT_VERSION, ff_machine_codec:payload_to_binary(Encoded)}.

-spec unmarshal_event_body(pos_integer(), binary()) -> prg_machine:event_body().
unmarshal_event_body(?EVENT_FORMAT_VERSION, Payload) ->
    Timestamped = ff_machine_codec:unmarshal_event(deposit, ?EVENT_FORMAT_VERSION, Payload),
    ff_machine_lib:event_body_from_timestamped(Timestamped);
unmarshal_event_body(Format, _Payload) ->
    erlang:error({unknown_event_format, Format}).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    ff_machine_codec:marshal_aux_state(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    ff_machine_codec:unmarshal_aux_state(Payload).

%% Internals

-spec machine_to_st(prg_machine:machine()) -> st().
machine_to_st(#{aux_state := undefined} = Machine) ->
    machine_to_st(Machine#{aux_state => #{}});
machine_to_st(#{aux_state := AuxState} = Machine) ->
    Model = prg_machine:collapse(ff_deposit, Machine),
    Ctx = maps:get(ctx, AuxState, #{}),
    #{
        model => Model,
        ctx => Ctx
    }.

-spec process_transfer_result({prg_action:t(), [change()]}, machine()) -> prg_result().
process_transfer_result({Action, Events}, Machine) ->
    #{
        events => Events,
        action => Action,
        auxst => maps:get(aux_state, Machine, #{})
    }.
