%%% Progressor trace → JSON-compatible maps (replaces ff_machine:trace/2).

-module(ff_machine_trace).

-export([trace/2]).

-type namespace() :: prg_machine:namespace().
-type id() :: prg_machine:id().
-type trace() :: [trace_unit()].
-type trace_unit() :: map().

-spec trace(namespace(), id()) -> {ok, trace()} | {error, term()}.
trace(NS, ID) ->
    case progressor:trace(#{ns => NS, id => ID}) of
        {ok, RawTrace} ->
            case prg_machine_registry:lookup(NS) of
                {ok, Handler} ->
                    {ok, lists:map(fun(Unit) -> unmarshal_trace_unit(Unit, Handler) end, RawTrace)};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

unmarshal_trace_unit(TraceUnit, Handler) ->
    Args = decode_trace_value(maps:get(args, TraceUnit, undefined)),
    Events = maps:get(events, TraceUnit, []),
    Context = decode_context(maps:get(context, TraceUnit, undefined)),
    OtelTraceID = extract_trace_id(Context),
    Error = extract_error(TraceUnit),
    maps:merge(
        maps:without([response, context], TraceUnit),
        #{
            args => json_compatible_value(Args),
            events => unmarshal_trace_events(Events, Handler),
            otel_trace_id => OtelTraceID,
            error => Error
        }
    ).

unmarshal_trace_events(Events, Handler) ->
    lists:map(fun(Event) -> unmarshal_trace_event(Event, Handler) end, Events).

unmarshal_trace_event(Event, Handler) ->
    Payload = maps:get(event_payload, Event),
    Meta = maps:get(event_metadata, Event, #{}),
    Format = maps:get(<<"format">>, Meta, maps:get(format, Meta, 1)),
    EventID = maps:get(event_id, Event),
    Ts = maps:get(event_timestamp, Event),
    Body = Handler:unmarshal_event_body(Format, Payload),
    #{
        event_id => EventID,
        event_payload => json_compatible_value(Body),
        event_timestamp => Ts
    }.

decode_context(undefined) ->
    #{};
decode_context(<<>>) ->
    #{};
decode_context(Bin) when is_binary(Bin) ->
    woody_rpc_helper:decode_rpc_context(decode_term(Bin));
decode_context(Ctx) when is_map(Ctx) ->
    Ctx.

extract_trace_id(#{<<"otel">> := [OtelTraceID | _]}) ->
    OtelTraceID;
extract_trace_id(#{otel := [OtelTraceID | _]}) ->
    OtelTraceID;
extract_trace_id(_) ->
    null.

extract_error(#{response := Response}) ->
    extract_error_response(decode_trace_value(Response));
extract_error(_) ->
    null.

extract_error_response({error, Reason}) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason]));
extract_error_response(_) ->
    null.

decode_trace_value(undefined) ->
    undefined;
decode_trace_value(Bin) when is_binary(Bin) ->
    decode_term(Bin);
decode_trace_value(Value) ->
    Value.

decode_term(Bin) when is_binary(Bin) ->
    binary_to_term(Bin, [safe]);
decode_term(Term) ->
    Term.

json_compatible_value([]) ->
    [];
json_compatible_value(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true ->
            unicode:characters_to_binary(V);
        false ->
            [json_compatible_value(E) || E <- V]
    end;
json_compatible_value(V) when is_map(V) ->
    maps:fold(
        fun(K, Val, Acc) ->
            Acc#{json_compatible_key(K) => json_compatible_value(Val)}
        end,
        #{},
        V
    );
json_compatible_value({K, V}) when is_atom(K) ->
    #{K => json_compatible_value(V)};
json_compatible_value(V) when is_tuple(V) ->
    [json_compatible_value(E) || E <- tuple_to_list(V)];
json_compatible_value(true) ->
    true;
json_compatible_value(false) ->
    false;
json_compatible_value(null) ->
    null;
json_compatible_value(undefined) ->
    null;
json_compatible_value(V) when is_atom(V) ->
    erlang:atom_to_binary(V);
json_compatible_value(V) when is_integer(V) ->
    V;
json_compatible_value(V) when is_float(V) ->
    V;
json_compatible_value(V) when is_binary(V) ->
    try unicode:characters_to_binary(V) of
        Binary when is_binary(Binary) ->
            Binary;
        _ ->
            content(<<"base64">>, base64:encode(V))
    catch
        _:_ ->
            content(<<"base64">>, base64:encode(V))
    end;
json_compatible_value(V) ->
    CompatVal = unicode:characters_to_binary(io_lib:format("~p", [V])),
    content(<<"unknown">>, CompatVal).

json_compatible_key(K) when is_atom(K); is_integer(K); is_float(K) ->
    K;
json_compatible_key(K) when is_list(K) ->
    case io_lib:printable_unicode_list(K) of
        true ->
            unicode:characters_to_binary(K);
        false ->
            unicode:characters_to_binary(io_lib:format("~p", [K]))
    end;
json_compatible_key(K) when is_binary(K) ->
    try unicode:characters_to_binary(K) of
        Binary when is_binary(Binary) ->
            Binary;
        _ ->
            base64:encode(K)
    catch
        _:_ ->
            base64:encode(K)
    end;
json_compatible_key(K) ->
    unicode:characters_to_binary(io_lib:format("~p", [K])).

content(Type, Payload) ->
    #{
        <<"content_type">> => Type,
        <<"content">> => Payload
    }.
