-module(hg_invoice_cashflow_SUITE).

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
-export([payment_with_provider_settlement_account/1]).
-export([payment_with_provider_guarantee_account/1]).
-export([payment_undefined_provider_guarantee_accout/1]).

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
        payment_with_provider_settlement_account,
        payment_with_provider_guarantee_account,
        payment_undefined_provider_guarantee_accout
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
    RootUrl = maps:get(hellgate_root_url, Ret),
    _ = hg_limiter_helper:init_per_suite(C),
    _ = hg_domain:upsert(hg_invoice_dummy_data:construct_domain_fixture()),
    PartyConfigRef = #domain_PartyConfigRef{id = hg_utils:unique_id()},
    PartyClient = {party_client:create_client(), party_client:create_context()},
    ok = op_context:save(op_context:key(hellgate), op_context:create()),
    ShopConfigRef = hg_ct_helper:create_party_and_shop(
        PartyConfigRef, ?cat(1), <<"RUB">>, ?trms(1), ?pinst(1), PartyClient
    ),
    ok = op_context:cleanup(hellgate),
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    _ = unlink(SupPid),
    ok = hg_invoice_helper:start_kv_store(SupPid),
    C1 = [
        {party_config_ref, PartyConfigRef},
        {shop_config_ref, ShopConfigRef},
        {root_url, RootUrl},
        {test_sup, SupPid},
        {apps, Apps}
        | C
    ],
    ok = hg_invoice_helper:start_proxies([{hg_dummy_provider, 1, C1}, {hg_dummy_inspector, 2, C1}]),
    [{base_domain_revision, hg_domain:head()} | C1].

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    _ = hg_domain:cleanup(),
    _ = application:stop(progressor),
    _ = hg_ct_helper:cleanup_progressor_namespaces(),
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
init_per_testcase(Name, C) ->
    _ = hg_domain:reset(cfg(base_domain_revision, C)),
    ApiClient = hg_ct_helper:create_client(cfg(root_url, C)),
    Client = hg_client_invoicing:start_link(ApiClient),
    ok = op_context:save(op_context:key(hellgate), op_context:create()),
    C1 = [{client, Client} | C],
    case Name of
        payment_with_provider_guarantee_account ->
            GuaranteeAccountID = configure_provider_guarantee_account(),
            [{provider_guarantee_account_id, GuaranteeAccountID} | C1];
        payment_undefined_provider_guarantee_accout ->
            ok = configure_provider_guarantee_cashflow(),
            C1;
        _ ->
            C1
    end.

-spec end_per_testcase(test_case_name(), config()) -> config().
end_per_testcase(_, C) ->
    ok = op_context:cleanup(hellgate),
    C.

%% Tests

-spec payment_with_provider_settlement_account(config()) -> test_return().
payment_with_provider_settlement_account(C) ->
    Amount = 42000,
    {CashFlow, Route} = execute_payment(Amount, C),
    #domain_Provider{accounts = ProviderAccounts} = hg_domain:get({provider, ?prv(1)}),
    #domain_ProviderAccount{settlement = SettlementAccountID, guarantee = undefined} =
        maps:get(?cur(<<"RUB">>), ProviderAccounts),
    [
        #domain_FinalCashFlowPosting{
            source = #domain_FinalCashFlowAccount{
                account_id = SettlementAccountID,
                transaction_account =
                    {provider, #domain_ProviderTransactionAccount{
                        type = settlement,
                        owner = #domain_ProviderTransactionAccountOwner{
                            provider_ref = ?prv(1),
                            terminal_ref = ?trm(1)
                        }
                    }}
            },
            volume = ?cash(Amount, <<"RUB">>)
        }
    ] = lookup_posting(CashFlow, {provider, settlement}, {merchant, settlement}),
    assert_route(Route),
    ok.

-spec payment_with_provider_guarantee_account(config()) -> test_return().
payment_with_provider_guarantee_account(C) ->
    Amount = 42000,
    GuaranteeAccountID = cfg(provider_guarantee_account_id, C),
    {CashFlow, Route} = execute_payment(Amount, C),
    [
        #domain_FinalCashFlowPosting{
            source = #domain_FinalCashFlowAccount{
                account_id = GuaranteeAccountID,
                transaction_account =
                    {provider, #domain_ProviderTransactionAccount{
                        type = guarantee,
                        owner = #domain_ProviderTransactionAccountOwner{
                            provider_ref = ?prv(1),
                            terminal_ref = ?trm(1)
                        }
                    }}
            },
            volume = ?cash(Amount, <<"RUB">>)
        }
    ] = lookup_posting(CashFlow, {provider, guarantee}, {merchant, settlement}),
    #{own_amount := GuaranteeBalance} = hg_accounting:get_balance(GuaranteeAccountID),
    ?assertEqual(-Amount, GuaranteeBalance),
    assert_route(Route),
    ok.

