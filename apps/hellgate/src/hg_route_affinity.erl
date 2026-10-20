-module(hg_route_affinity).

-behaviour(hg_route_collector).

-include_lib("damsel/include/dmsl_customer_thrift.hrl").

-export([enabled/1]).
-export([fill/3]).

-spec enabled([hg_route:t()]) -> boolean().
enabled(Routes) ->
    lists:any(fun(Route) -> hg_route:affinity(Route) =/= undefined end, Routes).

%% A place in the history is computed once for all candidates: ranks are compared with
%% one another, so they must not be numbered within a filtered subset — two candidates
%% would get the same rank on different scales. Each candidate has its own lifetime, and
%% it only decides whether that candidate keeps its place or loses it.
-spec fill([dmsl_customer_thrift:'TerminalAffinity'()], [hg_route:t()], integer()) -> [hg_route:t()].
fill(Affinities, Routes, Now) ->
    Sorted = lists:keysort(#customer_TerminalAffinity.bind_seq, Affinities),
    Total = length(Sorted),
    Ranks = maps:from_list([
        {{ProviderRef, TerminalRef}, {Total - Index, Affinity}}
     || {#customer_TerminalAffinity{provider_ref = ProviderRef, terminal_ref = TerminalRef} = Affinity, Index} <-
            lists:zip(Sorted, lists:seq(0, Total - 1))
    ]),
    [hg_route:set_affinity_rank(rank(Route, Ranks, Now), Route) || Route <- Routes].

rank(Route, Ranks, Now) ->
    case hg_route:affinity(Route) of
        undefined ->
            0;
        Config ->
            Key = {hg_route:provider_ref(Route), hg_route:terminal_ref(Route)},
            case maps:get(Key, Ranks, undefined) of
                undefined -> 0;
                {Rank, Affinity} -> live_rank(Affinity, Config, Rank, Now)
            end
    end.

live_rank(Affinity, Config, Rank, Now) ->
    case hg_terminal_affinity:live([Affinity], Config, Now) of
        [_] -> Rank;
        [] -> 0
    end.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-spec test() -> _.

-spec affinity_routing_test_() -> [_].
affinity_routing_test_() ->
    A = test_route(1),
    B = test_route(2),
    C = test_route(3),
    History = [test_affinity(1), test_affinity(2)],
    [
        ?_assertNot(enabled([])),
        ?_assertNot(enabled([maps:remove(affinity, A)])),
        ?_assert(enabled([A, B])),
        ?_assertEqual([2, 1, 0], [hg_route:affinity_rank(R) || R <- fill(History, [A, B, C], now_ms())]),
        ?_assertEqual(0, hg_route:affinity_rank(hd(fill(History, [maps:remove(affinity, A)], now_ms())))),
        ?_test(per_candidate_ttl()),
        ?_test(rank_scale_is_shared()),
        ?_assertEqual(1, choose(History, [A, B, C])),
        ?_assertEqual(2, choose([test_affinity(1)], [B])),
        ?_assertEqual(2, choose(History, [hg_route:set_availability(0, 0.0, A), B])),
        ?_assertEqual(2, choose(History, [hg_route:set_conversion(0, 0.0, A), B])),
        ?_assertEqual(1, choose(History, [A, hg_route:set_priority(100, B)])),
        ?_assertEqual([1], lists:usort([choose([test_affinity(1)], [A, B]) || _ <- lists:seq(1, 1000)])),
        ?_test(assert_distribution([], [A, B], [1, 2])),
        ?_test(assert_distribution([], [A, B, C], [1, 2, 3]))
    ].

assert_distribution(History, Routes, IDs) ->
    _ = rand:seed(exsss, {11, 22, 33}),
    Chosen = [choose(History, Routes) || _ <- lists:seq(1, 1000)],
    Expected = 1000 / length(IDs),
    lists:foreach(
        fun(ID) ->
            Count = length([X || X <- Chosen, X =:= ID]),
            ?assert(abs(Count - Expected) < 80)
        end,
        IDs
    ).

choose(History, Routes) ->
    {Chosen, _} = hg_routing:choose_route(hg_route_balancer:fill(fill(History, Routes, now_ms()))),
    (hg_route:terminal_ref(Chosen))#domain_TerminalRef.id.

now_ms() ->
    erlang:system_time(millisecond).

%% Ranks of live bindings are comparable with one another: the earlier one is strictly
%% greater, even when the candidates have different lifetimes and filtering drops
%% different rows
rank_scale_is_shared() ->
    Now = now_ms(),
    Old = #customer_TerminalAffinity{
        provider_ref = #domain_ProviderRef{id = 1},
        terminal_ref = #domain_TerminalRef{id = 1},
        bind_seq = 1,
        bound_at = <<"2000-01-01T00:00:00Z">>,
        last_used_at = list_to_binary(calendar:system_time_to_rfc3339(Now div 1000, [{offset, "Z"}]))
    },
    New = Old#customer_TerminalAffinity{
        terminal_ref = #domain_TerminalRef{id = 2},
        bind_seq = 2,
        last_used_at = <<"2000-01-01T00:00:00Z">>
    },
    Route = fun(ID, Ttl) ->
        (hg_route:new(1, #domain_ProviderRef{id = 1}, #domain_TerminalRef{id = ID}, 50, 0, #{}))#{
            affinity => #domain_RoutingAffinity{ttl = Ttl}
        }
    end,
    %% Both bindings are live by their own configs, but their filters drop different rows
    [RankOld, RankNew] = [
        hg_route:affinity_rank(R)
     || R <- fill([Old, New], [Route(1, {since_last_use, 3600}), Route(2, undefined)], Now)
    ],
    ?assert(RankOld > RankNew),
    ?assert(RankNew > 0).

%% Two candidates on one provider-terminal pair with different lifetimes: a neighbour's
%% lifetime must neither revive nor bury someone else's binding
per_candidate_ttl() ->
    Stale = #customer_TerminalAffinity{
        provider_ref = #domain_ProviderRef{id = 1},
        terminal_ref = #domain_TerminalRef{id = 1},
        bind_seq = 1,
        bound_at = <<"2000-01-01T00:00:00Z">>,
        last_used_at = <<"2000-01-01T00:00:00Z">>
    },
    Route = fun(Ttl) ->
        (hg_route:new(1, #domain_ProviderRef{id = 1}, #domain_TerminalRef{id = 1}, 50, 0, #{}))#{
            affinity => #domain_RoutingAffinity{ttl = Ttl}
        }
    end,
    Expired = Route({since_bound, 60}),
    Eternal = Route(undefined),
    [RankExpired, RankEternal] = [
        hg_route:affinity_rank(R)
     || R <- fill([Stale], [Expired, Eternal], now_ms())
    ],
    ?assertEqual(0, RankExpired),
    ?assertEqual(1, RankEternal).

test_route(ID) ->
    (hg_route:new(1, #domain_ProviderRef{id = ID}, #domain_TerminalRef{id = ID}, 50, 0, #{}))#{
        affinity => #domain_RoutingAffinity{}
    }.

test_affinity(ID) ->
    #customer_TerminalAffinity{
        provider_ref = #domain_ProviderRef{id = ID},
        terminal_ref = #domain_TerminalRef{id = ID},
        bind_seq = ID,
        bound_at = <<"2026-01-01T00:00:00Z">>,
        last_used_at = <<"2026-01-01T00:00:00Z">>
    }.

-endif.
