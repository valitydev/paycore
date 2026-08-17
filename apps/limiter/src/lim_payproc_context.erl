-module(lim_payproc_context).

-include_lib("limiter_proto/include/limproto_context_payproc_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-behaviour(lim_context).
-export([get_operation/1]).
-export([make_change_context/1]).
-export([get_value/2]).

-type context() :: limproto_context_payproc_thrift:'Context'().

-type operation() ::
    invoice
    | invoice_payment
    | invoice_payment_adjustment
    | invoice_payment_refund
    | invoice_payment_chargeback.

-export_type([operation/0]).
-export_type([context/0]).

%%

-spec get_operation(context()) -> {ok, operation()} | {error, notfound}.
get_operation(#context_payproc_Context{op = {Operation, _}}) ->
    {ok, Operation};
get_operation(#context_payproc_Context{op = undefined}) ->
    {error, notfound}.

-spec make_change_context(context()) -> {ok, lim_context:change_context()}.
make_change_context(#context_payproc_Context{op = undefined}) ->
    {ok, #{}};
make_change_context(
    #context_payproc_Context{
        op = {Operation, _}
    } = Context
) ->
    {ok,
        genlib_map:compact(#{
            <<"Context.op">> => genlib:to_binary(Operation),
            <<"Context.owner_id">> => try_get_value(owner_id, Context, undefined),
            <<"Context.shop_id">> => try_get_value(shop_id, Context, undefined)
        })}.

-spec get_value(atom(), context()) -> {ok, term()} | {error, notfound | {unsupported, _}}.
get_value(ValueName, Context) ->
    case get_operation(Context) of
        {ok, Operation} ->
            get_value(ValueName, Operation, Context);
        {error, _} = Error ->
            Error
    end.

try_get_value(ValueName, Context, Default) ->
    case get_operation(Context) of
        {ok, Operation} ->
            case get_value(ValueName, Operation, Context) of
                {ok, Value} ->
                    Value;
                {error, _} ->
                    Default
            end;
        {error, _} ->
            Default
    end.

get_value(owner_id, _Operation, Context) ->
    get_owner_id(Context);
get_value(shop_id, _Operation, Context) ->
    get_shop_id(Context);
get_value(created_at, Operation, Context) ->
    get_created_at(Operation, Context);
get_value(cost, Operation, Context) ->
    get_cost(Operation, Context);
get_value(capture_cost, Operation, Context) ->
    get_capture_cost(Operation, Context);
get_value(payment_tool, Operation, Context) ->
    get_payment_tool(Operation, Context);
get_value(provider_id, Operation, Context) ->
    get_provider_id(Operation, Context);
get_value(terminal_id, Operation, Context) ->
    get_terminal_id(Operation, Context);
get_value(session, Operation, Context) ->
    get_session(Operation, Context);
get_value(payer_contact_email, Operation, Context) ->
    get_payer_contact_email(Operation, Context);
get_value(sender, Operation, Context) ->
    get_destination_sender(Operation, Context);
get_value(receiver, Operation, Context) ->
    get_destination_receiver(Operation, Context);
get_value(ValueName, _Operation, _Context) ->
    {error, {unsupported, ValueName}}.

%%

-define(INVOICE(V), #context_payproc_Context{
    invoice = #context_payproc_Invoice{
        invoice = V = #domain_Invoice{}
    }
}).

-define(INVOICE_PAYMENT(V), #context_payproc_Context{
    invoice = #context_payproc_Invoice{
        payment = #context_payproc_InvoicePayment{payment = V = #domain_InvoicePayment{}}
    }
}).

-define(INVOICE_PAYMENT_ADJUSTMENT(V), #context_payproc_Context{
    invoice = #context_payproc_Invoice{
        payment = #context_payproc_InvoicePayment{adjustment = V = #domain_InvoicePaymentAdjustment{}}
    }
}).

-define(INVOICE_PAYMENT_REFUND(V), #context_payproc_Context{
    invoice = #context_payproc_Invoice{
        payment = #context_payproc_InvoicePayment{refund = V = #domain_InvoicePaymentRefund{}}
    }
}).

-define(INVOICE_PAYMENT_CHARGEBACK(V), #context_payproc_Context{
    invoice = #context_payproc_Invoice{
        payment = #context_payproc_InvoicePayment{chargeback = V = #domain_InvoicePaymentChargeback{}}
    }
}).

