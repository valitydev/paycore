-module(ff_withdrawal_routing).

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
-export([select_routes/2]).
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

-type routing_rule_route() :: #{
    provider_ref := provider_ref(),
    terminal_ref := terminal_ref(),
    priority := integer(),
    weight := integer()
}.

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

-type select_opts() :: #{
    has_quote => boolean(),
    domain_revision => domain_revision()
}.

-export_type([select_opts/0]).

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
    routes(State).

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
        collector_callbacks()
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
    lists:foldl(
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
    ).

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

-spec select_routes(routing_state(), select_opts()) ->
    {ok, [route()]} | {error, route_not_found() | {misconfiguration, term()}}.
select_routes(#{routes := []} = State, _Opts) ->
    routes(State);
select_routes(#{routes := Routes} = State, Opts) ->
    HasQuote = maps:get(has_quote, Opts, false),
    case {HasQuote, balancer_enabled(), has_negative_weight(Routes), all_zero_weights(Routes)} of
        {true, _, _, _} ->
            routes(State);
        {false, false, _, _} ->
            routes(State);
        {false, true, true, _} ->
            {error, {misconfiguration, {negative_weight, Routes}}};
        {false, true, false, true} ->
            routes(State);
        {false, true, false, false} ->
            choose_balanced(Routes, maps:get(domain_revision, Opts))
    end.

-spec get_routes(routing_state()) ->
    [route()].
get_routes(#{routes := Routes}) ->
    [
        make_route(P, T)
     || #{
            provider_ref := #domain_ProviderRef{id = P},
            terminal_ref := #domain_TerminalRef{id = T}
        } <- Routes
    ].

balancer_enabled() ->
    genlib_app:env(ff_transfer, withdrawal_route_balancer, false) =:= true.

has_negative_weight(Routes) ->
    lists:any(
        fun(#{weight := Weight}) -> is_integer(Weight) andalso Weight < 0 end,
        Routes
    ).

all_zero_weights(Routes) ->
    lists:all(
        fun(#{weight := Weight}) -> Weight =:= 0 end,
        Routes
    ).

choose_balanced(Routes, Revision) ->
    HgRoutes = [to_hg_route(Route, Revision) || Route <- Routes],
    Balanced = hg_route_balancer:fill(HgRoutes),
    {Chosen, _Ctx} = hg_routing:choose_route(Balanced),
    {ok, [from_hg_route(Chosen)]}.

to_hg_route(
    #{
        provider_ref := ProviderRef,
        terminal_ref := TerminalRef,
        weight := Weight,
        priority := Priority
    },
    Revision
) ->
    hg_route:new(Revision, ProviderRef, TerminalRef, Weight, Priority, #{}).

from_hg_route(Route) ->
    #domain_ProviderRef{id = ProviderID} = hg_route:provider_ref(Route),
    #domain_TerminalRef{id = TerminalID} = hg_route:terminal_ref(Route),
    make_route(ProviderID, TerminalID).

-spec sort_routes([routing_rule_route()]) -> [route()].
sort_routes(RoutingRuleRoutes) ->
    ProviderTerminalMap = lists:foldl(
        fun(#{provider_ref := ProviderRef, terminal_ref := TerminalRef, priority := Priority}, Acc0) ->
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

collector_callbacks() ->
    #{
        compute_ruleset => fun compute_ruleset/3,
        resolve_terminal => fun resolve_terminal/2,
        allowed_policy => withdrawal_legacy
    }.

compute_ruleset(RulesetRef, VS, Revision) ->
    case ff_party:compute_routing_ruleset(RulesetRef, VS, Revision) of
        {ok, Ruleset} ->
            {ok, Ruleset};
        {error, ruleset_not_found} ->
            throw({misconfiguration, {ruleset, RulesetRef, not_found}})
    end.

resolve_terminal(TerminalRef, Revision) ->
    case ff_domain_config:object(Revision, {terminal, TerminalRef}) of
        {ok, #domain_Terminal{provider_ref = ProviderRef}} ->
            {ok, ProviderRef};
        {error, notfound} ->
            {error, notfound}
    end.

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
    {[from_collector_route(Route) || Route <- Accepted], Rejected}.

prohibit_reason(Route) ->
    case hg_route:rejection_reason(Route) of
        {prohibit, {true, Description}} ->
            Description;
        _Other ->
            {'RoutingRule', undefined}
    end.

from_collector_route(Route) ->
    #{
        provider_ref => hg_route:provider_ref(Route),
        terminal_ref => hg_route:terminal_ref(Route),
        priority => hg_route:priority(Route),
        weight => weight_or_zero(hg_route:weight(Route))
    }.

weight_or_zero(Weight) ->
    Weight.

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
            #{
                provider_ref => #domain_ProviderRef{id = 100},
                terminal_ref => #domain_TerminalRef{id = 2000},
                priority => 1000,
                weight => 0
            },
            #{
                provider_ref => #domain_ProviderRef{id = 100},
                terminal_ref => #domain_TerminalRef{id = 2001},
                priority => 1000,
                weight => 0
            },
            #{
                provider_ref => #domain_ProviderRef{id = 200},
                terminal_ref => #domain_TerminalRef{id = 2100},
                priority => 900,
                weight => 0
            },
            #{
                provider_ref => #domain_ProviderRef{id = 200},
                terminal_ref => #domain_TerminalRef{id = 2101},
                priority => 900,
                weight => 0
            },
            #{
                provider_ref => #domain_ProviderRef{id = 300},
                terminal_ref => #domain_TerminalRef{id = 2200},
                priority => 100,
                weight => 0
            }
        ])
    ).