-spec payment_undefined_provider_guarantee_accout(config()) -> test_return().
payment_undefined_provider_guarantee_accout(C) ->
    Client = cfg(client, C),
    #domain_Provider{accounts = ProviderAccounts} = hg_domain:get({provider, ?prv(1)}),
    #domain_ProviderAccount{guarantee = undefined} = maps:get(?cur(<<"RUB">>), ProviderAccounts),

    InvoiceID = hg_invoice_helper:start_invoice(
        <<"undefined provider guarantee account">>, hg_invoice_helper:make_due_date(10), 42000, C
    ),
    PaymentParams = hg_invoice_helper:make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    Route = hg_invoice_helper:start_payment_ev(InvoiceID, Client),
    assert_route(Route),

    %% The configured cash flow cannot be finalized without the provider guarantee account.
    %% Cash-flow building fails with a misconfiguration error and emits no further payment event.
    timeout = hg_invoice_helper:next_change(InvoiceID, 2000, Client),
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{status = ?pending()},
        route = Route,
        cash_flow = undefined
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    ok.

%% Internals

execute_payment(Amount, C) ->
    Client = cfg(client, C),
    InvoiceID = hg_invoice_helper:start_invoice(
        <<"provider cashflow">>, hg_invoice_helper:make_due_date(10), Amount, C
    ),
    PaymentParams = hg_invoice_helper:make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentID = hg_invoice_helper:execute_payment(InvoiceID, PaymentParams, Client),
    #payproc_InvoicePayment{route = Route, cash_flow = CashFlow} =
        hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    {CashFlow, Route}.

configure_provider_guarantee_account() ->
    Currency = ?cur(<<"RUB">>),
    GuaranteeAccountID = hg_accounting:create_account(<<"RUB">>),
    Provider0 = #domain_Provider{accounts = Accounts0} = hg_domain:get({provider, ?prv(1)}),
    ProviderAccount0 = maps:get(Currency, Accounts0),
    ProviderAccount1 = ProviderAccount0#domain_ProviderAccount{guarantee = GuaranteeAccountID},
    Provider1 = Provider0#domain_Provider{accounts = Accounts0#{Currency => ProviderAccount1}},
    _ = hg_domain:upsert({provider, #domain_ProviderObject{ref = ?prv(1), data = Provider1}}),
    ok = configure_provider_guarantee_cashflow(),
    GuaranteeAccountID.

configure_provider_guarantee_cashflow() ->
    Terminal0 = #domain_Terminal{terms = Terms0} = hg_domain:get({terminal, ?trm(1)}),
    PaymentTerms0 = Terms0#domain_ProvisionTermSet.payments,
    CashFlow = [
        ?cfpost(
            {provider, guarantee},
            {merchant, settlement},
            ?share(1, 1, operation_amount)
        ),
        ?cfpost(
            {system, settlement},
            {provider, settlement},
            ?fixed(10, <<"RUB">>)
        )
    ],
    PaymentTerms1 = PaymentTerms0#domain_PaymentsProvisionTerms{cash_flow = {value, CashFlow}},
    Terminal1 = Terminal0#domain_Terminal{
        terms = Terms0#domain_ProvisionTermSet{payments = PaymentTerms1}
    },
    _ = hg_domain:upsert({terminal, #domain_TerminalObject{ref = ?trm(1), data = Terminal1}}),
    ok.

lookup_posting(CashFlow, Source, Destination) ->
    lists:filter(
        fun(
            #domain_FinalCashFlowPosting{
                source = #domain_FinalCashFlowAccount{account_type = SourceAccount},
                destination = #domain_FinalCashFlowAccount{account_type = DestinationAccount}
            }
        ) ->
            Source =:= SourceAccount andalso Destination =:= DestinationAccount
        end,
        CashFlow
    ).

assert_route(#domain_PaymentRoute{provider = ?prv(1), terminal = ?trm(1)}) ->
    ok.

cfg(Key, Config) ->
    hg_ct_helper:cfg(Key, Config).