-define(INVOICE_PAYMENT_ROUTE(V), #context_payproc_Context{
    invoice = #context_payproc_Invoice{
        payment = #context_payproc_InvoicePayment{route = V = #base_Route{}}
    }
}).

-define(INVOICE_PAYMENT_SESSION(V), #context_payproc_Context{
    invoice = #context_payproc_Invoice{
        session = V
    }
}).

get_owner_id(?INVOICE(Invoice)) ->
    {ok, Invoice#domain_Invoice.party_ref#domain_PartyConfigRef.id};
get_owner_id(_) ->
    {error, notfound}.

get_shop_id(?INVOICE(Invoice)) ->
    {ok, Invoice#domain_Invoice.shop_ref#domain_ShopConfigRef.id};
get_shop_id(_) ->
    {error, notfound}.

get_created_at(invoice, ?INVOICE(Invoice)) ->
    {ok, Invoice#domain_Invoice.created_at};
get_created_at(invoice_payment, ?INVOICE_PAYMENT(Payment)) ->
    {ok, Payment#domain_InvoicePayment.created_at};
get_created_at(invoice_payment_adjustment, ?INVOICE_PAYMENT_ADJUSTMENT(Adjustment)) ->
    {ok, Adjustment#domain_InvoicePaymentAdjustment.created_at};
get_created_at(invoice_payment_refund, ?INVOICE_PAYMENT_REFUND(Refund)) ->
    {ok, Refund#domain_InvoicePaymentRefund.created_at};
get_created_at(invoice_payment_chargeback, ?INVOICE_PAYMENT_CHARGEBACK(Chargeback)) ->
    {ok, Chargeback#domain_InvoicePaymentChargeback.created_at};
get_created_at(_, _CtxInvoice) ->
    {error, notfound}.

get_cost(invoice, ?INVOICE(Invoice)) ->
    lim_payproc_utils:cash(Invoice#domain_Invoice.cost);
get_cost(invoice_payment, ?INVOICE_PAYMENT(Payment)) ->
    lim_payproc_utils:cash(Payment#domain_InvoicePayment.cost);
get_cost(invoice_payment_refund, ?INVOICE_PAYMENT_REFUND(Refund)) ->
    lim_payproc_utils:cash(Refund#domain_InvoicePaymentRefund.cash);
get_cost(invoice_payment_chargeback, ?INVOICE_PAYMENT_CHARGEBACK(Chargeback)) ->
    lim_payproc_utils:cash(Chargeback#domain_InvoicePaymentChargeback.body);
get_cost(_, _CtxInvoice) ->
    {error, notfound}.

get_capture_cost(invoice_payment, ?INVOICE_PAYMENT(Payment)) ->
    get_capture_cost(Payment#domain_InvoicePayment.status);
get_capture_cost(_, _CtxInvoice) ->
    {error, notfound}.

get_capture_cost({captured, #domain_InvoicePaymentCaptured{cost = Cost}}) when Cost /= undefined ->
    lim_payproc_utils:cash(Cost);
get_capture_cost({_Status, _}) ->
    {error, notfound}.

get_payment_tool(Operation, ?INVOICE_PAYMENT(Payment)) when
    Operation == invoice_payment;
    Operation == invoice_payment_adjustment;
    Operation == invoice_payment_refund;
    Operation == invoice_payment_chargeback
->
    {_Type, Payer} = Payment#domain_InvoicePayment.payer,
    get_payer_payment_tool(Payer);
get_payment_tool(_, _CtxInvoice) ->
    {error, notfound}.

get_payer_payment_tool(#domain_PaymentResourcePayer{resource = #domain_DisposablePaymentResource{payment_tool = PT}}) ->
    lim_payproc_utils:payment_tool(PT);
get_payer_payment_tool(#domain_RecurrentPayer{payment_tool = PT}) ->
    lim_payproc_utils:payment_tool(PT).

get_provider_id(Operation, ?INVOICE_PAYMENT_ROUTE(Route)) when
    Operation == invoice_payment;
    Operation == invoice_payment_adjustment;
    Operation == invoice_payment_refund;
    Operation == invoice_payment_chargeback
->
    lim_context_utils:route_provider_id(Route);
get_provider_id(_, _CtxInvoice) ->
    {error, notfound}.

get_terminal_id(Operation, ?INVOICE_PAYMENT_ROUTE(Route)) when
    Operation == invoice_payment;
    Operation == invoice_payment_adjustment;
    Operation == invoice_payment_refund;
    Operation == invoice_payment_chargeback
->
    lim_context_utils:route_terminal_id(Route);
get_terminal_id(_, _CtxInvoice) ->
    {error, notfound}.

get_session(invoice_payment, ?INVOICE_PAYMENT_SESSION(Session)) ->
    {ok, Session};
get_session(_, _CtxInvoice) ->
    {error, notfound}.

get_payer_contact_email(Operation, ?INVOICE_PAYMENT(Payment)) when
    Operation == invoice_payment;
    Operation == invoice_payment_adjustment;
    Operation == invoice_payment_refund;
    Operation == invoice_payment_chargeback
->
    {_Type, Payer} = Payment#domain_InvoicePayment.payer,
    CI = get_payer_contact_info(Payer),
    {ok, string:lowercase(CI#domain_ContactInfo.email)};
get_payer_contact_email(_, _CtxInvoice) ->
    {error, notfound}.

get_payer_contact_info(#domain_PaymentResourcePayer{contact_info = CI}) ->
    CI;
get_payer_contact_info(#domain_RecurrentPayer{contact_info = CI}) ->
    CI.

get_destination_sender(_, _CtxWithdrawal) ->
    {error, notfound}.

get_destination_receiver(_, _CtxWithdrawal) ->
    {error, notfound}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-define(PAYMENT_W_PAYER(Payer), #domain_InvoicePayment{
    id = <<"ID">>,
    created_at = <<"2000-02-02T12:12:12Z">>,
    status = {pending, #domain_InvoicePaymentPending{}},
    cost = #domain_Cash{
        amount = 42,
        currency = #domain_CurrencyRef{symbolic_code = <<"CNY">>}
    },
    domain_revision = 42,
    flow = {instant, #domain_InvoicePaymentFlowInstant{}},
    payer = Payer
}).

-define(CONTEXT_PAYMENT(Payment), #context_payproc_Context{
    op = {invoice_payment, #context_payproc_OperationInvoicePayment{}},
    invoice = #context_payproc_Invoice{
        payment = #context_payproc_InvoicePayment{
            payment = Payment
        }
    }
}).

-spec get_payment_tool_test_() -> [_TestGen].
get_payment_tool_test_() ->
    PaymentTool =
        {bank_card, #domain_BankCard{
            token = <<"Token">>,
            bin = <<"654321">>,
            exp_date = #domain_BankCardExpDate{month = 2, year = 2022},
            last_digits = <<"1234">>
        }},
    PaymentResourcePayer =
        {payment_resource, #domain_PaymentResourcePayer{
            resource = #domain_DisposablePaymentResource{payment_tool = PaymentTool},
            contact_info = #domain_ContactInfo{}
        }},
    RecurrentPayer =
        {recurrent, #domain_RecurrentPayer{
            payment_tool = PaymentTool,
            recurrent_parent = #domain_RecurrentParentPayment{
                invoice_id = <<"invoice_id">>,
                payment_id = <<"payment_id">>
            },
            contact_info = #domain_ContactInfo{}
        }},
    ExpectedValue = {bank_card, #{token => <<"Token">>, exp_date => {2, 2022}}},
    [
        ?_assertEqual(
            {ok, ExpectedValue},
            get_value(payment_tool, ?CONTEXT_PAYMENT(?PAYMENT_W_PAYER(PaymentResourcePayer)))
        ),
        ?_assertEqual(
            {ok, ExpectedValue},
            get_value(payment_tool, ?CONTEXT_PAYMENT(?PAYMENT_W_PAYER(RecurrentPayer)))
        )
    ].

-spec get_payment_tool_unsupported_test_() -> _TestGen.
get_payment_tool_unsupported_test_() ->
    Payer =
        {recurrent, #domain_RecurrentPayer{
            payment_tool = {payment_terminal, #domain_PaymentTerminal{}},
            recurrent_parent = #domain_RecurrentParentPayment{
                invoice_id = <<"invoice_id">>,
                payment_id = <<"payment_id">>
            },
            contact_info = #domain_ContactInfo{}
        }},
    ?_assertEqual(
        {error, {unsupported, {payment_tool, payment_terminal}}},
        get_value(payment_tool, ?CONTEXT_PAYMENT(?PAYMENT_W_PAYER(Payer)))
    ).

-endif.