-spec withdrawal_balancer_disabled_sort_test() -> _.
withdrawal_balancer_disabled_sort_test() ->
    with_balancer_flag(
        false,
        fun() ->
            with_chooser_mocks(fun() ->
                State = test_select_state([
                    test_rule_route(2, 20, 1000, 100),
                    test_rule_route(1, 10, 1000, 1)
                ]),
                {ok, Chosen} = select_routes(State, #{has_quote => false, domain_revision => 1}),
                ?assertEqual(
                    [
                        #{provider_id => 1, terminal_id => 10, version => 1},
                        #{provider_id => 2, terminal_id => 20, version => 1}
                    ],
                    Chosen
                ),
                ?assertEqual(0, meck:num_calls(hg_route_balancer, fill, '_')),
                ?assertEqual(0, meck:num_calls(hg_routing, choose_route, '_'))
            end)
        end
    ).

-spec withdrawal_balancer_all_zero_weights_test() -> _.
withdrawal_balancer_all_zero_weights_test() ->
    with_balancer_flag(
        true,
        fun() ->
            with_chooser_mocks(fun() ->
                State = test_select_state([
                    test_rule_route(2, 2, 900, 0),
                    test_rule_route(1, 1, 1000, 0),
                    test_rule_route(1, 2, 1000, 0)
                ]),
                {ok, Chosen} = select_routes(State, #{has_quote => false, domain_revision => 1}),
                ?assertEqual(
                    [
                        #{provider_id => 1, terminal_id => 1, version => 1},
                        #{provider_id => 1, terminal_id => 2, version => 1},
                        #{provider_id => 2, terminal_id => 2, version => 1}
                    ],
                    Chosen
                ),
                ?assertEqual(0, meck:num_calls(hg_route_balancer, fill, '_')),
                ?assertEqual(0, meck:num_calls(hg_routing, choose_route, '_'))
            end)
        end
    ).

-spec withdrawal_balancer_quote_keeps_sort_test() -> _.
withdrawal_balancer_quote_keeps_sort_test() ->
    with_balancer_flag(
        true,
        fun() ->
            with_chooser_mocks(fun() ->
                State = test_select_state([
                    test_rule_route(2, 20, 1000, 100),
                    test_rule_route(1, 10, 1000, 1)
                ]),
                {ok, Chosen} = select_routes(State, #{has_quote => true, domain_revision => 1}),
                ?assertEqual(
                    [
                        #{provider_id => 1, terminal_id => 10, version => 1},
                        #{provider_id => 2, terminal_id => 20, version => 1}
                    ],
                    Chosen
                ),
                ?assertEqual(0, meck:num_calls(hg_route_balancer, fill, '_')),
                ?assertEqual(0, meck:num_calls(hg_routing, choose_route, '_'))
            end)
        end
    ).

-spec withdrawal_balancer_enabled_after_filters_test() -> _.
withdrawal_balancer_enabled_after_filters_test() ->
    with_balancer_flag(
        true,
        fun() ->
            with_collector_mocks(
                fun weighted_compute/3,
                fun default_resolve/2,
                fun limited_terms/4,
                fun() ->
                    meck:expect(ff_limiter, hold_withdrawal_limits, fun(_, _, _, _) -> ok end),
                    meck:expect(ff_limiter, check_limits, fun(_, _, _, _) -> {ok, []} end),
                    Context = (test_context())#{withdrawal => ff_withdrawal:test_withdrawal_state()},
                    Gathered = gather_routes(test_varset(), Context),
                    ?assertEqual(0, meck:num_calls(hg_route_balancer, fill, '_')),
                    ?assertEqual(0, meck:num_calls(hg_routing, choose_route, '_')),
                    Overflow = filter_limit_overflow_routes(Gathered, test_varset(), Context),
                    ?assertEqual(0, meck:num_calls(hg_route_balancer, fill, '_')),
                    ?assertEqual(0, meck:num_calls(hg_routing, choose_route, '_')),
                    Result = select_routes(Overflow, #{has_quote => false, domain_revision => 1}),
                    ?assertMatch({ok, [_]}, Result),
                    ?assertEqual(1, meck:num_calls(hg_route_balancer, fill, '_')),
                    ?assertEqual(1, meck:num_calls(hg_routing, choose_route, '_'))
                end
            )
        end
    ).

-spec withdrawal_balancer_weights_test() -> _.
withdrawal_balancer_weights_test() ->
    with_balancer_flag(
        true,
        fun() ->
            with_chooser_mocks(fun() ->
                _ = rand:seed(exsss, {1, 2, 3}),
                ZeroKept = test_select_state([
                    test_rule_route(1, 1, 1000, 0),
                    test_rule_route(2, 2, 1000, 100)
                ]),
                meck:expect(hg_route_balancer, fill, fun(Routes) ->
                    put(fill_args, Routes),
                    meck:passthrough([Routes])
                end),
                {ok, [Chosen]} = select_routes(ZeroKept, #{has_quote => false, domain_revision => 7}),
                Filled = get(fill_args),
                ?assertEqual(2, length(Filled)),
                ?assertEqual(
                    true,
                    lists:any(fun(Route) -> hg_route:weight(Route) =:= 0 end, Filled)
                ),
                ?assertEqual(#{provider_id => 2, terminal_id => 2, version => 1}, Chosen),
                HighPriority = test_select_state([
                    test_rule_route(1, 1, 100, 100),
                    test_rule_route(2, 2, 1000, 1)
                ]),
                {ok, [PriorityChosen]} = select_routes(HighPriority, #{has_quote => false, domain_revision => 7}),
                ?assertEqual(#{provider_id => 2, terminal_id => 2, version => 1}, PriorityChosen),
                Negative = test_select_state([
                    test_rule_route(1, 1, 1000, 10),
                    test_rule_route(2, 2, 1000, -1)
                ]),
                FillCalls = meck:num_calls(hg_route_balancer, fill, '_'),
                ChooseCalls = meck:num_calls(hg_routing, choose_route, '_'),
                ?assertEqual(
                    {error, {misconfiguration, {negative_weight, maps:get(routes, Negative)}}},
                    select_routes(Negative, #{has_quote => false, domain_revision => 7})
                ),
                ?assertEqual(FillCalls, meck:num_calls(hg_route_balancer, fill, '_')),
                ?assertEqual(ChooseCalls, meck:num_calls(hg_routing, choose_route, '_'))
            end)
        end
    ).

-spec prepare_routes_no_hold_test() -> _.
prepare_routes_no_hold_test() ->
    with_collector_mocks(
        fun default_compute/3,
        fun default_resolve/2,
        fun default_terms/4,
        fun() ->
            Result = prepare_routes(test_varset(), test_context()),
            ?assertMatch({ok, [_ | _]}, Result),
            ?assertEqual(0, meck:num_calls(ff_limiter, hold_withdrawal_limits, '_'))
        end
    ).

-spec prepare_routes_no_withdrawal_state_test() -> _.
prepare_routes_no_withdrawal_state_test() ->
    with_collector_mocks(
        fun default_compute/3,
        fun default_resolve/2,
        fun default_terms/4,
        fun() ->
            Context = #{wallet => test_wallet(), domain_revision => 1, iteration => 1},
            ?assertMatch({ok, [_ | _]}, prepare_routes(test_varset(), Context))
        end
    ).

-spec prepare_routes_no_candidates_journal_test() -> _.
prepare_routes_no_candidates_journal_test() ->
    with_balancer_flag(
        true,
        fun() ->
            with_collector_mocks(
                fun default_compute/3,
                fun default_resolve/2,
                fun default_terms/4,
                fun() ->
                    Result = prepare_routes(test_varset(), test_context()),
                    ?assertMatch({ok, [_ | _]}, Result),
                    ?assertEqual(0, meck:num_calls(ff_limiter, hold_withdrawal_limits, '_')),
                    ?assertEqual(0, meck:num_calls(hg_route_balancer, fill, '_')),
                    ?assertEqual(0, meck:num_calls(hg_routing, choose_route, '_'))
                end
            )
        end
    ).

-spec do_validate_terms_no_limiter_hold_test() -> _.
do_validate_terms_no_limiter_hold_test() ->
    with_collector_mocks(
        fun default_compute/3,
        fun default_resolve/2,
        fun default_terms/4,
        fun() ->
            _ = gather_routes(test_varset(), test_context()),
            ?assertEqual(0, meck:num_calls(ff_limiter, hold_withdrawal_limits, '_'))
        end
    ).

-spec gather_routes_no_limiter_hold_test() -> _.
gather_routes_no_limiter_hold_test() ->
    with_collector_mocks(
        fun default_compute/3,
        fun default_resolve/2,
        fun default_terms/4,
        fun() ->
            State = gather_routes(test_varset(), test_context()),
            ?assertMatch(#{routes := [_ | _]}, State),
            ?assertEqual(0, meck:num_calls(ff_limiter, hold_withdrawal_limits, '_'))
        end
    ).

-spec gather_routes_keeps_weight_priority_test() -> _.
gather_routes_keeps_weight_priority_test() ->
    with_collector_mocks(
        fun weighted_compute/3,
        fun default_resolve/2,
        fun default_terms/4,
        fun() ->
            Context = (test_context())#{withdrawal => ff_withdrawal:test_withdrawal_state()},
            Gathered = gather_routes(test_varset(), Context),
            ok = assert_weight_priority(Gathered),
            Overflow = filter_limit_overflow_routes(Gathered, test_varset(), Context),
            ok = assert_weight_priority(Overflow),
            Chosen = sort_routes(maps:get(routes, Overflow)),
            lists:foreach(
                fun(Route) ->
                    ?assertEqual(false, maps:is_key(weight, Route))
                end,
                Chosen
            )
        end
    ).

-spec accounted_includes_overflow_routes_test() -> _.
accounted_includes_overflow_routes_test() ->
    Overflow = {overflow, [{<<"lim">>, 10, 1}]},
    with_collector_mocks(
        fun weighted_compute/3,
        fun default_resolve/2,
        fun limited_terms/4,
        fun() ->
            meck:expect(ff_limiter, hold_withdrawal_limits, fun(_, _, _, _) -> ok end),
            meck:expect(ff_limiter, check_limits, fun
                (_, _, #{terminal_id := 1}, _) ->
                    {error, Overflow};
                (_, _, _, _) ->
                    {ok, []}
            end),
            Context = (test_context())#{withdrawal => ff_withdrawal:test_withdrawal_state()},
            Gathered = gather_routes(test_varset(), Context),
            Filtered = filter_limit_overflow_routes(Gathered, test_varset(), Context),
            Accounted = accounted_candidates(Filtered),
            ?assertEqual(true, is_list(Accounted)),
            ?assertEqual(true, lists:any(fun(#{terminal_id := T}) -> T =:= 1 end, Accounted)),
            Routes = maps:get(routes, Filtered),
            ?assertEqual(
                false,
                lists:any(
                    fun
                        (#{terminal_ref := #domain_TerminalRef{id = 1}}) -> true;
                        (_) -> false
                    end,
                    Routes
                )
            )
        end
    ).

-spec withdrawal_allowed_constant_false_legacy_test() -> _.
withdrawal_allowed_constant_false_legacy_test() ->
    with_collector_mocks(
        fun false_allowed_compute/3,
        fun default_resolve/2,
        fun default_terms/4,
        fun() ->
            State = gather_routes(test_varset(), test_context()),
            ?assertMatch(#{routes := [_ | _]}, State),
            ?assertEqual(undefined, maps:get(error, State, undefined))
        end
    ).

-spec withdrawal_compute_rpc_retryable_test() -> _.
withdrawal_compute_rpc_retryable_test() ->
    Timeout = {woody_error, {system, result_unknown, <<"timeout">>}},
    with_collector_mocks(
        fun(_, _, _) -> raise(Timeout) end,
        fun default_resolve/2,
        fun default_terms/4,
        fun() ->
            ok = assert_timeout_propagates(fun() -> gather_routes(test_varset(), test_context()) end, Timeout),
            ok = assert_timeout_propagates(
                fun() -> ff_withdrawal:process_transfer(ff_withdrawal:test_withdrawal_state()) end,
                Timeout
            )
        end
    ).

assert_timeout_propagates(Fun, Timeout) ->
    try
        Result = Fun(),
        case Result of
            {_, Events} when is_list(Events) ->
                case lists:keyfind(status_changed, 1, Events) of
                    {status_changed, {failed, _}} ->
                        erlang:error(wrote_status_failed);
                    _ ->
                        erlang:error({unexpected_process_result, Result})
                end;
            _ ->
                erlang:error({unexpected_result, Result})
        end
    catch
        error:Timeout ->
            ok;
        error:{route_not_found, _} ->
            erlang:error(mapped_to_route_not_found);
        throw:{route_not_found, _} ->
            erlang:error(mapped_to_route_not_found);
        error:{woody_error, _} ->
            ok;
        throw:{woody_error, _} ->
            ok
    end.

assert_weight_priority(#{routes := Routes}) ->
    ?assertMatch([_ | _], Routes),
    lists:foreach(
        fun(Route) ->
            Priority = maps:get(priority, Route),
            Weight = maps:get(weight, Route),
            ?assert(is_integer(Priority)),
            ?assert(is_integer(Weight))
        end,
        Routes
    ).

with_balancer_flag(Flag, Fun) ->
    Prev = application:get_env(ff_transfer, withdrawal_route_balancer),
    ok = application:set_env(ff_transfer, withdrawal_route_balancer, Flag),
    try
        Fun()
    after
        case Prev of
            undefined ->
                application:unset_env(ff_transfer, withdrawal_route_balancer);
            {ok, Value} ->
                application:set_env(ff_transfer, withdrawal_route_balancer, Value)
        end
    end.

with_chooser_mocks(Fun) ->
    meck:new(hg_route_balancer, [passthrough, no_link, unstick]),
    meck:new(hg_routing, [passthrough, no_link, unstick]),
    try
        Fun()
    after
        meck:unload()
    end.

test_select_state(Routes) ->
    #{
        routes => Routes,
        reject_context => #{varset => #{}, accepted_routes => Routes, rejected_routes => []}
    }.

test_rule_route(ProviderID, TerminalID, Priority, Weight) ->
    #{
        provider_ref => #domain_ProviderRef{id = ProviderID},
        terminal_ref => #domain_TerminalRef{id = TerminalID},
        priority => Priority,
        weight => Weight
    }.

with_collector_mocks(ComputeFun, ResolveFun, TermsFun, Fun) ->
    meck:new(ff_payment_institution, [passthrough, no_link, unstick]),
    meck:new(ff_party, [passthrough, no_link, unstick]),
    meck:new(ff_domain_config, [passthrough, no_link, unstick]),
    meck:new(ff_limiter, [passthrough, no_link, unstick]),
    meck:new(ff_destination_machine, [passthrough, no_link, unstick]),
    meck:new(hg_route_balancer, [passthrough, no_link, unstick]),
    meck:new(hg_routing, [passthrough, no_link, unstick]),
    meck:expect(ff_payment_institution, get, fun(_, _, _) -> {ok, test_payment_institution()} end),
    meck:expect(ff_party, compute_routing_ruleset, ComputeFun),
    meck:expect(ff_party, compute_provider_terminal_terms, TermsFun),
    meck:expect(ff_party, get_wallet, fun(_, _, _) -> {ok, test_wallet()} end),
    meck:expect(ff_domain_config, object, fun(Rev, {terminal, Ref}) -> ResolveFun(Ref, Rev) end),
    meck:expect(ff_limiter, hold_withdrawal_limits, fun(_, _, _, _) -> ok end),
    meck:expect(ff_limiter, check_limits, fun(_, _, _, _) -> {ok, []} end),
    meck:expect(ff_destination_machine, get, fun(_) -> {ok, dest_machine} end),
    meck:expect(ff_destination_machine, destination, fun(_) -> #{id => <<"dest">>} end),
    try
        Fun()
    after
        meck:unload()
    end.

default_compute(#domain_RoutingRulesetRef{id = 1}, _, _) ->
    {ok, #domain_RoutingRuleset{
        name = <<"policies">>,
        decisions = {candidates, [candidate(#domain_TerminalRef{id = 1}, {constant, true}, 1000, 7)]}
    }};
default_compute(#domain_RoutingRulesetRef{id = 2}, _, _) ->
    {ok, #domain_RoutingRuleset{name = <<"prohibitions">>, decisions = {candidates, []}}}.

weighted_compute(#domain_RoutingRulesetRef{id = 1}, _, _) ->
    {ok, #domain_RoutingRuleset{
        name = <<"policies">>,
        decisions =
            {candidates, [
                candidate(#domain_TerminalRef{id = 1}, {constant, true}, 50, 3),
                candidate(#domain_TerminalRef{id = 2}, {constant, true}, undefined, undefined)
            ]}
    }};
weighted_compute(Ref, VS, Rev) ->
    default_compute(Ref, VS, Rev).

false_allowed_compute(#domain_RoutingRulesetRef{id = 1}, _, _) ->
    {ok, #domain_RoutingRuleset{
        name = <<"policies">>,
        decisions = {candidates, [candidate(#domain_TerminalRef{id = 1}, {constant, false}, 1000, 0)]}
    }};
false_allowed_compute(Ref, VS, Rev) ->
    default_compute(Ref, VS, Rev).

default_resolve(#domain_TerminalRef{id = ID}, _Revision) ->
    {ok, #domain_Terminal{
        name = <<"terminal">>,
        description = <<"terminal">>,
        provider_ref = #domain_ProviderRef{id = ID}
    }}.

default_terms(_ProviderRef, _TerminalRef, _VS, _Rev) ->
    Currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>},
    {ok, #domain_ProvisionTermSet{
        wallet = #domain_WalletProvisionTerms{
            withdrawals = #domain_WithdrawalProvisionTerms{
                currencies = {value, ordsets:from_list([Currency])},
                cash_limit =
                    {value, #domain_CashRange{
                        lower = {inclusive, #domain_Cash{amount = 0, currency = Currency}},
                        upper = {exclusive, #domain_Cash{amount = 10000000, currency = Currency}}
                    }},
                cash_flow = {value, []}
            }
        }
    }}.

limited_terms(ProviderRef, TerminalRef, VS, Rev) ->
    {ok, #domain_ProvisionTermSet{wallet = WalletTerms}} = default_terms(ProviderRef, TerminalRef, VS, Rev),
    #domain_WalletProvisionTerms{withdrawals = WithdrawalTerms} = WalletTerms,
    {ok, #domain_ProvisionTermSet{
        wallet = WalletTerms#domain_WalletProvisionTerms{
            withdrawals = WithdrawalTerms#domain_WithdrawalProvisionTerms{
                turnover_limit = {value, []}
            }
        }
    }}.

candidate(TerminalRef, Allowed, Priority, Weight) ->
    #domain_RoutingCandidate{
        terminal = TerminalRef,
        allowed = Allowed,
        priority = Priority,
        weight = Weight
    }.

test_payment_institution() ->
    #{
        id => 1,
        realm => live,
        system_accounts => {value, #domain_SystemAccountSetRef{id = 1}},
        withdrawal_routing_rules => #domain_RoutingRules{
            policies = #domain_RoutingRulesetRef{id = 1},
            prohibitions = #domain_RoutingRulesetRef{id = 2}
        }
    }.

test_wallet() ->
    #domain_WalletConfig{
        name = <<"wallet">>,
        block = {unblocked, #domain_Unblocked{reason = <<>>, since = <<"1970-01-01T00:00:00Z">>}},
        suspension = {active, #domain_Active{since = <<"1970-01-01T00:00:00Z">>}},
        terms = #domain_TermSetHierarchyRef{id = 1},
        account = #domain_WalletAccount{
            currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>},
            settlement = 1
        },
        payment_institution = #domain_PaymentInstitutionRef{id = 1},
        party_ref = #domain_PartyConfigRef{id = <<"party">>}
    }.

%% erlang:error/1 alone is a no-return fun, which dialyzer flags.
raise(Reason) ->
    case get('$dialyzer_raise') of
        true -> ok;
        _ -> erlang:error(Reason)
    end.

test_context() ->
    #{wallet => test_wallet(), domain_revision => 1, iteration => 1}.

test_varset() ->
    Currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>},
    #{
        currency => Currency,
        cost => #domain_Cash{amount = 100, currency = Currency},
        party_id => <<"party">>
    }.

-endif.
