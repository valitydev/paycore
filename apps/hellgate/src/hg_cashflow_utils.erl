-module(hg_cashflow_utils).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-include_lib("hellgate/include/allocation.hrl").
-include_lib("hellgate/include/domain.hrl").
-include("hg_invoice_payment.hrl").

-type cash_flow_context() :: #{
    operation := refund | payment,
    provision_terms := dmsl_domain_thrift:'PaymentsProvisionTerms'(),
    party := {party_config_ref(), party()},
    shop := {shop_config_ref(), shop()},
    route := route(),
    payment := payment(),
    provider := provider(),
    timestamp := hg_datetime:timestamp(),
    varset := hg_varset:varset(),
    revision := revision(),
    merchant_terms => dmsl_domain_thrift:'PaymentsServiceTerms'(),
    refund => refund(),
    allocation => hg_allocation:allocation(),
    exchange_context => hg_invoice_payment:exchange_context() | undefined
}.

-export_type([cash_flow_context/0]).

-export([collect_cashflow/1]).
-export([collect_cashflow/2]).
-export([convert_cashflow/2]).
-export([convert_volume/2]).

-type party() :: dmsl_domain_thrift:'PartyConfig'().
-type party_config_ref() :: dmsl_domain_thrift:'PartyConfigRef'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type shop_config_ref() :: dmsl_domain_thrift:'ShopConfigRef'().
-type route() :: dmsl_domain_thrift:'PaymentRoute'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type refund() :: dmsl_domain_thrift:'InvoicePaymentRefund'().
-type provider() :: dmsl_domain_thrift:'Provider'().
-type revision() :: hg_domain:revision().
-type payment_institution() :: hg_payment_institution:t().
-type final_cash_flow() :: hg_cashflow:final_cash_flow().
-type cash_flow() :: hg_cashflow:cash_flow().
-type cash_volume() :: hg_cashflow:cash_volume().

-spec collect_cashflow(cash_flow_context()) -> final_cash_flow().
collect_cashflow(#{shop := {_, Shop}, varset := VS, revision := Revision} = Context) ->
    PaymentInstitution = get_cashflow_payment_institution(Shop, VS, Revision),
    collect_cashflow(PaymentInstitution, Context).

-spec collect_cashflow(payment_institution(), cash_flow_context()) -> final_cash_flow().
collect_cashflow(PaymentInstitution, Context) ->
    CF =
        case maps:get(allocation, Context, undefined) of
            undefined ->
                Amount = get_amount(Context),
                construct_transaction_cashflow(Amount, PaymentInstitution, Context);
            ?allocation(Transactions) ->
                collect_allocation_cash_flow(Transactions, Context)
        end,
    ProviderCashflow = construct_provider_cashflow(PaymentInstitution, Context),
    CF ++ ProviderCashflow.

%% Internal

collect_allocation_cash_flow(
    Transactions,
    Context = #{
        revision := Revision,
        shop := {_, Shop},
        varset := VS0
    }
) ->
    lists:foldl(
        fun(?allocation_trx(_ID, Target, Amount), Acc) ->
            ?allocation_trx_target_shop(PartyConfigRef, ShopConfigRef) = Target,
            {PartyConfigRef, TargetParty} = hg_party:get_party(PartyConfigRef),
            {#domain_ShopConfigRef{id = ShopConfigID} = ShopConfigRef, TargetShop} =
                hg_party:get_shop(ShopConfigRef, PartyConfigRef, Revision),
            VS1 = VS0#{
                party_config_ref => PartyConfigRef,
                shop_id => ShopConfigID,
                cost => Amount
            },
            AllocationPaymentInstitution =
                get_cashflow_payment_institution(Shop, VS1, Revision),
            construct_transaction_cashflow(
                Amount,
                AllocationPaymentInstitution,
                Context#{party => {PartyConfigRef, TargetParty}, shop => {ShopConfigRef, TargetShop}}
            ) ++ Acc
        end,
        [],
        Transactions
    ).

