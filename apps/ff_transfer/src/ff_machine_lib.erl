-module(ff_machine_lib).

%%% Shared helpers for the ff_* prg_machine handlers and their thin machine
%%% clients. Extracted to remove the per-namespace copy-paste.

-export([create/4]).
-export([get/5]).
-export([events/4]).
-export([repair/3]).
-export([init_result/2]).
-export([init_result/3]).
-export([machine_to_st/2]).
-export([to_prg_result/1]).
-export([process_repair/3]).
-export([process_repair/4]).
-export([to_repair_machine/1]).
-export([from_repair_result/2]).
-export([repair_events_to_domain/1]).
-export([event_body_from_timestamped/1]).
-export([history_to_events/1]).
-export([codec_timestamp/1]).
-export([marshal_event_body/3]).
-export([unmarshal_event_body/2]).
-export([marshal_aux_state/1]).
-export([unmarshal_aux_state/1]).

-export_type([repair_call_error/0]).

-import(ff_pipeline, [do/1, unwrap/1]).

-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.
-type event_range() :: {After :: non_neg_integer() | undefined, Limit :: non_neg_integer() | undefined}.
-type create_fun() :: fun((map()) -> {ok, [term()]} | {error, term()}).

-type processor_error() :: prg_machine:processor_error().

-type repair_call_error() ::
    notfound
    | working
    | failed
    | {failed, ff_repair:repair_error()}
    | processor_error().

-spec create(prg_machine:namespace(), create_fun(), map(), ff_entity_context:context()) ->
    ok | {error, term()}.
create(NS, CreateFun, Params, Ctx) ->
    do(fun() ->
        #{id := ID} = Params,
        Events = unwrap(CreateFun(Params)),
        unwrap(prg_machine:start(NS, ID, {Events, Ctx}))
    end).

-spec get(prg_machine:namespace(), prg_machine:id(), event_range(), module(), term()) ->
    {ok, map()} | {error, term()}.
get(NS, ID, {After, Limit}, Handler, NotFoundError) ->
    case prg_machine:get(NS, ID, prg_machine:history_range(After, Limit, forward)) of
        {ok, Machine} ->
            {ok, machine_to_st(Handler, Machine)};
        {error, notfound} ->
            {error, NotFoundError};
        {error, {exception, Class, Reason}} ->
            erlang:error({process_exception, Class, Reason})
    end.

-spec events(prg_machine:namespace(), prg_machine:id(), event_range(), term()) ->
    {ok, [{prg_machine:event_id(), timestamped_event(term())}]} | {error, term()}.
events(NS, ID, {After, Limit}, NotFoundError) ->
    case prg_machine:get_history(NS, ID, After, Limit, forward) of
        {ok, History} ->
            {ok, history_to_events(History)};
        {error, notfound} ->
            {error, NotFoundError};
        {error, {exception, Class, Reason}} ->
            erlang:error({process_exception, Class, Reason})
    end.

-spec repair(prg_machine:namespace(), prg_machine:id(), ff_repair:scenario()) ->
    {ok, ff_repair:repair_response()} | {error, repair_call_error()}.
repair(NS, ID, Scenario) ->
    case prg_machine:repair(NS, ID, Scenario) of
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

-spec init_result([term()], ff_entity_context:context()) -> prg_machine:result().
init_result(Events, Ctx) ->
    #{
        events => Events,
        auxst => #{ctx => Ctx}
    }.

-spec init_result([term()], ff_entity_context:context(), prg_action:t()) -> prg_machine:result().
init_result(Events, Ctx, Action) ->
    (init_result(Events, Ctx))#{action => Action}.

-spec machine_to_st(module(), prg_machine:machine()) -> map().
machine_to_st(Handler, #{aux_state := AuxState} = Machine) ->
    #{
        model => prg_machine:collapse(Handler, Machine),
        ctx => ctx(AuxState)
    }.

-spec to_prg_result({prg_action:t(), [term()]}) -> prg_machine:result().
to_prg_result({Action, Events}) ->
    #{
        events => Events,
        action => Action
    }.

-spec process_repair(module(), prg_machine:machine(), ff_repair:scenario()) ->
    prg_machine:result() | {error, term()}.
process_repair(Handler, Machine, Scenario) ->
    case ff_repair:apply_scenario(Handler, to_repair_machine(Machine), Scenario) of
        {ok, {_Response, Result}} ->
            from_repair_result(Result, Machine);
        {error, Reason} ->
            {error, Reason}
    end.

-spec process_repair(module(), prg_machine:machine(), ff_repair:scenario(), ff_repair:processors()) ->
    prg_machine:result() | {error, term()}.
process_repair(Handler, Machine, Scenario, ScenarioProcessors) ->
    case ff_repair:apply_scenario(Handler, to_repair_machine(Machine), Scenario, ScenarioProcessors) of
        {ok, {_Response, Result}} ->
            from_repair_result(Result, Machine);
        {error, Reason} ->
            {error, Reason}
    end.

-spec to_repair_machine(prg_machine:machine()) -> ff_repair:machine().
to_repair_machine(#{namespace := NS, id := ID, history := History, aux_state := AuxState}) ->
    #{
        namespace => NS,
        id => ID,
        history => [{EventID, {ev, Timestamp, Body}} || {EventID, Timestamp, Body} <- History],
        aux_state => AuxState
    }.

-spec from_repair_result(ff_repair:scenario_result(), prg_machine:machine()) -> prg_machine:result().
from_repair_result(#{events := Events} = Result, _Machine) ->
    PrgResult = to_prg_result({maps:get(action, Result, idle), repair_events_to_domain(Events)}),
    case maps:is_key(aux_state, Result) of
        true ->
            PrgResult#{auxst => maps:get(aux_state, Result)};
        false ->
            PrgResult
    end.

-spec repair_events_to_domain([timestamped_event(T)]) -> [T].
repair_events_to_domain(Events) ->
    [event_body_from_timestamped(E) || E <- Events].

-spec event_body_from_timestamped(timestamped_event(T) | T) -> T.
event_body_from_timestamped({ev, _Timestamp, Change}) ->
    Change;
event_body_from_timestamped(Change) ->
    Change.

-spec history_to_events(prg_machine:history()) ->
    [{prg_machine:event_id(), timestamped_event(term())}].
history_to_events(History) ->
    [{EventID, {ev, codec_timestamp(Timestamp), Body}} || {EventID, Timestamp, Body} <- History].

-spec codec_timestamp(timestamp() | calendar:datetime()) -> timestamp().
codec_timestamp({DateTime, USec}) when is_integer(USec) ->
    {DateTime, USec};
codec_timestamp(DateTime) ->
    {DateTime, 0}.

-spec marshal_event_body(ff_machine_codec:domain(), pos_integer(), prg_machine:event_body()) ->
    {pos_integer(), binary()}.
marshal_event_body(Domain, Format, Body) ->
    Timestamped = {ev, prg_machine:timestamp(), Body},
    Encoded = ff_machine_codec:marshal_event(Domain, Format, Timestamped),
    {Format, ff_machine_codec:payload_to_binary(Encoded)}.

-spec unmarshal_event_body(ff_machine_codec:domain(), binary()) ->
    prg_machine:event_body().
unmarshal_event_body(Domain, Payload) ->
    Timestamped = ff_machine_codec:unmarshal_event(Domain, Payload),
    event_body_from_timestamped(Timestamped).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    ff_machine_codec:marshal_aux_state(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    ff_machine_codec:unmarshal_aux_state(Payload).

ctx(#{ctx := Ctx}) ->
    Ctx;
ctx(_AuxState) ->
    ff_entity_context:new().
