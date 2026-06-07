%%%
%%% Destination
%%%
%%% TODOs
%%%
%%%  - We must consider withdrawal provider terms ensure that the provided
%%%    Resource is ok to withdraw to.

-module(ff_destination).

-behaviour(prg_machine).

-define(NS, 'ff/destination_v2').
-define(EVENT_FORMAT_VERSION, 1).

-type id() :: binary().
-type token() :: binary().
-type name() :: binary().
-type account() :: ff_account:account().
-type currency() :: ff_currency:id().
-type metadata() :: ff_entity_context:md().
-type timestamp() :: ff_time:timestamp_ms().
-type party_id() :: ff_party:id().
-type realm() :: ff_payment_institution:realm().

-type resource_params() :: ff_resource:resource_params().
-type resource() :: ff_resource:resource().

-type exp_date() :: {integer(), integer()}.

-define(ACTUAL_FORMAT_VERSION, 5).

-type destination() :: #{
    version := ?ACTUAL_FORMAT_VERSION,
    id := id(),
    realm := realm(),
    party_id := party_id(),
    resource := resource(),
    name := name(),
    created_at => timestamp(),
    external_id => id(),
    metadata => metadata(),
    auth_data => auth_data()
}.

-type destination_state() :: #{
    id := id(),
    realm := realm(),
    account := account() | undefined,
    party_id := party_id(),
    resource := resource(),
    name := name(),
    created_at => timestamp(),
    external_id => id(),
    metadata => metadata(),
    auth_data => auth_data()
}.

-type params() :: #{
    id := id(),
    realm := realm(),
    party_id := party_id(),
    name := name(),
    currency := ff_currency:id(),
    resource := resource_params(),
    external_id => id(),
    metadata => metadata(),
    auth_data => auth_data()
}.

-type auth_data() :: #{
    sender := token(),
    receiver := token()
}.

-type event() ::
    {created, destination()}
    | {account, ff_account:event()}.

-type create_error() ::
    {party, notfound}
    | {currency, notfound}
    | ff_account:create_error()
    | {party, ff_party:inaccessibility()}.

-export_type([id/0]).
-export_type([destination/0]).
-export_type([destination_state/0]).
-export_type([resource_params/0]).
-export_type([resource/0]).
-export_type([params/0]).
-export_type([event/0]).
-export_type([create_error/0]).
-export_type([exp_date/0]).
-export_type([auth_data/0]).

%% Accessors

-export([id/1]).
-export([realm/1]).
-export([party_id/1]).
-export([name/1]).
-export([account/1]).
-export([currency/1]).
-export([resource/1]).
-export([external_id/1]).
-export([created_at/1]).
-export([metadata/1]).
-export([auth_data/1]).

%% API

-export([create/1]).
-export([is_accessible/1]).
-export([apply_event/2]).

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

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1, unwrap/2]).

-type ctx() :: ff_entity_context:context().
-type machine() :: prg_machine:machine().
-type prg_result() :: prg_machine:result().

%% Accessors

-spec party_id(destination_state()) -> party_id().
-spec id(destination_state()) -> id().
-spec realm(destination_state()) -> realm().
-spec name(destination_state()) -> name().
-spec account(destination_state()) -> account() | undefined.
-spec currency(destination_state()) -> currency().
-spec resource(destination_state()) -> resource().

