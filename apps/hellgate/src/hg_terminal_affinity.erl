-module(hg_terminal_affinity).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_customer_thrift.hrl").

-export([live/3]).
-export([can_bind/2]).

-type affinity() :: dmsl_customer_thrift:'TerminalAffinity'().
-type ttl() :: dmsl_domain_thrift:'RoutingAffinityTtl'() | undefined.

%% Selects the bindings that are live from one particular candidate's point of view:
%% the lifetime comes from its own config, not from that of a neighbour sharing the
%% same provider-terminal pair.
-spec live([affinity()], dmsl_domain_thrift:'RoutingAffinity'() | undefined, integer()) -> [affinity()].
live(Affinities, Config, Now) ->
    lists:keysort(#customer_TerminalAffinity.bind_seq, [
        Affinity
     || Affinity <- Affinities, is_live(Affinity, Config, Now)
    ]).

is_live(Affinity, #domain_RoutingAffinity{ttl = Ttl}, Now) ->
    case Ttl of
        {since_bound, Timeout} -> timestamp(Affinity#customer_TerminalAffinity.bound_at) + Timeout * 1000 > Now;
        {since_last_use, Timeout} -> timestamp(Affinity#customer_TerminalAffinity.last_used_at) + Timeout * 1000 > Now;
        _ -> can_bind(Ttl, Now)
    end;
is_live(_Affinity, undefined, _Now) ->
    true.

-spec can_bind(ttl(), integer()) -> boolean().
can_bind({deadline, Deadline}, Now) ->
    timestamp(Deadline) > Now;
can_bind(_, _) ->
    true.

timestamp(Value) ->
    calendar:rfc3339_to_system_time(binary_to_list(Value), [{unit, millisecond}]).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec ttl_test_() -> [_].
ttl_test_() ->
    Now = timestamp(<<"2026-01-01T00:01:00Z">>),
    A = #customer_TerminalAffinity{
        provider_ref = #domain_ProviderRef{id = 1},
        terminal_ref = #domain_TerminalRef{id = 1},
        bind_seq = 1,
        bound_at = <<"2026-01-01T00:00:00Z">>,
        last_used_at = <<"2026-01-01T00:00:59Z">>
    },
    B = A#customer_TerminalAffinity{
        terminal_ref = #domain_TerminalRef{id = 2}, bind_seq = 2, bound_at = <<"2026-01-01T00:00:59Z">>
    },
    Routes = fun(Ttl) -> #domain_RoutingAffinity{ttl = Ttl} end,
    [
        ?_assertEqual([A, B], live([B, A], Routes(undefined), Now)),
        ?_assertEqual([B], live([A, B], Routes({since_bound, 60}), Now)),
        ?_assertEqual([], live([A, B], Routes({since_bound, 1}), Now)),
        ?_assertEqual([A, B], live([A, B], Routes({since_last_use, 60}), Now)),
        ?_assertEqual([], live([A, B], Routes({since_last_use, 1}), Now)),
        ?_assertEqual([], live([A, B], Routes({deadline, <<"2026-01-01T00:01:00Z">>}), Now)),
        ?_assertEqual([A, B], live([A, B], Routes({deadline, <<"2026-01-01T00:01:01Z">>}), Now)),
        ?_assertNot(can_bind({deadline, <<"2026-01-01T00:01:00Z">>}, Now))
    ].

-endif.
