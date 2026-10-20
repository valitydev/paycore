-module(hg_payment_routing).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").
-include_lib("hellgate/include/domain.hrl").

-export([get_routes/1]).
-export([get_logger_metadata/2]).
-export([collector_callbacks/0]).
-export([fill_accepted/4]).
-export([fill_blacklist/2]).
-export([fill_fd_overrides/2]).

-type payment_institution() :: dmsl_domain_thrift:'PaymentInstitution'().
-type route_predestination() :: payment | recurrent_paytool | recurrent_payment.
-type varset() :: hg_varset:varset().
-type revision() :: hg_domain:revision().

-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type client_ip() :: dmsl_domain_thrift:'IPAddress'().
-type email() :: binary().
-type card_token() :: dmsl_domain_thrift:'Token'().

-type gather_route_context() :: #{
    currency := currency(),
    payment_tool := payment_tool(),
    client_ip := client_ip() | undefined,
    email => email() | undefined,
    card_token => card_token() | undefined
}.

-type get_route_params() :: #{
    predestination := route_predestination(),
    revision := revision(),
    varset := varset(),
    payment_institution := payment_institution(),
    pin_context := gather_route_context(),
    blacklist_context => hg_inspector:blacklist_context()
}.

-type get_routes_result() :: #{
    routes := [hg_route:t()],
    rejections => #{hg_routing:initial_rejection_group() => [hg_route:t()]},
    error => hg_route_collector:get_routes_error()
}.

-export_type([payment_institution/0]).
-export_type([route_predestination/0]).
-export_type([varset/0]).
-export_type([revision/0]).
-export_type([gather_route_context/0]).
-export_type([get_route_params/0]).
-export_type([get_routes_result/0]).

-define(fd_overrides(Enabled), #domain_RouteFaultDetectorOverrides{enabled = Enabled}).
-define(rejected(Reason), {rejected, Reason}).

-spec collector_callbacks() -> hg_route_collector:callbacks().
collector_callbacks() ->
    #{
        compute_ruleset => fun compute_ruleset/3,
        resolve_terminal => fun resolve_terminal/2,
        allowed_policy => payment
    }.

-spec get_routes(get_route_params()) -> get_routes_result().
get_routes(
    #{
        predestination := Predestination,
        revision := Revision,
        varset := VS,
        payment_institution := PI,
        pin_context := PinCtx
    } = Params
) ->
    RoutingRules = PI#domain_PaymentInstitution.payment_routing_rules,
    Result =
        #{routes := Routes0} = hg_route_collector:get_routes(
            Revision, VS, RoutingRules, collector_callbacks()
        ),
    Routes1 = enrich_pins(Routes0, PinCtx),
    Routes2 = fill_accepted(Predestination, Revision, VS, Routes1),
    Routes3 = fill_fd_overrides(Revision, Routes2),
    Routes4 =
        case maps:get(blacklist_context, Params, undefined) of
            undefined ->
                Routes3;
            BlCtx ->
                fill_blacklist(BlCtx, Routes3)
        end,
    Routes5 = hg_route_fd:fill(Routes4),
    genlib_map:compact(
        maps:merge(
            #{error => maps:get(error, Result, undefined)},
            hg_routing:filter(Routes5, [{accepted, false}, {prohibit, true}, {blacklisted, 1}])
        )
    ).

-spec get_logger_metadata(hg_routing:route_choice_context(), revision()) -> LoggerFormattedMetadata :: map().
get_logger_metadata(RouteChoiceContext, Revision) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{K => format_logger_metadata(K, V, Revision)}
        end,
        #{},
        RouteChoiceContext
    ).

format_logger_metadata(reject_reason, Reason, _) ->
    Reason;
format_logger_metadata(Meta, Route, Revision) when
    Meta =:= chosen_route;
    Meta =:= preferable_route
