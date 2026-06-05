-module(operation_context_tests).

-compile(nowarn_unused_function).

-include_lib("eunit/include/eunit.hrl").

-define(HG_KEY, {p, l, stored_hg_context}).
-define(FF_KEY, {p, l, {ff_context, stored_context}}).

-spec test() -> _.

test() ->
    operation_context_test_().

-spec operation_context_test_() -> _.

operation_context_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun colocated_keys_isolated/0,
        fun scoped_helpers/0
    ]}.

-spec setup() -> ok.

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(woody),
    ok.

-spec cleanup(_) -> ok.

cleanup(_) ->
    ok.

-spec colocated_keys_isolated() -> _.

colocated_keys_isolated() ->
    WoodyHg = woody_context:add_meta(woody_context:new(), #{<<"app">> => <<"hg">>}),
    WoodyFf = woody_context:add_meta(woody_context:new(), #{<<"app">> => <<"ff">>}),
    try
        CtxHg = operation_context:create(#{woody_context => WoodyHg}),
        CtxFf = operation_context:create(#{woody_context => WoodyFf}),
        ok = operation_context:save(?HG_KEY, CtxHg),
        ok = operation_context:save(?FF_KEY, CtxFf),
        CtxHgLoaded = operation_context:load(?HG_KEY),
        CtxFfLoaded = operation_context:load(?FF_KEY),
        ?assertEqual(WoodyHg, operation_context:get_woody_context(CtxHgLoaded)),
        ?assertEqual(WoodyFf, operation_context:get_woody_context(CtxFfLoaded)),
        ?assertNotEqual(
            operation_context:get_party_client_context(CtxHgLoaded),
            operation_context:get_party_client_context(CtxFfLoaded)
        ),
        ok = operation_context:cleanup(?HG_KEY, strict),
        CtxFfAfterHgCleanup = operation_context:load(?FF_KEY),
        ?assertEqual(WoodyFf, operation_context:get_woody_context(CtxFfAfterHgCleanup)),
        ok = operation_context:cleanup(?FF_KEY, lenient)
    after
        _ = catch operation_context:cleanup(?HG_KEY, lenient),
        _ = catch operation_context:cleanup(?FF_KEY, lenient)
    end.

-spec scoped_helpers() -> _.

scoped_helpers() ->
    WoodyCtx = woody_context:new(),
    try
        ok = operation_context:save_fistful(operation_context:create(#{woody_context => WoodyCtx})),
        ?assertEqual(WoodyCtx, operation_context:get_woody_context(operation_context:load_fistful())),
        ok = operation_context:cleanup_fistful(),
        ok = operation_context:cleanup_fistful()
    after
        _ = catch operation_context:cleanup_fistful()
    end.
