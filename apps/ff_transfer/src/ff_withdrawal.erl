%%%
%%% Withdrawal
%%%

-module(ff_withdrawal).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-type id() :: binary().

-define(ACTUAL_FORMAT_VERSION, 4).
-define(BODY_CHANGED_ATTEMPT_MULTIPLIER, 1000).

-opaque withdrawal_state() :: #{
    id := id(),
    body := body(),
    params := transfer_params(),
    created_at => ff_time:timestamp_ms(),
    domain_revision => domain_revision(),
    route => route(),
    attempts => attempts(),
    resource => destination_resource(),
    adjustments => adjustments_index(),
    status => status(),
    metadata => metadata(),
    external_id => id(),
    validation => withdrawal_validation(),
    contact_info => contact_info(),
    client_info => client_info(),
    client_identity => client_identity(),
    new_body => body(),
    p_transfer_rebuild_needed => boolean(),
    routing_candidates => routing_candidates(),
    routing_rollback_data => routing_rollback_data()
}.

-opaque withdrawal() :: #{
    version := ?ACTUAL_FORMAT_VERSION,
    id := id(),
    body := body(),
    params := transfer_params(),
    created_at => ff_time:timestamp_ms(),
    domain_revision => domain_revision(),
    route => route(),
    metadata => metadata(),
    external_id => id(),
    contact_info => contact_info(),
    client_info => client_info(),
    client_identity => client_identity()
}.

-type params() :: #{
    id := id(),
    party_id := party_id(),
    wallet_id := wallet_id(),
    destination_id := ff_destination:id(),
    body := body(),
    external_id => id(),
    quote => quote(),
    metadata => metadata(),
    contact_info => contact_info(),
    client_info => client_info(),
    client_identity => client_identity()
}.

-type status() ::
    pending
    | succeeded
    | {failed, failure()}.

-type withdrawal_validation() :: #{
    sender => validation_result(),
    receiver => validation_result()
}.

-type contact_info() :: #{
    phone_number => binary(),
    email => binary()
}.

-type client_info() :: #{
    ip_address => binary(),
    fingerprint => binary()
}.

-type client_identity() :: #{
    customer_id := binary(),
    user_id => binary()
}.

-type validation_result() ::
    {personal, personal_data_validation()}.

-type personal_data_validation() :: #{
    validation_id := binary(),
    token := binary(),
    validation_status := validation_status()
}.

-type validation_status() :: valid | invalid.

-type event() ::
    {created, withdrawal()}
    | {resource_got, destination_resource()}
    | {route_changed, #{route := route(), candidates => routing_candidates()}}
    | {rollback_started, routing_rollback_data()}
    | {p_transfer, ff_postings_transfer:event()}
    | {limit_check, limit_check_details()}
    | {validation, {sender | receiver, validation_result()}}
    | {session_started, session_id()}
    | {session_finished, {session_id(), session_result()}}
    | {body_changed, #{old_body := body(), new_body := body()}}
    | {status_changed, status()}
    | wrapped_adjustment_event().

-type create_error() ::
    {wallet, notfound}
    | {party, notfound}
    | {destination, notfound | unauthorized}
    | {wallet, ff_party:inaccessibility()}
    | {inconsistent_currency, {Withdrawal :: currency_id(), Wallet :: currency_id(), Destination :: currency_id()}}
    | {terms, ff_party:validate_withdrawal_creation_error()}
    | {realms_mismatch, {realm(), realm()}}
    | {destination_resource, {bin_data, ff_bin_data:bin_data_error()}}
    | {customer, notfound}.

-type route() :: ff_withdrawal_routing:route().
-type routing_candidates() :: [route()].
-type routing_rollback_data() :: #{reason := failure(), candidates := nonempty_list(route())}.
-type realm() :: ff_payment_institution:realm().

-type attempts() :: ff_withdrawal_route_attempt_utils:attempts().

-type quote_params() :: #{
    wallet_id := wallet_id(),
    party_id := party_id(),
    currency_from := ff_currency:id(),
    currency_to := ff_currency:id(),
    body := ff_accounting:body(),
    destination_id => ff_destination:id(),
    external_id => id()
}.

-type quote() :: #{
    cash_from := cash(),
    cash_to := cash(),
    created_at := binary(),
    expires_on := binary(),
    quote_data := ff_adapter_withdrawal:quote_data(),
    route := route(),
    operation_timestamp := ff_time:timestamp_ms(),
    resource_descriptor => resource_descriptor(),
    domain_revision => domain_revision()
}.

-type quote_state() :: #{
    cash_from := cash(),
    cash_to := cash(),
    created_at := binary(),
    expires_on := binary(),
    quote_data := ff_adapter_withdrawal:quote_data(),
    route := route(),
    resource_descriptor => resource_descriptor()
}.

-type session() :: #{
    id := session_id(),
    result => session_result()
}.

-type limit_check_details() ::
    {wallet_sender, wallet_limit_check_details()}.

-type wallet_limit_check_details() ::
    ok
    | {failed, wallet_limit_check_error()}.

-type wallet_limit_check_error() :: #{
    expected_range := cash_range(),
    balance := cash()
}.

-type adjustment_params() :: #{
    id := adjustment_id(),
    change := adjustment_change(),
    external_id => id()
}.

-type adjustment_change() ::
    {change_status, status()}
    | {change_cash_flow, domain_revision()}
    | {change_body, body()}.

-type start_adjustment_error() ::
    invalid_withdrawal_status_error()
    | invalid_status_change_error()
    | {another_adjustment_in_progress, adjustment_id()}
    | {invalid_cash_flow_change,
        {already_has_domain_revision, domain_revision()}
        | {unavailable_status, status()}}
    | invalid_body_change_error()
    | ff_adjustment:create_error().

-type unknown_adjustment_error() :: ff_adjustment_utils:unknown_adjustment_error().

-type invalid_status_change_error() ::
    {invalid_status_change, {unavailable_status, status()}}
    | {invalid_status_change, {already_has_status, status()}}.

-type invalid_withdrawal_status_error() ::
    {invalid_withdrawal_status, status()}.

-type invalid_body_change_error() ::
    {invalid_body_change, {already_has_body, body()}}
    | {invalid_body_change, {invalid_operation_amount, body()}}.

-type action() :: prg_action:t().

-export_type([withdrawal/0]).
-export_type([withdrawal_state/0]).
-export_type([id/0]).
-export_type([params/0]).
-export_type([event/0]).
-export_type([route/0]).
-export_type([quote/0]).
-export_type([quote_params/0]).
-export_type([session/0]).
-export_type([create_error/0]).
-export_type([action/0]).
-export_type([adjustment_params/0]).
-export_type([start_adjustment_error/0]).
-export_type([limit_check_details/0]).
-export_type([activity/0]).
-export_type([contact_info/0]).
-export_type([client_info/0]).
-export_type([client_identity/0]).

%% Transfer logic callbacks

-export([process_transfer/1]).

%%

-export([finalize_session/3]).

%% Accessors

-export([wallet_id/1]).
-export([destination_id/1]).
-export([quote/1]).
-export([id/1]).
-export([party_id/1]).
-export([body/1]).
-export([new_body/1]).
-export([status/1]).
-export([route/1]).
-export([attempts/1]).
-export([external_id/1]).
-export([created_at/1]).
-export([domain_revision/1]).
-export([destination_resource/1]).
-export([metadata/1]).
-export([params/1]).
-export([activity/1]).
-export([validation/1]).
-export([contact_info/1]).
-export([client_info/1]).
-export([client_identity/1]).

%% API

-export([create/1]).
-export([get_quote/1]).
-export([is_finished/1]).

-export([start_adjustment/2]).
-export([find_adjustment/2]).
-export([adjustments/1]).
-export([effective_final_cash_flow/1]).
-export([final_domain_revision/1]).
-export([sessions/1]).
-export([session_id/1]).
-export([get_current_session/1]).
-export([get_current_session_status/1]).

%% Event source

-export([apply_event/2]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1, unwrap/2]).

%% Internal types

-type body() :: ff_accounting:body().
-type party_id() :: ff_party:id().
-type wallet_id() :: ff_party:wallet_id().
-type wallet() :: ff_party:wallet().
-type destination_id() :: ff_destination:id().
-type destination() :: ff_destination:destination_state().
-type process_result() :: {action(), [event()]}.
-type final_cash_flow() :: ff_cash_flow:final_cash_flow().
-type external_id() :: id() | undefined.
-type p_transfer() :: ff_postings_transfer:transfer().
-type session_id() :: id().
-type destination_resource() :: ff_destination:resource().
-type bin_data() :: ff_bin_data:bin_data().
-type cash() :: ff_cash:cash().
-type cash_range() :: ff_range:range(cash()).
-type failure() :: ff_failure:failure().
-type session_result() :: ff_withdrawal_session:session_result().
-type session_data() :: ff_withdrawal_session:session_data().
-type adjustment() :: ff_adjustment:adjustment().
-type adjustment_id() :: ff_adjustment:id().
-type adjustments_index() :: ff_adjustment_utils:index().
-type currency_id() :: ff_currency:id().
-type domain_revision() :: ff_domain_config:revision().
-type terms() :: ff_party:terms().
-type party_varset() :: ff_varset:varset().
-type metadata() :: ff_entity_context:md().
-type resource_descriptor() :: ff_resource:resource_descriptor().

-type wrapped_adjustment_event() :: ff_adjustment_utils:wrapped_event().

-type legacy_event() :: any().

-type transfer_params() :: #{
    party_id := party_id(),
    wallet_id := wallet_id(),
    destination_id := destination_id(),
    quote => quote_state()
}.

-type party_varset_params() :: #{
    body := body(),
    wallet_id := wallet_id(),
    party_id := party_id(),
    destination => destination(),
    resource => destination_resource(),
    bin_data := bin_data()
}.

-type activity() ::
    routing
    | p_transfer_start
    | p_transfer_recreate
    | p_transfer_prepare
    | session_starting
    | session_sleeping
    | p_transfer_commit
    | p_transfer_cancel
    | limit_check
    | {fail, fail_type()}
    | compensate_routing_failure
    | adjustment
    | rollback_routing
    % Legacy activity
    | finish.

-type fail_type() ::
    limit_check
    | ff_withdrawal_routing:route_not_found()
    | {inconsistent_quote_route, route()}
    | {validation_personal_data, sender | receiver}
    | session.

-type session_processing_status() :: undefined | pending | succeeded | failed.

%% Accessors

-spec wallet_id(withdrawal_state()) -> wallet_id().
wallet_id(T) ->
    maps:get(wallet_id, params(T)).

-spec destination_id(withdrawal_state()) -> destination_id().
destination_id(T) ->
    maps:get(destination_id, params(T)).

