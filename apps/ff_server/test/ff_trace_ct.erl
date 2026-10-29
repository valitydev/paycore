-module(ff_trace_ct).

-export([get_trace/2]).
-export([await_trace/2]).
-export([await_trace/3]).
-export([body_json/1]).
-export([is_finished_timeout/1]).
-export([task_type/1]).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_progressor_trace_thrift.hrl").

-type trace_data() :: fistful_progressor_trace_thrift:'TraceData'().

-spec get_trace(binary(), binary()) -> {ok, trace_data()} | {exception, _} | {error, _}.
get_trace(NS, ProcessID) ->
    Service = ff_services:get_service(progressor_trace),
    Request = {Service, 'GetTrace', {NS, ProcessID}},
    Client = ff_woody_client:new(#{
        url => "http://localhost:8022" ++ ff_services:get_service_path(progressor_trace)
    }),
    ff_woody_client:call(Client, Request).

-spec await_trace(binary(), binary()) -> trace_data().
await_trace(NS, ProcessID) ->
    await_trace(NS, ProcessID, fun(_) -> true end).

-spec await_trace(binary(), binary(), fun((trace_data()) -> boolean())) -> trace_data().
await_trace(NS, ProcessID, Pred) ->
    await_trace(NS, ProcessID, Pred, genlib_retry:linear(10, 500)).

await_trace(NS, ProcessID, Pred, Retry0) ->
    case get_trace(NS, ProcessID) of
        {ok, Trace} ->
            case Pred(Trace) of
                true ->
                    Trace;
                false ->
                    retry_await(NS, ProcessID, Pred, Retry0)
            end;
        _ ->
            retry_await(NS, ProcessID, Pred, Retry0)
    end.

retry_await(NS, ProcessID, Pred, Retry0) ->
    case genlib_retry:next_step(Retry0) of
        {wait, To, Retry1} ->
            timer:sleep(To),
            await_trace(NS, ProcessID, Pred, Retry1);
        finish ->
            error({await_trace_failed, NS, ProcessID})
    end.

-spec body_json(fistful_progressor_trace_thrift:'TaskBody'()) -> term().
body_json({content, #'fistful_base_Content'{data = Data}}) ->
    json:decode(Data);
body_json({thrift_call, #progressor_trace_ThriftCall{params = #'fistful_base_Content'{data = Data}}}) ->
    json:decode(Data).

-spec is_finished_timeout(fistful_progressor_trace_thrift:'TraceUnit'()) -> boolean().
is_finished_timeout(#progressor_trace_TraceUnit{
    header = #progressor_trace_TraceTaskHeader{task_type = <<"timeout">>, task_status = <<"finished">>}
}) ->
    true;
is_finished_timeout(_) ->
    false.

-spec task_type(fistful_progressor_trace_thrift:'TraceUnit'()) -> binary().
task_type(#progressor_trace_TraceUnit{header = #progressor_trace_TraceTaskHeader{task_type = TaskType}}) ->
    TaskType.
