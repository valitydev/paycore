-module(hg_route_collector).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([fill_prohibition/2]).
-export([get_routes/4]).

-callback fill(_Params, [hg_route:t()]) -> [hg_route:t()].
-callback fill([hg_route:t()]) -> [hg_route:t()].
-optional_callbacks([fill/1, fill/2]).

-type revision() :: hg_route:revision().
-type varset() :: map().
-type routing_rules() :: dmsl_domain_thrift:'RoutingRules'() | undefined.
-type allowed_policy() :: payment | withdrawal_legacy.
-type compute_ruleset() :: fun(
    (dmsl_domain_thrift:'RoutingRulesetRef'(), varset(), revision()) -> {ok, dmsl_domain_thrift:'RoutingRuleset'()}
).
-type resolve_terminal() :: fun(
    (hg_route:terminal_ref(), revision()) -> {ok, hg_route:provider_ref()} | {error, notfound | _Reason}
).
-type callbacks() :: #{
    compute_ruleset := compute_ruleset(),
    resolve_terminal := resolve_terminal(),
    allowed_policy := allowed_policy()
}.

-type get_routes_result() :: #{
    routes := [hg_route:t()],
    error => get_routes_error()
}.

-type get_routes_error() :: {misconfiguration, _Reason}.

-export_type([revision/0]).
-export_type([varset/0]).
-export_type([routing_rules/0]).
-export_type([allowed_policy/0]).
-export_type([callbacks/0]).
-export_type([get_routes_error/0]).
-export_type([get_routes_result/0]).

