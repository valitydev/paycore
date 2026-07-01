-module(hg_exrates).

-include_lib("exrates_proto/include/exrates_service_thrift.hrl").
-include_lib("exrates_proto/include/exrates_base_thrift.hrl").

-export([get_exchange_rate/2]).

-type currency_symbolic_code() :: binary().
-type rate() :: #{
    p := integer(),
    q := integer()
}.

-define(RATES_SERVICE, rate_boss).

-spec get_exchange_rate(currency_symbolic_code(), currency_symbolic_code()) ->
    {ok, rate()} | {error, _Reason}.
get_exchange_rate(SourceCurrency, DestinationCurrency) ->
    Args = #'service_GetCurrencyExchangeRateRequest'{
        currency_data = #'service_CurrencyData'{
            source_currency = SourceCurrency,
            destination_currency = DestinationCurrency
        }
    },
    case issue_call('GetExchangeRateData', {Args}) of
        {ok, #'service_GetCurrencyExchangeRateResult'{
            exchange_rate = #base_Rational{p = P, q = Q}
        }} ->
            {ok, #{p => P, q => Q}};
        {exception, #'service_ExRateNotFound'{}} ->
            {error, not_found};
        {error, _} ->
            {error, unexpected_error}
    end.

issue_call(Func, Args) ->
    try hg_woody_wrapper:call(?RATES_SERVICE, Func, Args) of
        Result ->
            Result
    catch
        error:{woody_error, _ErrorType} = Reason:_St ->
            logger:error("exchange rates error: ~p", [Reason]),
            {error, Reason}
    end.
