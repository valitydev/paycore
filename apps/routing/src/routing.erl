-module(routing).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([run/2, collect/4, fill/2, filter/2, check/3, hold/3, balance/1, select/1, choose_route/1]).
-export_type([step/0, route_choice_context/0]).

-type step() :: {atom(), fun((routing_ctx:t()) -> routing_ctx:t())}.
-type route_choice_context() :: #{
    chosen_route => hg_route:t(),
    preferable_route => hg_route:t(),
    reject_reason => atom()
}.
-type initial_rejection_group() :: atom().
-type check_result() :: ok | {error, term()}.
-type hold_result() :: check_result() | {held, term()}.

-define(ZERO, 0).

%% Domain errors stop the plan; exceptions propagate to the caller's retry mechanism.
-spec run(routing_ctx:t(), [step()]) -> routing_ctx:t().
run(State, []) ->
    State;
run(#{error := Error} = State, _) when Error =/= undefined ->
    State;
run(State, [{_Name, Step} | Rest]) ->
    run(Step(State), Rest).

-spec collect(hg_route:revision(), map(), hg_route_collector:routing_rules(), hg_route_collector:callbacks()) ->
    routing_ctx:t().
collect(Revision, Varset, Rules, Callbacks) ->
    routing_ctx:from_result(hg_route_collector:get_routes(Revision, Varset, Rules, Callbacks)).

-spec fill(routing_ctx:t(), fun(([hg_route:t()]) -> [hg_route:t()])) -> routing_ctx:t().
fill(State, Fill) ->
    State#{candidates := Fill(routing_ctx:candidates(State))}.

-spec filter(routing_ctx:t(), [{atom(), term()}]) -> routing_ctx:t().
filter(State, Keys) ->
    #{routes := Accepted, rejections := Rejections} = filter_routes(routing_ctx:candidates(State), Keys),
    %% First key wins on a single route. Groups are applied in reverse, so that same key
    %% becomes latest_rejection when several routes were rejected for different reasons.
    lists:foldl(
        fun({Group, _}, Acc) ->
            routing_ctx:append_rejected_routes(Group, Accepted, maps:get(Group, Rejections, []), Acc)
        end,
        State,
        lists:reverse(Keys)
    ).

-spec check(routing_ctx:t(), atom(), fun((hg_route:t()) -> check_result())) -> routing_ctx:t().
check(State, Group, Check) ->
    lists:foldl(
        fun(Route, Acc) ->
            case Check(Route) of
                ok -> Acc;
                {error, Reason} -> routing_ctx:reject(Group, hg_route:set_rejection_reason(Reason, Route), Acc)
            end
        end,
        State,
        routing_ctx:candidates(State)
    ).

%% A rejected candidate may still have a hold and must remain available for compensation.
-spec hold(routing_ctx:t(), atom(), fun((hg_route:t()) -> hold_result())) -> routing_ctx:t().
hold(State, Group, Hold) ->
    lists:foldl(
        fun(Route, Acc) ->
            case Hold(Route) of
                ok ->
                    routing_ctx:account(Route, Acc);
                {held, Reason} ->
                    routing_ctx:reject(
                        Group, hg_route:set_rejection_reason(Reason, Route), routing_ctx:account(Route, Acc)
                    );
                {error, Reason} ->
                    routing_ctx:reject(Group, hg_route:set_rejection_reason(Reason, Route), Acc)
            end
        end,
        State,
        routing_ctx:candidates(State)
    ).

-spec balance(routing_ctx:t()) -> routing_ctx:t().
balance(State) ->
    fill(State, fun hg_route_balancer:fill/1).

-spec select(routing_ctx:t()) -> routing_ctx:t().
select(State) ->
    case routing_ctx:candidates(State) of
        [] ->
            State;
        Routes ->
            {Chosen, Meta} = choose_route(Routes),
            routing_ctx:set_choosen(Chosen, Meta, State)
    end.

-spec filter_routes([hg_route:t()], [{atom(), term()}]) ->
    #{
        routes := [hg_route:t()],
        rejections => #{initial_rejection_group() => [hg_route:t()]}
    }.
