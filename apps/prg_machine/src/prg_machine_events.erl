-module(prg_machine_events).

-export([collapse/2]).
-export([emit_event/1]).
-export([emit_events/1]).
-export([timestamp/0]).
-export([unmarshal_machine/3]).
-export([marshal_new_events/3]).
-export([marshal_aux_state/2]).

-ifdef(TEST).
-export([event_metadata/1]).
-export([unmarshal_event_format/1]).
-endif.

-spec collapse(module(), prg_machine:machine()) -> term().
collapse(Handler, #{history := History, aux_state := AuxState}) ->
    lists:foldl(
        fun({EventID, Ts, Body}, Model) ->
            prg_machine:callback_apply_event(Handler, EventID, Ts, Body, Model)
        end,
        initial_model(AuxState),
        History
    ).

-spec emit_event(term()) -> [{ev, prg_machine:timestamp(), term()}].
emit_event(Event) ->
    emit_events([Event]).

-spec emit_events([term()]) -> [{ev, prg_machine:timestamp(), term()}].
emit_events(Events) ->
    Ts = timestamp(),
    [{ev, Ts, Body} || Body <- Events].

-spec timestamp() -> prg_machine:timestamp().
timestamp() ->
    Now = erlang:system_time(microsecond),
    {Seconds, Micro} = prg_utils:split_timestamp(Now),
    {calendar:system_time_to_universal_time(Seconds, second), Micro}.

-spec unmarshal_machine(module(), prg_machine:namespace(), map()) -> prg_machine:machine().
unmarshal_machine(Handler, NS, #{process_id := ID, history := RawHistory} = Process) ->
    Range = range_from_process(Process),
    History = [unmarshal_event(Handler, Ev) || Ev <- RawHistory],
    AuxState = unmarshal_aux_state(Handler, maps:get(aux_state, Process, undefined)),
    #{
        namespace => NS,
        id => ID,
        history => History,
        aux_state => AuxState,
        range => Range
    }.

-spec marshal_new_events(module(), non_neg_integer(), [prg_machine:event_body()]) -> [map()].
marshal_new_events(Handler, LastEventID, Bodies) ->
    %% One microsecond timestamp for the whole batch (as the old emit_events did).
    %% The PG backend stores timestamptz with microseconds and auto-detects units.
    Ts = erlang:system_time(microsecond),
    lists:zipwith(
        fun(EventID, Body) ->
            {Format, Bin} = marshal_event_body(Handler, Body),
            #{
                event_id => EventID,
                timestamp => Ts,
                metadata => event_metadata(Format),
                payload => Bin
            }
        end,
        lists:seq(LastEventID + 1, LastEventID + length(Bodies)),
        Bodies
    ).

unmarshal_event(Handler, #{
    event_id := EventID,
    timestamp := TsSec,
    metadata := Meta,
    payload := Payload
}) ->
    Format = unmarshal_event_format(Meta),
    Body = prg_machine:unmarshal_event_body(Handler, Format, Payload),
    {EventID, event_timestamp_to_datetime(TsSec), Body};
unmarshal_event(_Handler, #{event_id := EventID} = Ev) ->
    erlang:error({missing_event_payload, EventID, maps:keys(Ev)}).

marshal_event_body(Handler, Body) ->
    prg_machine:callback_marshal_event_body(Handler, Body).

-spec marshal_aux_state(module(), term()) -> binary().
marshal_aux_state(Handler, AuxSt) ->
    prg_machine:callback_marshal_aux_state(Handler, AuxSt).

unmarshal_aux_state(_Handler, undefined) ->
    undefined;
unmarshal_aux_state(Handler, Bin) when is_binary(Bin) ->
    prg_machine:callback_unmarshal_aux_state(Handler, Bin).

%% Write both legacy keys: old HG reader expects <<"format_version">>,
%% old FF reader expects <<"format">>. Keeping both keeps rollback safe for
%% both stacks and feeds the event sink (prg_notifier reads <<"format_version">>).
-spec event_metadata(undefined | non_neg_integer()) -> map().
event_metadata(undefined) ->
    event_metadata(0);
event_metadata(Format) when is_integer(Format) ->
    #{<<"format_version">> => Format, <<"format">> => Format}.

%% Read order: legacy HG <<"format_version">> -> legacy FF <<"format">> ->
%% atom format (defensive) -> undefined.
-spec unmarshal_event_format(map()) -> undefined | non_neg_integer().
unmarshal_event_format(Meta) ->
    maps:get(
        <<"format_version">>,
        Meta,
        maps:get(<<"format">>, Meta, maps:get(format, Meta, undefined))
    ).

%% Already in machinery format {datetime, micro}.
event_timestamp_to_datetime({{{_, _, _}, {_, _, _}}, Micro} = DtMicro) when is_integer(Micro) ->
    DtMicro;
%% Bare datetime (defensive) - assume zero microseconds.
event_timestamp_to_datetime({{_, _, _}, {_, _, _}} = Dt) ->
    {Dt, 0};
%% Integer timestamp stored by progressor - split into seconds + microseconds.
event_timestamp_to_datetime(Ts) when is_integer(Ts) ->
    {Seconds, Micro} = prg_utils:split_timestamp(Ts),
    {calendar:system_time_to_universal_time(Seconds, second), Micro}.

initial_model(AuxState) when is_map(AuxState) ->
    maps:get(model, AuxState, undefined);
initial_model(_AuxState) ->
    undefined.

range_from_process(#{range := Range = #{}}) ->
    Range;
range_from_process(_) ->
    #{direction => forward}.
