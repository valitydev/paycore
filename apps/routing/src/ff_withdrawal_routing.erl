-module(ff_withdrawal_routing).

-behaviour(hg_routing_domain).

-export([compute_ruleset/3]).
-export([resolve_terminal/2]).
-export([validate_candidate/1]).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([prepare_routes/2]).
-export([prepare_routes/3]).
-export([gather_routes/2]).
-export([gather_routes/3]).
-export([filter_limit_overflow_routes/3]).
-export([rollback_routes_limits/3]).
-export([commit_routes_limits/3]).
-export([make_route/2]).
-export([get_provider/1]).
-export([get_terminal/1]).
-export([routes/1]).
-export([select_routes/1]).
-export([get_routes/1]).
-export([accounted_candidates/1]).
-export([log_reject_context/1]).

-import(ff_pipeline, [do/1, unwrap/1]).

-type route() :: #{
    version := 1,
    provider_id := provider_id(),
    terminal_id := terminal_id(),
    provider_id_legacy => provider_id()
}.

-type routing_context() :: #{
    domain_revision := domain_revision(),
    wallet := wallet(),
    iteration := pos_integer(),
    withdrawal => withdrawal()
}.

-type routing_state() :: #{
    routes := [routing_rule_route()],
    reject_context := reject_context(),
    accounted => [route()]
}.

-type rejected_route() :: {provider_ref(), terminal_ref(), Reason :: term()}.

-type route_not_found() :: {route_not_found, [rejected_route()]}.

-export_type([route/0]).
-export_type([routing_context/0]).
-export_type([route_not_found/0]).
-export_type([rejected_route/0]).

-type wallet() :: ff_party:wallet().
-type withdrawal() :: ff_withdrawal:withdrawal_state().
-type domain_revision() :: ff_domain_config:revision().
-type party_varset() :: ff_varset:varset().

-type provider_id() :: ff_payouts_provider:id().
-type terminal_id() :: ff_payouts_terminal:id().
-type provider_ref() :: dmsl_domain_thrift:'ProviderRef'().
-type terminal_ref() :: dmsl_domain_thrift:'TerminalRef'().

-type routing_rule_route() :: hg_route:t().

-type reject_context() :: #{
    varset := party_varset(),
    accepted_routes := [routing_rule_route()],
    rejected_routes := [rejected_route()]
}.

