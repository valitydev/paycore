-module(hg_progressor_trace).

-export([get_trace/2]).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_progressor_trace_thrift.hrl").

-type namespace() :: binary().
-type id() :: binary().
-type trace_data() :: dmsl_progressor_trace_thrift:'TraceData'().

-spec get_trace(namespace(), id()) ->
    {ok, trace_data()} | {error, notfound | unknown_namespace | term()}.
get_trace(NsBin, ProcessID) ->
    case ns_atom(NsBin) of
        {ok, NS} ->
            case prg_machine_trace:trace(NS, ProcessID) of
                {ok, Units} ->
                    {ok, [marshal_unit(NS, Unit) || Unit <- Units]};
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

ns_atom(<<"invoice">>) ->
    {ok, invoice};
ns_atom(<<"invoice_template">>) ->
    {ok, invoice_template};
ns_atom(_) ->
    {error, unknown_namespace}.

marshal_unit(NS, Unit) ->
    #progressor_trace_TraceUnit{
        header = marshal_header(Unit),
        body = marshal_body(NS, maps:get(task_type, Unit), maps:get(args, Unit, undefined)),
        events = [marshal_event(NS, Event) || Event <- maps:get(events, Unit, [])]
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

marshal_body(NS, TaskType, Args) ->
    case thrift_call(NS, TaskType, Args) of
        {ok, Call} ->
            {thrift_call, Call};
        false ->
            {content, json_content(Args)}
    end.

thrift_call(invoice, <<"init">>, Args) when is_binary(Args) ->
    try hg_invoice:unmarshal_invoice(Args) of
        Invoice ->
            {ok, thrift_call_record(<<"Invoicing">>, <<"Create">>, Invoice)}
    catch
        _:_ ->
            false
    end;
thrift_call(invoice_template, <<"init">>, Args) when is_binary(Args) ->
    try hg_invoice_template:unmarshal_invoice_template_params(Args) of
        Params ->
            {ok, thrift_call_record(<<"InvoiceTemplating">>, <<"Create">>, Params)}
    catch
        _:_ ->
            false
    end;
thrift_call(_NS, _TaskType, {thrift_call, ServiceName, {_Service, Function}, EncodedArgs}) ->
    {Module, Service} = hg_proto:get_service(ServiceName),
    Params = hg_proto_utils:deserialize_function_args({Module, {Service, Function}}, EncodedArgs),
    {ok, thrift_call_record(to_bin(Service), to_bin(Function), Params)};
thrift_call(_NS, _TaskType, {{Service, Function}, Args}) ->
    {ok, thrift_call_record(to_bin(Service), to_bin(Function), Args)};
thrift_call(_NS, _TaskType, _) ->
    false.

thrift_call_record(Service, Function, Params) ->
    #progressor_trace_ThriftCall{
        service_name = Service,
        function_name = Function,
        params = json_content(Params)
    }.

marshal_event(NS, Event) ->
    #progressor_trace_TraceEvent{
        event_id = maps:get(event_id, Event),
        event_timestamp = maps:get(event_timestamp, Event),
        payload = event_payload(NS, maps:get(event_body, Event, []))
    }.

event_payload(invoice, Changes) when is_list(Changes) ->
    {invoice_changes, Changes};
event_payload(invoice_template, Changes) when is_list(Changes) ->
    {invoice_template_changes, Changes};
event_payload(invoice, _) ->
    {invoice_changes, []};
event_payload(invoice_template, _) ->
    {invoice_template_changes, []}.

json_content(Term) ->
    #base_Content{
        type = <<"application/json">>,
        data = prg_machine_trace:json_binary(Term)
    }.

to_bin(V) when is_binary(V) ->
    V;
to_bin(V) when is_atom(V) ->
    atom_to_binary(V, utf8).
