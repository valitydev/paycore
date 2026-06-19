-module(hg_currency_converter).

-include_lib("hellgate/include/domain.hrl").

-export([convert_cash/2]).
-export([reverse_convert_cash/2]).

-type cash() :: dmsl_domain_thrift:'Cash'().

-spec convert_cash(hg_invoice_payment:exchange_context(), cash()) -> cash().
convert_cash(
    #{source := SourceCurrency, destination := DestinationCurrency, rate := Rate},
    #domain_Cash{amount = Amount, currency = #domain_CurrencyRef{symbolic_code = SourceCurrency}}
) ->
    %% Example:
    %% Amount: 1000, Src: RUB, Dst: USD, Rate: {P=100, Q=1} (1 USD = 100 RUB)
    %% ConvertedAmountRational = {1000,100}
    %% ConvertedAmount = 10
    #base_Rational{p = P, q = Q} = Rate,
    RateRational = genlib_rational:new(P, Q),
    AmountRational = genlib_rational:new(Amount),
    ConvertedAmountRational = genlib_rational:dvd(AmountRational, RateRational),
    Rounding = application:get_env(hellgate, exchange_rounding_method, round_half_away_from_zero),
    ConvertedAmount = genlib_rational:round(ConvertedAmountRational, Rounding),
    #domain_Cash{amount = ConvertedAmount, currency = #domain_CurrencyRef{symbolic_code = DestinationCurrency}}.

-spec reverse_convert_cash(hg_invoice_payment:exchange_context(), cash()) -> cash().
reverse_convert_cash(
    #{source := SourceCurrency, destination := DestinationCurrency, rate := Rate},
    #domain_Cash{amount = Amount, currency = #domain_CurrencyRef{symbolic_code = DestinationCurrency}}
) ->
    %% We do not use two-way exchange rates for currency pairs
    #base_Rational{p = P, q = Q} = Rate,
    RateRational = genlib_rational:new(P, Q),
    AmountRational = genlib_rational:new(Amount),
    ReConvertedAmountRational = genlib_rational:mul(AmountRational, RateRational),
    Rounding = application:get_env(hellgate, exchange_rounding_method, round_half_away_from_zero),
    ReConvertedAmount = genlib_rational:round(ReConvertedAmountRational, Rounding),
    #domain_Cash{amount = ReConvertedAmount, currency = #domain_CurrencyRef{symbolic_code = SourceCurrency}}.
