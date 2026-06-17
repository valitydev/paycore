%%%
%%% Destination machine
%%%

-module(ff_destination_machine).

-behaviour(prg_machine).

-define(EVENT_FORMAT_VERSION, 1).

%% API

-type id() :: prg_machine:id().
-type ctx() :: ff_entity_context:context().
-type destination() :: ff_destination:destination_state().
-type change() :: ff_destination:event().
-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.
-type event() :: {integer(), timestamped_event(change())}.
-type events() :: [event()].
-type event_range() :: {After :: non_neg_integer() | undefined, Limit :: non_neg_integer() | undefined}.

-type params() :: ff_destination:params().
-type st() :: #{
    model := destination(),
    ctx := ctx()
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

-export([destination/1]).
-export([ctx/1]).

%% prg_machine

-export([namespace/0]).
-export([init/2]).
-export([process_signal/2]).
-export([process_call/2]).
-export([process_repair/2]).
-export([marshal_event_body/1]).
-export([unmarshal_event_body/1]).
-export([marshal_aux_state/1]).
-export([unmarshal_aux_state/1]).

-type machine() :: prg_machine:machine().
-type prg_result() :: prg_machine:result().

-define(NS, 'ff/destination_v2').

%% API

-spec create(params(), ctx()) ->
    ok
    | {error, ff_destination:create_error() | exists}.
create(Params, Ctx) ->
    ff_machine_lib:create(?NS, fun ff_destination:create/1, Params, Ctx).

-spec get(id()) ->
    {ok, st()}
    | {error, notfound}.
get(ID) ->
    get(ID, {undefined, undefined}).

-spec get(id(), event_range()) ->
    {ok, st()}
    | {error, notfound}.
get(ID, {After, Limit}) ->
    ff_machine_lib:get(?NS, ID, {After, Limit}, ff_destination, notfound).

-spec events(id(), event_range()) ->
    {ok, events()}
    | {error, notfound}.
events(ID, {After, Limit}) ->
    ff_machine_lib:events(?NS, ID, {After, Limit}, notfound).

%% Accessors

-spec destination(st()) -> destination().
destination(#{model := Model}) ->
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
    ff_machine_lib:init_result(Events, Ctx).

-spec process_signal(prg_machine:signal(), machine()) -> prg_result().
process_signal(timeout, _Machine) ->
    #{}.

-spec process_call(term(), machine()) -> no_return().
process_call(CallArgs, _Machine) ->
    erlang:error({unexpected_call, CallArgs}).

-spec process_repair(ff_repair:scenario(), machine()) -> prg_result() | {error, term()}.
process_repair(Scenario, Machine) ->
    ff_machine_lib:process_repair(ff_destination, Machine, Scenario).

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Body) ->
    ff_machine_lib:marshal_event_body(destination, ?EVENT_FORMAT_VERSION, Body).

-spec unmarshal_event_body(binary()) -> prg_machine:event_body().
unmarshal_event_body(Payload) ->
    ff_machine_lib:unmarshal_event_body(destination, Payload).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    ff_machine_lib:marshal_aux_state(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    ff_machine_lib:unmarshal_aux_state(Payload).
