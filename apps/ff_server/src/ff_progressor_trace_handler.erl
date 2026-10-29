-module(ff_progressor_trace_handler).

-behaviour(ff_woody_wrapper).

-include_lib("fistful_proto/include/fistful_progressor_trace_thrift.hrl").

-export([handle_function/3]).

-spec handle_function(woody:func(), woody:args(), woody:options()) -> {ok, woody:result()} | no_return().
handle_function(Func, Args, Opts) ->
    scoper:scope(
        progressor_trace,
        #{},
        fun() ->
            handle_function_(Func, Args, Opts)
        end
    ).

-spec handle_function_(woody:func(), woody:args(), woody:options()) -> {ok, woody:result()} | no_return().
handle_function_('GetTrace', {NS, ProcessID}, _Opts) ->
    case ff_progressor_trace:get_trace(NS, ProcessID) of
        {ok, Trace} ->
            {ok, Trace};
        {error, notfound} ->
            woody_error:raise(business, #progressor_trace_ProcessNotFound{});
        {error, unknown_namespace} ->
            woody_error:raise(business, #progressor_trace_UnknownNamespace{});
        {error, Reason} ->
            woody_error:raise(system, {internal, result_unexpected, woody_error:format_details(Reason)})
    end.