filter_routes(Routes, Keys) ->
    {Accepted, Rejections} = lists:foldr(
        fun(Route, {AcceptedAcc, RejectionsAcc}) ->
            case route_rejection_reason(Route, Keys) of
                undefined ->
                    {[Route | AcceptedAcc], RejectionsAcc};
                {Group, _} = Reason ->
                    RejectedRoute = hg_route:set_rejection_reason(Reason, Route),
                    GroupRoutes = maps:get(Group, RejectionsAcc, []),
                    {AcceptedAcc, RejectionsAcc#{Group => [RejectedRoute | GroupRoutes]}}
            end
        end,
        {[], #{}},
        Routes
    ),
    #{routes => Accepted, rejections => Rejections}.

route_rejection_reason(Route, Keys) ->
    Data = hg_route:route_data(Route),
    get_rejection_reason(Keys, Data).

get_rejection_reason([{Key, Value} | Rest], Data) ->
    case maps:get(Key, Data, undefined) of
        {Value, Reason} ->
            {Key, {Value, Reason}};
        Value ->
            {Key, Value};
        _ ->
            get_rejection_reason(Rest, Data)
    end;
get_rejection_reason([], _) ->
    undefined.

-spec choose_route([hg_route:t()]) -> {hg_route:t(), route_choice_context()}.
choose_route(Routes) ->
    {ChosenScoredRoute, IdealRoute} = find_best_routes(Routes),
    RouteChoiceContext = get_route_choice_context(ChosenScoredRoute, IdealRoute),
    {ChosenScoredRoute, RouteChoiceContext}.
%%

-spec find_best_routes([hg_route:t()]) -> {Chosen :: hg_route:t(), Ideal :: hg_route:t()}.
find_best_routes([Route]) ->
    {Route, Route};
find_best_routes([First | Rest]) ->
    %% In old master, equal scores were broken by route term order.
    %% After route maps transition this is non-stable, so keep the earlier
    %% candidate explicitly when scores are equal.
    lists:foldl(
        fun(RouteIn, {CurrentRouteChosen, CurrentRouteIdeal}) ->
            NewRouteIdeal = select_better_route_ideal(CurrentRouteIdeal, RouteIn),
            NewRouteChosen = select_better_route(CurrentRouteChosen, RouteIn),
            {NewRouteChosen, NewRouteIdeal}
        end,
        {First, First},
        Rest
    ).

select_better_route_ideal(Left, Right) ->
    IdealLeft = set_ideal_score(Left),
    IdealRight = set_ideal_score(Right),
    Winner = select_better_route(IdealLeft, IdealRight),
    case hg_route:equal(Winner, IdealLeft) of
        true -> Left;
        false -> Right
    end.

set_ideal_score(Route0) ->
    Route1 = hg_route:set_availability(1, 1.0, Route0),
    hg_route:set_conversion(1, 1.0, Route1).

select_better_route(Left, Right) ->
    LeftPin = hg_route:pin_hash(Left),
    RightPin = hg_route:pin_hash(Right),
    Res =
        case {LeftPin, RightPin} of
            _ when LeftPin /= ?ZERO, RightPin /= ?ZERO, RightPin == LeftPin ->
                select_better_pinned_route(Left, Right);
            _ ->
                select_better_regular_route(Left, Right)
        end,
    Res.

select_better_pinned_route(Left, Right) ->
    %% Compare pinned siblings without the random bucket, then keep the bucket on the winner
    %% so the whole pin-group preserves its share in later pairwise comparisons.
    GroupRandomCondition = max(hg_route:weight(Left), hg_route:weight(Right)),
    LeftScore = (hg_route:score(Left))#domain_PaymentRouteScores{
        random_condition = 0,
        route_pin = erlang:phash2({
            hg_route:pin_hash(Left),
            hg_route:provider_ref(Left),
            hg_route:terminal_ref(Left)
        })
    },
    RightScore = (hg_route:score(Right))#domain_PaymentRouteScores{
        random_condition = 0,
        route_pin = erlang:phash2({
            hg_route:pin_hash(Right),
            hg_route:provider_ref(Right),
            hg_route:terminal_ref(Right)
        })
    },

    case max(LeftScore, RightScore) of
        LeftScore ->
            hg_route:set_weight(GroupRandomCondition, Left);
        RightScore ->
            hg_route:set_weight(GroupRandomCondition, Right)
    end.

