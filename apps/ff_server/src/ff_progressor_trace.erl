-module(ff_progressor_trace).

-export([get_trace/2]).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_progressor_trace_thrift.hrl").

-type namespace() :: binary().
-type id() :: binary().
-type trace_data() :: fistful_progressor_trace_thrift:'TraceData'().

-spec get_trace(namespace(), id()) ->
    {ok, trace_data()} | {error, notfound | unknown_namespace | term()}.
get_trace(NsBin, ProcessID) ->
    case ns_atom(NsBin) of
        {ok, NS, Domain} ->
            case prg_machine_trace:trace(NS, ProcessID) of
                {ok, Units} ->
                    {ok, [marshal_unit(Domain, Unit) || Unit <- Units]};
                {error, notfound} ->
                    {error, notfound};
                {error, {unknown_namespace, _}} ->
                    {error, unknown_namespace};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, unknown_namespace} ->
            {error, unknown_namespace}
    end.

ns_atom(<<"ff/deposit_v1">>) ->
    {ok, 'ff/deposit_v1', deposit};
ns_atom(<<"ff/withdrawal_v2">>) ->
    {ok, 'ff/withdrawal_v2', withdrawal};
ns_atom(<<"ff/destination_v2">>) ->
    {ok, 'ff/destination_v2', destination};
ns_atom(<<"ff/source_v1">>) ->
    {ok, 'ff/source_v1', source};
ns_atom(<<"ff/withdrawal/session_v2">>) ->
    {ok, 'ff/withdrawal/session_v2', withdrawal_session};
ns_atom(_) ->
    {error, unknown_namespace}.

marshal_unit(Domain, Unit) ->
    #progressor_trace_TraceUnit{
        header = marshal_header(Unit),
        body = marshal_body(maps:get(args, Unit, undefined)),
        events = [marshal_event(Domain, Event) || Event <- maps:get(events, Unit, [])]
    }.

marshal_header(Unit) ->
    #progressor_trace_TraceTaskHeader{
        task_id = maps:get(task_id, Unit),
        task_type = maps:get(task_type, Unit),
        task_status = maps:get(task_status, Unit),
        scheduled = maps:get(scheduled, Unit, undefined),
        running = maps:get(running, Unit, undefined),
        finished = maps:get(finished, Unit, undefined),
        retry_attempts = maps:get(retry_attempts, Unit),
        retry_interval = maps:get(retry_interval, Unit),
        task_metadata = prg_machine_trace:metadata_string(maps:get(task_metadata, Unit, undefined)),
        otel_trace_id = maps:get(otel_trace_id, Unit, undefined),
        error = maps:get(error, Unit, undefined)
    }.

marshal_body({{Service, Function}, Args}) ->
    {thrift_call, #progressor_trace_ThriftCall{
        service_name = to_bin(Service),
        function_name = to_bin(Function),
        params = json_content(Args)
    }};
marshal_body(Args) ->
    {content, json_content(Args)}.

marshal_event(Domain, Event) ->
    Payload = maps:get(event_payload, Event),
    Timestamped = ff_machine_codec:unmarshal_event(Domain, Payload),
    Codec = codec(Domain),
    #progressor_trace_TraceEvent{
        event_id = maps:get(event_id, Event),
        event_timestamp = maps:get(event_timestamp, Event),
        payload = {payload_tag(Domain), Codec:marshal(timestamped_change, Timestamped)}
    }.

payload_tag(withdrawal_session) ->
    session;
payload_tag(Domain) ->
    Domain.

codec(deposit) ->
    ff_deposit_codec;
codec(withdrawal) ->
    ff_withdrawal_codec;
codec(destination) ->
    ff_destination_codec;
codec(source) ->
    ff_source_codec;
codec(withdrawal_session) ->
    ff_withdrawal_session_codec.

json_content(Term) ->
    #'fistful_base_Content'{
        type = <<"application/json">>,
        data = prg_machine_trace:json_binary(Term)
    }.

to_bin(V) when is_binary(V) ->
    V;
to_bin(V) when is_atom(V) ->
    atom_to_binary(V, utf8).
