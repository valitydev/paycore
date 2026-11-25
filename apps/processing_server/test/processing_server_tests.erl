-module(processing_server_tests).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec hellgate_bootstrap_test() -> _.
hellgate_bootstrap_test() ->
    {Flags, Registrations, Options} = bootstrap(hellgate, fun hellgate:init/1),
    ?assertEqual(#{strategy => one_for_all, intensity => 6, period => 30}, Flags),
    assert_registrations(Registrations, [hg_invoice, hg_invoice_template], hellgate),
    ?assertMatch(#{event_handler := {scoper_woody_event_handler, _}}, Options),
    assert_routes(
        Options,
        hg_woody_service_wrapper,
        [hg_invoice_handler, hg_invoice_template, hg_proxy_host_provider, hg_progressor_trace_handler],
        ["/healthz/liveness", "/healthz/readiness"]
    ).

-spec fistful_bootstrap_test() -> _.
fistful_bootstrap_test() ->
    {Flags, Registrations, Options} = bootstrap(ff_server, fun ff_server:init/1),
    ?assertEqual(#{strategy => one_for_one}, Flags),
    assert_registrations(
        Registrations,
        [
            ff_deposit_machine,
            ff_source_machine,
            ff_destination_machine,
            ff_withdrawal_machine,
            ff_withdrawal_session_machine
        ],
        fistful
    ),
    ?assertMatch(#{event_handler := ff_woody_event_handler}, Options),
    assert_routes(
        Options,
        ff_woody_wrapper,
        [
            ff_withdrawal_adapter_host,
            ff_destination_handler,
            ff_source_handler,
            ff_withdrawal_handler,
            ff_withdrawal_session_handler,
            ff_deposit_handler,
            ff_withdrawal_session_repair,
            ff_withdrawal_repair,
            ff_deposit_repair,
            ff_progressor_trace_handler
        ],
        ["/healthz/readiness", "/healthz/liveness"]
    ).

bootstrap(App, Init) ->
    ok = meck:new(woody_server, [passthrough]),
    try
        {ok,
            {Flags, [
                #{id := party_client},
                #{start := {prg_machine_registry, start_link, [Registrations]}},
                #{id := App} = Listener
            ]}} = Init([]),
        [{_, {woody_server, child_spec, [App, Options]}, Listener}] = meck:history(woody_server),
        {Flags, Registrations, Options}
    after
        ok = meck:unload(woody_server)
    end.

assert_registrations(Registrations, Handlers, Scope) ->
    Binding = op_context:binding(Scope),
    ?assertEqual([#{handler => Handler, binding => Binding} || Handler <- Handlers], Registrations).

assert_routes(#{handlers := Endpoints, additional_routes := Routes}, Wrapper, Handlers, HealthPaths) ->
    ?assertEqual(
        Handlers,
        [
            Handler
         || {_, {_, {Module, #{handler := Handler, party_client := _, default_handling_timeout := _}}}} <- Endpoints,
            Module =:= Wrapper
        ]
    ),
    ?assertEqual(length(Handlers), length(Endpoints)),
    ?assertEqual(["/metrics/[:registry]" | HealthPaths], [Path || {Path, _, _} <- Routes]).
