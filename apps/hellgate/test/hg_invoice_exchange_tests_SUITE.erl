-module(hg_invoice_exchange_tests_SUITE).

-include_lib("hellgate/include/hg_invoice.hrl").
-include_lib("hellgate/include/payment_events.hrl").
-include_lib("hellgate/include/invoice_events.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("hg_ct_domain.hrl").
-include("hg_ct_invoice.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

%% Tests
-export([payment_success/1]).
-export([payment_and_refund_with_increased_cost/1]).
-export([accept_payment_chargeback_new_body/1]).
-export([payment_adjustment_success/1]).
-export([payment_failed_exchange_rate_unknown/1]).
-export([payment_failed_exchange_rate_timeout/1]).
-export([payment_failed_exchange_rate_unexpected/1]).

-type config() :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().
-type group_name() :: hg_ct_helper:group_name().
-type test_return() :: _ | no_return().

%% Supervisor
-behaviour(supervisor).

-export([init/1]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 1, period => 1}, []}}.

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [
        payment_success,
        payment_and_refund_with_increased_cost,
        accept_payment_chargeback_new_body,
        payment_adjustment_success,
        payment_failed_exchange_rate_unknown,
        payment_failed_exchange_rate_timeout,
        payment_failed_exchange_rate_unexpected
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    CowboySpec = hg_dummy_provider:get_http_cowboy_spec(),
    {Apps, Ret} = hg_ct_helper:start_apps([
        woody,
        scoper,
        dmt_client,
        bender_client,
        party_client,
        hg_proto,
        epg_connector,
        progressor,
        hellgate,
        {cowboy, CowboySpec},
        snowflake
    ]),
    application:set_env(hellgate, currency_exchange_enabled, true),
    RootUrl = maps:get(hellgate_root_url, Ret),
    _ = hg_limiter_helper:init_per_suite(C),
    _ = hg_domain:upsert(hg_invoice_dummy_data:construct_domain_fixture()),
    PartyConfigRef = #domain_PartyConfigRef{id = hg_utils:unique_id()},
    PartyClient = {party_client:create_client(), party_client:create_context()},
    ok = hg_context:save(hg_context:create()),
    %% все магазины рублёвые, но каждая категория роутится на терминалы с раными валютами
    ShopConfigRef = hg_ct_helper:create_party_and_shop(
        PartyConfigRef, ?cat(2), <<"RUB">>, ?trms(1), ?pinst(1), PartyClient
    ),
    ShopConfigRefEur = hg_ct_helper:create_party_and_shop(
        PartyConfigRef, ?cat(3), <<"RUB">>, ?trms(1), ?pinst(1), PartyClient
    ),
    ShopConfigRefJpy = hg_ct_helper:create_party_and_shop(
        PartyConfigRef, ?cat(4), <<"RUB">>, ?trms(1), ?pinst(1), PartyClient
    ),
    ShopConfigRefCny = hg_ct_helper:create_party_and_shop(
        PartyConfigRef, ?cat(5), <<"RUB">>, ?trms(1), ?pinst(1), PartyClient
    ),
    ok = hg_context:cleanup(),
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    _ = unlink(SupPid),
    ok = hg_invoice_helper:start_kv_store(SupPid),
    _ = start_exchange_service_handler([{test_sup, SupPid} | C]),
    NewC = [
        {party_config_ref, PartyConfigRef},
        {shop_config_ref, ShopConfigRef},
        {shop_config_ref_eur, ShopConfigRefEur},
        {shop_config_ref_jpy, ShopConfigRefJpy},
        {shop_config_ref_cny, ShopConfigRefCny},
        {root_url, RootUrl},
        {test_sup, SupPid},
        {apps, Apps}
        | C
    ],
    ok = hg_invoice_helper:start_proxies([{hg_dummy_provider, 1, NewC}, {hg_dummy_inspector, 2, NewC}]),
    NewC.

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    _ = hg_domain:cleanup(),
    _ = application:stop(progressor),
    _ = hg_progressor:cleanup(),
    _ = [application:stop(App) || App <- cfg(apps, C)],
    hg_invoice_helper:stop_kv_store(cfg(test_sup, C)),
    exit(cfg(test_sup, C), shutdown).

-spec init_per_group(group_name(), config()) -> config().
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(_, C) ->
    ApiClient = hg_ct_helper:create_client(hg_ct_helper:cfg(root_url, C)),
    Client = hg_client_invoicing:start_link(ApiClient),
    ok = hg_context:save(hg_context:create()),
    [
        {client, Client}
        | C
    ].

-spec end_per_testcase(test_case_name(), config()) -> config().
end_per_testcase(_, C) ->
    C.

%% TESTS

-spec payment_success(config()) -> test_return().
payment_success(C) ->
    Client = cfg(client, C),

    InvoiceID = hg_invoice_helper:start_invoice(<<"rubberduck">>, hg_invoice_helper:make_due_date(10), 42000, C),
    PaymentParams = hg_invoice_helper:make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentID = hg_invoice_helper:process_payment(InvoiceID, PaymentParams, Client),
    PaymentID = hg_invoice_helper:await_payment_capture(InvoiceID, PaymentID, Client),
    #payproc_Invoice{payments = [Payment]} = hg_client_invoicing:get(InvoiceID, Client),
    #payproc_InvoicePayment{cash_flow = CashFlow} = Payment,
    [
        #domain_FinalCashFlowPosting{
            volume = ConvertedCash,
            exchange_context = ExchangeContext
        }
    ] = lookup_posting(CashFlow, {system, settlement}, {provider, settlement}),
    %% Expected Cash: converted 800 RUB from fixed 10 USD
    ExpectCash = #domain_Cash{amount = 800, currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>}},
    ?assertEqual(ExpectCash, ConvertedCash),
    ExpectContext = #domain_ExchangeContext{
        source_currency = <<"RUB">>,
        destination_currency = <<"USD">>,
        exchange_rate = #base_Rational{p = 80, q = 1}
    },
    ?assertEqual(ExpectContext, ExchangeContext),
    ok.

