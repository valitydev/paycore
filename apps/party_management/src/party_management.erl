%%% @doc Public API, supervisor and application startup.
%%% @end

-module(party_management).

-behaviour(supervisor).
-behaviour(application).

%% API
-export([start/0]).
-export([stop/0]).

%% Supervisor callbacks
-export([init/1]).

%% Application callbacks
-export([start/2]).
-export([stop/1]).

%%
%% API
%%
-spec start() -> {ok, _}.
start() ->
    application:ensure_all_started(?MODULE).

-spec stop() -> ok.
stop() ->
    application:stop(?MODULE).

%% Supervisor callbacks

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Options = application:get_env(?MODULE, cache_options, #{}),
    {ok,
        {
            #{strategy => one_for_all, intensity => 6, period => 30},
            [
                get_api_child_spec(Options)
            ]
        }}.

get_api_child_spec(Opts) ->
    {ok, Ip} = inet:parse_address(genlib_app:env(?MODULE, ip, "::")),
    HealthRoutes = construct_health_routes(genlib_app:env(?MODULE, health_check, #{})),
    EventHandlerOpts = genlib_app:env(?MODULE, scoper_event_handler_options, #{}),
    PrometeusRoute = get_prometheus_route(),
    EventHandlers = {pm_woody_event_handler, EventHandlerOpts},
    woody_server:child_spec(
        ?MODULE,
        #{
            ip => Ip,
            port => genlib_app:env(?MODULE, port, 8022),
            transport_opts => genlib_app:env(?MODULE, transport_opts, #{}),
            protocol_opts => genlib_app:env(?MODULE, protocol_opts, #{}),
            event_handler => EventHandlers,
            handlers =>
                [
                    construct_service_handler(party_management, pm_party_handler, Opts)
                ],
            additional_routes => [PrometeusRoute | HealthRoutes],
            shutdown_timeout => genlib_app:env(?MODULE, shutdown_timeout, 0)
        }
    ).

construct_health_routes(Check) ->
    [erl_health_handle:get_route(enable_health_logging(Check))].

enable_health_logging(Check) ->
    EvHandler = {erl_health_event_handler, []},
    maps:map(fun(_, V = {_, _, _}) -> #{runner => V, event_handler => EvHandler} end, Check).

construct_service_handler(Name, Module, Opts) ->
    {Path, Service} = pm_proto:get_service_spec(Name),
    {Path, {Service, {pm_woody_wrapper, maps:merge(#{handler => Module}, Opts)}}}.

-spec get_prometheus_route() -> {iodata(), module(), _Opts :: any()}.
get_prometheus_route() ->
    {"/metrics/[:registry]", prometheus_cowboy2_handler, []}.

%% Application callbacks

-spec start(normal, any()) -> {ok, pid()} | {error, any()}.
start(_StartType, _StartArgs) ->
    ok = setup_metrics(),
    supervisor:start_link(?MODULE, []).

-spec stop(any()) -> ok.
stop(_State) ->
    ok.

%%

setup_metrics() ->
    ok = woody_ranch_prometheus_collector:setup(),
    ok = woody_hackney_prometheus_collector:setup().
