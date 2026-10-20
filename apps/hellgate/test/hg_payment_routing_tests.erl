-module(hg_payment_routing_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-spec test() -> _.

-spec payment_adapter_no_second_fill_prohibition_test() -> _.
payment_adapter_no_second_fill_prohibition_test() ->
    ok = meck:new(hg_route_collector, [passthrough]),
    try
        ok = meck:expect(hg_route_collector, get_routes, fun(_, _, _, _) -> #{routes => []} end),
        _ = hg_payment_routing:get_routes(#{
            predestination => payment,
            revision => 1,
            varset => #{},
            payment_institution => #domain_PaymentInstitution{
                name = <<"test">>,
                realm = test,
                residences = [],
                system_account_set = {value, #domain_SystemAccountSetRef{id = 1}},
                inspector = {value, #domain_InspectorRef{id = 1}}
            },
            pin_context => #{
                currency => #domain_CurrencyRef{symbolic_code = <<"RUB">>},
                payment_tool =>
                    {generic, #domain_GenericPaymentTool{payment_service = #domain_PaymentServiceRef{id = <<"test">>}}},
                client_ip => undefined
            }
        }),
        ?assertEqual(0, meck:num_calls(hg_route_collector, fill_prohibition, '_'))
    after
        ok = meck:unload(hg_route_collector)
    end.