-spec payment_and_refund_with_increased_cost(config()) -> test_return().
payment_and_refund_with_increased_cost(C) ->
    Client = cfg(client, C),

    % top up merchant account
    InvoiceID2 = hg_invoice_helper:start_invoice(
        <<"rubberduck">>,
        hg_invoice_helper:make_due_date(10),
        42800,
        C
    ),
    _PaymentID2 = hg_invoice_helper:execute_payment(
        InvoiceID2,
        hg_invoice_helper:make_payment_params(?pmt_sys(<<"visa-ref">>)),
        Client
    ),

    InvoiceID = hg_invoice_helper:start_invoice(<<"rubberduck">>, hg_invoice_helper:make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(
        change_currency_and_increase,
        ?pmt_sys(<<"visa-ref">>)
    ),
    PaymentParams = hg_invoice_helper:make_payment_params(PaymentTool, Session, instant),
    PaymentID = hg_invoice_helper:start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = hg_invoice_helper:await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(_)))),
        ?payment_ev(PaymentID, ?cash_changed(_, _)),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?cash_flow_changed(_)),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = hg_invoice_helper:next_changes(InvoiceID, 5, Client),
    PaymentID = hg_invoice_helper:await_payment_capture(InvoiceID, PaymentID, Client),
    #payproc_Invoice{
        payments = [
            #payproc_InvoicePayment{
                payment = #domain_InvoicePayment{
                    changed_cost =
                        #domain_Cash{
                            amount = ChangedAmount,
                            currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>}
                        } = ChangedCost
                },
                route = Route,
                cash_flow = CashFlow
            }
        ]
    } = hg_client_invoicing:get(InvoiceID, Client),
    %% changed cost: 42800 = 42000 RUB + (10 USD * 80)
    ?assertEqual(42800, ChangedAmount),
    [
        #domain_FinalCashFlowPosting{
            volume = #domain_Cash{
                amount = ChangedVolumeAmount,
                currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>}
            },
            exchange_context = _ExchangeContext
        }
    ] = lookup_posting(CashFlow, {provider, settlement}, {merchant, settlement}),
    ?assertEqual(42800, ChangedVolumeAmount),

    CFContext = hg_invoice_helper:construct_ta_context(cfg(party_config_ref, C), cfg(shop_config_ref, C), Route),
    PrvAccount1 = get_deprecated_cashflow_account({provider, settlement}, CashFlow, CFContext),
    SysAccount1 = get_deprecated_cashflow_account({system, settlement}, CashFlow, CFContext),
    MrcAccount1 = get_deprecated_cashflow_account({merchant, settlement}, CashFlow, CFContext),

    %% payment with changed cost are captured
    %% now refund it

    RefundParams = make_refund_params(),
    % create a refund finally
    RefundID = hg_invoice_helper:execute_payment_refund(InvoiceID, PaymentID, RefundParams, Client),
    #domain_InvoicePaymentRefund{status = ?refund_succeeded()} =
        hg_client_invoicing:get_payment_refund(InvoiceID, PaymentID, RefundID, Client),

    % no more refunds for you
    {exception, #payproc_InvalidPaymentStatus{status = ?refunded()}} =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),

    Context = #{operation_amount => ChangedCost},
    PrvAccount2 = get_deprecated_cashflow_account({provider, settlement}, CashFlow, CFContext),
    SysAccount2 = get_deprecated_cashflow_account({system, settlement}, CashFlow, CFContext),
    MrcAccount2 = get_deprecated_cashflow_account({merchant, settlement}, CashFlow, CFContext),
    #domain_Cash{amount = MrcAmountFixed} = hg_cashflow:compute_volume(?fixed(100, <<"RUB">>), Context),
    #domain_Cash{amount = PrvAmountFixed} = hg_cashflow:compute_volume(?fixed(800, <<"RUB">>), Context),
    ?assertEqual(
        maps:get(own_amount, MrcAccount2),
        maps:get(own_amount, MrcAccount1) - ChangedAmount - MrcAmountFixed
    ),
    ?assertEqual(
        maps:get(own_amount, PrvAccount2),
        maps:get(own_amount, PrvAccount1) + ChangedAmount + PrvAmountFixed
    ),
    ?assertEqual(
        MrcAmountFixed - PrvAmountFixed,
        maps:get(own_amount, SysAccount2) - maps:get(own_amount, SysAccount1)
    ),
    ok.

-spec accept_payment_chargeback_new_body(config()) -> _ | no_return().
accept_payment_chargeback_new_body(C) ->
    %% new shop with new balances
    PartyConfigRef = cfg(party_config_ref, C),
    PartyPair = cfg(party_client, C),
    UpdShopConfigRef =
        hg_ct_helper:create_battle_ready_shop(PartyConfigRef, ?cat(2), <<"RUB">>, ?trms(1), ?pinst(1), PartyPair),
    NewC = lists:keyreplace(shop_config_ref, 1, C, {shop_config_ref, UpdShopConfigRef}),

    Client = cfg(client, NewC),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 5000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    PaymentParams = hg_invoice_helper:make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ExchangeContext = #domain_ExchangeContext{
        source_currency = <<"RUB">>,
        destination_currency = <<"USD">>,
        exchange_rate = #base_Rational{p = 80, q = 1}
    },
    {IID, PID, SID, CB} =
        hg_invoice_helper:start_chargeback(NewC, Cost, CBParams, PaymentParams),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(CF1)))
    ] = hg_invoice_helper:next_changes(IID, 2, Client),
    %% shared cash volume
    [
        #domain_FinalCashFlowPosting{
            volume = #domain_Cash{
                amount = Cost,
                currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>}
            },
            exchange_context = ExchangeContext
        }
    ] = lookup_posting(CF1, {merchant, settlement}, {provider, settlement}),
    %% fixed cash volume
    [
        #domain_FinalCashFlowPosting{
            volume = #domain_Cash{
                amount = 800,
                currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>}
            },
            exchange_context = ExchangeContext
        }
    ] = lookup_posting(CF1, {system, settlement}, {provider, settlement}),
    Settlement0 = hg_accounting:get_balance(SID),
    Body = 40000,
    AcceptParams = make_chargeback_accept_params(undefined, ?cash(Body, <<"RUB">>)),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_body_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(CF2))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted())))
    ] = hg_invoice_helper:next_changes(IID, 4, Client),
    %% shared cash volume
    [
        #domain_FinalCashFlowPosting{
            volume = #domain_Cash{
                amount = Body,
                currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>}
            },
            exchange_context = ExchangeContext
        }
    ] = lookup_posting(CF2, {merchant, settlement}, {provider, settlement}),
    %% fixed cash volume
    [
        #domain_FinalCashFlowPosting{
            volume = #domain_Cash{
                amount = 800,
                currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>}
            },
            exchange_context = ExchangeContext
        }
    ] = lookup_posting(CF2, {system, settlement}, {provider, settlement}),
    Settlement1 = hg_accounting:get_balance(SID),

    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - Body - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - Body - LevyAmount, maps:get(max_available_amount, Settlement1)),
    ok.

