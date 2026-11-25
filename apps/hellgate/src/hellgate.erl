%%% @doc Public API, supervisor and application startup.
%%% @end

-module(hellgate).

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

% 30 seconds
-define(DEFAULT_HANDLING_TIMEOUT, 30000).

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
    PartyClient = party_client:create_client(),
    DefaultTimeout = genlib_app:env(hellgate, default_woody_handling_timeout, ?DEFAULT_HANDLING_TIMEOUT),
    Opts = #{
        party_client => PartyClient,
        default_handling_timeout => DefaultTimeout
    },
    Binding = op_context:binding(hellgate),
    Registrations = [#{handler => Handler, binding => Binding} || Handler <- [hg_invoice, hg_invoice_template]],
    {ok,
        {
            #{strategy => one_for_all, intensity => 6, period => 30},
            [
                %% for debugging only
                %% hg_profiler:get_child_spec(),
                party_client:child_spec(party_client, PartyClient),
                prg_machine_registry:get_child_spec(Registrations),
                get_listener_child_spec(Opts)
            ]
        }}.

get_listener_child_spec(WrapperOpts) ->
    EventHandlerOpts = genlib_app:env(?MODULE, scoper_event_handler_options, #{}),
    processing_server:child_spec(?MODULE, #{
        options => #{
            ip => genlib_app:env(?MODULE, ip, "::"),
            port => genlib_app:env(?MODULE, port, 8022),
            transport_opts => genlib_app:env(?MODULE, transport_opts, #{}),
            protocol_opts => genlib_app:env(?MODULE, protocol_opts, #{}),
            event_handler => {scoper_woody_event_handler, EventHandlerOpts},
            shutdown_timeout => genlib_app:env(?MODULE, shutdown_timeout, 0)
        },
        endpoints => [
            endpoint(invoicing, hg_invoice_handler),
            endpoint(invoice_templating, hg_invoice_template),
            endpoint(proxy_host_provider, hg_proxy_host_provider),
            endpoint(progressor_trace, hg_progressor_trace_handler)
        ],
        wrapper => {hg_woody_service_wrapper, WrapperOpts},
        health_checks => [
            {liveness, genlib_app:env(?MODULE, health_check_liveness, #{})},
            {readiness, genlib_app:env(?MODULE, health_check_readiness, #{})}
        ]
    }).

endpoint(Name, Handler) ->
    {Path, Service} = hg_proto:get_service_spec(Name),
    {Path, Service, Handler}.

%% Application callbacks

-spec start(normal, any()) -> {ok, pid()} | {error, any()}.
start(_StartType, _StartArgs) ->
    ok = hg_customer_metrics:setup(),
    ok = processing_server_metrics:setup(),
    supervisor:start_link(?MODULE, []).

-spec stop(any()) -> ok.
stop(_State) ->
    ok.
