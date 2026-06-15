-module(ff_machine_lib).

%%% Shared helpers for the ff_* prg_machine handlers and their thin machine
%%% clients. Extracted to remove the per-namespace copy-paste.

-export([to_repair_machine/1]).
-export([from_repair_result/2]).
-export([repair_events_to_domain/1]).
-export([event_body_from_timestamped/1]).
-export([history_to_events/1]).
-export([codec_timestamp/1]).

-export_type([repair_call_error/0]).

-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.

-type processor_error() :: {exception, atom(), term()}.

-type repair_call_error() ::
    notfound
    | working
    | failed
    | {failed, ff_repair:repair_error()}
    | processor_error().

-spec to_repair_machine(prg_machine:machine()) -> ff_repair:machine().
to_repair_machine(#{namespace := NS, id := ID, history := History, aux_state := AuxState}) ->
    #{
        namespace => NS,
        id => ID,
        history => [{EventID, {ev, Timestamp, Body}} || {EventID, Timestamp, Body} <- History],
        aux_state => AuxState
    }.

-spec from_repair_result(ff_repair:scenario_result(), prg_machine:machine()) -> prg_machine:result().
from_repair_result(#{events := Events} = Result, Machine) ->
    #{
        events => repair_events_to_domain(Events),
        action => maps:get(action, Result, idle),
        auxst => maps:get(aux_state, Result, maps:get(aux_state, Machine, #{}))
    }.

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
