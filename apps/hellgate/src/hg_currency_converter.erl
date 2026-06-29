-module(hg_currency_converter).

-include_lib("hellgate/include/domain.hrl").

-export([convert_cash/2]).
-export([reverse_convert_cash/2]).
-export([maybe_convert_cash/2]).
-export([maybe_reverse_convert_cash/2]).

-export_type([exchange_context/0]).

-type cash() :: dmsl_domain_thrift:'Cash'().
-type exchange_context() :: dmsl_domain_thrift:'ExchangeContext'().

-spec convert_cash(exchange_context(), cash()) -> cash().
convert_cash(ExchangeContext, Cash) ->
    do_convert_cash(ExchangeContext, Cash, forward).

-spec reverse_convert_cash(exchange_context(), cash()) -> cash().
reverse_convert_cash(ExchangeContext, Cash) ->
    %% We do not use two-way exchange rates for currency pairs.
    do_convert_cash(ExchangeContext, Cash, reverse).

-spec maybe_convert_cash(exchange_context() | undefined, cash()) -> cash().
maybe_convert_cash(undefined, Cash) ->
    Cash;
maybe_convert_cash(ExchangeContext, Cash) ->
    convert_cash(ExchangeContext, Cash).

-spec maybe_reverse_convert_cash(exchange_context() | undefined, cash()) -> cash().
maybe_reverse_convert_cash(undefined, Cash) ->
    Cash;
maybe_reverse_convert_cash(ExchangeContext, Cash) ->
    reverse_convert_cash(ExchangeContext, Cash).

do_convert_cash(
    #domain_ExchangeContext{
        exchange_rate = ExchangeRate,
        source_currency = SourceCurrency,
        destination_currency = DestinationCurrency
    },
    Cash,
    Direction
) ->
    {InputCurrency, OutputCurrency, SkipCurrency} =
        case Direction of
            forward ->
                {SourceCurrency, DestinationCurrency, DestinationCurrency};
            reverse ->
                {DestinationCurrency, SourceCurrency, SourceCurrency}
        end,
    case Cash of
        #domain_Cash{currency = #domain_CurrencyRef{symbolic_code = SkipCurrency}} ->
            Cash;
        #domain_Cash{
            amount = Amount,
            currency = #domain_CurrencyRef{symbolic_code = InputCurrency}
        } ->
            convert_amount(Amount, ExchangeRate, OutputCurrency, Direction)
    end.

convert_amount(Amount, ExchangeRate, OutputCurrency, Direction) ->
    #base_Rational{p = P, q = Q} = ExchangeRate,
    RateRational = genlib_rational:new(P, Q),
    AmountRational = genlib_rational:new(Amount),
    ConvertedAmountRational =
        case Direction of
            forward ->
                genlib_rational:dvd(AmountRational, RateRational);
            reverse ->
                genlib_rational:mul(AmountRational, RateRational)
        end,
    Rounding = application:get_env(hellgate, exchange_rounding_method, round_half_away_from_zero),
    ConvertedAmount = genlib_rational:round(ConvertedAmountRational, Rounding),
    #domain_Cash{amount = ConvertedAmount, currency = #domain_CurrencyRef{symbolic_code = OutputCurrency}}.
