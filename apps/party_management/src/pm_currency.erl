%%% Currency related functions
%%%

-module(pm_currency).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([validate_currency/2]).

-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().

-spec validate_currency(currency(), shop()) -> ok.
validate_currency(Currency, Shop = #domain_ShopConfig{}) ->
    validate_currency_(Currency, get_shop_currency(Shop)).

validate_currency_(Currency, Currency) ->
    ok;
validate_currency_(_, _) ->
    throw(#base_InvalidRequest{errors = [<<"Invalid currency">>]}).

get_shop_currency(#domain_ShopConfig{account = #domain_ShopAccount{currency = Currency}}) ->
    Currency.