-spec payment_adjustment_success(config()) -> test_return().
payment_adjustment_success(C) ->
    %% old cf :
    %% merch - 1890   -> syst
    %% prov  - 42000  -> merch (with exchange)
    %% syst  - 800    -> prov (fixed, with exchange from 10 USD)
    %%
    %% new cf :
    %% merch - 1890   -> syst
    %% prov  - 42000  -> merch (with exchange)
    %% syst  - 400    -> prov (fixed, with exchange from 5 USD)
    Client = cfg(client, C),

    InvoiceID = hg_invoice_helper:start_invoice(<<"rubberduck">>, hg_invoice_helper:make_due_date(10), 42000, C),
    PaymentParams = hg_invoice_helper:make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentID = hg_invoice_helper:process_payment(InvoiceID, PaymentParams, Client),
    PaymentID = hg_invoice_helper:await_payment_capture(InvoiceID, PaymentID, Client),
    ExchangeContext = #domain_ExchangeContext{
        source_currency = <<"RUB">>,
        destination_currency = <<"USD">>,
        exchange_rate = #base_Rational{p = 80, q = 1}
    },
    #payproc_Invoice{
        payments = [
            #payproc_InvoicePayment{
                route = Route,
                cash_flow = CF1
            }
        ]
    } = hg_client_invoicing:get(InvoiceID, Client),
    %% System -> Provider fixed cash volume 800 RUB (10 USD * 80)
    [
        #domain_FinalCashFlowPosting{
            volume = #domain_Cash{
                amount = 800,
                currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>}
            },
            exchange_context = ExchangeContext
        }
    ] = lookup_posting(CF1, {system, settlement}, {provider, settlement}),

    CFContext = hg_invoice_helper:construct_ta_context(cfg(party_config_ref, C), cfg(shop_config_ref, C), Route),
    PrvAccount1 = get_deprecated_cashflow_account({provider, settlement}, CF1, CFContext),
    SysAccount1 = get_deprecated_cashflow_account({system, settlement}, CF1, CFContext),
    MrcAccount1 = get_deprecated_cashflow_account({merchant, settlement}, CF1, CFContext),

    %% update terminal cashflow
    ok = update_payment_terms_cashflow(?trm(2)),

    %% make an adjustment
    Params = make_adjustment_params(Reason = <<"imdrunk">>),
    ?adjustment(AdjustmentID, ?adjustment_pending()) =
        Adjustment =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, Params, Client),
    Adjustment =
        #domain_InvoicePaymentAdjustment{id = AdjustmentID, reason = Reason} =
        hg_client_invoicing:get_payment_adjustment(InvoiceID, PaymentID, AdjustmentID, Client),
    ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_created(Adjustment))) =
        hg_invoice_helper:next_change(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_status_changed(?adjustment_processed()))),
        ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_status_changed(?adjustment_captured(_))))
    ] = hg_invoice_helper:next_changes(InvoiceID, 2, Client),
    %% verify that cash deposited correctly everywhere
    #domain_InvoicePaymentAdjustment{new_cash_flow = DCF2} = Adjustment,
    %% System -> Provider change fixed cash volume 400 RUB (5 USD * 80)
    [
        #domain_FinalCashFlowPosting{
            volume = #domain_Cash{
                amount = 400,
                currency = #domain_CurrencyRef{symbolic_code = <<"RUB">>}
            },
            exchange_context = ExchangeContext
        }
    ] = lookup_posting(DCF2, {system, settlement}, {provider, settlement}),

    PrvAccount2 = get_deprecated_cashflow_account({provider, settlement}, DCF2, CFContext),
    SysAccount2 = get_deprecated_cashflow_account({system, settlement}, DCF2, CFContext),
    MrcAccount2 = get_deprecated_cashflow_account({merchant, settlement}, DCF2, CFContext),

    0 = MrcDiff = maps:get(own_amount, MrcAccount2) - maps:get(own_amount, MrcAccount1),
    -400 = PrvDiff = maps:get(own_amount, PrvAccount2) - maps:get(own_amount, PrvAccount1),
    SysDiff = MrcDiff - PrvDiff,
    SysDiff = maps:get(own_amount, SysAccount2) - maps:get(own_amount, SysAccount1),
    ok.

