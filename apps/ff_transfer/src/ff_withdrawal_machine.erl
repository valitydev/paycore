%%%
%%% Withdrawal machine
%%%

-module(ff_withdrawal_machine).

-behaviour(prg_machine).

-define(EVENT_FORMAT_VERSION, 1).

%% API

-type id() :: prg_machine:id().
-type change() :: ff_withdrawal:event().
-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.
-type event() :: {integer(), timestamped_event(change())}.
-type st() :: #{
    model := withdrawal(),
    ctx := ctx()
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
-type repair_call_error() :: ff_machine_lib:repair_call_error().

-type unknown_withdrawal_error() ::
    {unknown_withdrawal, id()}.

-type action() :: ff_withdrawal:action().

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
-export_type([repair_call_error/0]).
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

%% Internal types

-type ctx() :: ff_entity_context:context().
-type machine() :: prg_machine:machine().
-type prg_result() :: prg_machine:result().

-define(NS, 'ff/withdrawal_v2').

%% API

-spec create(params(), ctx()) ->
    ok
    | {error, ff_withdrawal:create_error() | exists}.
create(Params, Ctx) ->
    ff_machine_lib:create(?NS, fun ff_withdrawal:create/1, Params, Ctx).

-spec get(id()) ->
    {ok, st()}
    | {error, unknown_withdrawal_error()}.
get(ID) ->
    get(ID, {undefined, undefined}).

-spec get(id(), event_range()) ->
    {ok, st()}
    | {error, unknown_withdrawal_error()}.
get(ID, {After, Limit}) ->
    ff_machine_lib:get(?NS, ID, {After, Limit}, ff_withdrawal, {unknown_withdrawal, ID}).

-spec events(id(), event_range()) ->
    {ok, [event()]}
    | {error, unknown_withdrawal_error()}.
events(ID, {After, Limit}) ->
    ff_machine_lib:events(?NS, ID, {After, Limit}, {unknown_withdrawal, ID}).

-spec repair(id(), ff_repair:scenario()) ->
    {ok, repair_response()} | {error, repair_call_error()}.
repair(ID, Scenario) ->
    ff_machine_lib:repair(?NS, ID, Scenario).

-spec start_adjustment(id(), adjustment_params()) ->
    ok
    | {error, start_adjustment_error()}.
start_adjustment(WithdrawalID, Params) ->
    call(WithdrawalID, {start_adjustment, Params}).

-spec notify(id(), notify_args()) ->
    ok | {error, notfound | failed} | no_return().
notify(ID, Args) ->
    prg_machine:notify(?NS, ID, Args).

%% Accessors

-spec withdrawal(st()) -> withdrawal().
withdrawal(#{model := Model}) ->
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
    Withdrawal = prg_machine:collapse(ff_withdrawal, Machine),
    ff_machine_lib:to_prg_result(ff_withdrawal:process_transfer(Withdrawal)).

-spec process_call({start_adjustment, adjustment_params()}, machine()) ->
    {ok | {error, start_adjustment_error()}, prg_result()}.
process_call({start_adjustment, Params}, Machine) ->
    Withdrawal = prg_machine:collapse(ff_withdrawal, Machine),
    case ff_withdrawal:start_adjustment(Params, Withdrawal) of
        {ok, Result} ->
            {ok, ff_machine_lib:to_prg_result(Result)};
        {error, _Reason} = Error ->
            {Error, #{}}
    end;
process_call(CallArgs, _Machine) ->
    erlang:error({unexpected_call, CallArgs}).

-spec process_repair(ff_repair:scenario(), machine()) -> prg_result() | {error, term()}.
process_repair(Scenario, Machine) ->
    ff_machine_lib:process_repair(ff_withdrawal, Machine, Scenario).

-spec process_notification(notify_args(), machine()) -> prg_result().
process_notification({session_finished, SessionID, SessionResult}, Machine) ->
    Withdrawal = prg_machine:collapse(ff_withdrawal, Machine),
    case ff_withdrawal:finalize_session(SessionID, SessionResult, Withdrawal) of
        {ok, Result} ->
            ff_machine_lib:to_prg_result(Result);
        {error, Reason} ->
            erlang:error({unable_to_finalize_session, Reason})
    end.

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Body) ->
    ff_machine_lib:marshal_event_body(withdrawal, ?EVENT_FORMAT_VERSION, Body).

-spec unmarshal_event_body(binary()) -> prg_machine:event_body().
unmarshal_event_body(Payload) ->
    ff_machine_lib:unmarshal_event_body(withdrawal, Payload).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    ff_machine_lib:marshal_aux_state(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    ff_machine_lib:unmarshal_aux_state(Payload).

call(ID, Call) ->
    case prg_machine:call(?NS, ID, Call) of
        {ok, Reply} ->
            Reply;
        {error, notfound} ->
            {error, {unknown_withdrawal, ID}};
        {error, failed} ->
            {error, failed};
        {error, _} = Error ->
            Error
    end.
