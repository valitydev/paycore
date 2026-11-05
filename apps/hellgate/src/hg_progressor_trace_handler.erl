-module(hg_progressor_trace_handler).

-behaviour(hg_woody_service_wrapper).

-include_lib("damsel/include/dmsl_progressor_trace_thrift.hrl").

-export([handle_function/3]).

-spec handle_function(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function(Func, Args, Opts) ->
    scoper:scope(
        progressor_trace,
        fun() ->
            handle_function_(Func, Args, Opts)
        end
    ).

-spec handle_function_(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function_('GetTrace', {NS, ProcessID}, _Opts) ->
    case hg_progressor_trace:get_trace(NS, ProcessID) of
        {ok, Trace} ->
            Trace;
        {error, notfound} ->
            throw(#progressor_trace_ProcessNotFound{});
        {error, unknown_namespace} ->
            throw(#progressor_trace_UnknownNamespace{});
        {error, Reason} ->
            %% erlang:error, not throw: hg_woody_service_wrapper turns every throw into a business error.
            woody_error:raise(system, {internal, result_unexpected, woody_error:format_details(Reason)})
    end.
