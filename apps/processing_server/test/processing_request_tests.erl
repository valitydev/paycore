-module(processing_request_tests).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec request_test_() -> _.
request_test_() ->
    {setup, fun setup/0, [
        fun request_context_lifetime/0,
        fun existing_deadline_is_preserved/0,
        fun default_deadline_is_set/0,
        fun configured_deadline_is_set/0,
        fun other_binding_is_preserved/0,
        fun() -> exception_cleans_context(throw, fun throw_request_failure/0) end,
        fun() -> exception_cleans_context(error, fun error_request_failure/0) end,
        fun() -> exception_cleans_context(exit, fun exit_request_failure/0) end,
        fun hg_handler_contract/0,
        fun ff_handler_contract/0,
        fun ff_module_handler_options/0,
        fun hg_business_exception/0,
        fun ff_business_exception/0
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(processing_server),
    processing_server_metrics:setup().

request_context_lifetime() ->
    Options = options(lifetime),
    PartyClient = party_client:create_client(),
    Result = processing_request:run(woody_context:new(), Options#{party_client => PartyClient}, fun() ->
        Context = current_context(),
        ?assertEqual(PartyClient, op_context:get_party_client(Context)),
        ?assertNotEqual(undefined, woody_context:get_deadline(op_context:get_woody_context(Context))),
        response
    end),
    ?assertEqual(response, Result),
    assert_unbound(binding()),
    {Buckets, _Sum} = observation(lifetime),
    ?assertEqual(1, lists:sum(Buckets)).

existing_deadline_is_preserved() ->
    Deadline = woody_deadline:from_timeout(60000),
    WoodyContext = woody_context:set_deadline(Deadline, woody_context:new()),
    Options = (options(existing_deadline))#{default_handling_timeout => 1000},
    processing_request:run(WoodyContext, Options, fun() ->
        ?assertEqual(WoodyContext, op_context:get_woody_context(current_context()))
    end),
    assert_unbound(binding()).

default_deadline_is_set() ->
    Context = processing_request:ensure_deadline(woody_context:new(), #{}),
    Remaining = woody_deadline:to_timeout(woody_context:get_deadline(Context)),
    ?assert(Remaining > 0 andalso Remaining =< 30000).

configured_deadline_is_set() ->
    Options = (options(configured_deadline))#{default_handling_timeout => 10000},
    processing_request:run(woody_context:new(), Options, fun() ->
        Deadline = woody_context:get_deadline(op_context:get_woody_context(current_context())),
        Remaining = woody_deadline:to_timeout(Deadline),
        ?assert(Remaining > 0 andalso Remaining =< 10000)
    end),
    assert_unbound(binding()).

other_binding_is_preserved() ->
    OtherBinding = op_context:binding(hellgate),
    #{registry_key := OtherKey} = OtherBinding,
    OtherContext = op_context:create(),
    ok = op_context:save(OtherKey, OtherContext),
    try
        processing_request:run(woody_context:new(), options(other_binding), fun() ->
            ?assertEqual(OtherContext, op_context:load(OtherKey))
        end),
        ?assertEqual(OtherContext, op_context:load(OtherKey)),
        assert_unbound(binding())
    after
        op_context:cleanup(hellgate)
    end.

exception_cleans_context(Class, Handle) ->
    ?assertException(
        Class,
        handler_failed,
        processing_request:run(
            woody_context:new(), options(Class), Handle
        )
    ),
    assert_unbound(binding()),
    ?assertEqual(undefined, observation(Class)).

hg_handler_contract() ->
    Options = #{handler => processing_request_test_handler, ns => <<"test">>},
    Handle = fun(HandlerOptions) ->
        ?assertEqual(Options, HandlerOptions),
        _ = op_context:load(op_context:key(hellgate)),
        response
    end,
    ?assertEqual(
        {ok, response},
        hg_woody_service_wrapper:handle_function(
            hg_success, {Handle}, woody_context:new(), Options
        )
    ),
    assert_unbound(op_context:binding(hellgate)).

ff_handler_contract() ->
    HandlerOptions = #{setting => value},
    Options = #{
        handler => {processing_request_test_handler, HandlerOptions},
        party_client => party_client:create_client()
    },
    Handle = fun(ActualOptions) ->
        ?assertEqual(HandlerOptions, ActualOptions),
        _ = op_context:load(op_context:key(fistful)),
        {ok, response}
    end,
    ?assertEqual(
        {ok, response},
        ff_woody_wrapper:handle_function(
            ff_success, {Handle}, woody_context:new(), Options
        )
    ),
    assert_unbound(op_context:binding(fistful)).

ff_module_handler_options() ->
    Options = #{handler => processing_request_test_handler, party_client => party_client:create_client()},
    Handle = fun(HandlerOptions) -> {ok, HandlerOptions} end,
    ?assertEqual(
        {ok, undefined},
        ff_woody_wrapper:handle_function(
            ff_module, {Handle}, woody_context:new(), Options
        )
    ).

hg_business_exception() ->
    Handle = fun throw_business_failure/1,
    ?assertThrow(
        business_failure,
        hg_woody_service_wrapper:handle_function(
            hg_failure, {Handle}, woody_context:new(), #{handler => processing_request_test_handler}
        )
    ),
    assert_unbound(op_context:binding(hellgate)),
    ?assertEqual(undefined, observation(hg_failure)).

ff_business_exception() ->
    Options = #{handler => processing_request_test_handler, party_client => party_client:create_client()},
    Handle = fun raise_business_failure/1,
    ?assertThrow(
        business_failure,
        ff_woody_wrapper:handle_function(
            ff_failure, {Handle}, woody_context:new(), Options
        )
    ),
    assert_unbound(op_context:binding(fistful)),
    ?assertEqual(undefined, observation(ff_failure)).

options(Function) ->
    #{binding => binding(), handler => processing_request_test_handler, function => Function}.

binding() ->
    #{registry_key => {p, l, {?MODULE, request}}, cleanup_mode => strict}.

current_context() ->
    #{registry_key := Key} = binding(),
    op_context:load(Key).

assert_unbound(#{registry_key := Key}) ->
    ?assertError(badarg, op_context:load(Key)).

observation(Function) ->
    Labels = [atom_to_binary(processing_request_test_handler), atom_to_binary(Function)],
    prometheus_histogram:value(woody_wrapper_processing_duration_ms, Labels).

%% These callbacks deliberately fail to exercise the request cleanup paths.
-spec throw_request_failure() -> no_return().
throw_request_failure() ->
    throw(handler_failed).

-spec error_request_failure() -> no_return().
error_request_failure() ->
    error(handler_failed).

-spec exit_request_failure() -> no_return().
exit_request_failure() ->
    exit(handler_failed).

-spec throw_business_failure(term()) -> no_return().
throw_business_failure(_Options) ->
    throw(business_failure).

-spec raise_business_failure(term()) -> no_return().
raise_business_failure(_Options) ->
    woody_error:raise(business, business_failure).
