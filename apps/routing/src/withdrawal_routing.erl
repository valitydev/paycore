-module(withdrawal_routing).

-behaviour(routing_domain).

-export([callbacks/0]).
-export([compute_ruleset/3]).
-export([resolve_terminal/2]).
-export([validate_candidate/1]).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([prepare_routes/2]).
-export([prepare_routes/3]).
-export([gather_routes/2]).
-export([gather_routes/3, steps/3]).
-export([filter_limit_overflow_routes/3]).
-export([rollback_routes_limits/3]).
-export([commit_routes_limits/3]).
-export([make_route/2]).
-export([get_provider/1]).
-export([get_terminal/1]).
-export([route/4, result/1, rejected_routes/1]).
-export([select_routes/1]).
-export([get_routes/1]).
-export([accounted_candidates/1]).
-export([log_reject_context/2]).

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

-type routing_state() :: routing_ctx:t().

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
    log_reject_context(State, PartyVarset),
    select_routes(State).

-spec gather_routes(party_varset(), routing_context()) ->
    routing_state().
gather_routes(PartyVarset, Context) ->
    gather_routes(PartyVarset, Context, []).

-spec gather_routes(party_varset(), routing_context(), [terminal_id()]) ->
    routing_state().
gather_routes(PartyVarset, Context, ExcludeRoutes) ->
    try
        State = routing:run(routing_ctx:new([]), steps(PartyVarset, Context, ExcludeRoutes)),
        case routing_ctx:error(State) of
            undefined -> State;
            {misconfiguration, Reason} -> misconfigured_routes(Reason, PartyVarset)
        end
    catch
        throw:{misconfiguration, CatchReason} -> misconfigured_routes(CatchReason, PartyVarset)
    end.