-spec payment_failed_exchange_rate_unknown(config()) -> test_return().
payment_failed_exchange_rate_unknown(C) ->
    Client = cfg(client, C),

    InvoiceID = hg_invoice_helper:start_invoice(
        cfg(shop_config_ref_eur, C),
        <<"rubberduck">>,
        hg_invoice_helper:make_due_date(10),
        42000,
        C
    ),
    PaymentParams = hg_invoice_helper:make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    _ = hg_invoice_helper:start_payment_ev(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?payment_rollback_started(_)),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed(_)))
    ] = hg_invoice_helper:next_changes(InvoiceID, 2, Client),
    ok.

-spec payment_failed_exchange_rate_timeout(config()) -> test_return().
payment_failed_exchange_rate_timeout(C) ->
    Client = cfg(client, C),

    InvoiceID = hg_invoice_helper:start_invoice(
        cfg(shop_config_ref_jpy, C),
        <<"rubberduck">>,
        hg_invoice_helper:make_due_date(10),
        42000,
        C
    ),
    PaymentParams = hg_invoice_helper:make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    _ = hg_invoice_helper:start_payment_ev(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?payment_rollback_started(_)),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed(_)))
    ] = hg_invoice_helper:next_changes(InvoiceID, 2, Client),
    ok.

