-module(hg_terminal_affinity_SUITE).

-include("hg_ct_domain.hrl").
-include("hg_ct_invoice.hrl").
-include("invoice_events.hrl").
-include("payment_events.hrl").
-include("hg_invoice_payment.hrl").
-include_lib("damsel/include/dmsl_customer_thrift.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([email_customer/1, first_and_second_payment/1, prohibition_and_return/1, cascade_and_return/1]).
-export([lower_priority_cascade/1, limit_overflow_and_return/1, disabled_affinity/1, mixed_candidates/1]).
-export([unavailable_init/1, unavailable_routing/1, unavailable_capture/1, collector_affinity/1]).
-export([replay/1, hold_capture_order/1, cancelled_hold/1, expired_deadline/1]).
-export([payment_recorded_once/1]).

-type config() :: hg_ct_helper:config().

-spec all() -> [atom()].
all() ->
    [
        email_customer,
        first_and_second_payment,
        prohibition_and_return,
        cascade_and_return,
        lower_priority_cascade,
        limit_overflow_and_return,
        disabled_affinity,
        mixed_candidates,
        unavailable_init,
        unavailable_routing,
        unavailable_capture,
        collector_affinity,
        replay,
        hold_capture_order,
        cancelled_hold,
        expired_deadline,
        payment_recorded_once
    ].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    C1 = hg_direct_recurrent_tests_SUITE:init_per_suite(C),
    ok = op_context:save(op_context:key(hellgate), op_context:create()),
    Provider0 = #domain_Provider{terms = ProvisionTerms} = hg_domain:get({provider, ?prv(1)}),
    ProviderPayments = ProvisionTerms#domain_ProvisionTermSet.payments,
    Provider = Provider0#domain_Provider{
        terms = ProvisionTerms#domain_ProvisionTermSet{
            payments = ProviderPayments#domain_PaymentsProvisionTerms{
                holds = #domain_PaymentHoldsProvisionTerms{lifetime = {value, #domain_HoldLifetime{seconds = 120}}}
            }
        }
    },
    Terminal = hg_domain:get({terminal, ?trm(1)}),
    _ = hg_domain:upsert(
        lists:append([
            [
                {provider, #domain_ProviderObject{ref = ?prv(ID), data = Provider}},
                {terminal, #domain_TerminalObject{
                    ref = ?trm(ID), data = Terminal#domain_Terminal{provider_ref = ?prv(ID)}
                }}
            ]
         || ID <- [1, 2, 3]
        ])
    ),
    set_hold_lifetime(),
    set_attempt_limit(2),
    set_candidates([{1, 50, 0, true}, {2, 50, 0, true}]),
    Revision = hg_domain:head(),
    ok = op_context:cleanup(hellgate),
    [{affinity_revision, Revision} | C1].

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    hg_direct_recurrent_tests_SUITE:end_per_suite(C).

-spec init_per_testcase(atom(), config()) -> config().
init_per_testcase(Name, C) ->
    C1 = hg_direct_recurrent_tests_SUITE:init_per_testcase(Name, C),
    ok = op_context:save(op_context:key(hellgate), op_context:create()),
    [{email, <<(hg_utils:unique_id())/binary, "@example.test">>} | C1].

-spec end_per_testcase(atom(), config()) -> ok.
end_per_testcase(_Name, C) ->
    lists:foreach(
        fun(Module) ->
            case lists:member(Module, meck:mocked()) of
                true -> meck:unload(Module);
                false -> ok
            end
        end,
        [woody_client, hg_customer_client, hg_limiter, party_client_thrift]
    ),
    _ = hg_domain:reset(cfg(affinity_revision, C)),
    ok = op_context:cleanup(hellgate).

