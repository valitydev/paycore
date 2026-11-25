-module(processing_server).

-export([child_spec/2]).

-type endpoint() :: {woody:path(), woody:service(), module() | {module(), term()}}.
-type health_check() :: {liveness | readiness, erl_health:check()}.
-type listener() :: #{
    options := map(),
    endpoints := [endpoint()],
    wrapper := {module(), map()},
    health_checks := [health_check()]
}.

-spec child_spec(atom(), listener()) -> supervisor:child_spec().
child_spec(ID, #{options := Options, endpoints := Endpoints, wrapper := Wrapper, health_checks := HealthChecks}) ->
    {ok, IP} = inet:parse_address(maps:get(ip, Options)),
    HealthRoutes = [health_route(Check) || Check <- HealthChecks],
    woody_server:child_spec(ID, Options#{
        ip => IP,
        handlers => [wrap_endpoint(Endpoint, Wrapper) || Endpoint <- Endpoints],
        additional_routes => [{"/metrics/[:registry]", prometheus_cowboy2_handler, []} | HealthRoutes]
    }).

wrap_endpoint({Path, Service, Handler}, {Wrapper, Options}) ->
    {Path, {Service, {Wrapper, Options#{handler => Handler}}}}.

health_route({liveness, Check}) ->
    erl_health_handle:get_liveness_route(enable_health_logging(Check));
health_route({readiness, Check}) ->
    erl_health_handle:get_readiness_route(enable_health_logging(Check)).

enable_health_logging(Check) ->
    maps:map(
        fun(_, {_, _, _} = Runner) -> #{runner => Runner, event_handler => {erl_health_event_handler, []}} end,
        Check
    ).