-spec steps(party_varset(), routing_context(), [terminal_id()]) -> [routing:step()].
steps(PartyVarset, #{wallet := Wallet, domain_revision := DomainRevision} = Context, ExcludeRoutes) ->
    #domain_WalletConfig{payment_institution = PaymentInstitutionRef} = Wallet,
    {ok, PaymentInstitution} = ff_payment_institution:get(PaymentInstitutionRef, PartyVarset, DomainRevision),
    RoutingRules = maps:get(withdrawal_routing_rules, PaymentInstitution),
    Callbacks = callbacks(),
    [
        {collect, fun(_) -> routing:collect(DomainRevision, PartyVarset, RoutingRules, Callbacks) end},
        {prohibition, fun(S) ->
            routing:fill(S, fun(Rs) ->
                hg_route_collector:fill_prohibition(DomainRevision, PartyVarset, RoutingRules, Callbacks, Rs)
            end)
        end},
        {filter_prohibited, fun(S) -> routing:filter(S, [{prohibit, true}]) end},
        {attempted, fun(S) -> exclude_routes(S, ExcludeRoutes) end},
        {accepted, fun(S) -> routing:fill(S, fun(Rs) -> fill_accepted(PartyVarset, Context, Rs) end) end},
        {filter_accepted, fun(S) -> routing:filter(S, [{accepted, false}]) end}
    ].

misconfigured_routes(Reason, PartyVarset) ->
    logger:warning("Routing rule misconfiguration. Reason:~n~p~nVarset:~n~p", [Reason, PartyVarset]),
    routing_ctx:new([]).

%% Quote and normal routing share all eligibility and hold steps.
-spec route(party_varset(), routing_context(), [terminal_id()], map() | undefined) -> routing_state().
route(Varset, Context, Exclude, Quote) ->
    State = gather_routes(Varset, Context, Exclude),
    Selection =
        case Quote of
            undefined -> [{balance, fun routing:balance/1}, {choose, fun routing:select/1}];
            _ -> [{quote, fun(S) -> select_quote(S, Quote) end}]
        end,
    routing:run(State, [{limits, fun(S) -> filter_limit_overflow_routes(S, Varset, Context) end} | Selection]).

select_quote(State, #{route := QuoteRoute}) ->
    case routing_ctx:candidates(State) of
        [] ->
            State;
        Routes ->
            case
                lists:search(
                    fun(#{provider_ref := #domain_ProviderRef{id = P}, terminal_ref := #domain_TerminalRef{id = T}}) ->
                        P =:= get_provider(QuoteRoute) andalso T =:= get_terminal(QuoteRoute)
                    end,
                    Routes
                )
            of
                {value, Chosen} -> routing_ctx:set_choosen(Chosen, #{chosen_route => Chosen}, State);
                false -> routing_ctx:set_error({inconsistent_quote_route, QuoteRoute}, State)
            end
    end.

-spec filter_limit_overflow_routes(routing_state(), party_varset(), routing_context()) -> routing_state().
filter_limit_overflow_routes(State, PartyVarset, Context) ->
    routing:hold(State, limit_overflow, fun(Route) ->
        case
            get_route_terms_and_process(
                fun do_validate_limits/4,
                hg_route:provider_ref(Route),
                hg_route:terminal_ref(Route),
                PartyVarset,
                Context
            )
        of
            {ok, valid} -> ok;
            Other -> Other
        end
    end).

-spec accounted_candidates(routing_state()) -> [route()].
accounted_candidates(State) ->
    [hg_route:to_withdrawal_route(Route) || Route <- routing_ctx:accounted_candidates(State)].

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

-spec select_routes(routing_state()) -> {ok, [route()]} | {error, route_not_found()}.
select_routes(State) ->
    result(routing:run(State, [{balance, fun routing:balance/1}, {choose, fun routing:select/1}])).

-spec result(routing_state()) -> {ok, [route()]} | {error, route_not_found() | {inconsistent_quote_route, route()}}.
result(State) ->
    case {routing_ctx:error(State), routing_ctx:choosen_route(State)} of
        {undefined, undefined} -> {error, {route_not_found, rejected_routes(State)}};
        {undefined, Chosen} -> {ok, [hg_route:to_withdrawal_route(Chosen)]};
        {Error, _} -> {error, Error}
    end.

-spec get_routes(routing_state()) -> [route()].
get_routes(State) ->
    [hg_route:to_withdrawal_route(Route) || Route <- routing_ctx:candidates(State)].

-spec rejected_routes(routing_state()) -> [rejected_route()].
rejected_routes(State) ->
    [
        {hg_route:provider_ref(R), hg_route:terminal_ref(R), rejection_reason(R)}
     || R <- routing_ctx:rejected_routes(State)
    ].

rejection_reason(Route) ->
    case hg_route:rejection_reason(Route) of
        {prohibit, {true, Description}} -> Description;
        {accepted, {false, Reason}} -> Reason;
        Reason -> Reason
    end.

-spec log_reject_context(routing_state(), party_varset()) -> ok.
log_reject_context(State, Varset) ->
    logger:info("Routing reject context: rejected routes: ~p, accepted routes: ~p, varset: ~p", [
        rejected_routes(State), routing_ctx:candidates(State), Varset
    ]).

%%

-spec callbacks() -> hg_route_collector:callbacks().
callbacks() ->
    #{
        compute_ruleset => fun compute_ruleset/3,
        resolve_terminal => fun resolve_terminal/2,
        validate_candidate => fun validate_candidate/1
    }.

-spec compute_ruleset(dmsl_domain_thrift:'RoutingRulesetRef'(), party_varset(), domain_revision()) ->
    {ok, dmsl_domain_thrift:'RoutingRuleset'()}.
compute_ruleset(RulesetRef, VS, Revision) ->
    case ff_party:compute_routing_ruleset(RulesetRef, VS, Revision) of
        {ok, Ruleset} ->
            {ok, Ruleset};
        {error, ruleset_not_found} ->
            throw({misconfiguration, {ruleset, RulesetRef, not_found}})
    end.

-spec resolve_terminal(terminal_ref(), domain_revision()) -> {ok, provider_ref()}.
resolve_terminal(TerminalRef, Revision) ->
    {ok, #domain_Terminal{provider_ref = ProviderRef}} = ff_domain_config:object(Revision, {terminal, TerminalRef}),
    {ok, ProviderRef}.

-spec validate_candidate(dmsl_domain_thrift:'RoutingCandidate'()) -> ok | no_return().
validate_candidate(#domain_RoutingCandidate{allowed = {constant, Allowed}}) when is_boolean(Allowed) ->
    ok;
validate_candidate(Candidate) ->
    throw({misconfiguration, {routing_candidate, Candidate}}).

fill_accepted(Varset, Context, Routes) ->
    [
        case
            get_route_terms_and_process(
                fun do_validate_terms/4,
                hg_route:provider_ref(Route),
                hg_route:terminal_ref(Route),
                Varset,
                Context
            )
        of
            {ok, valid} -> Route;
            {error, Reason} -> hg_route:set_accepted({false, Reason}, Route)
        end
     || Route <- Routes
    ].

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

exclude_routes(State, Exclude) ->
    routing:check(State, already_attempted, fun(Route) ->
        #domain_TerminalRef{id = ID} = hg_route:terminal_ref(Route),
        case lists:member(ID, Exclude) of
            true -> {error, member_of_exclude_list};
            false -> ok
        end
    end).

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
                    routing_ctx:new(Routes)
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
