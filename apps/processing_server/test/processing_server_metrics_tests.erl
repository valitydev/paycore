-module(processing_server_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec repeated_setup_preserves_metrics_test() -> _.
repeated_setup_preserves_metrics_test() ->
    {ok, _} = application:ensure_all_started(processing_server),
    ok = processing_server_metrics:setup(),
    Name = woody_wrapper_processing_duration_ms,
    Labels = [atom_to_binary(?MODULE), <<"repeated_setup">>],
    ok = prometheus_histogram:observe(Name, Labels, 42),
    Value = prometheus_histogram:value(Name, Labels),
    Buckets = prometheus_histogram:buckets(Name, Labels),
    ok = processing_server_metrics:setup(),
    ?assertEqual(Value, prometheus_histogram:value(Name, Labels)),
    ?assertEqual(Buckets, prometheus_histogram:buckets(Name, Labels)),
    Collectors = prometheus_registry:collectors(default),
    ?assertEqual(1, length([C || C <- Collectors, C =:= woody_ranch_prometheus_collector])),
    ?assertEqual(1, length([C || C <- Collectors, C =:= woody_hackney_prometheus_collector])).
