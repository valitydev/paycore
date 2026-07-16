-module(lim_payproc_utils).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").

-export([cash/1]).
-export([payment_tool/1]).

-type cash() ::
    lim_body:cash().

-type payment_tool() ::
    {bank_card, #{
        token := binary(),
        exp_date := {1..12, 2000..9999} | undefined
    }}
    | {digital_wallet, #{
        id := binary(),
        service := binary()
    }}
    | {generic, #{
        service := binary(),
        data := #{
            type := binary(),
            data := binary()
        }
    }}.

%%

-spec cash(dmsl_domain_thrift:'Cash'()) ->
    {ok, cash()}.
cash(#domain_Cash{amount = Amount, currency = #domain_CurrencyRef{symbolic_code = Currency}}) ->
    {ok, #{amount => Amount, currency => Currency}}.

-spec payment_tool(dmsl_domain_thrift:'PaymentTool'()) ->
    {ok, payment_tool()} | {error, {unsupported, _}}.
payment_tool({bank_card, BC}) ->
    {ok,
        {bank_card, #{
            token => BC#domain_BankCard.token,
            exp_date => get_bank_card_expdate(BC#domain_BankCard.exp_date)
        }}};
payment_tool({digital_wallet, DW}) ->
    {ok,
        {digital_wallet, #{
            id => DW#domain_DigitalWallet.id,
            service => DW#domain_DigitalWallet.payment_service#domain_PaymentServiceRef.id
        }}};
payment_tool({generic, G}) ->
    %% TODO Move to codec into marshal/unmarshal clauses
    Content = G#domain_GenericPaymentTool.data,
    {ok,
        {generic, #{
            service => G#domain_GenericPaymentTool.payment_service#domain_PaymentServiceRef.id,
            data => #{
                %% TODO Content decoding
                type => Content#base_Content.type,
                data => Content#base_Content.data
            }
        }}};
payment_tool({Type, _}) ->
    {error, {unsupported, {payment_tool, Type}}}.

get_bank_card_expdate(#domain_BankCardExpDate{month = Month, year = Year}) ->
    {Month, Year};
get_bank_card_expdate(undefined) ->
    undefined.