-type withdrawal_provision_terms() :: dmsl_domain_thrift:'WithdrawalProvisionTerms'().
-type currency_selector() :: dmsl_domain_thrift:'CurrencySelector'().
-type cash_limit_selector() :: dmsl_domain_thrift:'CashLimitSelector'().
-type turnover_limit_selector() :: dmsl_domain_thrift:'TurnoverLimitSelector'().
-type process_route_fun() :: fun(
    (withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
        ok
        | {ok, valid}
        | {held, Error :: term()}
        | {error, Error :: term()}
).

%%

-spec prepare_routes(party_varset(), wallet(), domain_revision()) ->
    {ok, [route()]} | {error, route_not_found()}.
prepare_routes(PartyVarset, Wallet, DomainRevision) ->
    prepare_routes(PartyVarset, #{wallet => Wallet, domain_revision => DomainRevision, iteration => 1}).

-spec prepare_routes(party_varset(), routing_context()) ->
    {ok, [route()]} | {error, route_not_found()}.
prepare_routes(PartyVarset, Context) ->
    State = gather_routes(PartyVarset, Context),
    log_reject_context(State),
    select_routes(State).

-spec gather_routes(party_varset(), routing_context()) ->
    routing_state().
gather_routes(PartyVarset, Context) ->
    gather_routes(PartyVarset, Context, []).

-spec gather_routes(party_varset(), routing_context(), [terminal_id()]) ->
    routing_state().
gather_routes(PartyVarset, #{wallet := Wallet, domain_revision := DomainRevision} = Context, ExcludeRoutes) ->
    #domain_WalletConfig{payment_institution = PaymentInstitutionRef} = Wallet,
    {ok, PaymentInstitution} = ff_payment_institution:get(PaymentInstitutionRef, PartyVarset, DomainRevision),
    RoutingRules = maps:get(withdrawal_routing_rules, PaymentInstitution),
    CollectorResult = hg_route_collector:get_routes(
        DomainRevision,
        PartyVarset,
        RoutingRules,
        ?MODULE
    ),
    case maps:get(error, CollectorResult, undefined) of
        {misconfiguration, Reason} ->
            logger:warning("Routing rule misconfiguration. Reason:~n~p~nVarset:~n~p", [Reason, PartyVarset]),
            #{
                routes => [],
                reject_context => new_reject_context(PartyVarset)
            };
        undefined ->
            #{routes := Collected} = CollectorResult,
            {Accepted, Rejected} = split_prohibited(Collected),
            RejectContext = (new_reject_context(PartyVarset))#{
                accepted_routes => Accepted,
                rejected_routes => Rejected
            },
            State = exclude_routes(#{routes => Accepted, reject_context => RejectContext}, ExcludeRoutes),
            filter_valid_routes(State, PartyVarset, Context)
    end.

-spec filter_limit_overflow_routes(routing_state(), party_varset(), routing_context()) ->
    routing_state().
filter_limit_overflow_routes(#{routes := Routes, reject_context := RejectContext}, PartyVarset, RoutingContext) ->
    State = lists:foldl(
        fun(Route, #{routes := Valid, reject_context := RC, accounted := Acc} = St) ->
            ProviderRef = maps:get(provider_ref, Route),
            TerminalRef = maps:get(terminal_ref, Route),
            EventRoute = make_route(ProviderRef#domain_ProviderRef.id, TerminalRef#domain_TerminalRef.id),
            case
                get_route_terms_and_process(
                    fun do_validate_limits/4, ProviderRef, TerminalRef, PartyVarset, RoutingContext
                )
            of
                {ok, valid} ->
                    St#{
                        routes => [Route | Valid],
                        accounted => [EventRoute | Acc]
                    };
                {held, RejectReason} ->
                    Rejected = maps:get(rejected_routes, RC),
                    St#{
                        accounted => [EventRoute | Acc],
                        reject_context => RC#{
                            rejected_routes => [{ProviderRef, TerminalRef, RejectReason} | Rejected]
                        }
                    };
                {error, RejectReason} ->
                    Rejected = maps:get(rejected_routes, RC),
                    St#{
                        reject_context => RC#{
                            rejected_routes => [{ProviderRef, TerminalRef, RejectReason} | Rejected]
                        }
                    }
            end
        end,
        #{routes => [], reject_context => RejectContext, accounted => []},
        Routes
    ),
    State#{routes := lists:reverse(maps:get(routes, State))}.

-spec accounted_candidates(routing_state()) -> [route()].
accounted_candidates(#{accounted := Accounted}) ->
    Accounted;
accounted_candidates(_) ->
    [].

-spec rollback_routes_limits([route()], party_varset(), routing_context()) ->
    ok.
rollback_routes_limits(Routes, PartyVarset, RoutingContext) ->
    process_routes_with(
        fun do_rollback_limits/4,
        Routes,
        PartyVarset,
        RoutingContext
    ).

-spec commit_routes_limits([route()], party_varset(), routing_context()) ->
    ok.
commit_routes_limits(Routes, PartyVarset, RoutingContext) ->
    process_routes_with(
        fun do_commit_limits/4,
        Routes,
        PartyVarset,
        RoutingContext
    ).

-spec make_route(provider_id(), terminal_id() | undefined) -> route().
make_route(ProviderID, TerminalID) ->
    genlib_map:compact(#{
        version => 1,
        provider_id => ProviderID,
        terminal_id => TerminalID
    }).

