-module(processing_server_metrics).

-export([setup/0]).

-spec setup() -> ok.
setup() ->
    ok = woody_ranch_prometheus_collector:setup(),
    ok = woody_hackney_prometheus_collector:setup(),
    _ = prometheus_histogram:declare([
        {name, woody_wrapper_processing_duration_ms},
        {help, "Duration of processing handle_function in millisecond"},
        {buckets, [50, 150, 300, 500, 750, 1000]},
        {labels, [handler, function]}
    ]),
    ok.