->
    ProviderRef = #domain_ProviderRef{id = ProviderID} = hg_route:provider_ref(Route),
    TerminalRef = #domain_TerminalRef{id = TerminalID} = hg_route:terminal_ref(Route),
    #domain_Provider{name = ProviderName} = hg_domain:get(Revision, {provider, ProviderRef}),
    #domain_Terminal{name = TerminalName} = hg_domain:get(Revision, {terminal, TerminalRef}),
    genlib_map:compact(#{
        provider => #{id => ProviderID, name => ProviderName},
        terminal => #{id => TerminalID, name => TerminalName},
        priority => hg_route:priority(Route),
        weight => hg_route:weight(Route),
        terminal_affinity => hg_route:affinity_rank(Route),
        affinity_enabled => hg_route:affinity(Route) =/= undefined
    }).

compute_ruleset(RuleSetRef, VS, Revision) ->
    {Client, Context} = get_party_client(),
    party_client_thrift:compute_routing_ruleset(
        RuleSetRef,
        Revision,
        hg_varset:prepare_varset(VS),
        Client,
        Context
    ).

resolve_terminal(TerminalRef, Revision) ->
    try
        #domain_Terminal{provider_ref = ProviderRef} = hg_domain:get(Revision, {terminal, TerminalRef}),
        {ok, ProviderRef}
    catch
        error:{object_not_found, _} ->
            {error, notfound}
    end.

enrich_pins(Routes, Ctx) ->
    [enrich_pin(Route, Ctx) || Route <- Routes].

