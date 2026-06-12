%%%
%%% Withdrawal session model
%%%

-module(ff_withdrawal_session).

-behaviour(prg_machine).

-define(NS, 'ff/withdrawal/session_v2').
-define(EVENT_FORMAT_VERSION, 1).

%% Accessors

-export([id/1]).
-export([status/1]).
-export([adapter_state/1]).
-export([route/1]).
-export([withdrawal/1]).
-export([result/1]).
-export([transaction_info/1]).

%% API

-export([create/3]).
-export([process_session/1]).
-export([process_callback/2]).

-export([get_adapter_with_opts/1]).
-export([get_adapter_with_opts/2]).

%% ff_machine
-export([apply_event/2]).

%% ff_repair
-export([set_session_result/2]).

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

-define(ACTUAL_FORMAT_VERSION, 5).

-type session_state() :: #{
    id := id(),
    status := status(),
    withdrawal := withdrawal(),
    route := route(),
    adapter_state => ff_adapter:state(),
    callbacks => callbacks_index(),
    result => session_result(),
    % For validate outstanding TransactionsInfo
    transaction_info => transaction_info()
}.

-type session() :: #{
    version := ?ACTUAL_FORMAT_VERSION,
    id := id(),
    status := status(),
    withdrawal := withdrawal(),
    route := route()
}.

-type transaction_info() :: ff_adapter_withdrawal:transaction_info().
-type session_result() :: success | {success, transaction_info()} | {failed, ff_adapter_withdrawal:failure()}.
-type status() :: active | {finished, success | {failed, ff_adapter_withdrawal:failure()}}.
-type party_id() :: ff_party:id().

-type event() ::
    {created, session()}
    | {next_state, ff_adapter:state()}
    | {transaction_bound, transaction_info()}
    | {finished, session_result()}
    | wrapped_callback_event().

-type wrapped_callback_event() :: ff_withdrawal_callback_utils:wrapped_event().

-type data() :: #{
    id := id(),
    cash := ff_accounting:body(),
    sender := party_id(),
    receiver := party_id(),
    quote_data => ff_adapter_withdrawal:quote_data()
}.

-type route() :: ff_withdrawal_routing:route().

-type params() :: #{
    resource := ff_destination:resource(),
    route := route(),
    withdrawal_id := ff_withdrawal:id(),
    dest_auth_data => ff_destination:auth_data()
}.

-type callback_params() :: ff_withdrawal_callback:process_params().
-type process_callback_response() :: ff_withdrawal_callback:response().
-type process_callback_error() :: {session_already_finished, session_finished_params()}.

-type session_finished_params() :: #{
    withdrawal := withdrawal(),
    state := ff_adapter:state(),
    opts := ff_adapter:opts()
}.

-type id() :: binary().
-type machine() :: prg_machine:machine().
-type prg_result() :: prg_machine:result().

-type action() :: prg_action:t().

-type process_result() :: {action(), [event()]}.

-export_type([id/0]).
-export_type([data/0]).
-export_type([event/0]).
-export_type([route/0]).
-export_type([params/0]).
-export_type([status/0]).
-export_type([session_state/0]).
-export_type([session/0]).
-export_type([session_result/0]).
-export_type([callback_params/0]).
-export_type([process_callback_response/0]).
-export_type([process_callback_error/0]).
-export_type([process_result/0]).
-export_type([action/0]).

%%
%% Internal types
%%
-type withdrawal() :: ff_adapter_withdrawal:withdrawal().
-type callbacks_index() :: ff_withdrawal_callback_utils:index().
-type adapter_with_opts() :: {ff_adapter:adapter(), ff_adapter:opts()}.

%%
%% Accessors
%%

