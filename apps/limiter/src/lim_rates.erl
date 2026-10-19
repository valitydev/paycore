-module(lim_rates).

-include_lib("xrates_proto/include/xrates_rate_thrift.hrl").

-export([convert/4]).

-type limit_context() :: lim_context:t().
-type config() :: lim_config_machine:config().

-type conversion_error() :: quote_not_found | currency_not_found.

-export_type([conversion_error/0]).

-define(APP, limiter).
-define(DEFAULT_FACTOR, 1.1).
-define(DEFAULT_FACTOR_NAME, <<"DEFAULT">>).

-spec convert(lim_body:cash(), lim_body:currency(), config(), limit_context()) ->
    {ok, lim_body:cash()} | {error, conversion_error() | lim_context:context_error()}.
convert(#{amount := Amount, currency := Currency}, DestinationCurrency, Config, LimitContext) ->
    ContextType = lim_config_machine:context_type(Config),
    case lim_context:get_value(ContextType, created_at, LimitContext) of
        {ok, Timestamp} -> do_convert(Timestamp, Amount, Currency, DestinationCurrency, LimitContext);
        {error, _} = Error -> Error
    end.

do_convert(Timestamp, Amount, Currency, DestinationCurrency, LimitContext) ->
    Request = #rate_ConversionRequest{
        source = Currency,
        destination = DestinationCurrency,
        amount = Amount,
        datetime = Timestamp
    },
    case call_rates('GetConvertedAmount', {<<"CBR">>, Request}, LimitContext) of
        {ok, #base_Rational{p = P, q = Q}} ->
            Rational = genlib_rational:new(P, Q),
            Factor = get_exchange_factor(Currency),
            {ok, #{
                amount => genlib_rational:round(genlib_rational:mul(Rational, Factor)),
                currency => DestinationCurrency
            }};
        {exception, #rate_QuoteNotFound{}} ->
            {error, quote_not_found};
        {exception, #rate_CurrencyNotFound{}} ->
            {error, currency_not_found}
    end.

get_exchange_factor(Currency) ->
    Factors = genlib_app:env(?APP, exchange_factors, #{}),
    case maps:get(Currency, Factors, undefined) of
        undefined ->
            case maps:get(?DEFAULT_FACTOR_NAME, Factors, undefined) of
                undefined ->
                    ?DEFAULT_FACTOR;
                DefaultFactor ->
                    DefaultFactor
            end;
        Factor ->
            Factor
    end.

%%

call_rates(Function, Args, LimitContext) ->
    lim_client_woody:call(xrates, Function, Args, lim_context:woody_context(LimitContext)).
