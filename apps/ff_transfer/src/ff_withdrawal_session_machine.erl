%%%
%%% Withdrawal session machine
%%%

-module(ff_withdrawal_session_machine).

-behaviour(prg_machine).

-define(NS, 'ff/withdrawal/session_v2').
-define(EVENT_FORMAT_VERSION, 1).

%% API

-export([session/1]).
-export([ctx/1]).

-export([create/3]).
-export([get/1]).
-export([get/2]).
-export([events/2]).
-export([repair/2]).
-export([process_callback/1]).

%% prg_machine

-export([namespace/0]).
-export([init/2]).
-export([process_signal/2]).
-export([process_call/2]).
-export([process_repair/2]).
-export([process_notification/2]).
-export([marshal_event_body/1]).
-export([unmarshal_event_body/1]).
-export([marshal_aux_state/1]).
-export([unmarshal_aux_state/1]).
-export([apply_event/4]).

%%
%% Types
%%

-type repair_error() :: ff_repair:repair_error().
-type repair_response() :: ff_repair:repair_response().
-type repair_call_error() :: ff_machine_lib:repair_call_error().

-export_type([id/0]).
-export_type([st/0]).
-export_type([event/0]).
-export_type([params/0]).
-export_type([event_range/0]).
-export_type([repair_error/0]).
-export_type([repair_response/0]).
-export_type([repair_call_error/0]).

-type id() :: prg_machine:id().
-type data() :: ff_withdrawal_session:data().
-type params() :: ff_withdrawal_session:params().
-type change() :: ff_withdrawal_session:event().

-type st() :: #{
    model := session(),
    ctx := ctx()
}.
-type session() :: ff_withdrawal_session:session_state().
-type event() :: {integer(), timestamped_event(change())}.
-type event_range() :: {After :: non_neg_integer() | undefined, Limit :: non_neg_integer() | undefined}.
-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.

-type callback_params() :: ff_withdrawal_session:callback_params().
-type process_callback_response() :: ff_withdrawal_session:process_callback_response().
-type process_callback_error() ::
    {unknown_session, {tag, id()}}
    | ff_withdrawal_session:process_callback_error().

-type ctx() :: ff_entity_context:context().
-type machine() :: prg_machine:machine().
-type prg_result() :: prg_machine:result().

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%%
%% API
%%

-spec session(st()) -> session().
session(#{model := Model}) ->
    Model.

-spec ctx(st()) -> ctx().
ctx(#{ctx := Ctx}) ->
    Ctx.

-spec create(id(), data(), params()) -> ok | {error, exists}.
create(ID, Data, Params) ->
    do(fun() ->
        Events = unwrap(ff_withdrawal_session:create(ID, Data, Params)),
        unwrap(prg_machine:start(?NS, ID, Events))
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
    ff_machine_lib:get(?NS, ID, {After, Limit}, ?MODULE, notfound).

-spec events(id(), event_range()) ->
    {ok, [event()]}
    | {error, notfound}.
events(ID, {After, Limit}) ->
    ff_machine_lib:events(?NS, ID, {After, Limit}, notfound).

-spec repair(id(), ff_repair:scenario()) ->
    {ok, repair_response()} | {error, repair_call_error()}.
repair(ID, Scenario) ->
    ff_machine_lib:repair(?NS, ID, Scenario).

-spec process_callback(callback_params()) ->
    {ok, process_callback_response()}
    | {error, process_callback_error()}.
process_callback(#{tag := Tag} = Params) ->
    case ff_machine_tag:get_binding(?NS, Tag) of
        {ok, EntityID} ->
            call(EntityID, {process_callback, Params});
        {error, not_found} ->
            {error, {unknown_session, {tag, Tag}}}
    end.

%% prg_machine

-spec namespace() -> prg_machine:namespace().
namespace() ->
    ?NS.

-spec init([change()], machine()) -> prg_result().
init(Events, _Machine) ->
    ff_machine_lib:init_result(Events, ff_entity_context:new(), timeout).

-spec process_signal(prg_machine:signal(), machine()) -> prg_result().
process_signal(timeout, Machine) ->
    Session = prg_machine:collapse(?MODULE, Machine),
    ff_machine_lib:to_prg_result(ff_withdrawal_session:process_session(Session)).

-spec process_call({process_callback, callback_params()}, machine()) ->
    {{ok, process_callback_response()} | {error, process_callback_error()}, prg_result()}.
process_call({process_callback, Params}, Machine) ->
    Session = prg_machine:collapse(?MODULE, Machine),
    case ff_withdrawal_session:process_callback(Params, Session) of
        {ok, {Response, Result}} ->
            {{ok, Response}, ff_machine_lib:to_prg_result(Result)};
        {error, {Reason, _Result}} ->
            {{error, Reason}, #{}}
    end;
process_call(CallArgs, _Machine) ->
    erlang:error({unexpected_call, CallArgs}).

-spec process_repair(ff_repair:scenario(), machine()) -> prg_result() | {error, term()}.
process_repair(Scenario, Machine) ->
    ScenarioProcessors = #{
        set_session_result => fun(Args, RMachine) ->
            Session = prg_machine:collapse(?MODULE, ff_repair:to_prg_machine(RMachine)),
            {Action, Events} = ff_withdrawal_session:set_session_result(Args, Session),
            {ok, {ok, #{action => Action, events => Events}}}
        end
    },
    ff_machine_lib:process_repair(?MODULE, Machine, Scenario, ScenarioProcessors).

-spec process_notification(prg_machine:args(), machine()) -> prg_result().
process_notification(_Args, _Machine) ->
    #{}.

-spec apply_event(
    prg_machine:event_id(),
    prg_machine:timestamp(),
    prg_machine:event_body(),
    term()
) -> term().
apply_event(_EventID, _Ts, Body, Model) ->
    ff_withdrawal_session:apply_event(Body, Model).

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Body) ->
    ff_machine_lib:marshal_event_body(withdrawal_session, ?EVENT_FORMAT_VERSION, Body).

-spec unmarshal_event_body(binary()) -> prg_machine:event_body().
unmarshal_event_body(Payload) ->
    ff_machine_lib:unmarshal_event_body(withdrawal_session, Payload).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    ff_machine_lib:marshal_aux_state(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    ff_machine_lib:unmarshal_aux_state(Payload).

call(Ref, Call) ->
    case prg_machine:call(?NS, Ref, Call) of
        {ok, Reply} ->
            Reply;
        {error, notfound} ->
            {error, {unknown_session, Ref}};
        {error, failed} ->
            erlang:error({failed, ?NS, Ref});
        {error, {exception, _, _}} ->
            erlang:error({failed, ?NS, Ref});
        {error, _} = Error ->
            Error
    end.
