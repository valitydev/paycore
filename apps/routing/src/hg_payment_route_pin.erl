-module(hg_payment_route_pin).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([fill/2]).
-export([hash/1]).

-type context() :: #{
    currency := dmsl_domain_thrift:'CurrencyRef'(),
    payment_tool := dmsl_domain_thrift:'PaymentTool'(),
    client_ip => dmsl_domain_thrift:'IPAddress'(),
    email => binary(),
    card_token => dmsl_domain_thrift:'Token'()
}.

-export_type([context/0]).

-spec fill([hg_route:t()], context()) -> [hg_route:t()].
fill(Routes, Context) ->
    [fill_route(Route, Context) || Route <- Routes].

fill_route(Route, Context) ->
    Pin = maps:get(routing_pin, Route, undefined),
    PinHash = hash(gather_pin_info(Pin, Context)),
    maps:remove(routing_pin, Route#{pin_hash => PinHash}).

gather_pin_info(undefined, _Context) ->
    #{};
gather_pin_info(#domain_RoutingPin{features = Features}, Context) ->
    maps:from_list([{Feature, maps:get(Feature, Context, undefined)} || Feature <- ordsets:to_list(Features)]).

-spec hash(map() | undefined) -> non_neg_integer().
hash(Pin) when is_map(Pin), map_size(Pin) > 0 ->
    erlang:phash2(Pin);
hash(_) ->
    0.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec fill_pin_features_test() -> _.
fill_pin_features_test() ->
    Route = hg_route:new(1, #domain_ProviderRef{id = 1}, #domain_TerminalRef{id = 1}, 50, 1000, 0),
    Context = #{
        currency => #domain_CurrencyRef{symbolic_code = <<"RUB">>},
        payment_tool =>
            {generic, #domain_GenericPaymentTool{payment_service = #domain_PaymentServiceRef{id = <<"test">>}}},
        email => <<"payer@example.com">>
    },
    Pin = #domain_RoutingPin{features = ordsets:from_list([email, card_token])},
    [Pinned, Empty, Unpinned] = fill(
        [Route#{routing_pin => Pin}, Route#{routing_pin => #domain_RoutingPin{features = []}}, Route], Context
    ),
    ?assertEqual(
        erlang:phash2(#{email => <<"payer@example.com">>, card_token => undefined}), hg_route:pin_hash(Pinned)
    ),
    ?assertEqual(0, hg_route:pin_hash(Empty)),
    ?assertEqual(0, hg_route:pin_hash(Unpinned)),
    ?assertNot(maps:is_key(routing_pin, Pinned)).

-endif.