-spec id(session_state()) -> id().
id(#{id := V}) ->
    V.

-spec status(session_state()) -> status().
status(#{status := V}) ->
    V.

-spec route(session_state()) -> route().
route(#{route := V}) ->
    V.

-spec withdrawal(session_state()) -> withdrawal().
withdrawal(#{withdrawal := V}) ->
    V.

-spec adapter_state(session_state()) -> ff_adapter:state().
adapter_state(Session) ->
    maps:get(adapter_state, Session, undefined).

-spec callbacks_index(session_state()) -> callbacks_index().
callbacks_index(Session) ->
    case maps:find(callbacks, Session) of
        {ok, Callbacks} ->
            Callbacks;
        error ->
            ff_withdrawal_callback_utils:new_index()
    end.

-spec result(session_state()) -> session_result() | undefined.
result(#{result := Result}) ->
    Result;
result(_) ->
    undefined.

-spec transaction_info(session_state()) -> transaction_info() | undefined.
transaction_info(#{} = Session) ->
    maps:get(transaction_info, Session, undefined).

%%
%% API
%%

-spec create(id(), data(), params()) -> {ok, [event()]}.
create(ID, Data, Params) ->
    Session = create_session(ID, Data, Params),
    {ok, [{created, Session}]}.

-spec apply_event(event(), undefined | session_state()) -> session_state().
apply_event({created, Session}, undefined) ->
    Session;
apply_event({next_state, AdapterState}, Session) ->
    Session#{adapter_state => AdapterState};
apply_event({transaction_bound, TransactionInfo}, Session) ->
    Session#{transaction_info => TransactionInfo};
apply_event({finished, success = Result}, Session) ->
    Session#{status => {finished, success}, result => Result};
apply_event({finished, {success, TransactionInfo} = Result}, Session) ->
    %% for backward compatibility with events stored in DB - take TransactionInfo here.
    %% @see ff_adapter_withdrawal:rebind_transaction_info/1
    Session#{status => {finished, success}, result => Result, transaction_info => TransactionInfo};
apply_event({finished, {failed, _} = Result} = Status, Session) ->
    Session#{status => Status, result => Result};
apply_event({callback, _Ev} = WrappedEvent, Session) ->
    Callbacks0 = callbacks_index(Session),
    Callbacks1 = ff_withdrawal_callback_utils:apply_event(WrappedEvent, Callbacks0),
    set_callbacks_index(Callbacks1, Session).

-spec process_session(session_state()) -> process_result().
process_session(#{status := {finished, _}, id := ID, result := Result, withdrawal := Withdrawal}) ->
    % Session has finished, it should notify the withdrawal machine about the fact
    WithdrawalID = ff_adapter_withdrawal:id(Withdrawal),
    case ff_withdrawal_machine:notify(WithdrawalID, {session_finished, ID, Result}) of
        ok ->
            {suspend, []};
        {error, _} = Error ->
            erlang:error({unable_to_finish_session, Error})
    end;
process_session(#{status := active, withdrawal := Withdrawal, route := Route} = SessionState) ->
    {Adapter, AdapterOpts} = get_adapter_with_opts(Route),
    ASt = adapter_state(SessionState),
    {ok, ProcessResult} = ff_adapter_withdrawal:process_withdrawal(Adapter, Withdrawal, ASt, AdapterOpts),
    #{intent := Intent} = ProcessResult,
    Events0 = process_next_state(ProcessResult, [], ASt),
    Events1 = process_transaction_info(ProcessResult, Events0, SessionState),
    process_adapter_intent(Intent, SessionState, Events1).

process_transaction_info(#{transaction_info := TrxInfo}, Events, SessionState) ->
    ok = assert_transaction_info(TrxInfo, transaction_info(SessionState)),
    Events ++ [{transaction_bound, TrxInfo}];
process_transaction_info(_, Events, _Session) ->
    Events.

%% Only one static TransactionInfo within one session

assert_transaction_info(_NewTrxInfo, undefined) ->
    ok;
assert_transaction_info(TrxInfo, TrxInfo) ->
    ok;
assert_transaction_info(NewTrxInfo, _TrxInfo) ->
    erlang:error({transaction_info_is_different, NewTrxInfo}).

-spec set_session_result(session_result(), session_state()) -> process_result().
set_session_result(Result, #{status := active} = Session) ->
    process_adapter_intent({finish, Result}, Session).

-spec process_callback(callback_params(), session_state()) ->
    {ok, {process_callback_response(), process_result()}}
    | {error, {process_callback_error(), process_result()}}.
process_callback(#{tag := CallbackTag} = Params, Session) ->
    {ok, Callback} = find_callback(CallbackTag, Session),
    case ff_withdrawal_callback:status(Callback) of
        succeeded ->
            {ok, {ff_withdrawal_callback:response(Callback), {idle, []}}};
        pending ->
            case status(Session) of
                active ->
                    do_process_callback(Params, Callback, Session);
                {finished, _} ->
                    {error, {{session_already_finished, make_session_finish_params(Session)}, {idle, []}}}
            end
    end.

%%
%% Internals
%%

find_callback(CallbackTag, Session) ->
    ff_withdrawal_callback_utils:get_by_tag(CallbackTag, callbacks_index(Session)).

do_process_callback(CallbackParams, Callback, Session) ->
    {Adapter, AdapterOpts} = get_adapter_with_opts(route(Session)),
    Withdrawal = withdrawal(Session),
    AdapterState = adapter_state(Session),
    {ok, HandleCallbackResult} = ff_adapter_withdrawal:handle_callback(
        Adapter,
        CallbackParams,
        Withdrawal,
        AdapterState,
        AdapterOpts
    ),
    #{intent := Intent, response := Response} = HandleCallbackResult,
    Events0 = ff_withdrawal_callback_utils:process_response(Response, Callback),
    Events1 = process_next_state(HandleCallbackResult, Events0, AdapterState),
    Events2 = process_transaction_info(HandleCallbackResult, Events1, Session),
    {ok, {Response, process_adapter_intent(Intent, Session, Events2)}}.

make_session_finish_params(Session) ->
    {_Adapter, AdapterOpts} = get_adapter_with_opts(route(Session)),
    #{
        withdrawal => withdrawal(Session),
        state => adapter_state(Session),
        opts => AdapterOpts
    }.

process_next_state(#{next_state := NextState}, Events, AdapterState) when NextState =/= AdapterState ->
    Events ++ [{next_state, NextState}];
process_next_state(_Result, Events, _AdapterState) ->
    Events.

process_adapter_intent(Intent, Session, Events0) ->
    {Action, Events1} = process_adapter_intent(Intent, Session),
    {Action, Events0 ++ Events1}.

process_adapter_intent({finish, {success, _TransactionInfo}}, _Session) ->
    %% we ignore TransactionInfo here
    %% @see ff_adapter_withdrawal:rebind_transaction_info/1
    {timeout, [{finished, success}]};
process_adapter_intent({finish, Result}, _Session) ->
    {timeout, [{finished, Result}]};
process_adapter_intent({sleep, #{timer := Timer, tag := Tag}}, Session) ->
    ok = ff_machine_tag:create_binding(?NS, Tag, id(Session)),
    Events = create_callback(Tag, Session),
    {prg_action:schedule_timer(Timer), Events};
process_adapter_intent({sleep, #{timer := Timer}}, _Session) ->
    {prg_action:schedule_timer(Timer), []}.

%%

-spec create_session(id(), data(), params()) -> session().
create_session(ID, Data, #{withdrawal_id := WdthID, resource := Res, route := Route} = Params) ->
    DestAuthData = maps:get(dest_auth_data, Params, undefined),
    #{
        version => ?ACTUAL_FORMAT_VERSION,
        id => ID,
        withdrawal => create_adapter_withdrawal(Data, Res, WdthID, DestAuthData),
        route => Route,
        status => active
    }.

create_callback(Tag, Session) ->
    case ff_withdrawal_callback_utils:get_by_tag(Tag, callbacks_index(Session)) of
        {error, {unknown_callback, Tag}} ->
            {ok, CallbackEvents} = ff_withdrawal_callback:create(#{tag => Tag}),
            ff_withdrawal_callback_utils:wrap_events(Tag, CallbackEvents);
        {ok, Callback} ->
            erlang:error({callback_already_exists, Callback})
    end.

-spec get_adapter_with_opts(ff_withdrawal_routing:route()) -> adapter_with_opts().
get_adapter_with_opts(Route) ->
    ProviderID = ff_withdrawal_routing:get_provider(Route),
    TerminalID = ff_withdrawal_routing:get_terminal(Route),
    get_adapter_with_opts(ProviderID, TerminalID).

-spec get_adapter_with_opts(ProviderID, TerminalID) -> adapter_with_opts() when
    ProviderID :: ff_payouts_provider:id(),
    TerminalID :: ff_payouts_terminal:id() | undefined.
get_adapter_with_opts(ProviderID, TerminalID) when is_integer(ProviderID) ->
    DomainRevision = ff_domain_config:head(),
    {ok, Provider} = ff_payouts_provider:get(ProviderID, DomainRevision),
    ProviderOpts = ff_payouts_provider:adapter_opts(Provider),
    TerminalOpts = get_adapter_terminal_opts(TerminalID, DomainRevision),
    {ff_payouts_provider:adapter(Provider), maps:merge(ProviderOpts, TerminalOpts)}.

get_adapter_terminal_opts(undefined, _DomainRevision) ->
    #{};
get_adapter_terminal_opts(TerminalID, DomainRevision) ->
    {ok, Terminal} = ff_payouts_terminal:get(TerminalID, DomainRevision),
    ff_payouts_terminal:adapter_opts(Terminal).

create_adapter_withdrawal(
    #{id := SesID, sender := Sender, receiver := Receiver} = Data, Resource, WdthID, DestAuthData
) ->
    Data#{
        sender => Sender,
        receiver => Receiver,
        resource => Resource,
        id => WdthID,
        session_id => SesID,
        dest_auth_data => DestAuthData
    }.

-spec set_callbacks_index(callbacks_index(), session_state()) -> session_state().
set_callbacks_index(Callbacks, Session) ->
    Session#{callbacks => Callbacks}.

%% prg_machine

-spec namespace() -> prg_machine:namespace().
namespace() ->
    ?NS.

-spec init([event()], machine()) -> prg_result().
init(Events, _Machine) ->
    #{
        events => Events,
        action => timeout,
        auxst => #{ctx => ff_entity_context:new()}
    }.

-spec process_signal(prg_machine:signal(), machine()) -> prg_result().
process_signal(timeout, Machine) ->
    Session = prg_machine:collapse(?MODULE, Machine),
    process_session_result(process_session(Session), Machine);
process_signal({repair, _Args}, _Machine) ->
    erlang:error({unexpected_signal, repair}).

-spec process_call({process_callback, callback_params()}, machine()) ->
    {{ok, process_callback_response()} | {error, process_callback_error()}, prg_result()}.
process_call({process_callback, Params}, Machine) ->
    Session = prg_machine:collapse(?MODULE, Machine),
    case process_callback(Params, Session) of
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
            Session = prg_machine:collapse(?MODULE, ff_repair:to_prg_machine(RMachine)),
            {Action, Events} = set_session_result(Args, Session),
            {ok, {ok, #{action => Action, events => Events}}}
        end
    },
    case ff_repair:apply_scenario(?MODULE, to_repair_machine(Machine), Scenario, ScenarioProcessors) of
        {ok, {_Response, Result}} ->
            from_repair_result(Result, Machine);
        {error, Reason} ->
            {error, Reason}
    end.

-spec process_notification(term(), machine()) -> prg_result().
process_notification(_Args, _Machine) ->
    #{events => [], action => timeout}.

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Body) ->
    Timestamped = {ev, {prg_machine:timestamp(), 0}, Body},
    Encoded = ff_machine_codec:marshal_event(withdrawal_session, ?EVENT_FORMAT_VERSION, Timestamped),
    {?EVENT_FORMAT_VERSION, ff_machine_codec:payload_to_binary(Encoded)}.

-spec unmarshal_event_body(pos_integer(), binary()) -> prg_machine:event_body().
unmarshal_event_body(?EVENT_FORMAT_VERSION, Payload) ->
    Timestamped = ff_machine_codec:unmarshal_event(withdrawal_session, ?EVENT_FORMAT_VERSION, Payload),
    event_body_from_timestamped(Timestamped);
unmarshal_event_body(Format, _Payload) ->
    erlang:error({unknown_event_format, Format}).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    ff_machine_codec:marshal_aux_state(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    ff_machine_codec:unmarshal_aux_state(Payload).

-spec process_session_result(process_result(), machine()) -> prg_result().
process_session_result({Action, Events}, Machine) ->
    #{
        events => Events,
        action => Action,
        auxst => maps:get(aux_state, Machine, #{})
    }.

-type repair_result() :: #{
    events := [term()],
    action => action(),
    aux_state => term()
}.

-spec from_repair_result(repair_result(), machine()) -> prg_result().
from_repair_result(#{events := Events} = Result, Machine) ->
    #{
        events => repair_events_to_domain(Events),
        action => maps:get(action, Result, idle),
        auxst => maps:get(aux_state, Result, maps:get(aux_state, Machine, #{}))
    }.

-spec repair_events_to_domain([term()]) -> [event()].
repair_events_to_domain(Events) ->
    [event_body_from_timestamped(E) || E <- Events].

-spec event_body_from_timestamped(term()) -> event().
event_body_from_timestamped({ev, _Timestamp, Change}) ->
    Change;
event_body_from_timestamped(Change) ->
    Change.

-spec to_repair_machine(machine()) -> ff_repair:machine().
to_repair_machine(#{namespace := NS, id := ID, history := History, aux_state := AuxState}) ->
    #{
        namespace => NS,
        id => ID,
        history => [{EventID, {ev, Timestamp, Body}} || {EventID, Timestamp, Body} <- History],
        aux_state => AuxState
    }.
