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
    #service_GetCurrencyExchangeRateRequest{
        currency_data = CurrencyData
    },
    _
) ->
    Timestamp = calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}]),
    #service_GetCurrencyExchangeRateResult{
        currency_data = CurrencyData,
        exchange_rate = #base_Rational{p = 1, q = 1},
        timestamp = unicode:characters_to_binary(Timestamp)
    }.