-spec payment_failed_exchange_rate_unexpected(config()) -> test_return().
payment_failed_exchange_rate_unexpected(C) ->
    Client = cfg(client, C),

    InvoiceID = hg_invoice_helper:start_invoice(
        cfg(shop_config_ref_cny, C),
        <<"rubberduck">>,
        hg_invoice_helper:make_due_date(10),
        42000,
        C
    ),
    PaymentParams = hg_invoice_helper:make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    _ = hg_invoice_helper:start_payment_ev(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?payment_rollback_started(_)),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed(_)))
    ] = hg_invoice_helper:next_changes(InvoiceID, 2, Client),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Internals
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_exchange_service_handler(C) ->
    Module = hg_dummy_exrates,
    IP = "127.0.0.1",
    Port = 32022,
    ChildSpec = hg_test_proxy:get_child_spec(Module, Module, IP, Port, #{}),
    {ok, _} = supervisor:start_child(hg_ct_helper:cfg(test_sup, C), ChildSpec),
    hg_test_proxy:get_url(Module, IP, Port).

cfg(Key, Config) ->
    hg_ct_helper:cfg(Key, Config).

make_chargeback_params(Levy) ->
    #payproc_InvoicePaymentChargebackParams{
        id = hg_utils:unique_id(),
        reason = #domain_InvoicePaymentChargebackReason{
            code = <<"CB.C0DE">>,
            category = {fraud, #domain_InvoicePaymentChargebackCategoryFraud{}}
        },
        levy = Levy,
        occurred_at = hg_datetime:format_now()
    }.

make_chargeback_accept_params(Levy, Body) ->
    #payproc_InvoicePaymentChargebackAcceptParams{
        body = Body,
        levy = Levy
    }.

make_refund_params() ->
    #payproc_InvoicePaymentRefundParams{
        reason = <<"ZANOZED">>
    }.

make_adjustment_params(Reason) ->
    make_adjustment_params(Reason, undefined, undefined).

make_adjustment_params(Reason, Revision, Amount) ->
    #payproc_InvoicePaymentAdjustmentParams{
        reason = Reason,
        scenario =
            {cash_flow, #domain_InvoicePaymentAdjustmentCashFlow{
                domain_revision = Revision,
                new_amount = Amount
            }}
    }.

get_deprecated_cashflow_account(Type, CF, CFContext) ->
    hg_invoice_helper:get_deprecated_cashflow_account(Type, CF, CFContext).

update_payment_terms_cashflow(TerminalRef) ->
    NewCashFlow = [
        ?cfpost(
            {provider, settlement},
            {merchant, settlement},
            ?share(1, 1, operation_amount)
        ),
        ?cfpost(
            {system, settlement},
            {provider, settlement},
            ?fixed(5, <<"USD">>)
        )
    ],
    Terminal = hg_domain:get({terminal, TerminalRef}),
    TerminalTerms = Terminal#domain_Terminal.terms,
    PaymentTerms = TerminalTerms#domain_ProvisionTermSet.payments,
    NewTerminal = Terminal#domain_Terminal{
        terms = TerminalTerms#domain_ProvisionTermSet{
            payments = PaymentTerms#domain_PaymentsProvisionTerms{
                cash_flow = {value, NewCashFlow}
            }
        }
    },
    _ = hg_domain:upsert(
        {terminal, #domain_TerminalObject{
            ref = TerminalRef,
            data = NewTerminal
        }}
    ),
    ok.

lookup_posting(CashFlow, Source, Destination) ->
    lists:filter(
        fun(
            #domain_FinalCashFlowPosting{
                source = #domain_FinalCashFlowAccount{account_type = SourceAcc},
                destination = #domain_FinalCashFlowAccount{account_type = DestinationAcc}
            }
        ) ->
            Source =:= SourceAcc andalso Destination =:= DestinationAcc
        end,
        CashFlow
    ).