-spec destination_resource(withdrawal_state()) -> destination_resource().
destination_resource(#{resource := Resource}) ->
    Resource;
destination_resource(Withdrawal) ->
    DestinationID = destination_id(Withdrawal),
    {ok, DestinationMachine} = ff_destination_machine:get(DestinationID),
    Destination = ff_destination_machine:destination(DestinationMachine),
    {ok, Resource} = ff_resource:create_resource(ff_destination:resource(Destination)),
    Resource.

%%

-spec quote(withdrawal_state()) -> quote_state() | undefined.
quote(T) ->
    maps:get(quote, params(T), undefined).

-spec id(withdrawal_state()) -> id().
id(#{id := V}) ->
    V.

-spec party_id(withdrawal_state()) -> party_id().
party_id(#{params := #{party_id := V}}) ->
    V.

-spec body(withdrawal_state()) -> body().
body(#{body := V}) ->
    V.

-spec status(withdrawal_state()) -> status() | undefined.
status(T) ->
    maps:get(status, T, undefined).

-spec route(withdrawal_state()) -> route() | undefined.
route(T) ->
    maps:get(route, T, undefined).

-spec new_body(withdrawal_state()) -> body() | undefined.
new_body(T) ->
    maps:get(new_body, T, undefined).

-spec attempts(withdrawal_state()) -> attempts().
attempts(#{attempts := Attempts}) ->
    Attempts;
attempts(T) when not is_map_key(attempts, T) ->
    ff_withdrawal_route_attempt_utils:new().

-spec external_id(withdrawal_state()) -> external_id() | undefined.
external_id(T) ->
    maps:get(external_id, T, undefined).

-spec domain_revision(withdrawal_state()) -> domain_revision() | undefined.
domain_revision(T) ->
    maps:get(domain_revision, T, undefined).

-spec created_at(withdrawal_state()) -> ff_time:timestamp_ms() | undefined.
created_at(T) ->
    maps:get(created_at, T, undefined).

-spec metadata(withdrawal_state()) -> metadata() | undefined.
metadata(T) ->
    maps:get(metadata, T, undefined).

-spec params(withdrawal_state()) -> transfer_params().
params(#{params := V}) ->
    V.

-spec activity(withdrawal_state()) -> activity().
activity(Withdrawal) ->
    deduce_activity(Withdrawal).

-spec validation(withdrawal_state()) -> withdrawal_validation() | undefined.
validation(#{validation := WithdrawalValidation}) ->
    WithdrawalValidation;
validation(_) ->
    undefined.

-spec contact_info(withdrawal_state()) -> contact_info() | undefined.
contact_info(#{contact_info := ContactInfo}) ->
    ContactInfo;
contact_info(_) ->
    undefined.

-spec client_info(withdrawal_state()) -> client_info() | undefined.
client_info(#{client_info := ClientInfo}) ->
    ClientInfo;
client_info(_) ->
    undefined.

-spec client_identity(withdrawal_state()) -> client_identity() | undefined.
client_identity(#{client_identity := ClientIdentity}) ->
    ClientIdentity;
client_identity(_) ->
    undefined.

%% API

-spec create(params()) ->
    {ok, [event()]}
    | {error, create_error()}.
create(Params) ->
    do(fun() ->
        #{id := ID, wallet_id := WalletID, party_id := PartyID, destination_id := DestinationID, body := Body} = Params,
        CreatedAt = ff_time:now(),
        Quote = maps:get(quote, Params, undefined),
        ResourceDescriptor = quote_resource_descriptor(Quote),
        DomainRevision = ensure_domain_revision_defined(quote_domain_revision(Quote)),
        Wallet = unwrap(wallet, fetch_wallet(WalletID, PartyID, DomainRevision)),
        accessible = unwrap(wallet, ff_party:is_wallet_accessible(Wallet)),
        Destination = unwrap(destination, get_destination(DestinationID)),
        ResourceParams = ff_destination:resource(Destination),
        Resource = unwrap(
            destination_resource,
            create_resource(ResourceParams, ResourceDescriptor, Wallet, DomainRevision)
        ),
        valid = ff_resource:check_resource(DomainRevision, Resource),
        VarsetParams = genlib_map:compact(#{
            body => Body,
            wallet_id => WalletID,
            party_id => PartyID,
            destination => Destination,
            resource => Resource
        }),
        Varset = build_party_varset(VarsetParams),
        Terms = ff_party:get_terms(DomainRevision, Wallet, Varset),

        valid = unwrap(validate_withdrawal_creation(Terms, Body, Wallet, Destination, Resource)),
        ok = unwrap(customer, check_client_identity(maps:get(client_identity, Params, undefined), PartyID)),

        TransferParams = genlib_map:compact(#{
            party_id => PartyID,
            wallet_id => WalletID,
            destination_id => DestinationID,
            quote => Quote
        }),
        [
            {created,
                genlib_map:compact(#{
                    version => ?ACTUAL_FORMAT_VERSION,
                    id => ID,
                    body => Body,
                    params => TransferParams,
                    created_at => CreatedAt,
                    domain_revision => DomainRevision,
                    external_id => maps:get(external_id, Params, undefined),
                    metadata => maps:get(metadata, Params, undefined),
                    contact_info => maps:get(contact_info, Params, undefined),
                    client_info => maps:get(client_info, Params, undefined),
                    client_identity => maps:get(client_identity, Params, undefined)
                })},
            {status_changed, pending},
            {resource_got, Resource}
        ]
    end).

%% The recipient is a Customer of the party owning the wallet
check_client_identity(#{customer_id := CustomerID}, PartyID) ->
    ff_customer:check(CustomerID, PartyID);
check_client_identity(undefined, _PartyID) ->
    ok.

create_resource(
    {bank_card, #{bank_card := #{token := Token}} = ResourceBankCardParams},
    ResourceDescriptor,
    #domain_WalletConfig{payment_institution = PaymentInstitutionRef},
    DomainRevision
) ->
    BinData = ff_maybe:from_result(ff_resource:get_bin_data(Token, ResourceDescriptor)),
    Varset = #{
        bin_data => ff_dmsl_codec:maybe_marshal(bin_data, BinData)
    },
    {ok, PaymentInstitution} = ff_payment_institution:get(PaymentInstitutionRef, Varset, DomainRevision),
    PaymentSystem = ff_maybe:from_result(ff_payment_institution:payment_system(PaymentInstitution)),
    ff_resource:create_bank_card_basic(ResourceBankCardParams, BinData, PaymentSystem);
create_resource(ResourceParams, ResourceDescriptor, _Party, _DomainRevision) ->
    ff_resource:create_resource(ResourceParams, ResourceDescriptor).

-spec start_adjustment(adjustment_params(), withdrawal_state()) ->
    {ok, process_result()}
    | {error, start_adjustment_error()}.
start_adjustment(Params, Withdrawal) ->
    #{id := AdjustmentID} = Params,
    case find_adjustment(AdjustmentID, Withdrawal) of
        {error, {unknown_adjustment, _}} ->
            do_start_adjustment(Params, Withdrawal);
        {ok, _Adjustment} ->
            {ok, {idle, []}}
    end.

-spec find_adjustment(adjustment_id(), withdrawal_state()) -> {ok, adjustment()} | {error, unknown_adjustment_error()}.
find_adjustment(AdjustmentID, Withdrawal) ->
    ff_adjustment_utils:get_by_id(AdjustmentID, adjustments_index(Withdrawal)).

-spec adjustments(withdrawal_state()) -> [adjustment()].
adjustments(Withdrawal) ->
    ff_adjustment_utils:adjustments(adjustments_index(Withdrawal)).

-spec effective_final_cash_flow(withdrawal_state()) -> final_cash_flow().
effective_final_cash_flow(Withdrawal) ->
    case ff_adjustment_utils:cash_flow(adjustments_index(Withdrawal)) of
        undefined ->
            ff_cash_flow:make_empty_final();
        CashFlow ->
            CashFlow
    end.

-spec final_domain_revision(withdrawal_state()) -> domain_revision().
final_domain_revision(Withdrawal) ->
    case ff_adjustment_utils:domain_revision(adjustments_index(Withdrawal)) of
        undefined ->
            operation_domain_revision(Withdrawal);
        DomainRevision ->
            DomainRevision
    end.

-spec sessions(withdrawal_state()) -> [session()].
sessions(Withdrawal) ->
    ff_withdrawal_route_attempt_utils:get_sessions(attempts(Withdrawal)).

%% Сущность в настоящий момент нуждается в передаче ей управления для совершения каких-то действий
-spec is_active(withdrawal_state()) -> boolean().
is_active(#{status := succeeded} = Withdrawal) ->
    is_childs_active(Withdrawal);
is_active(#{status := {failed, _}} = Withdrawal) ->
    is_childs_active(Withdrawal);
is_active(#{status := pending}) ->
    true.

%% Сущность завершила свою основную задачу по переводу денег. Дальше её состояние будет меняться только
%% изменением дочерних сущностей, например запуском adjustment.
-spec is_finished(withdrawal_state()) -> boolean().
is_finished(#{status := succeeded}) ->
    true;
is_finished(#{status := {failed, _}}) ->
    true;
is_finished(#{status := pending}) ->
    false.

%% Transfer callbacks

-spec process_transfer(withdrawal_state()) -> process_result().
process_transfer(Withdrawal) ->
    Activity = deduce_activity(Withdrawal),
    scoper:scope(
        withdrawal,
        #{activity => format_activity(Activity)},
        fun() -> do_process_transfer(Activity, Withdrawal) end
    ).

format_activity(Activity) when is_atom(Activity) ->
    Activity;
format_activity(Activity) ->
    genlib:format(Activity).

%%

-spec finalize_session(session_id(), session_data(), withdrawal_state()) ->
    {ok, process_result()} | {error, session_not_found | old_session | result_mismatch}.
finalize_session(SessionID, #{result := SessionResult} = SessionData, Withdrawal) ->
    case get_session_by_id(SessionID, Withdrawal) of
        #{id := SessionID, result := SessionResult} ->
            {ok, {idle, []}};
        #{id := SessionID, result := OtherSessionResult} ->
            logger:warning("Session result mismatch - current: ~p, new: ~p", [OtherSessionResult, SessionResult]),
            {error, result_mismatch};
        #{id := SessionID} ->
            try_finish_session(SessionID, SessionData, Withdrawal);
        undefined ->
            {error, session_not_found}
    end.

-spec get_session_by_id(session_id(), withdrawal_state()) -> session() | undefined.
get_session_by_id(SessionID, Withdrawal) ->
    Sessions = ff_withdrawal_route_attempt_utils:get_sessions(attempts(Withdrawal)),
    case lists:filter(fun(#{id := SessionID0}) -> SessionID0 =:= SessionID end, Sessions) of
        [Session] -> Session;
        [] -> undefined
    end.

-spec try_finish_session(session_id(), session_data(), withdrawal_state()) ->
    {ok, process_result()} | {error, old_session}.
try_finish_session(SessionID, #{result := SessionResult} = SessionData, Withdrawal) ->
    case is_current_session(SessionID, Withdrawal) of
        true ->
            Events =
                [
                    {session_finished, {SessionID, SessionResult}}
                ] ++ body_changed_events(SessionData, Withdrawal),
            {ok, {timeout, Events}};
        false ->
            {error, old_session}
    end.

-spec is_current_session(session_id(), withdrawal_state()) -> boolean().
is_current_session(SessionID, Withdrawal) ->
    case session_id(Withdrawal) of
        SessionID ->
            true;
        _ ->
            false
    end.

%% Internals

body_changed_events(#{new_body := NewBody}, Withdrawal) ->
    case final_body(Withdrawal) of
        NewBody ->
            [];
        OldBody ->
            [{body_changed, #{new_body => NewBody, old_body => OldBody}}]
    end;
body_changed_events(_, _) ->
    [].

-spec do_start_adjustment(adjustment_params(), withdrawal_state()) ->
    {ok, process_result()}
    | {error, start_adjustment_error()}.
do_start_adjustment(Params, Withdrawal) ->
    do(fun() ->
        valid = unwrap(validate_adjustment_start(Params, Withdrawal)),
        AdjustmentParams = make_adjustment_params(Params, Withdrawal),
        #{id := AdjustmentID} = Params,
        {Action, Events} = unwrap(ff_adjustment:create(AdjustmentParams)),
        {Action, ff_adjustment_utils:wrap_events(AdjustmentID, Events)}
    end).

%% Internal getters

-spec update_attempts(attempts(), withdrawal_state()) -> withdrawal_state().
update_attempts(Attempts, T) ->
    maps:put(attempts, Attempts, T).

-spec p_transfer(withdrawal_state()) -> p_transfer() | undefined.
p_transfer(Withdrawal) ->
    ff_withdrawal_route_attempt_utils:get_current_p_transfer(attempts(Withdrawal)).

p_transfer_status(Withdrawal) ->
    case p_transfer(Withdrawal) of
        undefined ->
            undefined;
        Transfer ->
            ff_postings_transfer:status(Transfer)
    end.

-spec route_selection_status(withdrawal_state()) -> unknown | found.
route_selection_status(Withdrawal) ->
    case route(Withdrawal) of
        undefined ->
            unknown;
        _Known ->
            found
    end.

-spec adjustments_index(withdrawal_state()) -> adjustments_index().
adjustments_index(Withdrawal) ->
    case maps:find(adjustments, Withdrawal) of
        {ok, Adjustments} ->
            Adjustments;
        error ->
            ff_adjustment_utils:new_index()
    end.

-spec set_adjustments_index(adjustments_index(), withdrawal_state()) -> withdrawal_state().
set_adjustments_index(Adjustments, Withdrawal) ->
    Withdrawal#{adjustments => Adjustments}.

-spec operation_timestamp(withdrawal_state()) -> ff_time:timestamp_ms().
operation_timestamp(Withdrawal) ->
    QuoteTimestamp = quote_timestamp(quote(Withdrawal)),
    ff_maybe:get_defined([QuoteTimestamp, created_at(Withdrawal), ff_time:now()]).

-spec operation_domain_revision(withdrawal_state()) -> domain_revision().
operation_domain_revision(Withdrawal) ->
    case domain_revision(Withdrawal) of
        undefined ->
            ff_domain_config:head();
        Revision ->
            Revision
    end.

%% Processing helpers

-spec deduce_activity(withdrawal_state()) -> activity().
deduce_activity(Withdrawal) ->
    Params = #{
        route => route_selection_status(Withdrawal),
        p_transfer => p_transfer_status(Withdrawal),
        validation => withdrawal_validation_status(Withdrawal),
        session => get_current_session_status(Withdrawal),
        is_body_changed => is_body_changed(Withdrawal),
        p_transfer_rebuild_needed => is_p_transfer_rebuilding(Withdrawal),
        status => status(Withdrawal),
        limit_check => limit_check_processing_status(Withdrawal),
        active_adjustment => ff_adjustment_utils:is_active(adjustments_index(Withdrawal)),
        routing_rollback_data => maps:get(routing_rollback_data, Withdrawal, undefined)
    },
    do_deduce_activity(Params).

do_deduce_activity(#{status := pending} = Params) ->
    do_pending_activity(Params);
do_deduce_activity(#{status := succeeded} = Params) ->
    do_finished_activity(Params);
do_deduce_activity(#{status := {failed, _}} = Params) ->
    do_finished_activity(Params).

do_pending_activity(#{routing_rollback_data := #{}}) ->
    compensate_routing_failure;
do_pending_activity(#{route := unknown, p_transfer := undefined}) ->
    routing;
do_pending_activity(#{route := found, p_transfer := undefined}) ->
    p_transfer_start;
do_pending_activity(#{p_transfer := created}) ->
    p_transfer_prepare;
do_pending_activity(#{p_transfer := prepared, limit_check := unknown}) ->
    limit_check;
do_pending_activity(#{p_transfer := prepared, limit_check := ok, session := undefined}) ->
    session_starting;
do_pending_activity(#{p_transfer := prepared, limit_check := failed}) ->
    p_transfer_cancel;
do_pending_activity(#{p_transfer := cancelled, limit_check := failed}) ->
    {fail, limit_check};
do_pending_activity(#{p_transfer := prepared, session := pending}) ->
    session_sleeping;
do_pending_activity(#{p_transfer := prepared, session := succeeded, is_body_changed := false}) ->
    p_transfer_commit;
do_pending_activity(#{
    p_transfer := prepared, session := succeeded, is_body_changed := true, p_transfer_rebuild_needed := true
}) ->
    p_transfer_cancel;
do_pending_activity(#{p_transfer := cancelled, session := succeeded, is_body_changed := true}) ->
    p_transfer_recreate;
do_pending_activity(#{p_transfer := prepared, session := succeeded, is_body_changed := true}) ->
    p_transfer_commit;
do_pending_activity(#{p_transfer := committed, session := succeeded}) ->
    finish;
do_pending_activity(#{p_transfer := prepared, session := failed}) ->
    p_transfer_cancel;
do_pending_activity(#{p_transfer := cancelled, session := failed}) ->
    {fail, session}.

do_finished_activity(#{active_adjustment := true}) ->
    adjustment;
do_finished_activity(#{status := {failed, _}}) ->
    rollback_routing.

-spec do_process_transfer(activity(), withdrawal_state()) -> process_result().
do_process_transfer(routing, Withdrawal) ->
    process_routing(Withdrawal);
do_process_transfer(p_transfer_start, Withdrawal) ->
    Result = process_p_transfer_creation(Withdrawal),
    ok = rollback_unused_candidates(Withdrawal),
    Result;
do_process_transfer(p_transfer_recreate, Withdrawal) ->
    %% route limits already rolled back when p_transfer was cancelled
    %% new route limits with new amount are required
    WithdrawalWithNewBody = Withdrawal#{body => final_body(Withdrawal)},
    Route = route(Withdrawal),
    DomainRevision = final_domain_revision(Withdrawal),
    IterWithMultiplication =
        ff_withdrawal_route_attempt_utils:get_index(attempts(Withdrawal)) * ?BODY_CHANGED_ATTEMPT_MULTIPLIER,
    %% terms/limits selectors may depend on cost — use the changed body
    {Varset, _Context} = make_routing_varset_and_context(WithdrawalWithNewBody),
    {ok, #domain_ProvisionTermSet{
        wallet = #domain_WalletProvisionTerms{
            withdrawals = #domain_WithdrawalProvisionTerms{
                turnover_limit = SelectorTurnoverLimits
            }
        }
    }} = compute_provider_terminal_terms(Route, Varset, DomainRevision),
    TurnoverLimits = ff_limiter:get_turnover_limits(SelectorTurnoverLimits),
    ok = ff_limiter:hold_withdrawal_limits(TurnoverLimits, WithdrawalWithNewBody, Route, IterWithMultiplication),
    process_p_transfer_creation(Withdrawal);
do_process_transfer(p_transfer_prepare, Withdrawal) ->
    Tr = ff_withdrawal_route_attempt_utils:get_current_p_transfer(attempts(Withdrawal)),
    {ok, Events} = ff_postings_transfer:prepare(Tr),
    {timeout, [{p_transfer, Ev} || Ev <- Events]};
do_process_transfer(p_transfer_commit, Withdrawal) ->
    ok = commit_routes_limits([route(Withdrawal)], Withdrawal#{body => final_body(Withdrawal)}),
    Tr = ff_withdrawal_route_attempt_utils:get_current_p_transfer(attempts(Withdrawal)),
    {ok, Events} = ff_postings_transfer:commit(Tr),
    DomainRevision = final_domain_revision(Withdrawal),
    {ok, Wallet} = fetch_wallet(wallet_id(Withdrawal), party_id(Withdrawal), DomainRevision),
    ok = ff_party:wallet_log_balance(wallet_id(Withdrawal), Wallet),
    {timeout, [{p_transfer, Ev} || Ev <- Events]};
do_process_transfer(p_transfer_cancel, Withdrawal) ->
    ok = rollback_routes_limits([route(Withdrawal)], Withdrawal),
    Tr = ff_withdrawal_route_attempt_utils:get_current_p_transfer(attempts(Withdrawal)),
    {ok, Events} = ff_postings_transfer:cancel(Tr),
    {timeout, [{p_transfer, Ev} || Ev <- Events]};
do_process_transfer(limit_check, Withdrawal) ->
    process_limit_check(Withdrawal);
do_process_transfer(session_starting, Withdrawal) ->
    process_session_creation(Withdrawal);
do_process_transfer(session_sleeping, Withdrawal) ->
    process_session_sleep(Withdrawal);
do_process_transfer({fail, Reason}, Withdrawal) ->
    process_route_change(Withdrawal, Reason);
do_process_transfer(finish, Withdrawal) ->
    process_transfer_finish(Withdrawal);
do_process_transfer(adjustment, Withdrawal) ->
    process_adjustment(Withdrawal);
do_process_transfer(rollback_routing, Withdrawal) ->
    process_rollback_routing(Withdrawal);
do_process_transfer(compensate_routing_failure, Withdrawal) ->
    process_compensate_routing_failure(Withdrawal).

-spec process_routing(withdrawal_state()) -> process_result().
process_routing(Withdrawal) ->
    case do_process_routing(Withdrawal) of
        {ok, {[Route | _Rest], Accounted}} ->
            {timeout, [
                {route_changed, #{route => Route, candidates => Accounted}}
            ]};
        {error, {Reason, Accounted}} ->
            process_routing_failure(Reason, Accounted, Withdrawal)
    end.

-spec process_routing_failure(fail_type(), [route()], withdrawal_state()) -> process_result().
process_routing_failure(Reason, [], Withdrawal) ->
    {idle, process_transfer_fail(Reason, Withdrawal)};
process_routing_failure(Reason, Accounted, Withdrawal) ->
    Failure = build_failure(Reason, Withdrawal),
    {timeout, [{rollback_started, #{reason => Failure, candidates => Accounted}}]}.

-spec process_rollback_routing(withdrawal_state()) -> process_result().
process_rollback_routing(Withdrawal) ->
    case maps:get(routing_candidates, Withdrawal, undefined) of
        undefined ->
            ok = do_rollback_routing([], Withdrawal);
        _Accounted ->
            ok
    end,
    {idle, []}.

-spec process_compensate_routing_failure(withdrawal_state()) -> process_result().
process_compensate_routing_failure(Withdrawal) ->
    #{reason := Failure, candidates := Candidates} = maps:get(routing_rollback_data, Withdrawal),
    ok = rollback_routes_limits(Candidates, Withdrawal),
    {timeout, [{status_changed, {failed, Failure}}]}.

-spec do_process_routing(withdrawal_state()) ->
    {ok, {[route()], routing_candidates()}} | {error, {Reason, routing_candidates()}}
when
    Reason ::
        ff_withdrawal_routing:route_not_found()
        | attempt_limit_exceeded
        | InconsistentQuote,
    InconsistentQuote :: {inconsistent_quote_route, route()}.
do_process_routing(Withdrawal) ->
    do(fun() ->
        {Varset, Context} = make_routing_varset_and_context(Withdrawal),
        ExcludeRoutes = ff_withdrawal_route_attempt_utils:get_terminals(attempts(Withdrawal)),
        GatherResult = ff_withdrawal_routing:gather_routes(Varset, Context, ExcludeRoutes),
        FilterResult = ff_withdrawal_routing:filter_limit_overflow_routes(GatherResult, Varset, Context),
        ff_withdrawal_routing:log_reject_context(FilterResult),
        Accounted = ff_withdrawal_routing:accounted_candidates(FilterResult),
        Selection =
            case quote(Withdrawal) of
                undefined ->
                    ff_withdrawal_routing:select_routes(FilterResult);
                Quote ->
                    Routes = unwrap_routing_result(ff_withdrawal_routing:routes(FilterResult), Accounted),
                    select_quote_route(Routes, Quote)
            end,
        ValidatedRoutes = unwrap_routing_result(Selection, Accounted),
        {ValidatedRoutes, Accounted}
    end).

%% Errors after limit holds must carry candidates for compensation.
unwrap_routing_result({ok, Result}, _Accounted) ->
    Result;
unwrap_routing_result({error, Reason}, Accounted) ->
    throw({Reason, Accounted}).

do_rollback_routing(ExcludeRoutes0, Withdrawal) ->
    {Varset, Context} = make_routing_varset_and_context(Withdrawal),
    ExcludeUsedRoutes0 = ff_withdrawal_route_attempt_utils:get_terminals(attempts(Withdrawal)),
    ExcludeUsedRoutes1 =
        case ff_withdrawal_route_attempt_utils:get_current_p_transfer_status(attempts(Withdrawal)) of
            cancelled ->
                ExcludeUsedRoutes0;
            _ ->
                CurrentRoute = ff_withdrawal_route_attempt_utils:get_current_terminal(attempts(Withdrawal)),
                lists:filter(fun(R) -> CurrentRoute =/= R end, ExcludeUsedRoutes0)
        end,
    ExcludeRoutes1 =
        ExcludeUsedRoutes1 ++ lists:map(fun(R) -> ff_withdrawal_routing:get_terminal(R) end, ExcludeRoutes0),
    Routes = ff_withdrawal_routing:get_routes(ff_withdrawal_routing:gather_routes(Varset, Context, ExcludeRoutes1)),
    rollback_routes_limits(Routes, Varset, Context).

rollback_unused_candidates(Withdrawal) ->
    case maps:get(routing_candidates, Withdrawal, undefined) of
        undefined ->
            do_rollback_routing([route(Withdrawal)], Withdrawal);
        Candidates ->
            Unused = exclude_same_route(Candidates, route(Withdrawal)),
            rollback_routes_limits(Unused, Withdrawal)
    end.

exclude_same_route(Candidates, Chosen) ->
    lists:filter(
        fun(Candidate) -> not same_provider_terminal(Candidate, Chosen) end,
        Candidates
    ).

same_provider_terminal(#{provider_id := P, terminal_id := T}, #{provider_id := P, terminal_id := T}) ->
    true;
same_provider_terminal(_, _) ->
    false.

rollback_routes_limits([], _Withdrawal) ->
    ok;
rollback_routes_limits(Routes, Withdrawal) ->
    {Varset, Context} = make_routing_varset_and_context(Withdrawal),
    rollback_routes_limits(Routes, Varset, Context).

rollback_routes_limits(Routes, Varset, Context) ->
    ff_withdrawal_routing:rollback_routes_limits(Routes, Varset, Context).

commit_routes_limits(Routes, Withdrawal) ->
    {Varset, Context0} = make_routing_varset_and_context(Withdrawal),
    %% if body was changed then iteration value needs to be updated
    Context =
        case is_body_changed(Withdrawal) of
            true ->
                update_context_iteration(?BODY_CHANGED_ATTEMPT_MULTIPLIER, Context0);
            false ->
                Context0
        end,
    ff_withdrawal_routing:commit_routes_limits(Routes, Varset, Context).

make_routing_varset_and_context(Withdrawal) ->
    DomainRevision = final_domain_revision(Withdrawal),
    WalletID = wallet_id(Withdrawal),
    PartyID = party_id(Withdrawal),
    {ok, Wallet} = fetch_wallet(WalletID, PartyID, DomainRevision),
    {ok, Destination} = get_destination(destination_id(Withdrawal)),
    Resource = destination_resource(Withdrawal),
    VarsetParams = genlib_map:compact(#{
        body => body(Withdrawal),
        wallet_id => WalletID,
        wallet => Wallet,
        party_id => PartyID,
        destination => Destination,
        resource => Resource
    }),
    Context = #{
        domain_revision => DomainRevision,
        wallet => Wallet,
        withdrawal => Withdrawal,
        iteration => ff_withdrawal_route_attempt_utils:get_index(attempts(Withdrawal))
    },
    {build_party_varset(VarsetParams), Context}.

update_context_iteration(Multiplicator, #{iteration := Iter} = Context) ->
    Context#{iteration => Iter * Multiplicator}.

-spec select_quote_route([route()], quote_state()) -> {ok, [route()]} | {error, {inconsistent_quote_route, route()}}.
select_quote_route(Routes, #{route := QuoteRoute}) ->
    case lists:search(fun(Route) -> same_provider_terminal(Route, QuoteRoute) end, Routes) of
        {value, Route} ->
            {ok, [Route]};
        false ->
            {error, {inconsistent_quote_route, QuoteRoute}}
    end.

-spec process_limit_check(withdrawal_state()) -> process_result().
process_limit_check(Withdrawal) ->
    DomainRevision = final_domain_revision(Withdrawal),
    WalletID = wallet_id(Withdrawal),
    PartyID = party_id(Withdrawal),
    {ok, Wallet} = fetch_wallet(WalletID, PartyID, DomainRevision),
    {ok, Destination} = get_destination(destination_id(Withdrawal)),
    Resource = destination_resource(Withdrawal),
    VarsetParams = genlib_map:compact(#{
        body => body(Withdrawal),
        wallet_id => WalletID,
        wallet => Wallet,
        party_id => PartyID,
        destination => Destination,
        resource => Resource
    }),
    Terms = ff_party:get_terms(DomainRevision, Wallet, build_party_varset(VarsetParams)),
    Events =
        case validate_wallet_limits(Terms, Wallet) of
            {ok, valid} ->
                [{limit_check, {wallet_sender, ok}}];
            {error, {terms_violation, {wallet_limit, {cash_range, {Cash, Range}}}}} ->
                Details = #{
                    expected_range => Range,
                    balance => Cash
                },
                [{limit_check, {wallet_sender, {failed, Details}}}];
            {error, {terms_violation, {wallet_limit, {invalid_terms, Details}}}} ->
                [{limit_check, {wallet_sender, {failed, #{reason => invalid_terms, details => Details}}}}]
        end,
    {timeout, Events}.

-spec process_p_transfer_creation(withdrawal_state()) -> process_result().
process_p_transfer_creation(Withdrawal) ->
    FinalCashFlow = make_final_cash_flow(Withdrawal),
    PTransferID = construct_p_transfer_id(Withdrawal),
    {ok, PostingsTransferEvents} = ff_postings_transfer:create(PTransferID, FinalCashFlow),
    {timeout, [{p_transfer, Ev} || Ev <- PostingsTransferEvents]}.

-spec process_session_creation(withdrawal_state()) -> process_result().
process_session_creation(Withdrawal) ->
    ID = construct_session_id(Withdrawal),
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = params(Withdrawal),

    DomainRevision = final_domain_revision(Withdrawal),
    {ok, Wallet} = fetch_wallet(WalletID, party_id(Withdrawal), DomainRevision),
    {AccountID, Currency} = ff_party:get_wallet_account(Wallet),
    WalletRealm = ff_party:get_wallet_realm(Wallet, DomainRevision),
    WalletAccount = ff_account:build(party_id(Withdrawal), WalletRealm, AccountID, Currency),

    {ok, DestinationMachine} = ff_destination_machine:get(DestinationID),
    Destination = ff_destination_machine:destination(DestinationMachine),
    DestinationAccount = ff_destination:account(Destination),

    TransferData = genlib_map:compact(#{
        id => ID,
        cash => body(Withdrawal),
        sender => ff_account:party_id(WalletAccount),
        receiver => ff_account:party_id(DestinationAccount),
        quote => build_session_quote(quote(Withdrawal)),
        contact_info => contact_info(Withdrawal),
        client_info => client_info(Withdrawal)
    }),
    AuthData = ff_destination:auth_data(Destination),
    SessionParams = #{
        withdrawal_id => id(Withdrawal),
        resource => destination_resource(Withdrawal),
        route => route(Withdrawal),
        dest_auth_data => AuthData
    },
    ok = create_session(ID, TransferData, SessionParams),
    {timeout, [{session_started, ID}]}.

-spec construct_session_id(withdrawal_state()) -> id().
construct_session_id(Withdrawal) ->
    ID = id(Withdrawal),
    Attempt = ff_withdrawal_route_attempt_utils:get_attempt(attempts(Withdrawal)),
    SubID = integer_to_binary(Attempt),
    <<ID/binary, "/", SubID/binary>>.

-spec construct_p_transfer_id(withdrawal_state()) -> id().
construct_p_transfer_id(Withdrawal) ->
    ID = id(Withdrawal),
    Attempt0 = ff_withdrawal_route_attempt_utils:get_attempt(attempts(Withdrawal)),
    Attempt =
        case is_body_changed(Withdrawal) of
            true ->
                %% ID for new cashflow with multiplication
                Attempt0 * ?BODY_CHANGED_ATTEMPT_MULTIPLIER;
            false ->
                Attempt0
        end,
    SubID = integer_to_binary(Attempt),
    <<"ff/withdrawal/", ID/binary, "/", SubID/binary>>.

create_session(ID, TransferData, SessionParams) ->
    case ff_withdrawal_session_machine:create(ID, TransferData, SessionParams) of
        ok ->
            ok;
        {error, exists} ->
            ok
    end.

-spec process_session_sleep(withdrawal_state()) -> process_result().
process_session_sleep(_Withdrawal) ->
    {suspend, []}.

-spec process_transfer_finish(withdrawal_state()) -> process_result().
process_transfer_finish(Withdrawal) ->
    ok = maybe_add_to_customer(Withdrawal),
    {idle, [{status_changed, succeeded}]}.

maybe_add_to_customer(Withdrawal) ->
    case client_identity(Withdrawal) of
        #{customer_id := CustomerID} ->
            ff_customer:add_withdrawal(CustomerID, id(Withdrawal), party_id(Withdrawal));
        undefined ->
            ok
    end.

-spec process_transfer_fail(fail_type(), withdrawal_state()) -> [event()].
process_transfer_fail(FailType, Withdrawal) ->
    Failure = build_failure(FailType, Withdrawal),
    [{status_changed, {failed, Failure}}].

-spec handle_child_result(process_result(), withdrawal_state()) -> process_result().
handle_child_result({idle, Events} = Result, Withdrawal) ->
    NextWithdrawal = lists:foldl(fun(E, Acc) -> apply_event(E, Acc) end, Withdrawal, Events),
    case is_active(NextWithdrawal) of
        true ->
            {timeout, Events};
        false ->
            DomainRevision = final_domain_revision(Withdrawal),
            {ok, Wallet} = fetch_wallet(wallet_id(Withdrawal), party_id(Withdrawal), DomainRevision),
            ok = ff_party:wallet_log_balance(wallet_id(Withdrawal), Wallet),
            Result
    end;
handle_child_result({_OtherAction, _Events} = Result, _Withdrawal) ->
    Result.

-spec is_childs_active(withdrawal_state()) -> boolean().
is_childs_active(Withdrawal) ->
    ff_adjustment_utils:is_active(adjustments_index(Withdrawal)).

-spec make_final_cash_flow(withdrawal_state()) -> final_cash_flow().
make_final_cash_flow(Withdrawal) ->
    make_final_cash_flow(final_domain_revision(Withdrawal), Withdrawal).

-spec make_final_cash_flow(domain_revision(), withdrawal_state()) -> final_cash_flow().
make_final_cash_flow(DomainRevision, Withdrawal) ->
    Body = final_body(Withdrawal),
    WalletID = wallet_id(Withdrawal),

    {ok, Wallet} = fetch_wallet(WalletID, party_id(Withdrawal), DomainRevision),
    {AccountID, Currency} = ff_party:get_wallet_account(Wallet),
    WalletRealm = ff_party:get_wallet_realm(Wallet, DomainRevision),
    WalletAccount = ff_account:build(party_id(Withdrawal), WalletRealm, AccountID, Currency),

    Route = route(Withdrawal),
    {ok, Destination} = get_destination(destination_id(Withdrawal)),
    DestinationAccount = ff_destination:account(Destination),

    Resource = destination_resource(Withdrawal),
    VarsetParams = genlib_map:compact(#{
        body => Body,
        wallet_id => WalletID,
        wallet => Wallet,
        party_id => party_id(Withdrawal),
        destination => Destination,
        resource => Resource
    }),
    PartyVarset = build_party_varset(VarsetParams),

    {_Amount, CurrencyID} = Body,
    #{provider_id := ProviderID} = Route,
    {ok, Provider} = ff_payouts_provider:get(ProviderID, DomainRevision),
    ProviderAccounts = ff_payouts_provider:accounts(Provider),
    ProviderAccount = maps:get(CurrencyID, ProviderAccounts, #{}),
    ProviderSettlementAccount = maps:get(settlement, ProviderAccount, undefined),
    ProviderGuaranteeAccount = maps:get(guarantee, ProviderAccount, undefined),

    #domain_WalletConfig{payment_institution = PaymentInstitutionRef} = Wallet,
    {ok, PaymentInstitution} = ff_payment_institution:get(PaymentInstitutionRef, PartyVarset, DomainRevision),
    {ok, SystemAccounts} = ff_payment_institution:system_accounts(PaymentInstitution, DomainRevision),
    SystemAccount = maps:get(CurrencyID, SystemAccounts, #{}),
    SettlementAccount = maps:get(settlement, SystemAccount, undefined),
    SubagentAccount = maps:get(subagent, SystemAccount, undefined),

    {ok, ProviderFee} = compute_fees(Route, PartyVarset, DomainRevision),

    Terms = ff_party:get_terms(DomainRevision, Wallet, PartyVarset),

    {ok, WalletCashFlowPlan} = ff_party:get_withdrawal_cash_flow_plan(Terms),
    {ok, CashFlowPlan} = ff_cash_flow:add_fee(WalletCashFlowPlan, ProviderFee),
    Constants = #{
        operation_amount => Body
    },
    Accounts = genlib_map:compact(#{
        {wallet, sender_settlement} => WalletAccount,
        {wallet, receiver_destination} => DestinationAccount,
        {system, settlement} => SettlementAccount,
        {system, subagent} => SubagentAccount,
        {provider, settlement} => ProviderSettlementAccount,
        {provider, guarantee} => ProviderGuaranteeAccount
    }),
    {ok, FinalCashFlow} = ff_cash_flow:finalize(CashFlowPlan, Accounts, Constants),

    logger:info("Created FinalCashFlow: ~p", [FinalCashFlow]),
    FinalCashFlow.

-spec compute_fees(route(), party_varset(), domain_revision()) ->
    {ok, ff_cash_flow:cash_flow_fee()}
    | {error, term()}.
compute_fees(Route, VS, DomainRevision) ->
    case compute_provider_terminal_terms(Route, VS, DomainRevision) of
        {ok, #domain_ProvisionTermSet{
            wallet = #domain_WalletProvisionTerms{
                withdrawals = #domain_WithdrawalProvisionTerms{
                    cash_flow = CashFlowSelector
                }
            }
        }} ->
            cash_flow_postings(CashFlowSelector);
        {error, Error} ->
            {error, Error}
    end.

-spec compute_provider_terminal_terms(route(), party_varset(), domain_revision()) ->
    {ok, ff_party:provision_term_set()}
    | {error, provider_not_found}
    | {error, terminal_not_found}.
compute_provider_terminal_terms(#{provider_id := ProviderID, terminal_id := TerminalID}, VS, DomainRevision) ->
    ProviderRef = ff_payouts_provider:ref(ProviderID),
    TerminalRef = ff_payouts_terminal:ref(TerminalID),
    ff_party:compute_provider_terminal_terms(ProviderRef, TerminalRef, VS, DomainRevision).

cash_flow_postings(CashFlowSelector) ->
    case CashFlowSelector of
        {value, CashFlow} ->
            {ok, #{
                postings => ff_cash_flow:decode_domain_postings(CashFlow)
            }};
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {cash_flow, Ambiguous}}})
    end.

-spec ensure_domain_revision_defined(domain_revision() | undefined) -> domain_revision().
ensure_domain_revision_defined(undefined) ->
    ff_domain_config:head();
ensure_domain_revision_defined(Revision) ->
    Revision.

-spec get_destination(destination_id()) -> {ok, destination()} | {error, notfound}.
get_destination(DestinationID) ->
    do(fun() ->
        DestinationMachine = unwrap(ff_destination_machine:get(DestinationID)),
        ff_destination_machine:destination(DestinationMachine)
    end).

-spec build_party_varset(party_varset_params()) -> party_varset().
build_party_varset(#{body := Body, wallet_id := WalletID, party_id := PartyID} = Params) ->
    {_, CurrencyID} = Body,
    Destination = maps:get(destination, Params, undefined),
    Resource = maps:get(resource, Params, undefined),
    BinData = maps:get(bin_data, Params, undefined),
    PaymentTool =
        case {Destination, Resource} of
            {undefined, _} ->
                undefined;
            {_, Resource} ->
                construct_payment_tool(Resource)
        end,
    genlib_map:compact(#{
        currency => ff_dmsl_codec:marshal(currency_ref, CurrencyID),
        cost => ff_dmsl_codec:marshal(cash, Body),
        party_id => PartyID,
        wallet_id => WalletID,
        % TODO it's not fair, because it's PAYOUT not PAYMENT tool.
        payment_tool => PaymentTool,
        bin_data => ff_dmsl_codec:marshal(bin_data, BinData)
    }).

-spec construct_payment_tool(ff_destination:resource() | ff_destination:resource_params()) ->
    dmsl_domain_thrift:'PaymentTool'().
construct_payment_tool({bank_card, #{bank_card := ResourceBankCard}}) ->
    PaymentSystem = maps:get(payment_system, ResourceBankCard, undefined),
    {bank_card, #domain_BankCard{
        token = maps:get(token, ResourceBankCard),
        bin = maps:get(bin, ResourceBankCard),
        last_digits = maps:get(masked_pan, ResourceBankCard),
        payment_system = ff_dmsl_codec:marshal(payment_system, PaymentSystem),
        issuer_country = maps:get(issuer_country, ResourceBankCard, undefined),
        bank_name = maps:get(bank_name, ResourceBankCard, undefined)
    }};
construct_payment_tool({crypto_wallet, #{crypto_wallet := #{currency := Currency}}}) ->
    {crypto_currency, ff_dmsl_codec:marshal(crypto_currency, Currency)};
construct_payment_tool({generic, _} = Resource) ->
    ff_dmsl_codec:marshal(payment_tool, Resource);
construct_payment_tool(
    {digital_wallet, #{
        digital_wallet := Wallet = #{
            id := ID,
            payment_service := PaymentService
        }
    }}
) ->
    Token = maps:get(token, Wallet, undefined),
    {digital_wallet, #domain_DigitalWallet{
        id = ID,
        payment_service = ff_dmsl_codec:marshal(payment_service, PaymentService),
        token = Token,
        account_name = maps:get(account_name, Wallet, undefined),
        account_identity_number = maps:get(account_identity_number, Wallet, undefined)
    }}.

%% Quote helpers

-spec get_quote(quote_params()) ->
    {ok, quote()} | {error, create_error() | {route, ff_withdrawal_routing:route_not_found()}}.
get_quote(#{destination_id := DestinationID, body := Body, wallet_id := WalletID, party_id := PartyID} = Params) ->
    do(fun() ->
        Destination = unwrap(destination, get_destination(DestinationID)),
        DomainRevision = ff_domain_config:head(),
        Wallet = unwrap(wallet, fetch_wallet(WalletID, PartyID, DomainRevision)),
        Resource = unwrap(
            destination_resource,
            create_resource(ff_destination:resource(Destination), undefined, Wallet, DomainRevision)
        ),
        VarsetParams = genlib_map:compact(#{
            body => Body,
            wallet_id => WalletID,
            wallet => Wallet,
            party_id => PartyID,
            destination => Destination,
            resource => Resource
        }),
        PartyVarset = build_party_varset(VarsetParams),
        Timestamp = ff_time:now(),

        Terms = ff_party:get_terms(DomainRevision, Wallet, PartyVarset),

        valid = unwrap(validate_withdrawal_creation(Terms, Body, Wallet, Destination, Resource)),
        GetQuoteParams = #{
            base_params => Params,
            party_id => PartyID,
            party_varset => build_party_varset(VarsetParams),
            timestamp => Timestamp,
            domain_revision => DomainRevision,
            resource => Resource
        },
        unwrap(get_quote_(GetQuoteParams))
    end);
get_quote(Params) ->
    #{
        wallet_id := WalletID,
        party_id := PartyID,
        body := Body
    } = Params,
    DomainRevision = ff_domain_config:head(),
    {ok, Wallet} = fetch_wallet(WalletID, PartyID, DomainRevision),
    Timestamp = ff_time:now(),
    VarsetParams = genlib_map:compact(#{
        body => Body,
        wallet_id => WalletID,
        wallet => Wallet,
        party_id => PartyID
    }),
    GetQuoteParams = #{
        base_params => Params,
        party_id => PartyID,
        party_varset => build_party_varset(VarsetParams),
        timestamp => Timestamp,
        domain_revision => DomainRevision
    },
    get_quote_(GetQuoteParams).

get_quote_(Params) ->
    do(fun() ->
        #{
            base_params := #{
                body := Body,
                wallet_id := WalletID,
                currency_from := CurrencyFrom,
                currency_to := CurrencyTo
            },
            party_id := PartyID,
            party_varset := Varset,
            timestamp := Timestamp,
            domain_revision := DomainRevision
        } = Params,
        Resource = maps:get(resource, Params, undefined),
        Wallet = unwrap(wallet, fetch_wallet(WalletID, PartyID, DomainRevision)),

        %% TODO: don't apply turnover limits here
        [Route | _] = unwrap(route, ff_withdrawal_routing:prepare_routes(Varset, Wallet, DomainRevision)),
        {Adapter, AdapterOpts} = ff_withdrawal_session:get_adapter_with_opts(Route),
        GetQuoteParams = #{
            external_id => maps:get(external_id, Params, undefined),
            currency_from => CurrencyFrom,
            currency_to => CurrencyTo,
            body => Body,
            resource => Resource
        },
        {ok, Quote} = ff_adapter_withdrawal:get_quote(Adapter, GetQuoteParams, AdapterOpts),
        genlib_map:compact(#{
            cash_from => maps:get(cash_from, Quote),
            cash_to => maps:get(cash_to, Quote),
            created_at => maps:get(created_at, Quote),
            expires_on => maps:get(expires_on, Quote),
            quote_data => maps:get(quote_data, Quote),
            route => Route,
            operation_timestamp => Timestamp,
            resource_descriptor => ff_resource:resource_descriptor(Resource),
            domain_revision => DomainRevision
        })
    end).

-spec build_session_quote(quote_state() | undefined) -> ff_adapter_withdrawal:quote_data() | undefined.
build_session_quote(undefined) ->
    undefined;
build_session_quote(Quote) ->
    maps:with([cash_from, cash_to, created_at, expires_on, quote_data], Quote).

-spec fetch_wallet(wallet_id(), party_id(), domain_revision()) -> {ok, wallet()} | {error, notfound}.
fetch_wallet(WalletID, PartyID, DomainRevision) ->
    ff_party:get_wallet(WalletID, #domain_PartyConfigRef{id = PartyID}, DomainRevision).

-spec quote_resource_descriptor(quote() | undefined) -> resource_descriptor().
quote_resource_descriptor(undefined) ->
    undefined;
quote_resource_descriptor(Quote) ->
    maps:get(resource_descriptor, Quote, undefined).

-spec quote_timestamp(quote() | undefined) -> ff_time:timestamp_ms() | undefined.
quote_timestamp(undefined) ->
    undefined;
quote_timestamp(Quote) ->
    maps:get(operation_timestamp, Quote, undefined).

-spec quote_domain_revision(quote() | undefined) -> domain_revision() | undefined.
quote_domain_revision(undefined) ->
    undefined;
quote_domain_revision(Quote) ->
    maps:get(domain_revision, Quote, undefined).

%% Validation
-spec withdrawal_validation_status(withdrawal_state()) -> validated | skipped.
withdrawal_validation_status(#{validation := _Validation}) ->
    validated;
withdrawal_validation_status(#{params := #{destination_id := DestinationID}}) ->
    case get_destination(DestinationID) of
        {ok, #{auth_data := _AuthData}} ->
            skipped;
        _ ->
            skipped
    end.

%% Session management

-spec session_id(withdrawal_state()) -> session_id() | undefined.
session_id(T) ->
    case get_current_session(T) of
        undefined ->
            undefined;
        #{id := SessionID} ->
            SessionID
    end.

-spec get_current_session(withdrawal_state()) -> session() | undefined.
get_current_session(Withdrawal) ->
    ff_withdrawal_route_attempt_utils:get_current_session(attempts(Withdrawal)).

-spec get_session_result(withdrawal_state()) -> session_result() | unknown | undefined.
get_session_result(Withdrawal) ->
    case get_current_session(Withdrawal) of
        undefined ->
            undefined;
        #{result := Result} ->
            Result;
        #{} ->
            unknown
    end.

-spec get_current_session_status(withdrawal_state()) -> session_processing_status().
get_current_session_status(Withdrawal) ->
    Session = get_current_session(Withdrawal),
    case Session of
        undefined ->
            undefined;
        #{result := success} ->
            succeeded;
        #{result := {success, _}} ->
            succeeded;
        #{result := {failed, _}} ->
            failed;
        #{} ->
            pending
    end.

%% Withdrawal validators

-spec validate_withdrawal_creation(terms(), body(), wallet(), destination(), destination_resource()) ->
    {ok, valid}
    | {error, create_error()}.
validate_withdrawal_creation(Terms, Body, Wallet, Destination, Resource) ->
    do(fun() ->
        Method = ff_resource:method(Resource),
        valid = unwrap(terms, validate_withdrawal_creation_terms(Terms, Body, Method)),
        valid = unwrap(validate_withdrawal_currency(Body, Wallet, Destination)),
        valid = unwrap(validate_withdrawal_realms(Wallet, Destination))
    end).

validate_withdrawal_realms(#domain_WalletConfig{payment_institution = PaymentInstitutionRef}, Destination) ->
    DomainRevision = ff_domain_config:head(),
    {ok, WalletRealm} = ff_payment_institution:get_realm(PaymentInstitutionRef, DomainRevision),
    DestinationtRealm = ff_destination:realm(Destination),
    case WalletRealm =:= DestinationtRealm of
        true -> {ok, valid};
        false -> {error, {realms_mismatch, {WalletRealm, DestinationtRealm}}}
    end.

-spec validate_withdrawal_creation_terms(terms(), body(), ff_resource:method()) ->
    {ok, valid}
    | {error, ff_party:validate_withdrawal_creation_error()}.
validate_withdrawal_creation_terms(Terms, Body, Method) ->
    ff_party:validate_withdrawal_creation(Terms, Body, Method).

-spec validate_withdrawal_currency(body(), wallet(), destination()) ->
    {ok, valid}
    | {error, {inconsistent_currency, {currency_id(), currency_id(), currency_id()}}}.
validate_withdrawal_currency(Body, Wallet, Destination) ->
    DestiantionCurrencyID = ff_account:currency(ff_destination:account(Destination)),
    {_AccountID, WalletCurrencyID} = ff_party:get_wallet_account(Wallet),
    case Body of
        {_Amount, WithdrawalCurencyID} when
            WithdrawalCurencyID =:= DestiantionCurrencyID andalso
                WithdrawalCurencyID =:= WalletCurrencyID
        ->
            {ok, valid};
        {_Amount, WithdrawalCurencyID} ->
            {error, {inconsistent_currency, {WithdrawalCurencyID, WalletCurrencyID, DestiantionCurrencyID}}}
    end.

%% Limit helpers

-spec add_limit_check(limit_check_details(), withdrawal_state()) -> withdrawal_state().
add_limit_check(Check, Withdrawal) ->
    Attempts = attempts(Withdrawal),
    Checks =
        case ff_withdrawal_route_attempt_utils:get_current_limit_checks(Attempts) of
            undefined ->
                [Check];
            C ->
                [Check | C]
        end,
    R = ff_withdrawal_route_attempt_utils:update_current_limit_checks(Checks, Attempts),
    update_attempts(R, Withdrawal).

-spec limit_check_status(withdrawal_state()) -> ok | {failed, limit_check_details()} | unknown.
limit_check_status(Withdrawal) ->
    Attempts = attempts(Withdrawal),
    Checks = ff_withdrawal_route_attempt_utils:get_current_limit_checks(Attempts),
    limit_check_status_(Checks).

limit_check_status_(undefined) ->
    unknown;
limit_check_status_(Checks) ->
    case lists:dropwhile(fun is_limit_check_ok/1, Checks) of
        [] ->
            ok;
        [H | _Tail] ->
            {failed, H}
    end.

-spec limit_check_processing_status(withdrawal_state()) -> ok | failed | unknown.
limit_check_processing_status(Withdrawal) ->
    case limit_check_status(Withdrawal) of
        ok ->
            ok;
        unknown ->
            unknown;
        {failed, _Details} ->
            failed
    end.

-spec is_limit_check_ok(limit_check_details()) -> boolean().
is_limit_check_ok({wallet_sender, ok}) ->
    true;
is_limit_check_ok({wallet_sender, {failed, _Details}}) ->
    false.

-spec validate_wallet_limits(terms(), wallet()) ->
    {ok, valid}
    | {error, {terms_violation, {wallet_limit, {cash_range, {cash(), cash_range()}}}}}
    | {error, {terms_violation, {wallet_limit, {invalid_terms, term()}}}}.
validate_wallet_limits(Terms, Wallet) ->
    case ff_party:validate_wallet_limits(Terms, Wallet) of
        {ok, valid} = Result ->
            Result;
        {error, {terms_violation, {cash_range, {Cash, CashRange}}}} ->
            {error, {terms_violation, {wallet_limit, {cash_range, {Cash, CashRange}}}}};
        {error, {invalid_terms, _} = Reason} ->
            {error, {terms_violation, {wallet_limit, Reason}}}
    end.

%% Adjustment validators

-spec validate_adjustment_start(adjustment_params(), withdrawal_state()) ->
    {ok, valid}
    | {error, start_adjustment_error()}.
validate_adjustment_start(Params, Withdrawal) ->
    do(fun() ->
        valid = unwrap(validate_no_pending_adjustment(Withdrawal)),
        valid = unwrap(validate_withdrawal_finish(Withdrawal)),
        valid = unwrap(validate_status_change(Params, Withdrawal)),
        valid = unwrap(validate_domain_revision_change(Params, Withdrawal)),
        valid = unwrap(validate_body_change(Params, Withdrawal))
    end).

-spec validate_withdrawal_finish(withdrawal_state()) ->
    {ok, valid}
    | {error, {invalid_withdrawal_status, status()}}.
validate_withdrawal_finish(Withdrawal) ->
    case is_finished(Withdrawal) of
        true ->
            {ok, valid};
        false ->
            {error, {invalid_withdrawal_status, status(Withdrawal)}}
    end.

-spec validate_no_pending_adjustment(withdrawal_state()) ->
    {ok, valid}
    | {error, {another_adjustment_in_progress, adjustment_id()}}.
validate_no_pending_adjustment(Withdrawal) ->
    case ff_adjustment_utils:get_not_finished(adjustments_index(Withdrawal)) of
        error ->
            {ok, valid};
        {ok, AdjustmentID} ->
            {error, {another_adjustment_in_progress, AdjustmentID}}
    end.

-spec validate_status_change(adjustment_params(), withdrawal_state()) ->
    {ok, valid}
    | {error, invalid_status_change_error()}.
validate_status_change(#{change := {change_status, Status}}, Withdrawal) ->
    do(fun() ->
        valid = unwrap(invalid_status_change, validate_target_status(Status)),
        valid = unwrap(invalid_status_change, validate_change_same_status(Status, status(Withdrawal)))
    end);
validate_status_change(_Params, _Withdrawal) ->
    {ok, valid}.

-spec validate_target_status(status()) ->
    {ok, valid}
    | {error, {unavailable_status, status()}}.
validate_target_status(succeeded) ->
    {ok, valid};
validate_target_status({failed, _Failure}) ->
    {ok, valid};
validate_target_status(Status) ->
    {error, {unavailable_status, Status}}.

-spec validate_change_same_status(status(), status()) ->
    {ok, valid}
    | {error, {already_has_status, status()}}.
validate_change_same_status(NewStatus, OldStatus) when NewStatus =/= OldStatus ->
    {ok, valid};
validate_change_same_status(Status, Status) ->
    {error, {already_has_status, Status}}.

-spec validate_domain_revision_change(adjustment_params(), withdrawal_state()) ->
    {ok, valid}
    | {error,
        {invalid_cash_flow_change,
            {already_has_domain_revision, domain_revision()}
            | {unavailable_status, status()}}}.
validate_domain_revision_change(#{change := {change_cash_flow, DomainRevision}}, Withdrawal) ->
    do(fun() ->
        valid = unwrap(
            invalid_cash_flow_change,
            validate_change_same_domain_revision(DomainRevision, final_domain_revision(Withdrawal))
        ),
        valid = unwrap(invalid_cash_flow_change, validate_current_status(status(Withdrawal)))
    end);
validate_domain_revision_change(_Params, _Withdrawal) ->
    {ok, valid}.

-spec validate_change_same_domain_revision(domain_revision(), domain_revision()) ->
    {ok, valid}
    | {error, {already_has_domain_revision, domain_revision()}}.
validate_change_same_domain_revision(NewDomainRevision, OldDomainRevision) when
    NewDomainRevision =/= OldDomainRevision
->
    {ok, valid};
validate_change_same_domain_revision(DomainRevision, DomainRevision) ->
    {error, {already_has_domain_revision, DomainRevision}}.

-spec validate_current_status(status()) ->
    {ok, valid}
    | {error, {unavailable_status, status()}}.
validate_current_status(succeeded) ->
    {ok, valid};
validate_current_status({failed, _Failure} = Status) ->
    {error, {unavailable_status, Status}};
validate_current_status(Status) ->
    {error, {unavailable_status, Status}}.

-spec validate_body_change(adjustment_params(), withdrawal_state()) ->
    {ok, valid}
    | {error, invalid_body_change_error()}.
validate_body_change(#{change := {change_body, NewBody}}, Withdrawal) ->
    do(fun() ->
        valid = unwrap(invalid_body_change, validate_new_body(NewBody, final_body(Withdrawal)))
    end);
validate_body_change(_Params, _Withdrawal) ->
    {ok, valid}.

-spec validate_new_body(body(), body()) ->
    {ok, valid}
    | {error, {already_has_body, body()} | {invalid_operation_amount, body()}}.
validate_new_body({Amount, Currency}, {Amount, Currency}) ->
    {error, {already_has_body, {Amount, Currency}}};
validate_new_body({NewAmount, Currency}, {OldAmount, Currency}) when
    is_integer(NewAmount), NewAmount > 0, NewAmount < OldAmount
->
    {ok, valid};
validate_new_body(NewBody, _OldBody) ->
    {error, {invalid_operation_amount, NewBody}}.

%% Adjustment helpers

-spec apply_adjustment_event(wrapped_adjustment_event(), withdrawal_state()) -> withdrawal_state().
apply_adjustment_event(WrappedEvent, Withdrawal) ->
    Adjustments0 = adjustments_index(Withdrawal),
    Adjustments1 = ff_adjustment_utils:apply_event(WrappedEvent, Adjustments0),
    set_adjustments_index(Adjustments1, Withdrawal).

-spec make_adjustment_params(adjustment_params(), withdrawal_state()) -> ff_adjustment:params().
make_adjustment_params(Params, Withdrawal) ->
    #{id := ID, change := Change} = Params,
    genlib_map:compact(#{
        id => ID,
        changes_plan => make_adjustment_change(Change, Withdrawal),
        external_id => genlib_map:get(external_id, Params),
        domain_revision => adjustment_domain_revision(Change, Withdrawal),
        operation_timestamp => operation_timestamp(Withdrawal)
    }).

-spec adjustment_domain_revision(adjustment_change(), withdrawal_state()) -> domain_revision().
adjustment_domain_revision({change_cash_flow, NewDomainRevision}, _Withdrawal) ->
    NewDomainRevision;
adjustment_domain_revision(_, Withdrawal) ->
    operation_domain_revision(Withdrawal).

-spec make_adjustment_change(adjustment_change(), withdrawal_state()) -> ff_adjustment:changes().
make_adjustment_change({change_status, NewStatus}, Withdrawal) ->
    CurrentStatus = status(Withdrawal),
    make_change_status_params(CurrentStatus, NewStatus, Withdrawal);
make_adjustment_change({change_cash_flow, NewDomainRevision}, Withdrawal) ->
    make_change_cash_flow_params(NewDomainRevision, Withdrawal);
make_adjustment_change({change_body, NewBody}, Withdrawal) ->
    make_change_body_params(NewBody, Withdrawal).

-spec make_change_status_params(status(), status(), withdrawal_state()) -> ff_adjustment:changes().
make_change_status_params(succeeded, {failed, _} = NewStatus, Withdrawal) ->
    CurrentCashFlow = effective_final_cash_flow(Withdrawal),
    NewCashFlow = ff_cash_flow:make_empty_final(),
    #{
        new_status => #{
            new_status => NewStatus
        },
        new_cash_flow => #{
            old_cash_flow_inverted => ff_cash_flow:inverse(CurrentCashFlow),
            new_cash_flow => NewCashFlow
        }
    };
make_change_status_params({failed, _}, succeeded = NewStatus, Withdrawal) ->
    CurrentCashFlow = effective_final_cash_flow(Withdrawal),
    NewCashFlow = make_final_cash_flow(Withdrawal),
    #{
        new_status => #{
            new_status => NewStatus
        },
        new_cash_flow => #{
            old_cash_flow_inverted => ff_cash_flow:inverse(CurrentCashFlow),
            new_cash_flow => NewCashFlow
        }
    };
make_change_status_params({failed, _}, {failed, _} = NewStatus, _Withdrawal) ->
    #{
        new_status => #{
            new_status => NewStatus
        }
    }.

make_change_cash_flow_params(NewDomainRevision, Withdrawal) ->
    CurrentCashFlow = effective_final_cash_flow(Withdrawal),
    NewCashFlow = make_final_cash_flow(NewDomainRevision, Withdrawal),
    #{
        new_cash_flow => #{
            old_cash_flow_inverted => ff_cash_flow:inverse(CurrentCashFlow),
            new_cash_flow => NewCashFlow
        },
        new_domain_revision => #{
            new_domain_revision => NewDomainRevision
        }
    }.

-spec make_change_body_params(body(), withdrawal_state()) -> ff_adjustment:changes().
make_change_body_params(NewBody, #{status := {failed, _}}) ->
    #{
        new_body => #{
            new_body => NewBody
        }
    };
make_change_body_params(NewBody, #{status := succeeded} = Withdrawal) ->
    CurrentCashFlow = effective_final_cash_flow(Withdrawal),
    %% body_changed is not applied yet; inject new body before CF recalculation
    NewCashFlow = make_final_cash_flow(Withdrawal#{new_body => NewBody}),
    #{
        new_body => #{
            new_body => NewBody
        },
        new_cash_flow => #{
            old_cash_flow_inverted => ff_cash_flow:inverse(CurrentCashFlow),
            new_cash_flow => NewCashFlow
        }
    }.

-spec process_adjustment(withdrawal_state()) -> process_result().
process_adjustment(Withdrawal) ->
    #{
        action := Action,
        events := Events0,
        changes := Changes
    } = ff_adjustment_utils:process_adjustments(adjustments_index(Withdrawal)),
    Events1 = Events0 ++ handle_adjustment_changes(Changes, Withdrawal),
    handle_child_result({Action, Events1}, Withdrawal).

-spec process_route_change(withdrawal_state(), fail_type()) -> process_result().
process_route_change(Withdrawal, Reason) ->
    case is_failure_transient(Reason, Withdrawal) of
        true ->
            case do_process_routing(Withdrawal) of
                {ok, {Routes, Accounted}} ->
                    do_process_route_change(Routes, Accounted, Withdrawal, Reason);
                {error, {_GatherReason, Accounted}} ->
                    process_routing_failure(Reason, Accounted, Withdrawal)
            end;
        false ->
            Events = process_transfer_fail(Reason, Withdrawal),
            {idle, Events}
    end.

-spec is_failure_transient(fail_type(), withdrawal_state()) -> boolean().
is_failure_transient(Reason, Withdrawal) ->
    PartyID = party_id(Withdrawal),
    RetryableErrors = get_retryable_error_list(PartyID),
    ErrorTokens = to_error_token_list(Reason, Withdrawal),
    match_error_whitelist(ErrorTokens, RetryableErrors).

-spec get_retryable_error_list(party_id()) -> list(list(binary())).
get_retryable_error_list(PartyID) ->
    WithdrawalConfig = genlib_app:env(ff_transfer, withdrawal, #{}),
    PartyRetryableErrors = maps:get(party_transient_errors, WithdrawalConfig, #{}),
    Errors =
        case maps:get(PartyID, PartyRetryableErrors, undefined) of
            undefined ->
                maps:get(default_transient_errors, WithdrawalConfig, []);
            ErrorList ->
                ErrorList
        end,
    binaries_to_error_tokens(Errors).

-spec binaries_to_error_tokens(list(binary())) -> list(list(binary())).
binaries_to_error_tokens(Errors) ->
    lists:map(
        fun(Error) ->
            binary:split(Error, <<":">>, [global])
        end,
        Errors
    ).

-spec to_error_token_list(fail_type(), withdrawal_state()) -> list(binary()).
to_error_token_list(Reason, Withdrawal) ->
    Failure = build_failure(Reason, Withdrawal),
    failure_to_error_token_list(Failure).

-spec failure_to_error_token_list(ff_failure:failure()) -> list(binary()).
failure_to_error_token_list(#{code := Code, sub := SubFailure}) ->
    SubFailureList = failure_to_error_token_list(SubFailure),
    [Code | SubFailureList];
failure_to_error_token_list(#{code := Code}) ->
    [Code].

-spec match_error_whitelist(list(binary()), list(list(binary()))) -> boolean().
match_error_whitelist(ErrorTokens, RetryableErrors) ->
    lists:any(
        fun(RetryableError) ->
            error_tokens_match(ErrorTokens, RetryableError)
        end,
        RetryableErrors
    ).

-spec error_tokens_match(list(binary()), list(binary())) -> boolean().
error_tokens_match(_, []) ->
    true;
error_tokens_match([], [_ | _]) ->
    false;
error_tokens_match([Token0 | Rest0], [Token1 | Rest1]) when Token0 =:= Token1 ->
    error_tokens_match(Rest0, Rest1);
error_tokens_match([Token0 | _], [Token1 | _]) when Token0 =/= Token1 ->
    false.

-spec do_process_route_change([route()], [route()], withdrawal_state(), fail_type()) -> process_result().
do_process_route_change(Routes, Accounted, Withdrawal, Reason) ->
    Attempts = attempts(Withdrawal),
    AttemptLimit = get_attempt_limit(Withdrawal),
    case ff_withdrawal_route_attempt_utils:next_route(Routes, Attempts, AttemptLimit) of
        {ok, Route} ->
            {timeout, [
                {route_changed, #{route => Route, candidates => Accounted}}
            ]};
        {error, route_not_found} ->
            process_routing_failure(Reason, Accounted, Withdrawal);
        {error, attempt_limit_exceeded} ->
            process_routing_failure(Reason, Accounted, Withdrawal)
    end.

-spec handle_adjustment_changes(ff_adjustment:changes(), withdrawal_state()) -> [event()].
handle_adjustment_changes(Changes, Withdrawal) ->
    handle_adjustment_status_change(maps:get(new_status, Changes, undefined), Withdrawal) ++
        handle_adjustment_body_change(maps:get(new_body, Changes, undefined), Withdrawal).

-spec handle_adjustment_status_change(ff_adjustment:status_change() | undefined, withdrawal_state()) -> [event()].
handle_adjustment_status_change(undefined, _Withdrawal) ->
    [];
%% A withdrawal made succeeded by an adjustment is recorded for its Customer, as one that
%% succeeded on its own is
handle_adjustment_status_change(#{new_status := succeeded}, Withdrawal) ->
    ok = maybe_add_to_customer(Withdrawal),
    [{status_changed, succeeded}];
handle_adjustment_status_change(#{new_status := Status}, _Withdrawal) ->
    [{status_changed, Status}].

-spec handle_adjustment_body_change(ff_adjustment:body_change() | undefined, withdrawal_state()) -> [event()].
handle_adjustment_body_change(undefined, _Withdrawal) ->
    [];
handle_adjustment_body_change(#{new_body := NewBody}, Withdrawal) ->
    case final_body(Withdrawal) of
        NewBody ->
            [];
        OldBody ->
            [{body_changed, #{old_body => OldBody, new_body => NewBody}}]
    end.

-spec save_adjustable_info(event(), withdrawal_state()) -> withdrawal_state().
save_adjustable_info({p_transfer, {status_changed, committed}}, Withdrawal) ->
    CashFlow = ff_postings_transfer:final_cash_flow(p_transfer(Withdrawal)),
    update_adjusment_index(fun ff_adjustment_utils:set_cash_flow/2, CashFlow, Withdrawal);
save_adjustable_info(_Ev, Withdrawal) ->
    Withdrawal.

-spec update_adjusment_index(Updater, Value, withdrawal_state()) -> withdrawal_state() when
    Updater :: fun((Value, adjustments_index()) -> adjustments_index()),
    Value :: any().
update_adjusment_index(Updater, Value, Withdrawal) ->
    Index = adjustments_index(Withdrawal),
    set_adjustments_index(Updater(Value, Index), Withdrawal).

%% Failure helpers

-spec build_failure(fail_type(), withdrawal_state()) -> failure().
build_failure(limit_check, Withdrawal) ->
    {failed, {wallet_sender, _WalletLimitDetails} = Details} = limit_check_status(Withdrawal),
    #{
        code => <<"account_limit_exceeded">>,
        reason => genlib:format(Details),
        sub => #{
            code => <<"amount">>
        }
    };
build_failure({route_not_found, []}, _Withdrawal) ->
    #{
        code => <<"no_route_found">>
    };
build_failure({route_not_found, RejectedRoutes}, _Withdrawal) ->
    genlib_map:compact(#{
        code => <<"no_route_found">>,
        reason => genlib:format({rejected_routes, RejectedRoutes}),
        sub => build_route_not_found_sub_failure(RejectedRoutes)
    });
build_failure({inconsistent_quote_route, QuoteRoute}, _Withdrawal) ->
    #{
        code => <<"unknown">>,
        reason => genlib:format({inconsistent_quote_route, QuoteRoute})
    };
build_failure(session, Withdrawal) ->
    Result = get_session_result(Withdrawal),
    {failed, Failure} = Result,
    Failure.

-define(rejected_route(Reason), {_PrvRef, _TrmRef, Reason}).

build_route_not_found_sub_failure([]) ->
    undefined;
%% NOTE If limit overflow reason present in any rejected route See reason-tuple
%% construction in `ff_withdrawal_routing:validate_turnover_limits/4` and
%% `ff_limiter:check_limits/4`.
build_route_not_found_sub_failure([
    ?rejected_route({terms_violation, {overflow, OverflowedLimits}}) | _
]) ->
    #{
        code => <<"limit_overflow">>,
        sub => #{
            code => genlib_string:join($,, [LimitID || {LimitID, _Amount, _Boundary} <- OverflowedLimits])
        }
    };
build_route_not_found_sub_failure([_H | Rest]) ->
    build_route_not_found_sub_failure(Rest).

-spec apply_event(event() | legacy_event(), ff_maybe:'maybe'(withdrawal_state())) -> withdrawal_state().
apply_event({route_changed, #{provider_id := _} = Route}, T0) ->
    apply_event({route_changed, #{route => Route}}, T0);
apply_event(Ev, T0) ->
    T1 = apply_event_(Ev, T0),
    T2 = save_adjustable_info(Ev, T1),
    T2.

-spec apply_event_(event(), ff_maybe:'maybe'(withdrawal_state())) -> withdrawal_state().
apply_event_({created, T}, undefined) ->
    make_state(T);
apply_event_({status_changed, Status}, T0) ->
    T1 = maps:remove(routing_rollback_data, T0),
    maps:put(status, Status, T1);
apply_event_({resource_got, Resource}, T) ->
    maps:put(resource, Resource, T);
apply_event_({limit_check, Details}, T) ->
    add_limit_check(Details, T);
apply_event_({p_transfer, Ev}, T) ->
    Tr = ff_postings_transfer:apply_event(Ev, p_transfer(T)),
    R = ff_withdrawal_route_attempt_utils:update_current_p_transfer(Tr, attempts(T)),
    T1 = update_attempts(R, T),
    case is_body_changed(T) of
        true ->
            %% transfer rebuilding already initiated
            T1#{p_transfer_rebuild_needed => false};
        false ->
            T1
    end;
apply_event_({session_started, SessionID}, T0) ->
    %% clear body-change leftovers from a previous session before starting a new one
    T = maps:without([new_body, p_transfer_rebuild_needed], T0),
    Session = #{id => SessionID},
    Attempts = attempts(T),
    R = ff_withdrawal_route_attempt_utils:update_current_session(Session, Attempts),
    update_attempts(R, T);
apply_event_({session_finished, {SessionID, Result}}, T) ->
    Attempts = attempts(T),
    Session = ff_withdrawal_route_attempt_utils:get_current_session(Attempts),
    SessionID = maps:get(id, Session),
    UpdSession = Session#{result => Result},
    R = ff_withdrawal_route_attempt_utils:update_current_session(UpdSession, Attempts),
    update_attempts(R, T);
apply_event_({body_changed, #{new_body := NewBody}}, T) ->
    T#{new_body => NewBody, p_transfer_rebuild_needed => true};
apply_event_({route_changed, #{route := Route} = Change}, T0) ->
    R = ff_withdrawal_route_attempt_utils:new_route(Route, attempts(T0)),
    T1 = maps:without([routing_rollback_data, routing_candidates], T0),
    maps:merge(
        T1,
        genlib_map:compact(#{
            route => Route,
            attempts => R,
            routing_candidates => maps:get(candidates, Change, undefined)
        })
    );
apply_event_({rollback_started, #{reason := _, candidates := Candidates = [_ | _]} = Data}, T) ->
    T#{routing_candidates => Candidates, routing_rollback_data => Data};
apply_event_({validation, {Part, ValidationResult}}, T) ->
    Validates = maps:get(validation, T, #{}),
    PartValidations = maps:get(Part, Validates, []),
    T#{validation => Validates#{Part => [ValidationResult | PartValidations]}};
apply_event_({adjustment, _Ev} = Event, T) ->
    apply_adjustment_event(Event, T).

-spec make_state(withdrawal()) -> withdrawal_state().
make_state(#{route := Route} = T) ->
    Attempts = ff_withdrawal_route_attempt_utils:new(),
    T#{
        attempts => ff_withdrawal_route_attempt_utils:new_route(Route, Attempts)
    };
make_state(T) when not is_map_key(route, T) ->
    T.

get_attempt_limit(Withdrawal) ->
    #{
        body := Body,
        params := #{
            wallet_id := WalletID,
            destination_id := DestinationID
        },
        resource := Resource
    } = Withdrawal,
    DomainRevision = final_domain_revision(Withdrawal),
    PartyID = party_id(Withdrawal),

    {ok, Wallet} = fetch_wallet(WalletID, party_id(Withdrawal), DomainRevision),
    {ok, Destination} = get_destination(DestinationID),
    VarsetParams = genlib_map:compact(#{
        body => Body,
        wallet_id => WalletID,
        party_id => PartyID,
        destination => Destination,
        resource => Resource
    }),

    Terms = ff_party:get_terms(DomainRevision, Wallet, build_party_varset(VarsetParams)),

    #domain_TermSet{wallets = WalletTerms} = Terms,
    #domain_WalletServiceTerms{withdrawals = WithdrawalTerms} = WalletTerms,
    #domain_WithdrawalServiceTerms{attempt_limit = AttemptLimit} = WithdrawalTerms,
    get_attempt_limit_(AttemptLimit).

get_attempt_limit_(undefined) ->
    %% When attempt_limit is undefined
    %% do not try all defined providers, if any
    %% just stop after first one
    1;
get_attempt_limit_({value, Limit}) ->
    ff_dmsl_codec:unmarshal(attempt_limit, Limit).

is_body_changed(#{new_body := _NewBody}) ->
    true;
is_body_changed(_) ->
    false.

is_p_transfer_rebuilding(#{p_transfer_rebuild_needed := true}) ->
    true;
is_p_transfer_rebuilding(_) ->
    false.

final_body(#{new_body := NewBody}) ->
    NewBody;
final_body(#{body := Body}) ->
    Body.

%% Tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec match_error_whitelist_test() -> _.

match_error_whitelist_test() ->
    ErrorWhitelist = binaries_to_error_tokens([
        <<"some:test:error">>,
        <<"another:test:error">>,
        <<"wide">>
    ]),
    ?assertEqual(
        false,
        match_error_whitelist(
            [<<>>],
            ErrorWhitelist
        )
    ),
    ?assertEqual(
        false,
        match_error_whitelist(
            [<<"some">>, <<"completely">>, <<"different">>, <<"error">>],
            ErrorWhitelist
        )
    ),
    ?assertEqual(
        false,
        match_error_whitelist(
            [<<"some">>, <<"test">>],
            ErrorWhitelist
        )
    ),
    ?assertEqual(
        false,
        match_error_whitelist(
            [<<"wider">>],
            ErrorWhitelist
        )
    ),
    ?assertEqual(
        true,
        match_error_whitelist(
            [<<"some">>, <<"test">>, <<"error">>],
            ErrorWhitelist
        )
    ),
    ?assertEqual(
        true,
        match_error_whitelist(
            [<<"another">>, <<"test">>, <<"error">>, <<"that">>, <<"is">>, <<"more">>, <<"specific">>],
            ErrorWhitelist
        )
    ).

-spec routing_journal_test() -> _.
routing_journal_test() ->
    Chosen = test_route(1, 7),
    Overflowed = test_route(2, 8),
    with_routing_mocks([Chosen, Overflowed], fun() ->
        ok = meck:expect(ff_limiter, check_limits, fun
            (_, _, Route, _) when Route =:= Overflowed -> {error, {overflow, [{<<"limit">>, 101, 100}]}};
            (_, _, _, _) -> {ok, []}
        end),
        {timeout, [{route_changed, #{route := Chosen, candidates := Candidates}} = Event]} =
            process_transfer(test_withdrawal_state()),
        ?assertEqual(lists:sort([Chosen, Overflowed]), lists:sort(Candidates)),
        State = apply_event(Event, test_withdrawal_state()),
        %% meck 0.9.2 incorrectly specifies meck:raise/2's reason as the atom 'term'.
        ok = meck:expect(ff_withdrawal_routing, gather_routes, 3, meck_ret_spec:raise(error, ruleset_unavailable)),
        {timeout, CreationEvents} = process_transfer(State),
        ?assert(meck:called(ff_limiter, rollback_withdrawal_limits, [[], '_', Overflowed, 1])),
        Created = lists:foldl(fun apply_event/2, State, CreationEvents),
        ?assertMatch(
            {timeout, [{p_transfer, {status_changed, prepared}}]},
            process_transfer(Created)
        ),
        ?assertEqual(1, meck:num_calls(ff_limiter, rollback_withdrawal_limits, '_')),
        ?assertNot(meck:called(ff_limiter, rollback_withdrawal_limits, [[], '_', Chosen, 1]))
    end).

-spec routing_failure_compensation_test() -> _.
routing_failure_compensation_test() ->
    Route = test_route(1, 7),
    with_routing_mocks([Route], fun() ->
        ok = meck:expect(ff_limiter, check_limits, 4, {error, {overflow, [{<<"limit">>, 101, 100}]}}),
        {timeout, [{rollback_started, #{reason := Failure, candidates := [Route]}} = Event]} =
            process_transfer(test_withdrawal_state()),
        State = apply_event(Event, test_withdrawal_state()),
        ?assertEqual(#{reason => Failure, candidates => [Route]}, maps:get(routing_rollback_data, State)),
        ok = meck:expect(ff_party, compute_provider_terminal_terms, 4, {error, provision_termset_undefined}),
        ?assertError({route_terms, provision_termset_undefined}, process_transfer(State)),
        ?assertEqual(0, meck:num_calls(ff_limiter, rollback_withdrawal_limits, '_')),
        Timeout = {woody_error, {system, result_unknown, <<"timeout">>}},
        ok = meck:expect(
            ff_party, compute_provider_terminal_terms, 4, meck_ret_spec:raise(error, Timeout)
        ),
        ?assertError(Timeout, process_transfer(State)),
        ?assertEqual(0, meck:num_calls(ff_limiter, rollback_withdrawal_limits, '_')),
        ok = meck:expect(ff_party, compute_provider_terminal_terms, 4, test_route_terms()),
        ok = meck:expect(
            ff_limiter, rollback_withdrawal_limits, 4, meck:seq([meck_ret_spec:raise(error, Timeout), ok])
        ),
        ?assertError(Timeout, process_transfer(State)),
        {timeout, Events} = process_transfer(State),
        ?assertEqual([{status_changed, {failed, Failure}}], Events),
        ?assertEqual({timeout, Events}, process_transfer(State)),
        ?assertEqual(3, meck:num_calls(ff_limiter, rollback_withdrawal_limits, [[], '_', Route, 1])),
        Failed = lists:foldl(fun apply_event/2, State, Events),
        ?assertNot(maps:is_key(routing_rollback_data, Failed)),
        ?assertEqual({idle, []}, process_transfer(Failed)),
        ?assertEqual(3, meck:num_calls(ff_limiter, rollback_withdrawal_limits, '_'))
    end).

%% No holds means routing can fail without a rollback event or another timeout.
-spec empty_routing_failure_test() -> _.
empty_routing_failure_test() ->
    with_routing_mocks([], fun() ->
        ?assertMatch(
            {idle, [{status_changed, {failed, #{code := <<"no_route_found">>}}}]},
            process_transfer(test_withdrawal_state())
        ),
        ?assertEqual(0, meck:num_calls(ff_limiter, hold_withdrawal_limits, '_')),
        ?assertEqual(0, meck:num_calls(ff_limiter, rollback_withdrawal_limits, '_'))
    end).

-spec chosen_rollback_iteration_test() -> _.
chosen_rollback_iteration_test() ->
    Route = test_route(1, 7),
    NextRoute = test_route(2, 8),
    Failure = #{code => <<"authorization_error">>},
    with_routing_mocks([Route, NextRoute], fun() ->
        Routed = apply_event({route_changed, #{route => Route, candidates => [Route]}}, test_withdrawal_state()),
        Prepared = test_p_transfer(Routed, prepared),
        State = lists:foldl(fun apply_event/2, Prepared, [
            {limit_check, {wallet_sender, ok}},
            {session_started, <<"s1">>},
            {session_finished, {<<"s1">>, {failed, Failure}}}
        ]),
        ok = meck:expect(ff_postings_transfer, cancel, 1, {ok, [{status_changed, cancelled}]}),
        {timeout, Events} = process_transfer(State),
        ?assertMatch(
            [{p_transfer, {status_changed, cancelled}}],
            Events
        ),
        Cancelled = lists:foldl(fun apply_event/2, State, Events),
        ?assertEqual(2, ff_withdrawal_route_attempt_utils:get_index(attempts(Cancelled))),
        ?assert(meck:called(ff_limiter, rollback_withdrawal_limits, [[], '_', Route, 1])),
        {timeout, [{route_changed, #{route := NextRoute}} = NextEvent]} = process_routing(Cancelled),
        ?assert(meck:called(ff_limiter, hold_withdrawal_limits, [[], '_', NextRoute, 2])),
        NextState = apply_event(NextEvent, Cancelled),
        ok = rollback_routes_limits([NextRoute], NextState),
        ?assert(meck:called(ff_limiter, rollback_withdrawal_limits, [[], '_', NextRoute, 2])),
        ?assertEqual(2, meck:num_calls(ff_limiter, rollback_withdrawal_limits, '_'))
    end).

-spec routing_hold_retry_test() -> _.
routing_hold_retry_test() ->
    Route = test_route(1, 7),
    with_routing_mocks([Route], fun() ->
        Timeout = {woody_error, {system, result_unknown, <<"timeout">>}},
        ok = meck:expect(ff_limiter, hold_withdrawal_limits, 4, meck:seq([meck_ret_spec:raise(error, Timeout), ok])),
        State = test_withdrawal_state(),
        ?assertError(Timeout, process_transfer(State)),
        ?assertMatch({timeout, [{route_changed, #{route := Route, candidates := [Route]}}]}, process_transfer(State)),
        ?assertEqual(2, meck:num_calls(ff_limiter, hold_withdrawal_limits, [[], State, Route, 1]))
    end).

-spec quote_mismatch_rollback_test() -> _.
quote_mismatch_rollback_test() ->
    Route = test_route(1, 7),
    with_routing_mocks([Route], fun() ->
        State0 = test_withdrawal_state(),
        Params = maps:get(params, State0),
        Quote = #{
            cash_from => {100, <<"RUB">>},
            cash_to => {100, <<"USD">>},
            created_at => <<"t">>,
            expires_on => <<"t">>,
            quote_data => #{},
            route => test_route(2, 8)
        },
        State = State0#{params => Params#{quote => Quote}},
        {timeout, [Event]} = process_transfer(State),
        {rollback_started, #{reason := #{code := <<"unknown">>} = Failure, candidates := [Route]}} = Event,
        ?assertEqual({timeout, [{status_changed, {failed, Failure}}]}, process_transfer(apply_event(Event, State))),
        ?assert(meck:called(ff_limiter, rollback_withdrawal_limits, [[], '_', Route, 1]))
    end).

-spec quote_route_selection_test() -> _.
quote_route_selection_test() ->
    Preferred = test_route(1, 7),
    Quoted = test_route(2, 8),
    with_routing_mocks([Preferred, Quoted], fun() ->
        ok = meck:expect(ff_withdrawal_routing, gather_routes, fun(VS, _, _) ->
            Candidates = [
                hg_route:new(1, #domain_ProviderRef{id = 1}, #domain_TerminalRef{id = 7}, 100, 1000, 0),
                hg_route:new(1, #domain_ProviderRef{id = 2}, #domain_TerminalRef{id = 8}, 0, 900, 0)
            ],
            #{
                routes => Candidates,
                reject_context => #{varset => VS, accepted_routes => Candidates, rejected_routes => []}
            }
        end),
        State0 = test_withdrawal_state(),
        Params = maps:get(params, State0),
        Quote = #{
            cash_from => {100, <<"RUB">>},
            cash_to => {100, <<"USD">>},
            created_at => <<"t">>,
            expires_on => <<"t">>,
            quote_data => #{},
            route => Quoted
        },
        State = State0#{params => Params#{quote => Quote}},
        {timeout, [{route_changed, #{route := Quoted, candidates := Accounted}} = Event]} = process_transfer(State),
        ?assertEqual(lists:sort([Preferred, Quoted]), lists:sort(Accounted)),
        {timeout, _} = process_transfer(apply_event(Event, State)),
        ?assert(meck:called(ff_limiter, rollback_withdrawal_limits, [[], '_', Preferred, 1])),
        ?assertNot(meck:called(ff_limiter, rollback_withdrawal_limits, [[], '_', Quoted, 1])),
        %% A quoted route rejected by the limit check is no longer eligible.
        ok = meck:expect(ff_limiter, check_limits, fun
            (_, _, Route, _) when Route =:= Quoted -> {error, {overflow, []}};
            (_, _, _, _) -> {ok, []}
        end),
        ?assertMatch(
            {timeout, [{rollback_started, #{candidates := [_, _]}}]},
            process_transfer(State)
        )
    end).

-spec legacy_routing_cleanup_test() -> _.
legacy_routing_cleanup_test() ->
    Chosen = test_route(1, 7),
    Unused = test_route(2, 8),
    with_routing_mocks([Chosen, Unused], fun() ->
        lists:foreach(
            fun(Event) ->
                State = apply_event(Event, (test_withdrawal_state())#{routing_candidates => [Chosen]}),
                ?assertNot(maps:is_key(routing_candidates, State)),
                {timeout, CreationEvents} = process_transfer(State),
                Created = lists:foldl(fun apply_event/2, State, CreationEvents),
                ?assertMatch(
                    {timeout, [{p_transfer, {status_changed, prepared}}]},
                    process_transfer(Created)
                )
            end,
            [
                {route_changed, Chosen},
                {route_changed, #{route => Chosen}},
                {route_changed, #{route => Chosen, candidates => undefined}}
            ]
        ),
        ?assert(meck:called(ff_limiter, rollback_withdrawal_limits, [[], '_', Unused, 1])),
        ?assertNot(meck:called(ff_limiter, rollback_withdrawal_limits, [[], '_', Chosen, 1]))
    end).

-spec legacy_resource_routing_context_test() -> _.
legacy_resource_routing_context_test() ->
    Route = test_route(1, 7),
    State0 = test_withdrawal_state(),
    Resource = maps:get(resource, State0),
    Legacy = maps:remove(resource, State0),
    with_routing_mocks([Route], fun() ->
        ok = meck:new(ff_resource, [passthrough]),
        try
            ok = meck:expect(ff_destination_machine, destination, 1, #{id => <<"dest">>, resource => Resource}),
            ok = meck:expect(ff_resource, create_resource, 1, {ok, Resource}),
            {RoutingVarset, _} = make_routing_varset_and_context(Legacy),
            Events = [
                {route_changed, #{route => Route, candidates => [Route]}},
                {rollback_started, #{reason => #{code => <<"no_route_found">>}, candidates => [Route]}}
            ],
            lists:foreach(
                fun(Event) ->
                    ResourceReads = meck:num_calls(ff_resource, create_resource, '_'),
                    State = apply_event(Event, Legacy),
                    ?assertEqual(ResourceReads, meck:num_calls(ff_resource, create_resource, '_')),
                    Current = apply_event(
                        {body_changed, #{old_body => body(State), new_body => {200, <<"RUB">>}}},
                        State
                    ),
                    ok = meck:expect(ff_party, compute_provider_terminal_terms, fun(_, _, Varset, Revision) ->
                        ?assertEqual(RoutingVarset, Varset),
                        ?assertEqual(42, Revision),
                        test_route_terms()
                    end),
                    ok = rollback_routes_limits([Route], Current),
                    ?assert(meck:called(ff_limiter, rollback_withdrawal_limits, [[], Current, Route, 1]))
                end,
                Events
            )
        after
            ok = meck:unload(ff_resource)
        end
    end).

test_p_transfer(State, Status) ->
    lists:foldl(fun apply_event/2, State, [
        {p_transfer, {created, #{id => <<"pt">>, final_cash_flow => #{postings => []}}}},
        {p_transfer, {status_changed, Status}}
    ]).

with_routing_mocks(Routes, Fun) ->
    Modules = [
        ff_party,
        ff_limiter,
        ff_destination_machine,
        ff_postings_transfer,
        ff_withdrawal_routing,
        ff_payouts_provider,
        ff_payment_institution
    ],
    ok = meck:new(Modules, [passthrough]),
    try
        ok = meck:expect(ff_party, get_wallet, 3, {ok, test_wallet()}),
        ok = meck:expect(ff_party, wallet_log_balance, 2, ok),
        ok = meck:expect(ff_party, compute_provider_terminal_terms, 4, test_route_terms()),
        ok = meck:expect(ff_destination_machine, get, 1, {ok, test_destination}),
        ok = meck:expect(ff_destination_machine, destination, 1, #{id => <<"dest">>}),
        ok = meck:expect(ff_limiter, hold_withdrawal_limits, 4, ok),
        ok = meck:expect(ff_limiter, check_limits, 4, {ok, []}),
        ok = meck:expect(ff_limiter, rollback_withdrawal_limits, 4, ok),
        ok = meck:expect(ff_postings_transfer, create, fun(ID, CashFlow) ->
            {ok, [
                {created, #{id => ID, final_cash_flow => CashFlow}},
                {status_changed, created}
            ]}
        end),
        ok = meck:expect(ff_postings_transfer, prepare, 1, {ok, [{status_changed, prepared}]}),
        ok = meck:expect(ff_party, get_wallet_realm, 2, test),
        ok = meck:expect(ff_party, get_terms, 3, #domain_TermSet{}),
        ok = meck:expect(ff_party, get_withdrawal_cash_flow_plan, 1, {ok, #{postings => []}}),
        ok = meck:expect(ff_payouts_provider, get, 2, {ok, #{accounts => #{}}}),
        ok = meck:expect(ff_payment_institution, get, 3, {ok, #{}}),
        ok = meck:expect(ff_payment_institution, system_accounts, 2, {ok, #{}}),
        ok = meck:expect(ff_withdrawal_routing, gather_routes, fun(VS, _, Exclude) ->
            Candidates = [
                hg_route:new(1, #domain_ProviderRef{id = P}, #domain_TerminalRef{id = T}, 0, 1000, 0)
             || #{provider_id := P, terminal_id := T} <- Routes, not lists:member(T, Exclude)
            ],
            #{
                routes => Candidates,
                reject_context => #{varset => VS, accepted_routes => Candidates, rejected_routes => []}
            }
        end),
        Fun()
    after
        ok = meck:unload(Modules)
    end.

test_route_terms() ->
    {ok, #domain_ProvisionTermSet{
        wallet = #domain_WalletProvisionTerms{
            withdrawals = #domain_WithdrawalProvisionTerms{cash_flow = {value, []}, turnover_limit = {value, []}}
        }
    }}.

test_wallet() ->
    #domain_WalletConfig{
        name = <<"wallet">>,
        block = {unblocked, #domain_Unblocked{reason = <<>>, since = <<"1970-01-01T00:00:00Z">>}},
        suspension = {active, #domain_Active{since = <<"1970-01-01T00:00:00Z">>}},
        terms = #domain_TermSetHierarchyRef{id = 1},
        account = #domain_WalletAccount{
            currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>},
            settlement = 1
        },
        payment_institution = #domain_PaymentInstitutionRef{id = 1},
        party_ref = #domain_PartyConfigRef{id = <<"party">>}
    }.

test_route(ProviderID, TerminalID) ->
    #{
        version => 1,
        provider_id => ProviderID,
        terminal_id => TerminalID
    }.

-spec test_withdrawal_state() -> withdrawal_state().
test_withdrawal_state() ->
    #{
        id => <<"w-1">>,
        body => {100, <<"RUB">>},
        params => #{
            party_id => <<"party">>,
            wallet_id => <<"wallet">>,
            destination_id => <<"dest">>
        },
        created_at => 1,
        domain_revision => 42,
        attempts => ff_withdrawal_route_attempt_utils:new(),
        status => pending,
        validation => #{},
        resource =>
            {bank_card, #{
                bank_card => #{
                    token => <<"tok">>,
                    bin => <<"424242">>,
                    masked_pan => <<"4242">>
                }
            }}
    }.

-endif.