select_better_regular_route(Left, Right) ->
    LeftScore = (hg_route:score(Left))#domain_PaymentRouteScores{
        route_pin = 0
    },
    RightScore = (hg_route:score(Right))#domain_PaymentRouteScores{
        route_pin = 0
    },
    case max(LeftScore, RightScore) of
        LeftScore ->
            Left;
        RightScore ->
            Right
    end.

get_route_choice_context(SameRoute, SameRoute) ->
    #{
        chosen_route => SameRoute
    };
get_route_choice_context(ChosenRoute, IdealRoute) ->
    #{
        chosen_route => ChosenRoute,
        preferable_route => IdealRoute,
        reject_reason => map_route_switch_reason(hg_route:score(ChosenRoute), hg_route:score(IdealRoute))
    }.

map_route_switch_reason(SameScores, SameScores) ->
    unknown;
map_route_switch_reason(RealScores, IdealScores) when
    is_record(RealScores, 'domain_PaymentRouteScores'); is_record(IdealScores, 'domain_PaymentRouteScores')
->
    Zipped = lists:zip(tuple_to_list(RealScores), tuple_to_list(IdealScores)),
    DifferenceIdx = find_idx_of_difference(Zipped),
    lists:nth(DifferenceIdx, record_info(fields, 'domain_PaymentRouteScores')).

find_idx_of_difference(ZippedList) ->
    find_idx_of_difference(ZippedList, 0).

find_idx_of_difference([{Same, Same} | Rest], I) ->
    find_idx_of_difference(Rest, I + 1);
find_idx_of_difference(_, I) ->
    I.

%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-spec test() -> _.

-type testcase() :: {_, fun(() -> _)}.