-spec get_provider(route()) -> provider_id().
get_provider(#{provider_id := ProviderID}) ->
    ProviderID.

-spec get_terminal(route()) -> terminal_id().
get_terminal(#{terminal_id := TerminalID}) ->
    TerminalID.

-spec routes(routing_state()) ->
    {ok, [route()]} | {error, route_not_found()}.
routes(#{routes := Routes = [_ | _]}) ->
    {ok, sort_routes(Routes)};
routes(#{
    routes := _Routes,
    reject_context := #{
        varset := _Varset,
        accepted_routes := _Accepted,
        rejected_routes := Rejected
    }
}) ->
    {error, {route_not_found, Rejected}}.

-spec select_routes(routing_state()) -> {ok, [route()]} | {error, route_not_found()}.
select_routes(#{routes := []} = State) ->
    routes(State);
select_routes(#{routes := Routes}) ->
    choose_balanced(Routes).

-spec get_routes(routing_state()) ->
    [route()].
get_routes(#{routes := Routes}) ->
    [hg_route:to_withdrawal_route(Route) || Route <- Routes].

choose_balanced(Routes) ->
    Balanced = hg_route_balancer:fill(Routes),
    {Chosen, _Ctx} = hg_routing:choose_route(Balanced),
    {ok, [hg_route:to_withdrawal_route(Chosen)]}.

-spec sort_routes([routing_rule_route()]) -> [route()].
sort_routes(RoutingRuleRoutes) ->
    ProviderTerminalMap = lists:foldl(
        fun(Route, Acc0) ->
            ProviderRef = hg_route:provider_ref(Route),
            TerminalRef = hg_route:terminal_ref(Route),
            Priority = hg_route:priority(Route),
            TerminalID = TerminalRef#domain_TerminalRef.id,
            ProviderID = ProviderRef#domain_ProviderRef.id,
            AccRoutes = maps:get(Priority, Acc0, []),
            Acc1 = maps:put(Priority, [{ProviderID, TerminalID} | AccRoutes], Acc0),
            Acc1
        end,
        #{},
        RoutingRuleRoutes
    ),
    lists:foldl(
        fun({_, Data}, Acc) ->
            SortedRoutes = [make_route(P, T) || {P, T} <- lists:sort(Data)],
            SortedRoutes ++ Acc
        end,
        [],
        lists:keysort(1, maps:to_list(ProviderTerminalMap))
    ).

-spec log_reject_context(routing_state()) ->
    ok.
log_reject_context(#{reject_context := RejectContext}) ->
    _ = logger:log(
        info,
        "Routing reject context: rejected routes: ~p, accepted routes: ~p, varset: ~p",
        [
            maps:get(rejected_routes, RejectContext),
            maps:get(accepted_routes, RejectContext),
            maps:get(varset, RejectContext)
        ],
        logger:get_process_metadata()
    ),
    ok.

%%

-spec compute_ruleset(dmsl_domain_thrift:'RoutingRulesetRef'(), party_varset(), domain_revision()) ->
    {ok, dmsl_domain_thrift:'RoutingRuleset'()}.
compute_ruleset(RulesetRef, VS, Revision) ->
    case ff_party:compute_routing_ruleset(RulesetRef, VS, Revision) of
        {ok, Ruleset} ->
            {ok, Ruleset};
        {error, ruleset_not_found} ->
            throw({misconfiguration, {ruleset, RulesetRef, not_found}})
    end.

-spec resolve_terminal(terminal_ref(), domain_revision()) -> {ok, provider_ref()} | {error, notfound}.
resolve_terminal(TerminalRef, Revision) ->
    case ff_domain_config:object(Revision, {terminal, TerminalRef}) of
        {ok, #domain_Terminal{provider_ref = ProviderRef}} ->
            {ok, ProviderRef};
        {error, notfound} ->
            {error, notfound}
    end.

-spec validate_candidate(dmsl_domain_thrift:'RoutingCandidate'()) -> ok | no_return().
validate_candidate(#domain_RoutingCandidate{allowed = {constant, Allowed}}) when is_boolean(Allowed) ->
    ok;
validate_candidate(Candidate) ->
    throw({misconfiguration, {routing_candidate, Candidate}}).

new_reject_context(VS) ->
    #{
        varset => VS,
        accepted_routes => [],
        rejected_routes => []
    }.

split_prohibited(Routes) ->
    #{routes := Accepted, rejections := Rejections} = hg_routing:filter(Routes, [{prohibit, true}]),
    Rejected = [
        {hg_route:provider_ref(Route), hg_route:terminal_ref(Route), prohibit_reason(Route)}
     || Route <- maps:get(prohibit, Rejections, [])
    ],
    {Accepted, Rejected}.

prohibit_reason(Route) ->
    case hg_route:rejection_reason(Route) of
        {prohibit, {true, Description}} ->
            Description;
        _Other ->
            {'RoutingRule', undefined}
    end.

-spec filter_valid_routes(routing_state(), party_varset(), routing_context()) ->
    routing_state().
filter_valid_routes(State, PartyVarset, RoutingContext) ->
    validate_routes_with(
        fun do_validate_terms/4,
        State,
        PartyVarset,
        RoutingContext
    ).

-spec process_routes_with(process_route_fun(), [route()], party_varset(), routing_context()) ->
    ok.
process_routes_with(Func, Routes, PartyVarset, RoutingContext) ->
    lists:foreach(
        fun(Route) ->
            ProviderID = maps:get(provider_id, Route),
            TerminalID = maps:get(terminal_id, Route),
            ProviderRef = #domain_ProviderRef{id = ProviderID},
            TerminalRef = #domain_TerminalRef{id = TerminalID},
            case get_route_terms_and_process(Func, ProviderRef, TerminalRef, PartyVarset, RoutingContext) of
                ok ->
                    ok;
                {ok, _} ->
                    ok;
                {error, Reason} ->
                    %% accounted hold already exists; skip would leave a reserve
                    erlang:error({route_terms, Reason});
                Unexpected ->
                    erlang:error({route_terms, Unexpected})
            end
        end,
        Routes
    ).

-spec validate_routes_with(
    process_route_fun(), routing_state(), party_varset(), routing_context()
) ->
    routing_state().
validate_routes_with(Func, #{routes := Routes, reject_context := RejectContext}, PartyVarset, RoutingContext) ->
    lists:foldl(
        fun(Route, #{routes := ValidRoutes0, reject_context := RejectContext0} = State) ->
            ProviderRef = maps:get(provider_ref, Route),
            TerminalRef = maps:get(terminal_ref, Route),
            case get_route_terms_and_process(Func, ProviderRef, TerminalRef, PartyVarset, RoutingContext) of
                {ok, valid} ->
                    ValidRoutes1 = [Route | ValidRoutes0],
                    State#{routes => ValidRoutes1};
                {error, RejectReason} ->
                    RejectedRoutes0 = maps:get(rejected_routes, RejectContext0),
                    RejectedRoutes1 = [{ProviderRef, TerminalRef, RejectReason} | RejectedRoutes0],
                    RejectContext1 = maps:put(rejected_routes, RejectedRoutes1, RejectContext0),
                    State#{reject_context => RejectContext1}
            end
        end,
        #{routes => [], reject_context => RejectContext},
        Routes
    ).

get_route_terms_and_process(
    Func, ProviderRef, TerminalRef, PartyVarset, #{domain_revision := DomainRevision} = RoutingContext
) ->
    case ff_party:compute_provider_terminal_terms(ProviderRef, TerminalRef, PartyVarset, DomainRevision) of
        {ok, #domain_ProvisionTermSet{
            wallet = #domain_WalletProvisionTerms{
                withdrawals = WithdrawalProvisionTerms
            }
        }} when WithdrawalProvisionTerms =/= undefined ->
            Route = make_route(ProviderRef#domain_ProviderRef.id, TerminalRef#domain_TerminalRef.id),
            Func(WithdrawalProvisionTerms, PartyVarset, Route, RoutingContext);
        {ok, _} ->
            {error, {'WithdrawalProvisionTerms', not_found}};
        {error, Error} ->
            {error, Error}
    end.

exclude_routes(#{routes := Routes, reject_context := RejectContext}, ExcludeRoutes) ->
    lists:foldl(
        fun(Route, #{routes := ValidRoutes0, reject_context := RejectContext0} = State) ->
            ProviderRef = maps:get(provider_ref, Route),
            TerminalRef = maps:get(terminal_ref, Route),
            TerminalID = TerminalRef#domain_TerminalRef.id,
            case not lists:member(TerminalID, ExcludeRoutes) of
                true ->
                    ValidRoutes1 = [Route | ValidRoutes0],
                    State#{routes => ValidRoutes1};
                false ->
                    RejectedRoutes0 = maps:get(rejected_routes, RejectContext0),
                    RejectedRoutes1 = [{ProviderRef, TerminalRef, member_of_exclude_list} | RejectedRoutes0],
                    RejectContext1 = maps:put(rejected_routes, RejectedRoutes1, RejectContext0),
                    State#{reject_context => RejectContext1}
            end
        end,
        #{routes => [], reject_context => RejectContext},
        Routes
    ).

-spec do_rollback_limits(withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
    ok.
do_rollback_limits(CombinedTerms, _PartyVarset, Route, #{withdrawal := Withdrawal, iteration := Iter}) ->
    #domain_WithdrawalProvisionTerms{
        turnover_limit = TurnoverLimit
    } = CombinedTerms,
    Limits = ff_limiter:get_turnover_limits(TurnoverLimit),
    ff_limiter:rollback_withdrawal_limits(Limits, Withdrawal, Route, Iter).

-spec do_commit_limits(withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
    ok.
do_commit_limits(CombinedTerms, _PartyVarset, Route, #{withdrawal := Withdrawal, iteration := Iter}) ->
    #domain_WithdrawalProvisionTerms{
        turnover_limit = TurnoverLimit
    } = CombinedTerms,
    Limits = ff_limiter:get_turnover_limits(TurnoverLimit),
    ff_limiter:commit_withdrawal_limits(Limits, Withdrawal, Route, Iter).

-spec do_validate_limits(withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
    {ok, valid}
    | {held, Error :: term()}
    | {error, Error :: term()}.
do_validate_limits(CombinedTerms, PartyVarset, Route, RoutingContext) ->
    #domain_WithdrawalProvisionTerms{
        turnover_limit = TurnoverLimits
    } = CombinedTerms,
    validate_turnover_limits(TurnoverLimits, PartyVarset, Route, RoutingContext).

-spec do_validate_terms(withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
    {ok, valid}
    | {error, Error :: term()}.
do_validate_terms(CombinedTerms, PartyVarset, _Route, _RoutingContext) ->
    do(fun() ->
        #domain_WithdrawalProvisionTerms{
            allow = Allow,
            global_allow = GAllow,
            currencies = CurrenciesSelector,
            cash_limit = CashLimitSelector
        } = CombinedTerms,
        valid = unwrap(validate_selectors_defined(CombinedTerms)),
        valid = unwrap(validate_allow(global_allow, GAllow)),
        valid = unwrap(validate_allow(allow, Allow)),
        valid = unwrap(validate_currencies(CurrenciesSelector, PartyVarset)),
        valid = unwrap(validate_cash_limit(CashLimitSelector, PartyVarset))
    end).

-spec validate_selectors_defined(withdrawal_provision_terms()) ->
    {ok, valid}
    | {error, Error :: term()}.
validate_selectors_defined(Terms) ->
    Selectors = [
        Terms#domain_WithdrawalProvisionTerms.currencies,
        Terms#domain_WithdrawalProvisionTerms.cash_limit,
        Terms#domain_WithdrawalProvisionTerms.cash_flow
    ],
    case lists:any(fun(Selector) -> Selector =:= undefined end, Selectors) of
        false ->
            {ok, valid};
        true ->
            {error, terms_undefined}
    end.

validate_allow(Type, Constant) ->
    case Constant of
        undefined ->
            {ok, valid};
        {constant, true} ->
            {ok, valid};
        {constant, false} ->
            {error, {terms_violation, terminal_forbidden}};
        Ambiguous ->
            {error, {misconfiguration, {'Could not reduce predicate to a value', {Type, Ambiguous}}}}
    end.

-spec validate_currencies(currency_selector(), party_varset()) ->
    {ok, valid}
    | {error, Error :: term()}.
validate_currencies({value, Currencies}, #{currency := CurrencyRef}) ->
    case ordsets:is_element(CurrencyRef, Currencies) of
        true ->
            {ok, valid};
        false ->
            {error, {terms_violation, {not_allowed_currency, {CurrencyRef, Currencies}}}}
    end;
validate_currencies(_NotReducedSelector, _VS) ->
    {error, {misconfiguration, {not_reduced_termset, currencies}}}.

-spec validate_cash_limit(cash_limit_selector(), party_varset()) ->
    {ok, valid}
    | {error, Error :: term()}.
validate_cash_limit({value, CashRange}, #{cost := Cash}) ->
    case ff_range:is_inside(Cash, CashRange) of
        within ->
            {ok, valid};
        _NotInRange ->
            {error, {terms_violation, {cash_range, {Cash, CashRange}}}}
    end;
validate_cash_limit(_NotReducedSelector, _VS) ->
    {error, {misconfiguration, {not_reduced_termset, cash_range}}}.

-spec validate_turnover_limits(turnover_limit_selector(), party_varset(), route(), routing_context()) ->
    {ok, valid}
    | {held, Error :: term()}
    | {error, Error :: term()}.
validate_turnover_limits(undefined, _VS, _Route, _RoutingContext) ->
    {ok, valid};
validate_turnover_limits({value, TurnoverLimits}, _VS, Route, #{withdrawal := Withdrawal, iteration := Iter}) ->
    try
        ok = ff_limiter:hold_withdrawal_limits(TurnoverLimits, Withdrawal, Route, Iter),
        case ff_limiter:check_limits(TurnoverLimits, Withdrawal, Route, Iter) of
            {ok, _} ->
                {ok, valid};
            {error, Error} ->
                {held, {terms_violation, Error}}
        end
    catch
        error:(#limiter_InvalidOperationCurrency{} = LimitError) ->
            {error, {limit_hold_error, LimitError}};
        error:(#limiter_OperationContextNotSupported{} = LimitError) ->
            {error, {limit_hold_error, LimitError}};
        error:(#limiter_PaymentToolNotSupported{} = LimitError) ->
            {error, {limit_hold_error, LimitError}}
    end;
validate_turnover_limits(NotReducedSelector, _VS, _Route, _RoutingContext) ->
    {error, {misconfiguration, {'Could not reduce selector to a value', NotReducedSelector}}}.

%% TESTS

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec convert_to_route_test() -> _.
convert_to_route_test() ->
    ?assertEqual(
        [],
        sort_routes([])
    ),
    ?assertEqual(
        [
            #{provider_id => 100, terminal_id => 2000, version => 1},
            #{provider_id => 100, terminal_id => 2001, version => 1},
            #{provider_id => 200, terminal_id => 2100, version => 1},
            #{provider_id => 200, terminal_id => 2101, version => 1},
            #{provider_id => 300, terminal_id => 2200, version => 1}
        ],
        sort_routes([
            hg_route:new(1, #domain_ProviderRef{id = 100}, #domain_TerminalRef{id = 2000}, 0, 1000, 0),
            hg_route:new(1, #domain_ProviderRef{id = 100}, #domain_TerminalRef{id = 2001}, 0, 1000, 0),
            hg_route:new(1, #domain_ProviderRef{id = 200}, #domain_TerminalRef{id = 2100}, 0, 900, 0),
            hg_route:new(1, #domain_ProviderRef{id = 200}, #domain_TerminalRef{id = 2101}, 0, 900, 0),
            hg_route:new(1, #domain_ProviderRef{id = 300}, #domain_TerminalRef{id = 2200}, 0, 100, 0)
        ])
    ).

-spec select_routes_test_() -> [_].
select_routes_test_() ->
    A = hg_route:new(1, #domain_ProviderRef{id = 1}, #domain_TerminalRef{id = 1}, 0, 1000, 0),
    B = hg_route:new(1, #domain_ProviderRef{id = 2}, #domain_TerminalRef{id = 2}, 100, 1000, 0),
    RA = make_route(1, 1),
    RB = make_route(2, 2),
    Cases = [
        {"weights within one priority", [A, B], {ok, [RB]}},
        {"priority before weight", [A, hg_route:set_priority(900, B)], {ok, [RA]}},
        {"zero weights choose the first candidate", [hg_route:set_weight(0, B), A], {ok, [RB]}}
    ],
    [
        {Name,
            ?_assertEqual(
                Expected,
                select_routes(
                    #{
                        routes => Routes,
                        reject_context => #{varset => #{}, accepted_routes => Routes, rejected_routes => []}
                    }
                )
            )}
     || {Name, Routes, Expected} <- Cases
    ].

-spec prepare_routes_uses_weights_test() -> _.
prepare_routes_uses_weights_test() ->
    Modules = [ff_payment_institution, ff_party, hg_route_collector, ff_limiter],
    ok = meck:new(Modules, [passthrough]),
    try
        Currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>},
        Cash = #domain_Cash{amount = 100, currency = Currency},
        Wallet = #domain_WalletConfig{
            name = <<"wallet">>,
            block = {unblocked, #domain_Unblocked{reason = <<>>, since = <<"1970-01-01T00:00:00Z">>}},
            suspension = {active, #domain_Active{since = <<"1970-01-01T00:00:00Z">>}},
            payment_institution = #domain_PaymentInstitutionRef{id = 1},
            terms = #domain_TermSetHierarchyRef{id = 1},
            account = #domain_WalletAccount{currency = Currency, settlement = 1},
            party_ref = #domain_PartyConfigRef{id = <<"party">>}
        },
        A = hg_route:new(1, #domain_ProviderRef{id = 1}, #domain_TerminalRef{id = 1}, 0, 1000, 0),
        B = hg_route:new(1, #domain_ProviderRef{id = 2}, #domain_TerminalRef{id = 2}, 100, 1000, 0),
        ok = meck:expect(ff_payment_institution, get, 3, {ok, #{withdrawal_routing_rules => undefined}}),
        ok = meck:expect(hg_route_collector, get_routes, 4, #{routes => [A, B]}),
        ok = meck:expect(
            ff_party,
            compute_provider_terminal_terms,
            4,
            {ok, #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        currencies = {value, [Currency]},
                        cash_limit = {value, #domain_CashRange{lower = {inclusive, Cash}, upper = {inclusive, Cash}}},
                        cash_flow = {value, []}
                    }
                }
            }}
        ),
        ?assertEqual({ok, [make_route(2, 2)]}, prepare_routes(#{currency => Currency, cost => Cash}, Wallet, 1)),
        ?assertEqual(0, meck:num_calls(ff_limiter, hold_withdrawal_limits, '_'))
    after
        ok = meck:unload(Modules)
    end.

-endif.
