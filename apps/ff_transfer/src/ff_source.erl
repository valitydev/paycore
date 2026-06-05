%%%
%%% Source
%%%
%%% TODOs
%%%
%%%  - Implement a generic source instead of a current dummy one.

-module(ff_source).

-behaviour(prg_machine).

-define(NS, 'ff/source_v1').
-define(EVENT_FORMAT_VERSION, 1).

-type id() :: binary().
-type name() :: binary().
-type account() :: ff_account:account().
-type currency() :: ff_currency:id().
-type metadata() :: ff_entity_context:md().
-type timestamp() :: ff_time:timestamp_ms().
-type realm() :: ff_payment_institution:realm().
-type party_id() :: ff_party:id().

-type resource() :: #{
    type := internal,
    details => binary()
}.

-define(ACTUAL_FORMAT_VERSION, 4).

-type source() :: #{
    version := ?ACTUAL_FORMAT_VERSION,
    resource := resource(),
    id := id(),
    realm := realm(),
    party_id := party_id(),
    name := name(),
    created_at => timestamp(),
    external_id => id(),
    metadata => metadata()
}.

-type source_state() :: #{
    account := account() | undefined,
    resource := resource(),
    id := id(),
    realm := realm(),
    party_id := party_id(),
    name := name(),
    created_at => timestamp(),
    external_id => id(),
    metadata => metadata()
}.

-type params() :: #{
    id := id(),
    realm := realm(),
    party_id := party_id(),
    name := name(),
    currency := ff_currency:id(),
    resource := resource(),
    external_id => id(),
    metadata => metadata()
}.

-type event() ::
    {created, source_state()}
    | {account, ff_account:event()}.

-type create_error() ::
    {party, notfound}
    | {currency, notfound}
    | ff_account:create_error()
    | {party, ff_party:inaccessibility()}.

-export_type([id/0]).
-export_type([source/0]).
-export_type([source_state/0]).
-export_type([resource/0]).
-export_type([params/0]).
-export_type([event/0]).
-export_type([create_error/0]).

%% Accessors

-export([id/1]).
-export([realm/1]).
-export([account/1]).
-export([name/1]).
-export([party_id/1]).
-export([currency/1]).
-export([resource/1]).
-export([external_id/1]).
-export([created_at/1]).
-export([metadata/1]).

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

-spec id(source_state()) -> id().
-spec realm(source_state()) -> realm().
-spec name(source_state()) -> name().
-spec party_id(source_state()) -> party_id().
-spec account(source_state()) -> account() | undefined.
-spec currency(source_state()) -> currency().
-spec resource(source_state()) -> resource().

id(#{id := V}) ->
    V.

realm(#{realm := V}) ->
    V.

name(#{name := V}) ->
    V.

party_id(#{party_id := V}) ->
    V.

account(#{account := V}) ->
    V;
account(_) ->
    undefined.

currency(Source) ->
    ff_account:currency(account(Source)).

resource(#{resource := V}) ->
    V.

-spec external_id(source_state()) -> id() | undefined.
external_id(#{external_id := ExternalID}) ->
    ExternalID;
external_id(_Source) ->
    undefined.

-spec created_at(source_state()) -> ff_time:timestamp_ms() | undefined.
created_at(#{created_at := CreatedAt}) ->
    CreatedAt;
created_at(_Source) ->
    undefined.

-spec metadata(source_state()) -> ff_entity_context:context() | undefined.
metadata(#{metadata := Metadata}) ->
    Metadata;
metadata(_Source) ->
    undefined.

%% API

-spec create(params()) ->
    {ok, [event()]}
    | {error, create_error()}.
create(Params) ->
    do(fun() ->
        #{
            id := ID,
            party_id := PartyID,
            name := Name,
            currency := CurrencyID,
            resource := Resource,
            realm := Realm
        } = Params,
        Currency = unwrap(currency, ff_currency:get(CurrencyID)),
        Events = unwrap(ff_account:create(PartyID, Realm, Currency)),
        accessible = unwrap(party, ff_party:is_accessible(PartyID)),
        CreatedAt = ff_time:now(),
        [
            {created,
                genlib_map:compact(#{
                    version => ?ACTUAL_FORMAT_VERSION,
                    party_id => PartyID,
                    realm => Realm,
                    id => ID,
                    name => Name,
                    resource => Resource,
                    external_id => maps:get(external_id, Params, undefined),
                    metadata => maps:get(metadata, Params, undefined),
                    created_at => CreatedAt
                })}
        ] ++ [{account, Ev} || Ev <- Events]
    end).

-spec is_accessible(source_state()) ->
    {ok, accessible}
    | {error, ff_party:inaccessibility()}.
is_accessible(Source) ->
    ff_account:is_accessible(account(Source)).

-spec apply_event(event(), ff_maybe:'maybe'(source_state())) -> source_state().
apply_event({created, Source}, undefined) ->
    Source;
apply_event({account, Ev}, #{account := Account} = Source) ->
    Source#{account => ff_account:apply_event(Ev, Account)};
apply_event({account, Ev}, Source) ->
    apply_event({account, Ev}, Source#{account => undefined}).

%% prg_machine

-spec namespace() -> prg_machine:namespace().
namespace() ->
    ?NS.

-spec init({[event()], ctx()}, machine()) -> prg_result().
init({Events, Ctx}, _Machine) ->
    #{
        events => Events,
        action => prg_machine_action:instant(),
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
    #{}.

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Body) ->
    Timestamped = {ev, ff_time:now(), Body},
    Encoded = ff_machine_codec:marshal_event(source, ?EVENT_FORMAT_VERSION, Timestamped),
    {?EVENT_FORMAT_VERSION, ff_machine_codec:payload_to_binary(Encoded)}.

-spec unmarshal_event_body(pos_integer(), binary()) -> prg_machine:event_body().
unmarshal_event_body(?EVENT_FORMAT_VERSION, Payload) ->
    Timestamped = ff_machine_codec:unmarshal_event(source, ?EVENT_FORMAT_VERSION, Payload),
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
repair_events_to_domain(undefined) ->
    [];
repair_events_to_domain(Events) ->
    [event_body_from_timestamped(E) || E <- Events].

-spec event_body_from_timestamped(term()) -> event().
event_body_from_timestamped({ev, _Timestamp, Change}) ->
    Change;
event_body_from_timestamped(Change) ->
    Change.

-type repair_machine() :: #{
    history := [{pos_integer(), {ev, non_neg_integer(), event()}}],
    aux_state := term()
}.

-spec to_repair_machine(machine()) -> repair_machine().
to_repair_machine(#{history := History, aux_state := AuxState}) ->
    #{
        history => [{EventID, {ev, Timestamp, Body}} || {EventID, Timestamp, Body} <- History],
        aux_state => AuxState
    }.
