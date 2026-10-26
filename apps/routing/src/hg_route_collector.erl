-module(hg_route_collector).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([get_routes/4]).
-export([fill_prohibition/5]).

-callback fill(_Params, [hg_route:t()]) -> [hg_route:t()].
-callback fill([hg_route:t()]) -> [hg_route:t()].
-optional_callbacks([fill/1, fill/2]).

-type revision() :: hg_route:revision().
-type varset() :: map().
-type routing_rules() :: dmsl_domain_thrift:'RoutingRules'() | undefined.
-type compute_ruleset() :: fun(
    (dmsl_domain_thrift:'RoutingRulesetRef'(), varset(), revision()) -> {ok, dmsl_domain_thrift:'RoutingRuleset'()}
).
-type resolve_terminal() :: fun((hg_route:terminal_ref(), revision()) -> {ok, hg_route:provider_ref()}).
-type validate_candidate() :: fun((dmsl_domain_thrift:'RoutingCandidate'()) -> ok | no_return()).
-type callbacks() :: #{
    compute_ruleset := compute_ruleset(),
    resolve_terminal := resolve_terminal(),
    validate_candidate := validate_candidate()
}.

-type get_routes_result() :: #{
    routes := [hg_route:t()],
    error => get_routes_error()
}.

-type get_routes_error() :: {misconfiguration, _Reason}.

-export_type([revision/0]).
-export_type([varset/0]).
-export_type([routing_rules/0]).
-export_type([callbacks/0]).
-export_type([get_routes_error/0]).
-export_type([get_routes_result/0]).

-spec get_routes(revision(), varset(), routing_rules(), module() | callbacks()) ->
    get_routes_result().
get_routes(_, _, undefined, _) ->
    #{routes => [], error => {misconfiguration, {payment_routing_rules, empty}}};
get_routes(Revision, VS, #domain_RoutingRules{policies = Policies}, Domain) ->
    Callbacks = domain_callbacks(Domain),
    try
        Candidates = get_candidates(Policies, VS, Revision, Callbacks),
        #{routes => collect_routes(Candidates, Revision, Callbacks)}
    catch
        throw:{misconfiguration, _Reason} = Error ->
            #{routes => [], error => Error}
    end.

-spec fill_prohibition(revision(), varset(), routing_rules(), module() | callbacks(), [hg_route:t()]) -> [hg_route:t()].
fill_prohibition(_Revision, _VS, undefined, _Domain, Routes) ->
    Routes;
fill_prohibition(Revision, VS, #domain_RoutingRules{prohibitions = Prohibitions}, Domain, Routes) ->
    Table = get_table_prohibitions(Prohibitions, VS, Revision, domain_callbacks(Domain)),
    apply_prohibition(Table, Routes).

domain_callbacks(Domain) when is_atom(Domain) ->
    #{
        compute_ruleset => fun Domain:compute_ruleset/3,
        resolve_terminal => fun Domain:resolve_terminal/2,
        validate_candidate => fun Domain:validate_candidate/1
    };
domain_callbacks(Callbacks) when is_map(Callbacks) ->
    Callbacks.

get_candidates(RoutingRule, VS, Revision, Callbacks) ->
    get_decisions_candidates(
        compute_rule_set(RoutingRule, VS, Revision, Callbacks),
        maps:get(validate_candidate, Callbacks)
    ).

get_decisions_candidates(#domain_RoutingRuleset{decisions = Decisions}, ValidateCandidate) ->
    case Decisions of
        {delegates, _Delegates} ->
            throw({misconfiguration, {routing_decisions, Decisions}});
        {candidates, Candidates} ->
            ok = lists:foreach(ValidateCandidate, Candidates),
            Candidates
    end.

compute_rule_set(RuleSetRef, VS, Revision, #{compute_ruleset := Compute}) ->
    {ok, RuleSet} = Compute(RuleSetRef, VS, Revision),
    RuleSet.

get_table_prohibitions(Prohibitions, VS, Revision, Callbacks) ->
    RuleSetDeny = compute_rule_set(Prohibitions, VS, Revision, Callbacks),
    lists:foldr(
        fun(#domain_RoutingCandidate{terminal = K, description = V}, AccIn) ->
            AccIn#{K => V}
        end,
        #{},
        get_decisions_candidates(RuleSetDeny, maps:get(validate_candidate, Callbacks))
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
    {ok, ProviderRef} = Resolve(TerminalRef, Revision),
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

make_route(Revision, ProviderRef, TerminalRef, Weight, Priority, Pin, Affinity) ->
    Route = hg_route:new(
        Revision,
        ProviderRef,
        TerminalRef,
        stored_weight(Weight),
        stored_priority(Priority),
        0
    ),
    maps:merge(Route, genlib_map:compact(#{affinity => Affinity, routing_pin => Pin})).

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
    ?assertEqual(#{routes => []}, hg_route_collector:get_routes(1, #{}, routing_rules(), ProhibitFail)),
    ?assertThrow(
        {misconfiguration, {routing_decisions, {delegates, []}}},
        fill_prohibition(1, #{}, routing_rules(), ProhibitFail, [])
    ).

-spec domain_candidate_validation_test() -> _.
domain_candidate_validation_test() ->
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
    UndefinedWeight = (candidate(?trm(4), {constant, true}, 1, 0))#domain_RoutingCandidate{weight = undefined},
    DefinedWeight = candidate(?trm(4), {constant, true}, 1, 2),
    UndefCallbacks = callbacks([UndefinedWeight, DefinedWeight], [], payment, fun default_resolve/2),
    #{routes := [UndefWinner]} = hg_route_collector:get_routes(1, #{}, routing_rules(), UndefCallbacks),
    ?assertEqual(2, hg_route:weight(UndefWinner)).

-spec collector_missing_terminal_error_test() -> _.
collector_missing_terminal_error_test() ->
    Candidate = candidate(?trm(99), {constant, true}, 1000, 0),
    Error = {object_not_found, {1, {terminal, ?trm(99)}}},
    Callbacks = callbacks([Candidate], [], payment, fun(_Ref, _) -> erlang:error(Error) end),
    ?assertError(Error, hg_route_collector:get_routes(1, #{}, routing_rules(), Callbacks)).

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
        validate_candidate => candidate_validator(Policy)
    }.

callbacks_with_compute(Compute) ->
    #{
        compute_ruleset => Compute,
        resolve_terminal => fun default_resolve/2,
        validate_candidate => candidate_validator(payment)
    }.

candidate_validator(payment) ->
    fun hg_payment_routing:validate_candidate/1;
candidate_validator(withdrawal_legacy) ->
    fun ff_withdrawal_routing:validate_candidate/1.

-endif.