construct_transaction_cashflow(
    Amount,
    PaymentInstitution,
    #{
        revision := Revision,
        operation := OpType,
        shop := {_, Shop},
        varset := VS
    } = Context
) ->
    MerchantPaymentsTerms1 =
        case maps:get(merchant_terms, Context, undefined) of
            undefined ->
                TermSet = hg_invoice_utils:compute_shop_terms(Revision, Shop, VS),
                TermSet#domain_TermSet.payments;
            MerchantPaymentsTerms0 ->
                MerchantPaymentsTerms0
        end,
    MerchantCashflowSelector = get_terms_cashflow(OpType, MerchantPaymentsTerms1),
    MerchantCashflow = get_selector_value(merchant_payment_fees, MerchantCashflowSelector),
    AccountMap = hg_accounting:collect_account_map(make_collect_account_context(PaymentInstitution, Context)),
    construct_final_cashflow(MerchantCashflow, #{operation_amount => Amount}, AccountMap).

construct_provider_cashflow(PaymentInstitution, #{provision_terms := ProvisionTerms} = Context) ->
    ProviderCashflowSelector = get_provider_cashflow_selector(ProvisionTerms),
    ProviderCashflow0 = get_selector_value(provider_payment_cash_flow, ProviderCashflowSelector),
    ExchangeContext = maps:get(exchange_context, Context, undefined),
    ProviderCashflow = maybe_convert_cashflow(ExchangeContext, ProviderCashflow0),
    AccountMap = hg_accounting:collect_account_map(make_collect_account_context(PaymentInstitution, Context)),
    construct_final_cashflow(ProviderCashflow, #{operation_amount => get_amount(Context)}, AccountMap).

maybe_convert_cashflow(undefined, ProviderCashflow) ->
    ProviderCashflow;
maybe_convert_cashflow(ExchangeContext, ProviderCashflow) ->
    convert_cashflow(ExchangeContext, ProviderCashflow).

-spec convert_cashflow(hg_invoice_payment:exchange_context(), cash_flow()) -> cash_flow().
convert_cashflow(ExchangeContext, ProviderCashflow) ->
    lists:foldr(
        fun(#domain_CashFlowPosting{volume = CashVolume} = P, Acc) ->
            [
                P#domain_CashFlowPosting{
                    volume = convert_volume(ExchangeContext, CashVolume),
                    exchange_context = construct_exchange_context(ExchangeContext)
                }
                | Acc
            ]
        end,
        [],
        ProviderCashflow
    ).

construct_exchange_context(#{
    source := SourceCurrency,
    destination := DestinationCurrency,
    rate := ExchangeRate
}) ->
    #domain_ExchangeContext{
        source_currency = SourceCurrency,
        destination_currency = DestinationCurrency,
        exchange_rate = ExchangeRate
    }.

-spec convert_volume(hg_invoice_payment:exchange_context(), cash_volume()) -> cash_volume().
convert_volume(_ExchangeContext, {share, _} = CashVolume) ->
    CashVolume;
convert_volume(ExchangeContext, {product, {Kind, CashVolumeList}}) ->
    {product, {Kind, convert_volumes(ExchangeContext, CashVolumeList)}};
convert_volume(
    #{source := PaymentCurrency, destination := TerminalCurrency} = ExchangeContext,
    {fixed, #domain_CashVolumeFixed{
        cash =
            #domain_Cash{
                currency = #domain_CurrencyRef{symbolic_code = FeeCurrency}
            } = Cash
    }} = CashVolume
) ->
    case FeeCurrency of
        PaymentCurrency ->
            CashVolume;
        TerminalCurrency ->
            %% reverse conversion needed
            ReConvertedCash = hg_currency_converter:reverse_convert_cash(ExchangeContext, Cash),
            {fixed, #domain_CashVolumeFixed{
                cash = ReConvertedCash
            }}
    end.

convert_volumes(ExchangeContext, CashVolumeList) ->
    lists:foldr(
        fun(CashVolume, Acc) ->
            [convert_volume(ExchangeContext, CashVolume) | Acc]
        end,
        [],
        CashVolumeList
    ).

construct_final_cashflow(Cashflow, Context, AccountMap) ->
    hg_cashflow:finalize(Cashflow, Context, AccountMap).

get_cashflow_payment_institution(
    #domain_ShopConfig{payment_institution = PaymentInstitutionRef},
    VS,
    Revision
) ->
    hg_payment_institution:compute_payment_institution(
        PaymentInstitutionRef,
        VS,
        Revision
    ).

get_amount(#{refund := #domain_InvoicePaymentRefund{cash = Cash}}) ->
    Cash;
get_amount(#{payment := #domain_InvoicePayment{cost = Cost}}) ->
    Cost.

get_provider_cashflow_selector(#domain_PaymentsProvisionTerms{cash_flow = ProviderCashflowSelector}) ->
    ProviderCashflowSelector;
get_provider_cashflow_selector(#domain_PaymentRefundsProvisionTerms{cash_flow = ProviderCashflowSelector}) ->
    ProviderCashflowSelector.

get_terms_cashflow(payment, MerchantPaymentsTerms) ->
    MerchantPaymentsTerms#domain_PaymentsServiceTerms.fees;
get_terms_cashflow(refund, MerchantPaymentsTerms) ->
    MerchantRefundTerms = MerchantPaymentsTerms#domain_PaymentsServiceTerms.refunds,
    MerchantRefundTerms#domain_PaymentRefundsServiceTerms.fees.

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

-spec make_collect_account_context(payment_institution(), cash_flow_context()) ->
    hg_accounting:collect_account_context().
make_collect_account_context(PaymentInstitution, #{
    payment := Payment,
    party := {PartyConfigRef, _},
    shop := Shop,
    route := Route,
    provider := Provider,
    varset := VS,
    revision := Revision
}) ->
    #{
        payment => Payment,
        party_config_ref => PartyConfigRef,
        shop => Shop,
        route => Route,
        payment_institution => PaymentInstitution,
        provider => Provider,
        varset => VS,
        revision => Revision
    }.