-spec email_customer(config()) -> _.
email_customer(C) ->
    {InvoiceID, PaymentID, Payment, _Events} = pay(C),
    CustomerID = customer_id(Payment),
    ?assertNotEqual(undefined, CustomerID),
    {ok, State} = hg_customer_client:get_by_parent_payment(InvoiceID, PaymentID),
    ?assertEqual(CustomerID, (State#customer_CustomerState.customer)#customer_Customer.id).

-spec first_and_second_payment(config()) -> _.
first_and_second_payment(C) ->
    {_, _, First, _} = pay(C),
    ?assertEqual([First#payproc_InvoicePayment.route], history(First)),
    {_, _, Second, _} = pay(C),
    ?assertEqual(customer_id(First), customer_id(Second)),
    ?assertEqual(First#payproc_InvoicePayment.route, Second#payproc_InvoicePayment.route),
    ?assertEqual(history(First), history(Second)).

-spec prohibition_and_return(config()) -> _.
prohibition_and_return(C) ->
    {_, _, First, _} = pay(C),
    A = terminal_id(First),
    prohibit([A]),
    {_, _, Second, _} = pay(C),
    ?assertNotEqual(A, terminal_id(Second)),
    ?assertEqual([First#payproc_InvoicePayment.route, Second#payproc_InvoicePayment.route], history(Second)),
    prohibit([]),
    {_, _, Third, _} = pay(C),
    ?assertEqual(A, terminal_id(Third)).

-spec cascade_and_return(config()) -> _.
cascade_and_return(C) ->
    {_, _, First, _} = pay(C),
    A = terminal_id(First),
    fail_provider(A, true),
    {_, _, Second, Events} = pay(C),
    ?assertNotEqual(A, terminal_id(Second)),
    ?assertEqual(2, length([R || ?route_changed(R) <- Events])),
    ?assertEqual(2, length(history(Second))),
    fail_provider(A, false),
    {_, _, Third, _} = pay(C),
    ?assertEqual(A, terminal_id(Third)).

-spec lower_priority_cascade(config()) -> _.
lower_priority_cascade(C) ->
    set_candidates([{1, 100, 0, true}]),
    _ = pay(C),
    set_candidates([{2, 50, 20, true}, {3, 50, 10, true}, {1, 100, 0, true}]),
    fail_provider(1, true),
    fail_provider(2, true),
    {InvoiceID, PaymentID} = start_payment(C, instant),
    FailedEvents = await_status(InvoiceID, PaymentID, failed, C),
    ?assertEqual([?trm(1), ?trm(2)], [R#domain_PaymentRoute.terminal || ?route_changed(R) <- FailedEvents]),
    set_attempt_limit(3),
    {_, _, Payment, Events} = pay(C),
    ?assertEqual(3, terminal_id(Payment)),
    ?assertEqual([?trm(1), ?trm(2), ?trm(3)], [R#domain_PaymentRoute.terminal || ?route_changed(R) <- Events]).

-spec limit_overflow_and_return(config()) -> _.
limit_overflow_and_return(C) ->
    {_, _, First, _} = pay(C),
    A = First#payproc_InvoicePayment.route,
    ok = meck:new(hg_limiter, [passthrough]),
    ok = meck:expect(hg_limiter, check_limits, [
        {['_', '_', '_', '_', A, '_'], meck:val({error, {limit_overflow, [<<"affinity-limit">>], []}})},
        {['_', '_', '_', '_', '_', '_'], meck:passthrough()}
    ]),
    {_, _, Second, _} = pay(C),
    ?assertNotEqual(A, Second#payproc_InvoicePayment.route),
    ?assertEqual(2, length(history(Second))),
    ok = meck:unload(hg_limiter),
    {_, _, Third, _} = pay(C),
    ?assertEqual(A, Third#payproc_InvoicePayment.route).

-spec disabled_affinity(config()) -> _.
disabled_affinity(C) ->
    {_, _, First, _} = pay(C),
    BoundRoutes = [First#payproc_InvoicePayment.route],
    ?assertEqual(BoundRoutes, history(First)),
    set_candidates([{1, 50, 0, false}, {2, 50, 0, false}]),
    ok = meck:new(hg_customer_client, [passthrough]),
    {_, _, Second, Events} = pay(C),
    ?assertEqual([false], [
        Decision#payproc_RouteDecisionContext.terminal_affinity
     || ?route_changed(_, _, _, _, Decision) <- Events
    ]),
    ?assertEqual([undefined], [
        Decision#payproc_RouteDecisionContext.affinity_ttl
     || ?route_changed(_, _, _, _, Decision) <- Events
    ]),
    ?assertEqual(0, meck:num_calls(hg_customer_client, get_terminal_affinities, '_')),
    ?assertEqual(0, meck:num_calls(hg_customer_client, bind_terminal_affinity, '_')),
    ?assertEqual(BoundRoutes, history(Second)),
    ok = meck:unload(hg_customer_client),
    set_candidates([{1, 50, 0, true}, {2, 50, 0, true}]),
    {_, _, Third, _} = pay(C),
    ?assertEqual(terminal_id(First), terminal_id(Third)).

-spec mixed_candidates(config()) -> _.
mixed_candidates(C) ->
    set_candidates([{1, 0, 0, true}, {2, 100, 0, false}]),
    {_, _, First, _} = pay(C),
    ?assertEqual(2, terminal_id(First)),
    ?assertEqual([], history(First)),
    set_candidates([{1, 100, 0, true}, {2, 0, 0, false}]),
    {_, _, Second, _} = pay(C),
    ?assertEqual(1, terminal_id(Second)),
    ?assertEqual([Second#payproc_InvoicePayment.route], history(Second)).

-spec unavailable_init(config()) -> _.
unavailable_init(C) ->
    unavailable(['FindOrCreateByEmail']),
    {_, _, Payment, _} = pay(C),
    ?assertEqual(undefined, customer_id(Payment)),
    assert_unavailable('FindOrCreateByEmail').

-spec unavailable_routing(config()) -> _.
unavailable_routing(C) ->
    set_candidates([{1, 100, 10, true}, {2, 100, 0, true}]),
    fail_provider(1, true),
    unavailable(['GetTerminalAffinities']),
    {_, _, _Payment, Events} = pay(C),
    ?assertEqual([[]], [A || ?terminal_affinities_loaded(A) <- Events]),
    ?assertEqual(
        1,
        meck:num_calls(woody_client, call, [{'_', 'GetTerminalAffinities', '_'}, '_', '_'])
    ),
    assert_unavailable('GetTerminalAffinities').

-spec unavailable_capture(config()) -> _.
unavailable_capture(C) ->
    unavailable(['AddPayment', 'AddBankCard', 'BindTerminalAffinity']),
    _ = pay(C),
    assert_unavailable('AddPayment'),
    assert_unavailable('BindTerminalAffinity').

-spec collector_affinity(config()) -> _.
collector_affinity(_C) ->
    op_context:save(
        op_context:key(hellgate), op_context:set_party_client(party_client:create_client(), op_context:create())
    ),
    Affinity = #domain_RoutingAffinity{ttl = {since_bound, 3600}},
    Candidate = #domain_RoutingCandidate{
        terminal = ?trm(1), allowed = {constant, true}, affinity = Affinity
    },
    ok = meck:new(party_client_thrift, [passthrough]),
    ok = meck:expect(party_client_thrift, compute_routing_ruleset, fun(_, _, _, _, _) ->
        {ok, #domain_RoutingRuleset{name = <<"affinity">>, decisions = {candidates, [Candidate]}}}
    end),
    PI = hg_domain:get({payment_institution, ?pinst(1)}),
    #{routes := Routes} = hg_route_collector:get_routes(
        hg_domain:head(),
        #{},
        PI,
        #{
            currency => ?cur(<<"RUB">>),
            payment_tool => {generic, #domain_GenericPaymentTool{payment_service = ?pmt_srv(<<"test">>)}},
            client_ip => undefined
        }
    ),
    ?assert(hg_route_affinity:enabled(Routes)),
    ?assertEqual([Affinity], [hg_route:affinity(R) || R <- Routes]).

-spec replay(config()) -> _.
replay(C) ->
    Affinity = #domain_RoutingAffinity{ttl = {since_bound, 3600}},
    set_rules(2, [#domain_RoutingCandidate{terminal = ?trm(1), allowed = {constant, true}, affinity = Affinity}]),
    _ = pay(C),
    {InvoiceID, PaymentID, Payment, Events} = pay(C),
    Opts = #{invoice_id => InvoiceID, timestamp => <<"2026-01-01T00:00:00Z">>},
    State = hg_invoice_payment:collapse_changes(Events, undefined, Opts),
    ?assertEqual(Payment#payproc_InvoicePayment.route, hg_invoice_payment:get_route(State)),
    ?assertMatch([_], State#st.terminal_affinities),
    ?assert(State#st.route_affinity),
    ?assertEqual(State, hg_invoice_payment:collapse_changes(Events, undefined, Opts)),
    {ok, History} = prg_machine:get_history(hg_invoice:namespace(), InvoiceID, undefined, undefined),
    Machine = #{
        namespace => hg_invoice:namespace(),
        id => InvoiceID,
        history => hg_invoice:unmarshal_history(History),
        aux_state => #{}
    },
    {ok, Replayed} = hg_invoice:get_payment(PaymentID, prg_machine:collapse(hg_invoice, Machine)),
    ?assertEqual(State#st.routes, Replayed#st.routes),
    ?assertEqual(State#st.terminal_affinities, Replayed#st.terminal_affinities),
    ?assertEqual(Affinity#domain_RoutingAffinity.ttl, State#st.affinity_ttl),
    ?assertEqual(State#st.affinity_ttl, Replayed#st.affinity_ttl).

-spec hold_capture_order(config()) -> _.
hold_capture_order(C) ->
    set_candidates([{1, 100, 0, true}]),
    {InvoiceID, PaymentID} = start_payment(C, hold),
    _ = await_status(InvoiceID, PaymentID, processed, C),
    set_candidates([{2, 100, 0, true}]),
    {_, _, Instant, _} = pay(C),
    ?assertEqual(2, terminal_id(Instant)),
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"capture">>, cfg(client, C)),
    _ = await_status(InvoiceID, PaymentID, captured, C),
    ?assertEqual(
        [
            #domain_PaymentRoute{provider = ?prv(2), terminal = ?trm(2)},
            #domain_PaymentRoute{provider = ?prv(1), terminal = ?trm(1)}
        ],
        history(Instant)
    ).

-spec cancelled_hold(config()) -> _.
cancelled_hold(C) ->
    {InvoiceID, PaymentID} = start_payment(C, hold),
    _ = await_status(InvoiceID, PaymentID, processed, C),
    ok = hg_client_invoicing:cancel_payment(InvoiceID, PaymentID, <<"cancel">>, cfg(client, C)),
    _ = await_status(InvoiceID, PaymentID, cancelled, C),
    Payment = hg_client_invoicing:get_payment(InvoiceID, PaymentID, cfg(client, C)),
    ?assertEqual([], history(Payment)),
    {ok, Customer} = hg_woody_wrapper:call(customer_management, 'Get', {customer_id(Payment)}),
    ?assertEqual([], Customer#customer_CustomerState.payment_refs).

-spec expired_deadline(config()) -> _.
expired_deadline(C) ->
    set_rules(2, [
        #domain_RoutingCandidate{
            terminal = ?trm(1),
            allowed = {constant, true},
            affinity = #domain_RoutingAffinity{ttl = {deadline, <<"2000-01-01T00:00:00Z">>}}
        }
    ]),
    {_, _, Payment, _} = pay(C),
    ?assertEqual([], history(Payment)).

%% The payment must reach the Customer exactly once down either branch: a binding
%% remembers it with the same call, without one a separate AddPayment remains
-spec payment_recorded_once(config()) -> _.
payment_recorded_once(C) ->
    ok = meck:new(hg_customer_client, [passthrough]),
    {InvoiceID, PaymentID, First, _} = pay(C),
    CustomerID = customer_id(First),
    ?assertEqual([First#payproc_InvoicePayment.route], history(First)),
    ?assertEqual(1, meck:num_calls(hg_customer_client, bind_terminal_affinity, '_')),
    ?assertEqual(0, meck:num_calls(hg_customer_client, add_payment, '_')),
    ?assertEqual([{InvoiceID, PaymentID}], payment_refs(CustomerID)),
    set_candidates([{1, 50, 0, false}, {2, 50, 0, false}]),
    {NextInvoiceID, NextPaymentID, Second, _} = pay(C),
    ?assertEqual(CustomerID, customer_id(Second)),
    ?assertEqual(1, meck:num_calls(hg_customer_client, bind_terminal_affinity, '_')),
    ?assertEqual(1, meck:num_calls(hg_customer_client, add_payment, '_')),
    ?assertEqual(
        lists:sort([{InvoiceID, PaymentID}, {NextInvoiceID, NextPaymentID}]),
        lists:sort(payment_refs(CustomerID))
    ).

cfg(Key, C) -> hg_ct_helper:cfg(Key, C).

payment_refs(CustomerID) ->
    {ok, State} = hg_woody_wrapper:call(customer_management, 'Get', {CustomerID}),
    [
        {InvoiceID, PaymentID}
     || #customer_PaymentRef{invoice_id = InvoiceID, payment_id = PaymentID} <-
            State#customer_CustomerState.payment_refs
    ].

customer_id(#payproc_InvoicePayment{payment = Payment}) -> Payment#domain_InvoicePayment.customer_id.

terminal_id(#payproc_InvoicePayment{route = #domain_PaymentRoute{terminal = #domain_TerminalRef{id = ID}}}) -> ID.

history(Payment) ->
    {ok, Affinities} = hg_customer_client:get_terminal_affinities(customer_id(Payment)),
    [
        #domain_PaymentRoute{provider = P, terminal = T}
     || #customer_TerminalAffinity{provider_ref = P, terminal_ref = T} <- Affinities
    ].

pay(C) ->
    {InvoiceID, PaymentID} = start_payment(C, instant),
    Events = await_status(InvoiceID, PaymentID, captured, C),
    Payment = hg_client_invoicing:get_payment(InvoiceID, PaymentID, cfg(client, C)),
    ?assertMatch(#payproc_InvoicePayment{payment = #domain_InvoicePayment{status = ?captured()}}, Payment),
    {InvoiceID, PaymentID, Payment, Events}.

start_payment(C, FlowType) ->
    Client = cfg(client, C),
    Params = hg_ct_helper:make_invoice_params(
        cfg(party_config_ref, C),
        cfg(shop_config_ref, C),
        <<"terminal affinity">>,
        genlib_time:unow() + 60,
        hg_ct_helper:make_cash(42000, <<"RUB">>)
    ),
    ?invoice_state(?invoice(InvoiceID)) = hg_client_invoicing:create(Params, Client),
    {{bank_card, Card}, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    Token = <<(Card#domain_BankCard.token)/binary, "/", (hg_utils:unique_id())/binary>>,
    Flow =
        case FlowType of
            instant -> {instant, #payproc_InvoicePaymentParamsFlowInstant{}};
            hold -> {hold, #payproc_InvoicePaymentParamsFlowHold{on_hold_expiration = cancel}}
        end,
    PaymentParams = #payproc_InvoicePaymentParams{
        flow = Flow,
        make_recurrent = false,
        payer =
            {payment_resource, #payproc_PaymentResourcePayerParams{
                resource = #domain_DisposablePaymentResource{
                    payment_tool = {bank_card, Card#domain_BankCard{token = Token}},
                    payment_session_id = Session,
                    client_info = #domain_ClientInfo{}
                },
                contact_info = #domain_ContactInfo{email = cfg(email, C)}
            }}
    },
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    {InvoiceID, PaymentID}.

await_status(InvoiceID, PaymentID, Status, C) ->
    await_status(InvoiceID, PaymentID, Status, C, []).

await_status(InvoiceID, PaymentID, Status, C, Acc) ->
    case hg_client_invoicing:pull_event(InvoiceID, 12000, cfg(client, C)) of
        {ok, ?invoice_ev(Changes)} ->
            Events = [E || ?payment_ev(ID, E) <- Changes, ID =:= PaymentID],
            All = Acc ++ Events,
            case
                lists:any(
                    fun
                        (?payment_status_changed({S, _})) -> S =:= Status;
                        (_) -> false
                    end,
                    Events
                )
            of
                true -> All;
                false -> await_status(InvoiceID, PaymentID, Status, C, All)
            end;
        Result ->
            ct:fail({payment_status_timeout, Status, Result, Acc})
    end.

set_hold_lifetime() ->
    Hierarchy = #domain_TermSetHierarchy{term_set = Terms} = hg_domain:get({term_set_hierarchy, ?trms(1)}),
    Payments = Terms#domain_TermSet.payments,
    Holds = Payments#domain_PaymentsServiceTerms.holds,
    _ = hg_domain:upsert([
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = Hierarchy#domain_TermSetHierarchy{
                term_set = Terms#domain_TermSet{
                    payments = Payments#domain_PaymentsServiceTerms{
                        holds = Holds#domain_PaymentHoldsServiceTerms{
                            lifetime = {value, #domain_HoldLifetime{seconds = 120}}
                        }
                    }
                }
            }
        }}
    ]),
    ok.

set_attempt_limit(Attempts) ->
    Hierarchy = #domain_TermSetHierarchy{term_set = Terms} = hg_domain:get({term_set_hierarchy, ?trms(1)}),
    Payments = Terms#domain_TermSet.payments,
    _ = hg_domain:upsert([
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = Hierarchy#domain_TermSetHierarchy{
                term_set = Terms#domain_TermSet{
                    payments = Payments#domain_PaymentsServiceTerms{
                        attempt_limit = {value, #domain_AttemptLimit{attempts = Attempts}}
                    }
                }
            }
        }}
    ]),
    ok.

set_candidates(Candidates) ->
    set_rules(2, [
        #domain_RoutingCandidate{
            terminal = ?trm(ID),
            allowed = {constant, true},
            weight = Weight,
            priority = Priority,
            affinity =
                case Enabled of
                    true -> #domain_RoutingAffinity{};
                    false -> undefined
                end
        }
     || {ID, Weight, Priority, Enabled} <- Candidates
    ]).

prohibit(IDs) ->
    set_rules(1, [#domain_RoutingCandidate{terminal = ?trm(ID), allowed = {constant, true}} || ID <- IDs]).

set_rules(ID, Candidates) ->
    _ = hg_domain:upsert([
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(ID),
            data = #domain_RoutingRuleset{name = <<"terminal affinity">>, decisions = {candidates, Candidates}}
        }}
    ]),
    ok.

fail_provider(ID, Fail) ->
    Provider = hg_domain:get({provider, ?prv(ID)}),
    Proxy = Provider#domain_Provider.proxy,
    Additional =
        case Fail of
            true ->
                #{
                    <<"always_fail">> => <<"preauthorization_failed:card_blocked">>,
                    <<"override">> => <<"affinity_failure">>
                };
            false ->
                #{}
        end,
    _ = hg_domain:upsert([
        {provider, #domain_ProviderObject{
            ref = ?prv(ID),
            data = Provider#domain_Provider{proxy = Proxy#domain_Proxy{additional = Additional}}
        }}
    ]),
    ok.

unavailable(Functions) ->
    ok = meck:new(woody_client, [passthrough]),
    ok = meck:expect(woody_client, call, fun({_, Function, _} = Request, Opts, Context) ->
        case lists:member(Function, Functions) of
            true ->
                ?assert(woody_deadline:to_timeout(woody_context:get_deadline(Context)) =< 1000),
                timer:sleep(10),
                %% The source in the term is internal | external; woody never yields the atom system
                error({woody_error, {internal, resource_unavailable, <<"timeout">>}});
            false ->
                meck:passthrough([Request, Opts, Context])
        end
    end).

assert_unavailable(Op) ->
    ?assert(prometheus_counter:value(customer_unavailable, [Op]) > 0).
