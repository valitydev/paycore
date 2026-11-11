-module(ff_woody_wrapper).

%% Woody handler

-behaviour(woody_server_thrift_handler).

-export([handle_function/4]).

-export_type([options/0]).
-export_type([handler/0]).
-export_type([client_opts/0]).

-type handler() :: module() | {module(), handler_options()}.
-type handler_options() :: any().
-type options() :: #{
    handler := handler(),
    party_client := party_client:client(),
    default_handling_timeout => timeout()
}.

-type client_opts() :: #{
    url := woody:url(),
    transport_opts => [{_, _}]
}.

%% Callbacks

-callback handle_function(woody:func(), woody:args(), handler_options()) -> {ok, woody:result()} | no_return().

%% API

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), options()) -> {ok, woody:result()} | no_return().
handle_function(Func, Args, WoodyContext, #{handler := Handler} = Opts) ->
    {HandlerMod, HandlerOptions} = get_handler_opts(Handler),
    RequestOptions = Opts#{
        binding => op_context:binding(fistful),
        handler => HandlerMod,
        function => Func,
        party_client => maps:get(party_client, Opts)
    },
    Handle = fun() -> HandlerMod:handle_function(Func, Args, HandlerOptions) end,
    processing_request:run(WoodyContext, RequestOptions, Handle).

%% Internal functions

-spec get_handler_opts(handler()) -> {module(), handler_options()}.
get_handler_opts(Handler) when is_atom(Handler) ->
    {Handler, undefined};
get_handler_opts({Handler, Options}) when is_atom(Handler) ->
    {Handler, Options}.