-spec fill_prohibition(#{hg_route:terminal_ref() => _Description}, [hg_route:t()]) -> [hg_route:t()].
fill_prohibition(Table, Routes) ->
    apply_prohibition(Table, Routes).

-spec get_routes(revision(), varset(), routing_rules(), callbacks()) ->
    get_routes_result().
get_routes(_, _, undefined, _) ->
    #{routes => [], error => {misconfiguration, {payment_routing_rules, empty}}};
get_routes(Revision, VS, #domain_RoutingRules{} = RoutingRules, Callbacks) ->
    #domain_RoutingRules{
        policies = Policies,
        prohibitions = Prohibitions
    } = RoutingRules,
    try
        Candidates = get_candidates(Policies, VS, Revision, Callbacks),
        Table = get_table_prohibitions(Prohibitions, VS, Revision, Callbacks),
        Routes0 = collect_routes(Candidates, Revision, Callbacks),
        #{routes => apply_prohibition(Table, Routes0)}
    catch
        throw:{misconfiguration, _Reason} = Error ->
            #{routes => [], error => Error}
    end.

get_candidates(RoutingRule, VS, Revision, Callbacks) ->
    get_decisions_candidates(
        compute_rule_set(RoutingRule, VS, Revision, Callbacks),
        maps:get(allowed_policy, Callbacks)
    ).

get_decisions_candidates(#domain_RoutingRuleset{decisions = Decisions}, AllowedPolicy) ->
    case Decisions of
        {delegates, _Delegates} ->
            throw({misconfiguration, {routing_decisions, Decisions}});
        {candidates, Candidates} ->
            ok = validate_decisions_candidates(AllowedPolicy, Candidates),
            Candidates
    end.

compute_rule_set(RuleSetRef, VS, Revision, #{compute_ruleset := Compute}) ->
    {ok, RuleSet} = Compute(RuleSetRef, VS, Revision),
    RuleSet.

validate_decisions_candidates(_Policy, []) ->
    ok;
validate_decisions_candidates(payment, [#domain_RoutingCandidate{allowed = {constant, true}} | Rest]) ->
    validate_decisions_candidates(payment, Rest);
validate_decisions_candidates(payment, [Candidate | _]) ->
    throw({misconfiguration, {routing_candidate, Candidate}});
validate_decisions_candidates(withdrawal_legacy, [#domain_RoutingCandidate{allowed = {constant, Bool}} | Rest]) when
    is_boolean(Bool)
->
    validate_decisions_candidates(withdrawal_legacy, Rest);
validate_decisions_candidates(withdrawal_legacy, [Candidate | _]) ->
    throw({misconfiguration, {routing_candidate, Candidate}}).

get_table_prohibitions(Prohibitions, VS, Revision, Callbacks) ->
    RuleSetDeny = compute_rule_set(Prohibitions, VS, Revision, Callbacks),
    lists:foldr(
        fun(#domain_RoutingCandidate{terminal = K, description = V}, AccIn) ->
            AccIn#{K => V}
        end,
        #{},
        get_decisions_candidates(RuleSetDeny, maps:get(allowed_policy, Callbacks))
    ).

collect_routes(Candidates, Revision, #{resolve_terminal := Resolve}) ->
    {Routes, _Index} = lists:foldl(
        fun(Candidate, Acc) ->
            add_or_merge_candidate(Candidate, Revision, Resolve, Acc)
        end,
        {[], #{}},
        Candidates
    ),
    Routes.

add_or_merge_candidate(Candidate, Revision, Resolve, {Routes, Index}) ->
    #domain_RoutingCandidate{
        terminal = TerminalRef,
        priority = Priority,
        weight = Weight,
        pin = Pin,
        affinity = Affinity
    } = Candidate,
    ProviderRef = resolve_provider(Resolve, TerminalRef, Revision),
    Key = {ProviderRef, TerminalRef},
    CmpPriority = stored_priority(Priority),
    CmpWeight = stored_weight(Weight),
    Route = make_route(Revision, ProviderRef, TerminalRef, Weight, Priority, Pin, Affinity),
    case maps:find(Key, Index) of
        error ->
            Pos = length(Routes) + 1,
            {Routes ++ [Route], Index#{Key => {Pos, CmpPriority, CmpWeight}}};
        {ok, {Pos, PrevPriority, PrevWeight}} ->
            case is_better({CmpPriority, CmpWeight}, {PrevPriority, PrevWeight}) of
                true ->
                    {replace_nth(Pos, Route, Routes), Index#{Key => {Pos, CmpPriority, CmpWeight}}};
                false ->
                    {Routes, Index}
            end
    end.

resolve_provider(Resolve, TerminalRef, Revision) ->
    case Resolve(TerminalRef, Revision) of
        {ok, ProviderRef} ->
            ProviderRef;
        {error, notfound} ->
            throw({misconfiguration, {terminal, TerminalRef, notfound}})
    end.

make_route(Revision, ProviderRef, TerminalRef, Weight, Priority, Pin, Affinity) ->
    Route = hg_route:new(
        Revision,
        ProviderRef,
        TerminalRef,
        stored_weight(Weight),
        stored_priority(Priority),
        #{}
    ),
    Route#{affinity => Affinity, routing_pin => Pin}.

stored_weight(undefined) ->
    ?DOMAIN_CANDIDATE_WEIGHT;
stored_weight(Weight) ->
    Weight.

stored_priority(undefined) ->
    ?DOMAIN_CANDIDATE_PRIORITY;
stored_priority(Priority) ->
    Priority.

is_better({Priority, Weight}, {PrevPriority, PrevWeight}) ->
    (Priority > PrevPriority) orelse (Priority =:= PrevPriority andalso Weight > PrevWeight).

replace_nth(Pos, Value, List) ->
    {Head, [_ | Tail]} = lists:split(Pos - 1, List),
    Head ++ [Value | Tail].

apply_prohibition(Table, Routes) ->
    lists:foldr(
        fun(Route, AccIn) ->
            TRef = hg_route:terminal_ref(Route),
            case maps:find(TRef, Table) of
                error ->
                    [Route | AccIn];
                {ok, Description} ->
                    [hg_route:set_prohibit({true, {'RoutingRule', Description}}, Route) | AccIn]
            end
        end,
        [],
        Routes
    ).

%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-define(prv(ID), #domain_ProviderRef{id = ID}).
-define(trm(ID), #domain_TerminalRef{id = ID}).
-define(rs(ID), #domain_RoutingRulesetRef{id = ID}).

-spec collector_without_payment_institution_test() -> _.
collector_without_payment_institution_test() ->
    Candidate = candidate(?trm(1), {constant, true}, 1000, 0),
    Callbacks = callbacks([Candidate], [], payment, fun default_resolve/2),
    #{routes := [Route]} = hg_route_collector:get_routes(1, #{}, routing_rules(), Callbacks),
    ?assertEqual(?prv(1), hg_route:provider_ref(Route)),
    ?assertEqual(?trm(1), hg_route:terminal_ref(Route)).

-spec collector_undefined_rules_test() -> _.
collector_undefined_rules_test() ->
    ?assertEqual(
        #{routes => [], error => {misconfiguration, {payment_routing_rules, empty}}},
        hg_route_collector:get_routes(1, #{}, undefined, callbacks([], [], payment, fun default_resolve/2))
    ).

-spec collector_misconfiguration_policies_and_prohibitions_test() -> _.
collector_misconfiguration_policies_and_prohibitions_test() ->
    Delegates = {ok, #domain_RoutingRuleset{name = <<"bad">>, decisions = {delegates, []}}},
    Ok = {ok, #domain_RoutingRuleset{name = <<"ok">>, decisions = {candidates, []}}},
    PolicyFail = callbacks_with_compute(fun(Ref, _, _) ->
        case Ref of
            ?rs(1) -> Delegates;
            ?rs(2) -> Ok
        end
    end),
    ProhibitFail = callbacks_with_compute(fun(Ref, _, _) ->
        case Ref of
            ?rs(1) -> Ok;
            ?rs(2) -> Delegates
        end
    end),
    ?assertMatch(
        #{routes := [], error := {misconfiguration, {routing_decisions, _}}},
        hg_route_collector:get_routes(1, #{}, routing_rules(), PolicyFail)
    ),
    ?assertMatch(
        #{routes := [], error := {misconfiguration, {routing_decisions, _}}},
        hg_route_collector:get_routes(1, #{}, routing_rules(), ProhibitFail)
    ).

-spec collector_allowed_policy_payment_vs_withdrawal_legacy_test() -> _.
collector_allowed_policy_payment_vs_withdrawal_legacy_test() ->
    FalseAllowed = candidate(?trm(1), {constant, false}, 1000, 0),
    Payment = callbacks([FalseAllowed], [], payment, fun default_resolve/2),
    Withdrawal = callbacks([FalseAllowed], [], withdrawal_legacy, fun default_resolve/2),
    ?assertMatch(
        #{routes := [], error := {misconfiguration, {routing_candidate, _}}},
        hg_route_collector:get_routes(1, #{}, routing_rules(), Payment)
    ),
    #{routes := [Route]} = hg_route_collector:get_routes(1, #{}, routing_rules(), Withdrawal),
    ?assertEqual(?trm(1), hg_route:terminal_ref(Route)).

-spec collector_merge_duplicate_provider_terminal_test() -> _.
collector_merge_duplicate_provider_terminal_test() ->
    %% Higher priority wins; equal priority then higher weight; then first original.
    CLowPrio = candidate(?trm(1), {constant, true}, 1, 100),
    CHighPrioLowWeight = candidate(?trm(1), {constant, true}, 5, 1),
    CHighPrioHighWeight = candidate(?trm(1), {constant, true}, 5, 20),
    COther = candidate(?trm(2), {constant, true}, 1, 0),
    Callbacks = callbacks(
        [CLowPrio, COther, CHighPrioLowWeight, CHighPrioHighWeight],
        [],
        payment,
        fun default_resolve/2
    ),
    #{routes := Routes} = hg_route_collector:get_routes(1, #{}, routing_rules(), Callbacks),
    ?assertEqual([?trm(1), ?trm(2)], [hg_route:terminal_ref(R) || R <- Routes]),
    [Winner, _] = Routes,
    ?assertEqual(5, hg_route:priority(Winner)),
    ?assertEqual(20, hg_route:weight(Winner)),
    TieFirst = candidate(?trm(3), {constant, true}, 3, 7),
    TieSecond = candidate(?trm(3), {constant, true}, 3, 7),
    TieCallbacks = callbacks([TieFirst, TieSecond], [], payment, fun default_resolve/2),
    #{routes := [TieWinner]} = hg_route_collector:get_routes(1, #{}, routing_rules(), TieCallbacks),
    ?assertEqual(3, hg_route:priority(TieWinner)),
    ?assertEqual(7, hg_route:weight(TieWinner)),
    UndefinedWeight = (candidate(?trm(4), {constant, true}, 1, 0))#domain_RoutingCandidate{weight = undefined},
    DefinedWeight = candidate(?trm(4), {constant, true}, 1, 2),
    UndefCallbacks = callbacks([UndefinedWeight, DefinedWeight], [], payment, fun default_resolve/2),
    #{routes := [UndefWinner]} = hg_route_collector:get_routes(1, #{}, routing_rules(), UndefCallbacks),
    ?assertEqual(2, hg_route:weight(UndefWinner)).

-spec collector_missing_terminal_misconfiguration_test() -> _.
collector_missing_terminal_misconfiguration_test() ->
    Candidate = candidate(?trm(99), {constant, true}, 1000, 0),
    Callbacks = callbacks([Candidate], [], payment, fun(_Ref, _) -> {error, notfound} end),
    ?assertEqual(
        #{routes => [], error => {misconfiguration, {terminal, ?trm(99), notfound}}},
        hg_route_collector:get_routes(1, #{}, routing_rules(), Callbacks)
    ).

-spec collector_merge_duplicate_default_priority_test() -> _.
collector_merge_duplicate_default_priority_test() ->
    Default = (candidate(?trm(1), {constant, true}, 0, 1))#domain_RoutingCandidate{priority = undefined},
    Lower = candidate(?trm(1), {constant, true}, ?DOMAIN_CANDIDATE_PRIORITY - 1, 100),
    lists:foreach(
        fun(Candidates) ->
            Callbacks = callbacks(Candidates, [], payment, fun default_resolve/2),
            #{routes := [Route]} = hg_route_collector:get_routes(1, #{}, routing_rules(), Callbacks),
            ?assertEqual(?DOMAIN_CANDIDATE_PRIORITY, hg_route:priority(Route)),
            ?assertEqual(1, hg_route:weight(Route))
        end,
        [[Default, Lower], [Lower, Default]]
    ).

-spec collector_rpc_error_not_misconfig_test() -> _.
collector_rpc_error_not_misconfig_test() ->
    Woody = {woody_error, {system, resource_unavailable, rpc}},
    ErrorCallbacks = callbacks_with_compute(fun(_, _, _) -> raise(error, Woody) end),
    ok = assert_rpc_propagates(ErrorCallbacks),
    ThrowCallbacks = callbacks_with_compute(fun(_, _, _) -> raise(throw, Woody) end),
    ok = assert_rpc_propagates(ThrowCallbacks).

-spec assert_rpc_propagates(callbacks()) -> ok.
assert_rpc_propagates(Callbacks) ->
    try
        _ = hg_route_collector:get_routes(1, #{}, routing_rules(), Callbacks),
        erlang:error(expected_rpc_error)
    catch
        error:{woody_error, _} ->
            ok;
        throw:{woody_error, _} ->
            ok;
        throw:{misconfiguration, _} ->
            erlang:error(mapped_to_misconfiguration);
        error:{route_not_found, _} ->
            erlang:error(mapped_to_route_not_found);
        throw:{route_not_found, _} ->
            erlang:error(mapped_to_route_not_found)
    end.

-spec collector_timeout_not_route_not_found_test() -> _.
collector_timeout_not_route_not_found_test() ->
    Callbacks = callbacks_with_compute(fun(_, _, _) -> raise(error, timeout) end),
    try
        _ = hg_route_collector:get_routes(1, #{}, routing_rules(), Callbacks),
        erlang:error(expected_timeout)
    catch
        error:timeout ->
            ok;
        throw:{misconfiguration, _} ->
            erlang:error(mapped_to_misconfiguration);
        error:{route_not_found, _} ->
            erlang:error(mapped_to_route_not_found)
    end.

routing_rules() ->
    #domain_RoutingRules{
        policies = ?rs(1),
        prohibitions = ?rs(2)
    }.

candidate(TerminalRef, Allowed, Priority, Weight) ->
    #domain_RoutingCandidate{
        terminal = TerminalRef,
        allowed = Allowed,
        priority = Priority,
        weight = Weight
    }.

default_resolve(#domain_TerminalRef{id = ID}, _Revision) ->
    {ok, ?prv(ID)}.

callbacks(PolicyCandidates, ProhibitCandidates, Policy, Resolve) ->
    #{
        compute_ruleset => fun(Ref, _, _) ->
            Candidates =
                case Ref of
                    ?rs(1) -> PolicyCandidates;
                    ?rs(2) -> ProhibitCandidates
                end,
            {ok, #domain_RoutingRuleset{name = <<"rs">>, decisions = {candidates, Candidates}}}
        end,
        resolve_terminal => Resolve,
        allowed_policy => Policy
    }.

callbacks_with_compute(Compute) ->
    #{
        compute_ruleset => Compute,
        resolve_terminal => fun default_resolve/2,
        allowed_policy => payment
    }.

raise(error, Reason) ->
    case get('$dialyzer_raise') of
        true -> ok;
        _ -> erlang:error(Reason)
    end;
raise(throw, Reason) ->
    case get('$dialyzer_raise') of
        true -> ok;
        _ -> erlang:throw(Reason)
    end.

-endif.