party_id(#{party_id := V}) ->
    V.

id(#{id := V}) ->
    V.

realm(#{realm := V}) ->
    V.

name(#{name := V}) ->
    V.

account(#{account := V}) ->
    V;
account(_) ->
    undefined.

currency(Destination) ->
    ff_account:currency(account(Destination)).

resource(#{resource := V}) ->
    V.

-spec external_id(destination_state()) -> id() | undefined.
external_id(#{external_id := ExternalID}) ->
    ExternalID;
external_id(_Destination) ->
    undefined.

-spec created_at(destination_state()) -> ff_time:timestamp_ms() | undefined.
created_at(#{created_at := CreatedAt}) ->
    CreatedAt;
created_at(_Destination) ->
    undefined.

-spec metadata(destination_state()) -> ff_entity_context:context() | undefined.
metadata(#{metadata := Metadata}) ->
    Metadata;
metadata(_Destination) ->
    undefined.

-spec auth_data(destination_state()) -> auth_data() | undefined.
auth_data(#{auth_data := AuthData}) ->
    AuthData;
auth_data(_Destination) ->
    undefined.

%% API

-spec create(params()) ->
    {ok, [event()]}
    | {error, create_error()}.
create(Params) ->
    do(fun() ->
        #{
            id := ID,
            realm := Realm,
            party_id := PartyID,
            name := Name,
            currency := CurrencyID,
            resource := Resource
        } = Params,
        accessible = unwrap(party, ff_party:is_accessible(PartyID)),
        valid = ff_resource:check_resource(Resource),
        CreatedAt = ff_time:now(),
        Currency = unwrap(currency, ff_currency:get(CurrencyID)),
        Events = unwrap(ff_account:create(PartyID, Realm, Currency)),
        [
            {created,
                genlib_map:compact(#{
                    version => ?ACTUAL_FORMAT_VERSION,
                    id => ID,
                    realm => Realm,
                    name => Name,
                    party_id => PartyID,
                    resource => Resource,
                    external_id => maps:get(external_id, Params, undefined),
                    metadata => maps:get(metadata, Params, undefined),
                    auth_data => maps:get(auth_data, Params, undefined),
                    created_at => CreatedAt
                })}
        ] ++ [{account, Ev} || Ev <- Events]
    end).

-spec is_accessible(destination_state()) ->
    {ok, accessible}
    | {error, ff_party:inaccessibility()}.
is_accessible(Destination) ->
    ff_account:is_accessible(account(Destination)).

-spec apply_event(event(), ff_maybe:'maybe'(destination_state())) -> destination_state().
apply_event({created, Destination}, undefined) ->
    Destination;
apply_event({status_changed, S}, Destination) ->
    Destination#{status => S};
apply_event({account, Ev}, #{account := Account} = Destination) ->
    Destination#{account => ff_account:apply_event(Ev, Account)};
apply_event({account, Ev}, Destination) ->
    apply_event({account, Ev}, Destination#{account => undefined}).

%% prg_machine

-spec namespace() -> prg_machine:namespace().
namespace() ->
    ?NS.

-spec init({[event()], ctx()}, machine()) -> prg_result().
init({Events, Ctx}, _Machine) ->
    #{
        events => Events,
        action => progressor_action:instant(),
        auxst => #{ctx => Ctx}
    }.

-spec process_signal(prg_machine:signal(), machine()) -> prg_result().
process_signal(timeout, _Machine) ->
    #{};
process_signal({repair, _Args}, _Machine) ->
    erlang:error({unexpected_signal, repair}).

-spec process_call(term(), machine()) -> no_return().
process_call(CallArgs, _Machine) ->
    erlang:error({unexpected_call, CallArgs}).

-spec process_repair(ff_repair:scenario(), machine()) -> prg_result() | {error, term()}.
process_repair(Scenario, Machine) ->
    case ff_repair:apply_scenario(?MODULE, to_repair_machine(Machine), Scenario) of
        {ok, {_Response, Result}} ->
            from_repair_result(Result, Machine);
        {error, Reason} ->
            {error, Reason}
    end.

-spec process_notification(term(), machine()) -> prg_result().
process_notification(_Args, _Machine) ->
    #{events => [], action => progressor_action:instant()}.

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Body) ->
    Timestamped = {ev, {prg_machine:timestamp(), 0}, Body},
    Encoded = ff_machine_codec:marshal_event(destination, ?EVENT_FORMAT_VERSION, Timestamped),
    {?EVENT_FORMAT_VERSION, ff_machine_codec:payload_to_binary(Encoded)}.

-spec unmarshal_event_body(pos_integer(), binary()) -> prg_machine:event_body().
unmarshal_event_body(?EVENT_FORMAT_VERSION, Payload) ->
    Timestamped = ff_machine_codec:unmarshal_event(destination, ?EVENT_FORMAT_VERSION, Payload),
    event_body_from_timestamped(Timestamped);
unmarshal_event_body(Format, _Payload) ->
    erlang:error({unknown_event_format, Format}).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    ff_machine_codec:marshal_aux_state(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    ff_machine_codec:unmarshal_aux_state(Payload).

-spec from_repair_result(map(), machine()) -> prg_result().
from_repair_result(#{events := Events} = Result, Machine) ->
    #{
        events => repair_events_to_domain(Events),
        action => undefined,
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
