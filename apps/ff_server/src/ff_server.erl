%%%
%%% Server startup
%%%
%%% TODOs
%%%
%%%  - We should probably most of what is hardcoded here to the application
%%%    environment.
%%%  - Provide healthcheck.
%%%

-module(ff_server).

-export([start/0]).

%% Application

-behaviour(application).

-export([start/2]).
-export([stop/1]).

%% Supervisor

-behaviour(supervisor).

-export([init/1]).

% 30 seconds
-define(DEFAULT_HANDLING_TIMEOUT, 30000).

%%

-spec start() -> {ok, _}.
start() ->
    application:ensure_all_started(?MODULE).

%% Application

-spec start(normal, any()) -> {ok, pid()} | {error, any()}.
start(_StartType, _StartArgs) ->
    ok = processing_server:setup_metrics(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec stop(any()) -> ok.
stop(_State) ->
    ok.

%% Supervisor

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    PartyClient = party_client:create_client(),
    DefaultTimeout = genlib_app:env(?MODULE, default_woody_handling_timeout, ?DEFAULT_HANDLING_TIMEOUT),
    WrapperOpts = #{
        party_client => PartyClient,
        default_handling_timeout => DefaultTimeout
    },

    PartyClientSpec = party_client:child_spec(party_client, PartyClient),
    Binding = op_context:binding(fistful),
    Registrations = [
        #{handler => Handler, binding => Binding}
     || Handler <- [
            ff_deposit_machine,
            ff_source_machine,
            ff_destination_machine,
            ff_withdrawal_machine,
            ff_withdrawal_session_machine
        ]
    ],
    PrgMachineSpec = prg_machine_registry:get_child_spec(Registrations),
    % TODO
    %  - Zero thoughts given while defining this strategy.
    {ok, {#{strategy => one_for_one}, [PartyClientSpec, PrgMachineSpec, get_listener_child_spec(WrapperOpts)]}}.

get_listener_child_spec(WrapperOpts) ->
    WoodyOpts = maps:with([net_opts, handler_limits], genlib_app:env(?MODULE, woody_opts, #{})),
    processing_server:child_spec(?MODULE, #{
        options => WoodyOpts#{
            ip => genlib_app:env(?MODULE, ip, "::1"),
            port => genlib_app:env(?MODULE, port, 8022),
            event_handler => ff_woody_event_handler
        },
        endpoints => [
            endpoint(ff_withdrawal_adapter_host, ff_withdrawal_adapter_host),
            endpoint(destination_management, ff_destination_handler),
            endpoint(source_management, ff_source_handler),
            endpoint(withdrawal_management, ff_withdrawal_handler),
            endpoint(withdrawal_session_management, ff_withdrawal_session_handler),
            endpoint(deposit_management, ff_deposit_handler),
            endpoint(withdrawal_session_repairer, ff_withdrawal_session_repair),
            endpoint(withdrawal_repairer, ff_withdrawal_repair),
            endpoint(deposit_repairer, ff_deposit_repair),
            endpoint(progressor_trace, ff_progressor_trace_handler)
        ],
        wrapper => {ff_woody_wrapper, WrapperOpts},
        health_checks => [
            {readiness, genlib_app:env(?MODULE, health_check_readiness, #{})},
            {liveness, genlib_app:env(?MODULE, health_check_liveness, #{})}
        ]
    }).

endpoint(Name, Handler) ->
    {Path, Service} = ff_services:get_service_spec(Name),
    {Path, Service, Handler}.
