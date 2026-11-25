-module(hg_woody_service_wrapper).

%% Woody handler

-behaviour(woody_server_thrift_handler).

%% API
-export([handle_function/4]).
-export([raise/1]).

-export_type([handler_opts/0]).

-type handler_opts() :: #{
    handler := module(),
    ns => binary(),
    party_client => party_client:client(),
    default_handling_timeout => timeout()
}.

%% Callbacks

-callback handle_function(woody:func(), woody:args(), handler_opts()) -> term() | no_return().

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), handler_opts()) ->
    {ok, term()} | no_return().
handle_function(Func, Args, WoodyContext, #{handler := Handler} = Opts) ->
    RequestOptions = Opts#{binding => op_context:binding(hellgate), function => Func},
    Handle = fun() ->
        try
            Handler:handle_function(Func, Args, Opts)
        catch
            throw:Reason -> raise(Reason)
        end
    end,
    {ok, processing_request:run(WoodyContext, RequestOptions, Handle)}.

-spec raise(term()) -> no_return().
raise(Exception) ->
    woody_error:raise(business, Exception).