-define(prv(ID), #domain_ProviderRef{id = ID}).
-define(trm(ID), #domain_TerminalRef{id = ID}).

-spec pipeline_compensation_and_extension_test() -> _.
pipeline_compensation_and_extension_test() ->
    A = new_route(1, 1, 0, {1, 1.0}, {1, 1.0}),
    B = new_route(1, 2, 0, {1, 1.0}, {1, 1.0}),
    C = new_route(1, 3, 0, {1, 1.0}, {1, 1.0}),
    State = routing_ctx:new([A, B, C]),
    ?assertEqual([], routing_ctx:accounted_candidates(State)),
    Result = run(State, [
        {hold, fun(S) ->
            hold(S, limits, fun
                (R) when R =:= A -> ok;
                (R) when R =:= B -> {held, overflow};
                (_) -> {error, invalid_limit}
            end)
        end},
        {external_selection, fun(S) ->
            ?assertEqual([A], routing_ctx:candidates(S)),
            ?assertEqual([A, B], routing_ctx:accounted_candidates(S)),
            routing_ctx:set_error({quote, missing}, S)
        end},
        {after_failure, fun(S) -> routing_ctx:set_error({unexpected_step, ran}, S) end}
    ]),
    ?assertEqual({quote, missing}, routing_ctx:error(Result)),
    ?assertEqual([A, B], routing_ctx:accounted_candidates(Result)),
    ?assertEqual([overflow, invalid_limit], [hg_route:rejection_reason(R) || R <- routing_ctx:rejected_routes(Result)]).

-spec pipeline_infrastructure_error_test() -> _.
pipeline_infrastructure_error_test() ->
    Error = {woody_error, {system, result_unknown, <<"timeout">>}},
    ?assertError(
        Error,
        run(routing_ctx:new([]), [
            {hold, fun(S) ->
                case routing_ctx:candidates(S) of
                    [] -> error(Error);
                    _ -> S
                end
            end}
        ])
    ).

-spec record_comparsion_test() -> _.
record_comparsion_test() ->
    Bigger = new_route(42, 42, 0, {1, 0.5}, {1, 0.5}),
    Middle = new_route(50, 50, 0, {1, 0.1}, {1, 0.5}),
    Smaller = new_route(99, 99, 0, {0, 0.1}, {1, 0.5}),
    ?assertEqual(Bigger, select_better_route(Bigger, Smaller)),
    ?assertEqual(Middle, select_better_route(Middle, Smaller)),
    ?assertEqual(Bigger, select_better_route(Bigger, Middle)),
    ?assertMatch(
        {?trm(42), _},
        balance_and_choose_route([
            Bigger,
            Smaller
        ])
    ),
    ?assertMatch(
        {?trm(50), _},
        balance_and_choose_route([
            Middle,
            Smaller
        ])
    ),
    ?assertMatch(
        {?trm(42), _},
        balance_and_choose_route([
            Middle,
            Bigger
        ])
    ).

-spec tie_case_prefers_earlier_route_test() -> _.
tie_case_prefers_earlier_route_test() ->
    RouteFirst = new_route(1, 1, 0, {1, 1.0}, {1, 1.0}),
    RouteSecond = new_route(2, 2, 0, {1, 1.0}, {1, 1.0}),
    ?assertMatch(
        {?trm(1), _},
        balance_and_choose_route([RouteFirst, RouteSecond])
    ),
    ?assertMatch(
        {?trm(2), _},
        balance_and_choose_route([RouteSecond, RouteFirst])
    ).

-spec pin_random_test() -> _.
pin_random_test() ->
    Pin = #{email => <<"example@mail.com">>},
    Route1 = new_route(1, 1, 50, {1, 0.0}, {1, 0.0}, Pin),
    Route2 = new_route(2, 2, 50, {1, 0.0}, {1, 0.0}, Pin),
    lists:foldl(
        fun(_I, Acc) ->
            {ST, _} = Route = balance_and_choose_route([Route1, Route2]),
            case Acc of
                undefined ->
                    Route;
                {ST, _} ->
                    Route;
                _ ->
                    error({Route, Acc})
            end
        end,
        undefined,
        lists:seq(0, 1000)
    ).

-spec diff_pin_test() -> _.
diff_pin_test() ->
    Pin = #{email => <<"example@mail.com">>},
    Route1 = new_route(1, 1, 50, {1, 0.0}, {1, 0.0}, Pin),
    Route2 = new_route(1, 2, 50, {1, 0.0}, {1, 0.0}, Pin),
    Route3 = new_route(1, 3, 50, {1, 0.0}, {1, 0.0}, Pin#{client_ip => <<"IP">>}),
    {I1, I2, I3} = lists:foldl(
        fun(_I, {Iter1, Iter2, Iter3}) ->
            {ST, _} = balance_and_choose_route([Route1, Route2, Route3]),
            case ST of
                ?trm(1) ->
                    {Iter1 + 1, Iter2, Iter3};
                ?trm(2) ->
                    {Iter1, Iter2 + 1, Iter3};
                ?trm(3) ->
                    {Iter1, Iter2, Iter3 + 1}
            end
        end,
        {0, 0, 0},
        lists:seq(0, 1000)
    ),
    case {I1, I2} of
        {0, S} when S > 400 ->
            true;
        {S, 0} when S > 400 ->
            true;
        SomethingElse ->
            error({{i1, i2}, SomethingElse})
    end,
    case I3 of
        _ when I3 > 300 ->
            true;
        _ ->
            error({i3, I3})
    end.

-spec pin_weight_test() -> _.
pin_weight_test() ->
    Pin0 = #{email => <<"example@mail.com">>},
    Pin1 = #{email => <<"example1@mail.com">>},
    Route1 = new_route(1, 1, 50, {1, 0.0}, {1, 0.0}, Pin0),
    Route2 = new_route(1, 2, 50, {1, 0.0}, {1, 0.0}, Pin0),
    Route3 = new_route(1, 1, 50, {1, 0.0}, {1, 0.0}, Pin1),
    Route4 = new_route(1, 2, 50, {1, 0.0}, {1, 0.0}, Pin1),
    true = lists:foldl(
        fun(_I, _A) ->
            {BalancedRoute1, _} = balance_and_choose_route([Route1, Route2]),
            {BalancedRoute2, _} = balance_and_choose_route([Route3, Route4]),
            case true of
                _ when BalancedRoute1 == ?trm(1), BalancedRoute2 == ?trm(2) ->
                    true;
                _ ->
                    error({BalancedRoute1, BalancedRoute2})
            end
        end,
        true,
        lists:seq(0, 1000)
    ).

new_route(PNum, TNum, Weight, {ACond, AValue}, {CCond, CValue}) ->
    new_route(PNum, TNum, Weight, {ACond, AValue}, {CCond, CValue}, #{}).

new_route(PNum, TNum, Weight, {ACond, AValue}, {CCond, CValue}, Pin) ->
    Route0 = hg_route:new(
        1, ?prv(PNum), ?trm(TNum), Weight, ?DOMAIN_CANDIDATE_PRIORITY, hg_payment_route_pin:hash(Pin)
    ),
    Route1 = hg_route:set_availability(ACond, AValue, Route0),
    hg_route:set_conversion(CCond, CValue, Route1).

balance_and_choose_route(Routes0) ->
    Routes1 = hg_route_balancer:fill(Routes0),
    {Route, Ctx} = choose_route(Routes1),
    {hg_route:terminal_ref(Route), {Route, Ctx}}.

-spec filter_routes_splits_accepted_and_rejected_test() -> _.
filter_routes_splits_accepted_and_rejected_test() ->
    AcceptedRoute = new_route(1, 1, 0, {1, 1.0}, {1, 1.0}),
    RejectedByTerms = hg_route:set_accepted(
        {false, {rejected, {'ProvisionTermSet', undefined}}},
        new_route(1, 2, 0, {1, 1.0}, {1, 1.0})
    ),
    RejectedByProhibition = hg_route:set_prohibit(
        {true, <<"blocked">>},
        new_route(1, 3, 0, {1, 1.0}, {1, 1.0})
    ),
    RejectedByBlacklist = hg_route:set_blacklisted(
        1,
        new_route(1, 4, 0, {1, 1.0}, {1, 1.0})
    ),
    Result = #{
        routes => [AcceptedRoute],
        rejections => #{
            accepted => [
                hg_route:set_rejection_reason(
                    {accepted, {false, {rejected, {'ProvisionTermSet', undefined}}}}, RejectedByTerms
                )
            ],
            prohibit => [
                hg_route:set_rejection_reason({prohibit, {true, <<"blocked">>}}, RejectedByProhibition)
            ],
            blacklisted => [
                hg_route:set_rejection_reason({blacklisted, 1}, RejectedByBlacklist)
            ]
        }
    },
    ?assertMatch(
        Result,
        filter_routes(
            [AcceptedRoute, RejectedByTerms, RejectedByProhibition, RejectedByBlacklist],
            [{accepted, false}, {prohibit, true}, {blacklisted, 1}]
        )
    ).

-spec filter_keeps_prohibition_when_terms_also_fail_test() -> _.
filter_keeps_prohibition_when_terms_also_fail_test() ->
    Banned = hg_route:set_prohibit(
        {true, <<"blocked">>},
        hg_route:set_accepted(
            {false, {rejected, {'ProvisionTermSet', undefined}}},
            new_route(1, 1, 0, {1, 1.0}, {1, 1.0})
        )
    ),
    TermsOnly = hg_route:set_accepted(
        {false, {rejected, {'ProvisionTermSet', undefined}}},
        new_route(1, 2, 0, {1, 1.0}, {1, 1.0})
    ),
    Result = filter(routing_ctx:new([Banned, TermsOnly]), [
        {prohibit, true}, {blacklisted, 1}, {accepted, false}
    ]),
    ?assertEqual([], routing_ctx:candidates(Result)),
    ?assertEqual(prohibit, maps:get(latest_rejection, Result)),
    ?assertMatch(
        #{
            prohibit := [#{terminal_ref := ?trm(1), rejection_reason := {prohibit, {true, <<"blocked">>}}}],
            accepted := [#{terminal_ref := ?trm(2), rejection_reason := {accepted, {false, {rejected, _}}}}]
        },
        maps:get(rejections, Result)
    ).

-spec preferable_route_scoring_test_() -> [testcase()].
preferable_route_scoring_test_() ->
    RouteFallback0 = hg_route:new(1, ?prv(2), ?trm(99), 0, 0, 0),
    RouteFallback1 = hg_route:set_availability(1, 1.0, RouteFallback0),
    RouteFallback2 = hg_route:set_conversion(1, 1.0, RouteFallback1),
    [
        ?_assertMatch(
            {?trm(1), _},
            balance_and_choose_route([
                new_route(1, 1, 0, {1, 1.0}, {1, 1.0}),
                RouteFallback2
            ])
        ),
        ?_assertMatch(
            {?trm(3), _},
            balance_and_choose_route([
                new_route(1, 1, 0, {0, 0.6}, {0, 0.4}),
                new_route(1, 2, 0, {0, 0.6}, {0, 0.4}),
                new_route(1, 3, 0, {1, 1.0}, {1, 1.0})
            ])
        ),
        ?_assertMatch(
            {
                ?trm(99),
                {_, #{
                    preferable_route := #{terminal_ref := ?trm(1)},
                    reject_reason := availability_condition
                }}
            },
            balance_and_choose_route([
                new_route(1, 1, 0, {0, 0.6}, {0, 0.4}),
                RouteFallback2
            ])
        ),
        ?_assertMatch(
            {
                ?trm(99),
                {_, #{
                    preferable_route := #{terminal_ref := ?trm(1)},
                    reject_reason := conversion_condition
                }}
            },
            balance_and_choose_route([
                new_route(1, 1, 0, {1, 0.9}, {0, 0.2}),
                RouteFallback2
            ])
        ),
        ?_assertMatch(
            {
                ?trm(1),
                {_, #{
                    preferable_route := #{terminal_ref := ?trm(2)},
                    reject_reason := conversion
                }}
            },
            balance_and_choose_route([
                new_route(1, 2, 0, {1, 1.0}, {1, 0.9}),
                new_route(1, 1, 0, {1, 1.0}, {1, 1.0})
            ])
        ),
        ?_assertMatch(
            {
                ?trm(1),
                {_, #{
                    preferable_route := #{terminal_ref := ?trm(2)},
                    reject_reason := availability
                }}
            },
            balance_and_choose_route([
                new_route(1, 2, 0, {1, 0.9}, {1, 0.9}),
                new_route(1, 1, 0, {1, 1.0}, {1, 1.0}),
                RouteFallback2
            ])
        )
    ].