enrich_pin(Route, Ctx) ->
    Pin = maps:get(routing_pin, Route, undefined),
    maps:remove(routing_pin, Route#{pin_data => gather_pin_info(Pin, Ctx)}).

gather_pin_info(undefined, _Ctx) ->
    #{};
gather_pin_info(#domain_RoutingPin{features = Features}, Ctx) ->
    FeaturesList = ordsets:to_list(Features),
    lists:foldl(
        fun(Feature, Acc) ->
            Acc#{Feature => maps:get(Feature, Ctx, undefined)}
        end,
        #{},
        FeaturesList
    ).

-spec fill_blacklist(hg_inspector:blacklist_context(), [hg_route:t()]) -> [hg_route:t()].
fill_blacklist(_BlCtx, []) ->
    [];
fill_blacklist(BlCtx, [Route]) ->
    [hg_inspector:fill_blacklist(Route, BlCtx)];
fill_blacklist(BlCtx, Routes) ->
    HgContext = op_context:load(op_context:key(hellgate)),
    try
        genlib_pmap:map(
            fun(Route) ->
                ok = op_context:save(op_context:key(hellgate), HgContext),
                hg_inspector:fill_blacklist(Route, BlCtx)
            end,
            Routes,
            #{
                timeout => genlib_app:env(hellgate, inspect_timeout, infinity),
                proc_limit => genlib_app:env(hellgate, inspect_parallel_limit, 10)
            }
        )
    catch
        error:timeout ->
            %% genlib_pmap throws error:timeout, which progressor treats as
            %% {exception, _, _} and does not retry. Routing runs on a timeout
            %% machine step, so raise resource_unavailable to get a transient
            %% retry per retry_policy instead of failing the payment.
            erlang:error({woody_error, {system, resource_unavailable, 'blacklist_fill_timeout'}})
    end.

-spec fill_fd_overrides(revision(), [hg_route:t()]) ->
    [hg_route:t()].
fill_fd_overrides(Revision, Routes) ->
    lists:foldr(
        fun(Route, AccIn) ->
            TRef = hg_route:terminal_ref(Route),
            FdOverrides = get_provider_fd_overrides(Revision, TRef),
            [hg_route:set_fd_overrides(FdOverrides, Route) | AccIn]
        end,
        [],
        Routes
    ).

get_provider_fd_overrides(Revision, TerminalRef) ->
    #domain_Terminal{provider_ref = ProviderRef, route_fd_overrides = TrmFdOverrides} =
        hg_domain:get(Revision, {terminal, TerminalRef}),
    #domain_Provider{route_fd_overrides = PrvFdOverrides} =
        hg_domain:get(Revision, {provider, ProviderRef}),
    merge_fd_overrides(PrvFdOverrides, TrmFdOverrides).

merge_fd_overrides(_A, B = ?fd_overrides(Enabled)) when Enabled =/= undefined ->
    B;
merge_fd_overrides(A = ?fd_overrides(Enabled), _B) when Enabled =/= undefined ->
    A;
merge_fd_overrides(_A, _B) ->
    ?fd_overrides(undefined).

-spec fill_accepted(route_predestination(), revision(), varset(), [hg_route:t()]) ->
    [hg_route:t()].
fill_accepted(Predestination, Revision, VS, Routes) ->
    lists:foldr(
        fun(Route0, AccIn) ->
            try
                Route1 = acceptable_terminal(Predestination, Route0, VS, Revision),
                [Route1 | AccIn]
            catch
                {rejected, Reason} ->
                    [hg_route:set_accepted({false, {rejected, Reason}}, Route0) | AccIn];
                error:{misconfiguration, Reason} ->
                    [hg_route:set_accepted({false, {misconfiguration, Reason}}, Route0) | AccIn]
            end
        end,
        [],
        Routes
    ).

-spec acceptable_terminal(
    route_predestination(),
    hg_route:t(),
    varset(),
    revision()
) -> hg_route:t() | no_return().
acceptable_terminal(Predestination, Route, VS0, Revision) ->
    ProviderRef = hg_route:provider_ref(Route),
    TerminalRef = hg_route:terminal_ref(Route),
    {Client, Context} = get_party_client(),
    Result = party_client_thrift:compute_provider_terminal_terms(
        ProviderRef,
        TerminalRef,
        Revision,
        hg_varset:prepare_varset(VS0),
        Client,
        Context
    ),
    case Result of
        {ok, ProvisionTermSet} ->
            {VS1, ExchangeContext} = maybe_currency_conversion(
                ProvisionTermSet#domain_ProvisionTermSet.payments,
                VS0
            ),
            true = check_terms_acceptability(Predestination, ProvisionTermSet, VS1),
            hg_route:set_exchange_context(ExchangeContext, Route);
        {error, #payproc_ProvisionTermSetUndefined{}} ->
            throw(?rejected({'ProvisionTermSet', undefined}))
    end.

get_party_client() ->
    HgContext = op_context:load(op_context:key(hellgate)),
    Client = op_context:get_party_client(HgContext),
    Context = op_context:get_party_client_context(HgContext),
    {Client, Context}.

maybe_currency_conversion(
    #domain_PaymentsProvisionTerms{
        currencies = {value, [#domain_CurrencyRef{symbolic_code = DestinationCurrency} = DestinationCurrencyRef]},
        allow_exchange = {constant, true}
    },
    #{currency := #domain_CurrencyRef{symbolic_code = SourceCurrency}} = VS0
) when SourceCurrency =/= DestinationCurrency ->
    case hg_exrates:get_exchange_rate(SourceCurrency, DestinationCurrency) of
        {ok, #{p := P, q := Q}} ->
            ExchangeContext = #domain_ExchangeContext{
                source_currency = SourceCurrency,
                destination_currency = DestinationCurrency,
                exchange_rate = #base_Rational{p = P, q = Q}
            },
            VS1 = VS0#{
                currency => DestinationCurrencyRef,
                cost => hg_currency_converter:convert_cash(ExchangeContext, getv(cost, VS0))
            },
            {VS1, ExchangeContext};
        {error, _} ->
            throw(?rejected({'PaymentsProvisionTerms', exchange_error}))
    end;
maybe_currency_conversion(
    #domain_PaymentsProvisionTerms{
        currencies = {value, Currencies},
        allow_exchange = {constant, true}
    },
    _VS
) when erlang:length(Currencies) > 1 ->
    %% If currency conversion is allowed, only one currency must be specified
    throw(?rejected({'PaymentsProvisionTerms', too_many_currencies}));
maybe_currency_conversion(_Terms, VS) ->
    %% in other cases we rely on check_terms_acceptability/3
    {VS, undefined}.

check_terms_acceptability(payment, Terms, VS) ->
    acceptable_payment_terms(Terms#domain_ProvisionTermSet.payments, VS);
check_terms_acceptability(recurrent_paytool, Terms, VS) ->
    acceptable_recurrent_paytool_terms(Terms#domain_ProvisionTermSet.recurrent_paytools, VS);
check_terms_acceptability(recurrent_payment, Terms, VS) ->
    % Recurrent payment may be accepted either by recurrent terms
    % or via the skip_recurrent extension flag.
    _ = acceptable_payment_terms(Terms#domain_ProvisionTermSet.payments, VS),
    case Terms#domain_ProvisionTermSet.extension of
        #domain_ExtendedProvisionTerms{skip_recurrent = true} ->
            true;
        _ ->
            acceptable_recurrent_paytool_terms(Terms#domain_ProvisionTermSet.recurrent_paytools, VS)
    end.

acceptable_payment_terms(
    #domain_PaymentsProvisionTerms{
        allow = Allow,
        global_allow = GlobalAllow,
        currencies = CurrenciesSelector,
        categories = CategoriesSelector,
        payment_methods = PMsSelector,
        cash_limit = CashLimitSelector,
        holds = HoldsTerms,
        refunds = RefundsTerms,
        risk_coverage = RiskCoverageSelector
    },
    VS
) ->
    % TODO varsets getting mixed up
    %      it seems better to pass down here hierarchy of contexts w/ appropriate module accessors
    ParentName = 'PaymentsProvisionTerms',
    _ = acceptable_allow(ParentName, global_allow, GlobalAllow),
    _ = acceptable_allow(ParentName, allow, Allow),
    _ = try_accept_term(ParentName, currency, getv(currency, VS), CurrenciesSelector),
    _ = try_accept_term(ParentName, category, getv(category, VS), CategoriesSelector),
    _ = try_accept_term(ParentName, payment_tool, getv(payment_tool, VS), PMsSelector),
    _ = try_accept_term(ParentName, cost, getv(cost, VS), CashLimitSelector),
    _ = acceptable_holds_terms(HoldsTerms, getv(flow, VS, undefined)),
    _ = acceptable_refunds_terms(RefundsTerms, getv(refunds, VS, undefined)),
    _ = acceptable_risk(ParentName, RiskCoverageSelector, VS),
    %% TODO Check chargeback terms when there will be any
    %% _ = acceptable_chargeback_terms(...)
    true;
acceptable_payment_terms(undefined, _VS) ->
    throw(?rejected({'PaymentsProvisionTerms', undefined})).

acceptable_holds_terms(_Terms, undefined) ->
    true;
acceptable_holds_terms(_Terms, instant) ->
    true;
acceptable_holds_terms(Terms, {hold, Lifetime}) ->
    case Terms of
        #domain_PaymentHoldsProvisionTerms{lifetime = LifetimeSelector} ->
            _ = try_accept_term('PaymentHoldsProvisionTerms', lifetime, Lifetime, LifetimeSelector),
            true;
        undefined ->
            throw(?rejected({'PaymentHoldsProvisionTerms', undefined}))
    end.

acceptable_risk(_ParentName, undefined, _VS) ->
    true;
acceptable_risk(ParentName, Selector, VS) ->
    RiskCoverage = get_selector_value(risk_coverage, Selector),
    RiskScore = getv(risk_score, VS),
    hg_inspector:compare_risk_score(RiskCoverage, RiskScore) >= 0 orelse
        throw(?rejected({ParentName, risk_coverage})).

acceptable_refunds_terms(_Terms, undefined) ->
    true;
acceptable_refunds_terms(
    #domain_PaymentRefundsProvisionTerms{
        partial_refunds = PartialRefundsTerms
    },
    RVS
) ->
    _ = acceptable_partial_refunds_terms(
        PartialRefundsTerms,
        getv(partial, RVS, undefined)
    ),
    true;
acceptable_refunds_terms(undefined, _RVS) ->
    throw(?rejected({'PaymentRefundsProvisionTerms', undefined})).

acceptable_partial_refunds_terms(_Terms, undefined) ->
    true;
acceptable_partial_refunds_terms(
    #domain_PartialRefundsProvisionTerms{cash_limit = CashLimitSelector},
    #{cash_limit := MerchantLimit}
) ->
    ProviderLimit = get_selector_value(cash_limit, CashLimitSelector),
    hg_cash_range:is_subrange(MerchantLimit, ProviderLimit) == true orelse
        throw(?rejected({'PartialRefundsProvisionTerms', cash_limit}));
acceptable_partial_refunds_terms(undefined, _RVS) ->
    throw(?rejected({'PartialRefundsProvisionTerms', undefined})).

acceptable_allow(_ParentName, _Type, undefined) ->
    true;
acceptable_allow(_ParentName, _Type, {constant, true}) ->
    true;
acceptable_allow(ParentName, Type, {constant, false}) ->
    throw(?rejected({ParentName, Type}));
acceptable_allow(_ParentName, Type, Ambiguous) ->
    erlang:error({misconfiguration, {'Could not reduce predicate to a value', {Type, Ambiguous}}}).

acceptable_recurrent_paytool_terms(
    #domain_RecurrentPaytoolsProvisionTerms{
        categories = CategoriesSelector,
        payment_methods = PMsSelector
    },
    VS
) ->
    _ = try_accept_term('RecurrentPaytoolsProvisionTerms', category, getv(category, VS), CategoriesSelector),
    _ = try_accept_term('RecurrentPaytoolsProvisionTerms', payment_tool, getv(payment_tool, VS), PMsSelector),
    true;
acceptable_recurrent_paytool_terms(undefined, _VS) ->
    throw(?rejected({'RecurrentPaytoolsProvisionTerms', undefined})).

try_accept_term(ParentName, Name, _Value, undefined) ->
    throw(?rejected({ParentName, Name}));
try_accept_term(ParentName, Name, Value, Selector) ->
    Values = get_selector_value(Name, Selector),
    test_term(Name, Value, Values) orelse throw(?rejected({ParentName, Name})).

test_term(currency, V, Vs) ->
    ordsets:is_element(V, Vs);
test_term(category, V, Vs) ->
    ordsets:is_element(V, Vs);
test_term(payment_tool, PT, PMs) ->
    hg_payment_tool:has_any_payment_method(PT, PMs);
test_term(cost, Cost, CashRange) ->
    hg_cash_range:is_inside(Cost, CashRange) == within;
test_term(lifetime, ?hold_lifetime(Lifetime), ?hold_lifetime(Allowed)) ->
    Lifetime =< Allowed.

%%

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            erlang:error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

getv(Name, VS) ->
    maps:get(Name, VS).

getv(Name, VS, Default) ->
    maps:get(Name, VS, Default).

%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec merge_fd_overrides_test_() -> _.
merge_fd_overrides_test_() ->
    [
        ?_assertEqual(?fd_overrides(undefined), merge_fd_overrides(undefined, ?fd_overrides(undefined))),
        ?_assertEqual(?fd_overrides(true), merge_fd_overrides(?fd_overrides(true), undefined)),
        ?_assertEqual(?fd_overrides(true), merge_fd_overrides(?fd_overrides(true), ?fd_overrides(undefined))),
        ?_assertEqual(?fd_overrides(false), merge_fd_overrides(?fd_overrides(true), ?fd_overrides(false)))
    ].

-spec fill_blacklist_parallel_test_() -> _.
fill_blacklist_parallel_test_() ->
    {setup, fun setup_fill_blacklist_test/0, fun cleanup_fill_blacklist_test/1, [
        ?_test(fill_blacklist_preserves_hg_context_in_workers()),
        ?_test(fill_blacklist_timeout_raises_transient_error())
    ]}.

-spec setup_fill_blacklist_test() -> ok.
setup_fill_blacklist_test() ->
    _ = application:ensure_all_started(gproc),
    _ = application:ensure_all_started(party_client),
    ok.

-spec cleanup_fill_blacklist_test(_) -> ok.
cleanup_fill_blacklist_test(_Ok) ->
    try
        op_context:cleanup(hellgate)
    catch
        _:_ -> ok
    end,
    try
        meck:unload(hg_inspector)
    catch
        _:_ -> ok
    end,
    ok.

-spec fill_blacklist_preserves_hg_context_in_workers() -> _.
fill_blacklist_preserves_hg_context_in_workers() ->
    HgCtx = op_context:create(#{woody_context => woody_context:new()}),
    ok = op_context:save(op_context:key(hellgate), HgCtx),
    Parent = self(),
    Routes = [test_route(N) || N <- [1, 2, 3]],
    BlCtx = test_blacklist_context(hd(Routes)),
    Ref = make_ref(),
    ok = meck:new(hg_inspector, [passthrough]),
    ok = meck:expect(hg_inspector, fill_blacklist, fun(Route, _BlCtx) ->
        ?assertEqual(HgCtx, op_context:load(op_context:key(hellgate))),
        Parent ! {worker_done, self(), Ref},
        Route
    end),
    try
        ?assertEqual(Routes, hg_payment_routing:fill_blacklist(BlCtx, Routes)),
        WorkerPids = collect_worker_pids(Ref, 3),
        ?assertEqual(3, length(WorkerPids)),
        ?assert(lists:all(fun(Pid) -> Pid =/= Parent end, WorkerPids))
    after
        ok = meck:unload(hg_inspector),
        ok = op_context:cleanup(hellgate)
    end.

-spec fill_blacklist_timeout_raises_transient_error() -> _.
fill_blacklist_timeout_raises_transient_error() ->
    Routes = [test_route(1), test_route(2)],
    BlCtx = test_blacklist_context(hd(Routes)),
    HgCtx = op_context:create(#{woody_context => woody_context:new()}),
    ok = op_context:save(op_context:key(hellgate), HgCtx),
    PrevTimeout = application:get_env(hellgate, inspect_timeout, infinity),
    PrevLimit = application:get_env(hellgate, inspect_parallel_limit, 10),
    ok = application:set_env(hellgate, inspect_timeout, 100),
    ok = application:set_env(hellgate, inspect_parallel_limit, 2),
    ok = meck:new(hg_inspector, [passthrough]),
    ok = meck:expect(hg_inspector, fill_blacklist, fun(Route, _BlCtx) ->
        timer:sleep(300),
        Route
    end),
    try
        ?assertError(
            {woody_error, {system, resource_unavailable, blacklist_fill_timeout}},
            hg_payment_routing:fill_blacklist(BlCtx, Routes)
        )
    after
        ok = application:set_env(hellgate, inspect_timeout, PrevTimeout),
        ok = application:set_env(hellgate, inspect_parallel_limit, PrevLimit),
        ok = meck:unload(hg_inspector),
        ok = op_context:cleanup(hellgate)
    end.

-spec collect_worker_pids(reference(), non_neg_integer()) -> [pid()].
collect_worker_pids(Ref, Count) ->
    collect_worker_pids(Ref, Count, []).

-spec collect_worker_pids(reference(), non_neg_integer(), [pid()]) -> [pid()].
collect_worker_pids(_Ref, 0, Acc) ->
    lists:usort(Acc);
collect_worker_pids(Ref, Left, Acc) ->
    receive
        {worker_done, Pid, Ref} ->
            collect_worker_pids(Ref, Left - 1, [Pid | Acc])
    after 5000 ->
        error({timeout, #{expected_workers => Left, collected => length(Acc)}})
    end.

-spec test_inspector() -> dmsl_domain_thrift:'Inspector'().
test_inspector() ->
    #domain_Inspector{
        name = <<"test-inspector">>,
        description = <<"test-inspector">>,
        proxy = #domain_Proxy{
            ref = #domain_ProxyRef{id = 1},
            additional = #{}
        }
    }.

-spec test_blacklist_context(hg_route:t()) -> hg_inspector:blacklist_context().
test_blacklist_context(Route) ->
    #{
        route => Route,
        revision => 1,
        inspector => test_inspector()
    }.

-spec test_route(pos_integer()) -> hg_route:t().
test_route(N) ->
    hg_route:new(
        1,
        #domain_ProviderRef{id = N},
        #domain_TerminalRef{id = N},
        ?DOMAIN_CANDIDATE_WEIGHT,
        ?DOMAIN_CANDIDATE_PRIORITY,
        undefined
    ).

-endif.
