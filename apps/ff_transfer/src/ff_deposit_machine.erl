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
    ff_machine_lib:create(?NS, fun ff_deposit:create/1, Params, Ctx).

-spec get(id()) ->
    {ok, st()}
    | {error, unknown_deposit_error()}.
get(ID) ->
    get(ID, {undefined, undefined}).

-spec get(id(), event_range()) ->
    {ok, st()}
    | {error, unknown_deposit_error()}.
get(ID, {After, Limit}) ->
    ff_machine_lib:get(?NS, ID, {After, Limit}, ff_deposit, {unknown_deposit, ID}).

-spec events(id(), event_range()) ->
    {ok, [event()]}
    | {error, unknown_deposit_error()}.
events(ID, {After, Limit}) ->
    ff_machine_lib:events(?NS, ID, {After, Limit}, {unknown_deposit, ID}).

-spec repair(id(), ff_repair:scenario()) ->
    {ok, repair_response()} | {error, repair_call_error()}.
repair(ID, Scenario) ->
    ff_machine_lib:repair(?NS, ID, Scenario).

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
    ff_machine_lib:to_prg_result(ff_deposit:process_transfer(Deposit)).

-spec process_call(term(), machine()) -> no_return().
process_call(CallArgs, _Machine) ->
    erlang:error({unexpected_call, CallArgs}).

-spec process_repair(ff_repair:scenario(), machine()) -> prg_result() | {error, term()}.
process_repair(Scenario, Machine) ->
    ff_machine_lib:process_repair(ff_deposit, Machine, Scenario).

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Body) ->
    ff_machine_lib:marshal_event_body(deposit, ?EVENT_FORMAT_VERSION, Body).

-spec unmarshal_event_body(pos_integer(), binary()) -> prg_machine:event_body().
unmarshal_event_body(Format, Payload) ->
    ff_machine_lib:unmarshal_event_body(deposit, ?EVENT_FORMAT_VERSION, Format, Payload).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    ff_machine_lib:marshal_aux_state(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    ff_machine_lib:unmarshal_aux_state(Payload).
