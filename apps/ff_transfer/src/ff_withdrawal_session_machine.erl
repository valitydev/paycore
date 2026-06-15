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
-export([unmarshal_event_body/2]).
-export([marshal_aux_state/1]).
-export([unmarshal_aux_state/1]).

%%
%% Types
%%

-type repair_error() :: ff_repair:repair_error().
-type repair_response() :: ff_repair:repair_response().
-type repair_call_error() :: ff_machine_lib:repair_call_error().

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
-type event() :: ff_withdrawal_session:event().
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
    case prg_machine:get(?NS, ID, prg_machine:history_range(After, Limit, forward)) of
        {ok, Machine} ->
            {ok, machine_to_st(Machine)};
        {error, notfound} ->
            {error, notfound};
        {error, {exception, Class, Reason}} ->
            erlang:error({process_exception, Class, Reason})
    end.

-spec events(id(), event_range()) ->
    {ok, [{integer(), timestamped_event(event())}]}
    | {error, notfound}.
events(ID, {After, Limit}) ->
    case prg_machine:get_history(?NS, ID, After, Limit, forward) of
        {ok, History} ->
            {ok, ff_machine_lib:history_to_events(History)};
        {error, notfound} ->
            {error, notfound};
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

-spec process_callback(callback_params()) ->
    {ok, process_callback_response()}
    | {error, process_callback_error() | failed}.
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
    #{
        events => Events,
        action => timeout,
        auxst => #{ctx => ff_entity_context:new()}
    }.

-spec process_signal(prg_machine:signal(), machine()) -> prg_result().
process_signal(timeout, Machine) ->
    Session = prg_machine:collapse(ff_withdrawal_session, Machine),
    process_session_result(ff_withdrawal_session:process_session(Session), Machine).

-spec process_call({process_callback, callback_params()}, machine()) ->
    {{ok, process_callback_response()} | {error, process_callback_error()}, prg_result()}.
process_call({process_callback, Params}, Machine) ->
    Session = prg_machine:collapse(ff_withdrawal_session, Machine),
    case ff_withdrawal_session:process_callback(Params, Session) of
        {ok, {Response, Result}} ->
            {{ok, Response}, process_session_result(Result, Machine)};
        {error, {Reason, _Result}} ->
            {{error, Reason}, #{}}
    end;
process_call(CallArgs, _Machine) ->
    erlang:error({unexpected_call, CallArgs}).

-spec process_repair(ff_repair:scenario(), machine()) -> prg_result() | {error, term()}.
process_repair(Scenario, Machine) ->
    ScenarioProcessors = #{
        set_session_result => fun(Args, RMachine) ->
            Session = prg_machine:collapse(ff_withdrawal_session, ff_repair:to_prg_machine(RMachine)),
            {Action, Events} = ff_withdrawal_session:set_session_result(Args, Session),
            {ok, {ok, #{action => Action, events => Events}}}
        end
    },
    case
        ff_repair:apply_scenario(
            ff_withdrawal_session, ff_machine_lib:to_repair_machine(Machine), Scenario, ScenarioProcessors
        )
    of
        {ok, {_Response, Result}} ->
            ff_machine_lib:from_repair_result(Result, Machine);
        {error, Reason} ->
            {error, Reason}
    end.

-spec process_notification(term(), machine()) -> prg_result().
process_notification(_Args, _Machine) ->
    #{}.

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Body) ->
    Timestamped = {ev, prg_machine:timestamp(), Body},
    Encoded = ff_machine_codec:marshal_event(withdrawal_session, ?EVENT_FORMAT_VERSION, Timestamped),
    {?EVENT_FORMAT_VERSION, ff_machine_codec:payload_to_binary(Encoded)}.

-spec unmarshal_event_body(pos_integer(), binary()) -> prg_machine:event_body().
unmarshal_event_body(?EVENT_FORMAT_VERSION, Payload) ->
    Timestamped = ff_machine_codec:unmarshal_event(withdrawal_session, ?EVENT_FORMAT_VERSION, Payload),
    ff_machine_lib:event_body_from_timestamped(Timestamped);
unmarshal_event_body(Format, _Payload) ->
    erlang:error({unknown_event_format, Format}).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    ff_machine_codec:marshal_aux_state(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    ff_machine_codec:unmarshal_aux_state(Payload).

%%
%% Internals
%%

-spec machine_to_st(prg_machine:machine()) -> st().
machine_to_st(#{aux_state := undefined} = Machine) ->
    machine_to_st(Machine#{aux_state => #{}});
machine_to_st(#{aux_state := AuxState} = Machine) ->
    Model = prg_machine:collapse(ff_withdrawal_session, Machine),
    Ctx = maps:get(ctx, AuxState, #{}),
    #{
        model => Model,
        ctx => Ctx
    }.

-spec process_session_result(ff_withdrawal_session:process_result(), machine()) -> prg_result().
process_session_result({Action, Events}, Machine) ->
    #{
        events => Events,
        action => Action,
        auxst => maps:get(aux_state, Machine, #{})
    }.

call(Ref, Call) ->
    case prg_machine:call(?NS, Ref, Call) of
        {ok, Reply} ->
            Reply;
        {error, notfound} ->
            {error, {unknown_session, Ref}};
        {error, failed} ->
            {error, failed};
        {error, {exception, _, _}} ->
            {error, failed};
        {error, _} = Error ->
            Error
    end.
