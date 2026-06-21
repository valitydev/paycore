-module(hg_dummy_exrates).

-include_lib("exrates_proto/include/exrates_service_thrift.hrl").
-include_lib("exrates_proto/include/exrates_base_thrift.hrl").

-behaviour(hg_woody_service_wrapper).

-export([handle_function/3]).

-behaviour(hg_test_proxy).

-export([get_service_spec/0]).

-spec get_service_spec() -> hg_proto:service_spec().
get_service_spec() ->
    {"/test/exrates/dummy", {exrates_service_thrift, 'ExchangeRateService'}}.

-spec handle_function(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function(
    'GetExchangeRateData',
    {#service_GetCurrencyExchangeRateRequest{
        currency_data =
            #service_CurrencyData{
                source_currency = <<"RUB">>,
                destination_currency = <<"USD">>
            } = CurrencyData
    }},
    _
) ->
    Timestamp = calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}]),
    #service_GetCurrencyExchangeRateResult{
        currency_data = CurrencyData,
        exchange_rate = #base_Rational{p = 80, q = 1},
        timestamp = unicode:characters_to_binary(Timestamp)
    };
handle_function(
    'GetExchangeRateData',
    {#service_GetCurrencyExchangeRateRequest{
        currency_data =
            #service_CurrencyData{
                source_currency = <<"RUB">>,
                destination_currency = <<"EUR">>
            }
    }},
    _
) ->
    throw({exception, #service_ExRateNotFound{}});
handle_function(
    'GetExchangeRateData',
    {#service_GetCurrencyExchangeRateRequest{
        currency_data =
            #service_CurrencyData{
                source_currency = <<"RUB">>,
                destination_currency = <<"JPY">>
            }
    }},
    _
) ->
    timer:sleep(5100),
    {exception, #service_ExRateNotFound{}};
handle_function(
    'GetExchangeRateData',
    _,
    _
) ->
    erlang:error(internal_exchange_error).