-spec prefer_priority_over_availability_test() -> _.
prefer_priority_over_availability_test() ->
    Route1 = new_route(1, 1, 0, {1, 0.7}, {1, 0.7}),
    Route2 = hg_route:set_priority(1005, new_route(2, 2, 0, {1, 0.5}, {1, 0.7})),
    Route3 = new_route(3, 3, 0, {1, 0.7}, {1, 0.7}),
    Routes = [Route1, Route2, Route3],

    ?assertMatch({?trm(2), _}, balance_and_choose_route(Routes)).

-spec prefer_priority_over_conversion_test() -> _.
prefer_priority_over_conversion_test() ->
    Route1 = new_route(1, 1, 0, {1, 0.7}, {1, 0.7}),
    Route2 = hg_route:set_priority(1005, new_route(2, 2, 0, {1, 0.7}, {1, 0.5})),
    Route3 = new_route(3, 3, 0, {1, 0.7}, {1, 0.7}),
    Routes = [Route1, Route2, Route3],

    ?assertMatch({?trm(2), _}, balance_and_choose_route(Routes)).

-spec balance_surviving_routes_test() -> _.
balance_surviving_routes_test() ->
    A = hg_route:set_prohibit(true, hg_route:new(1, ?prv(1), ?trm(1), 50, 0, 0)),
    B = hg_route:new(1, ?prv(2), ?trm(2), 25, 0, 0),
    C = hg_route:new(1, ?prv(3), ?trm(3), 25, 0, 0),
    _ = rand:seed(exsss, {31, 41, 59}),
    Chosen = lists:map(
        fun(_) ->
            #{routes := Survivors} = filter_routes([A, B, C], [{prohibit, true}]),
            {Route, _} = choose_route(hg_route_balancer:fill(Survivors)),
            hg_route:terminal_ref(Route)
        end,
        lists:seq(1, 1000)
    ),
    ?assertNot(lists:member(?trm(1), Chosen)),
    ?assert(abs(length([T || T <- Chosen, T =:= ?trm(2)]) - 500) < 80).

-endif.
