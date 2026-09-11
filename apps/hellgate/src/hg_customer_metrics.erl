-module(hg_customer_metrics).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([setup/0]).
-export([unavailable/1]).
-export([rejected/1]).
-export([affinity/1]).
-export([bound/1]).

-spec setup() -> ok.
setup() ->
    _ = prometheus_counter:declare([
        {name, customer_unavailable},
        {help, "Customer operations unavailable"},
        {labels, [op]}
    ]),
    _ = prometheus_counter:declare([
        {name, customer_rejected},
        {help, "Customer operations rejected by the service"},
        {labels, [op]}
    ]),
    lists:foreach(
        fun(Name) ->
            _ = prometheus_counter:declare([{name, Name}, {help, "Terminal affinity routing decisions"}])
        end,
        [affinity_enabled, affinity_hit, affinity_miss]
    ),
    _ = prometheus_counter:declare([
        {name, affinity_bound},
        {help, "Successful terminal affinity bindings"},
        {labels, [terminal]}
    ]),
    ok.

-spec unavailable(atom()) -> ok.
unavailable(Op) ->
    prometheus_counter:inc(customer_unavailable, [Op]).

-spec rejected(atom()) -> ok.
rejected(Op) ->
    prometheus_counter:inc(customer_rejected, [Op]).

-spec affinity(enabled | hit | miss) -> ok.
affinity(enabled) -> prometheus_counter:inc(affinity_enabled);
affinity(hit) -> prometheus_counter:inc(affinity_hit);
affinity(miss) -> prometheus_counter:inc(affinity_miss).

-spec bound(dmsl_domain_thrift:'TerminalRef'()) -> ok.
bound(#domain_TerminalRef{id = ID}) ->
    prometheus_counter:inc(affinity_bound, [ID]).
