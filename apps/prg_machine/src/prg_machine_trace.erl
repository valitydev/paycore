-module(prg_machine_trace).

-export([trace/2]).
-export([json_binary/1]).
-export([metadata_string/1]).

-export_type([unit/0]).
-export_type([event/0]).
-export_type([error/0]).

-type namespace() :: prg_machine:namespace().
-type id() :: prg_machine:id().
-type error() :: notfound | {unknown_namespace, namespace()} | term().

-type event() :: #{
    event_id := integer(),
    event_timestamp := integer(),
    event_payload := binary(),
    event_body => term()
}.

-type unit() :: #{
    task_id := integer(),
    task_type := binary(),
    task_status := binary(),
    scheduled => integer(),
    running => integer(),
    finished => integer(),
    retry_attempts := integer(),
    retry_interval := integer(),
    task_metadata => term(),
    otel_trace_id => binary(),
    error => binary(),
    args => term(),
    events := [event()]
}.

-spec trace(namespace(), id()) -> {ok, [unit()]} | {error, error()}.
trace(NS, ID) ->
    case prg_machine_registry:lookup(NS) of
        {ok, Handler} ->
            case progressor:trace(#{ns => NS, id => ID}) of
                {ok, RawTrace} ->
                    {ok, [unmarshal_unit(Unit, Handler) || Unit <- RawTrace]};
                {error, <<"process not found">>} ->
                    {error, notfound};
                {error, <<"namespace not found">>} ->
                    {error, {unknown_namespace, NS}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, {unknown_namespace, _} = Error} ->
            {error, Error}
    end.

-spec json_binary(term()) -> binary().
json_binary(Term) ->
    unicode:characters_to_binary(json:encode(json_value(Term))).

-spec metadata_string(term()) -> binary() | undefined.
metadata_string(undefined) ->
    undefined;
metadata_string(<<>>) ->
    undefined;
metadata_string(Meta) when is_binary(Meta) ->
    Meta;
metadata_string(Meta) ->
    json_binary(Meta).

unmarshal_unit(TraceUnit, Handler) ->
    Args = decode_value(maps:get(args, TraceUnit, undefined)),
    Events = unmarshal_events(maps:get(events, TraceUnit, []), Handler),
    Context = decode_context(maps:get(context, TraceUnit, undefined)),
    Compact = #{
        task_id => to_integer(maps:get(task_id, TraceUnit)),
        task_type => to_binary(maps:get(task_type, TraceUnit)),
        task_status => to_binary(maps:get(task_status, TraceUnit)),
        retry_attempts => to_integer(maps:get(retry_attempts, TraceUnit, 0)),
        retry_interval => to_integer(maps:get(retry_interval, TraceUnit, 0)),
        args => Args,
        events => Events
    },
    genlib_map:compact(
        Compact#{
            scheduled => maps:get(scheduled, TraceUnit, undefined),
            running => maps:get(running, TraceUnit, undefined),
            finished => maps:get(finished, TraceUnit, undefined),
            task_metadata => maps:get(task_metadata, TraceUnit, undefined),
            otel_trace_id => extract_trace_id(Context),
            error => extract_error(TraceUnit)
        }
    ).

unmarshal_events(Events, Handler) ->
    [unmarshal_event(Event, Handler) || Event <- Events].

unmarshal_event(Event, Handler) ->
    Payload = maps:get(event_payload, Event),
    Base = #{
        event_id => maps:get(event_id, Event),
        event_timestamp => maps:get(event_timestamp, Event),
        event_payload => Payload
    },
    try prg_machine:unmarshal_event_body(Handler, Payload) of
        Body ->
            Base#{event_body => Body}
    catch
        _:_ ->
            Base
    end.

decode_context(undefined) ->
    #{};
decode_context(<<>>) ->
    #{};
decode_context(Ctx) when is_map(Ctx) ->
    Ctx;
decode_context(Value) ->
    decode_value(Value).

extract_trace_id(#{<<"otel">> := [OtelTraceID | _]}) ->
    to_binary(OtelTraceID);
extract_trace_id(#{otel := [OtelTraceID | _]}) ->
    to_binary(OtelTraceID);
extract_trace_id(_) ->
    undefined.

extract_error(#{response := Response}) ->
    extract_error_response(decode_value(Response));
extract_error(_) ->
    undefined.

extract_error_response({error, Reason}) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason]));
extract_error_response(_) ->
    undefined.

%% Timeout and synthetic tasks are stored with args = <<>>.
%% binary_to_term(<<>>) raises badarg and would fail the whole GetTrace.
decode_value(<<>>) ->
    undefined;
decode_value(Value) ->
    prg_machine:decode_term(Value).

to_integer(V) when is_integer(V) ->
    V;
to_integer(V) when is_binary(V) ->
    binary_to_integer(V).

to_binary(V) when is_binary(V) ->
    V;
to_binary(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
to_binary(V) when is_integer(V) ->
    integer_to_binary(V);
to_binary(V) ->
    unicode:characters_to_binary(io_lib:format("~p", [V])).

json_value([]) ->
    [];
json_value(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true ->
            unicode:characters_to_binary(V);
        false ->
            [json_value(E) || E <- V]
    end;
json_value(V) when is_map(V) ->
    maps:fold(
        fun(K, Val, Acc) ->
            Acc#{json_key(K) => json_value(Val)}
        end,
        #{},
        V
    );
json_value({K, V}) when is_atom(K) ->
    #{atom_to_binary(K, utf8) => json_value(V)};
json_value(V) when is_tuple(V) ->
    [json_value(E) || E <- tuple_to_list(V)];
json_value(true) ->
    true;
json_value(false) ->
    false;
json_value(null) ->
    null;
json_value(undefined) ->
    null;
json_value(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
json_value(V) when is_integer(V) ->
    V;
json_value(V) when is_float(V) ->
    V;
json_value(V) when is_binary(V) ->
    try unicode:characters_to_binary(V) of
        Binary when is_binary(Binary) ->
            Binary;
        _ ->
            #{<<"content_type">> => <<"base64">>, <<"content">> => base64:encode(V)}
    catch
        _:_ ->
            #{<<"content_type">> => <<"base64">>, <<"content">> => base64:encode(V)}
    end;
json_value(V) ->
    unicode:characters_to_binary(io_lib:format("~p", [V])).

json_key(K) when is_atom(K) ->
    atom_to_binary(K, utf8);
json_key(K) when is_binary(K) ->
    try unicode:characters_to_binary(K) of
        Binary when is_binary(Binary) ->
            Binary;
        _ ->
            base64:encode(K)
    catch
        _:_ ->
            base64:encode(K)
    end;
json_key(K) when is_integer(K); is_float(K) ->
    K;
json_key(K) ->
    unicode:characters_to_binary(io_lib:format("~p", [K])).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec decode_empty_args_test() -> _.
decode_empty_args_test() ->
    ?assertEqual(undefined, decode_value(<<>>)),
    ?assertEqual(undefined, decode_value(undefined)),
    ?assertEqual(#{<<"k">> => <<"v">>}, decode_value(term_to_binary(#{<<"k">> => <<"v">>}))).

-endif.
