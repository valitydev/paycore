-module(prg_machine_env_tests).

-compile(nowarn_unused_function).

-include_lib("eunit/include/eunit.hrl").

-define(TABLE, prg_machine_dispatch).
-define(NS, env_test_ns).
-define(TEST_REGISTRY_KEY, {p, l, prg_machine_env_test_context}).
-define(TEST_BINDING, #{
    registry_key => ?TEST_REGISTRY_KEY,
    cleanup_mode => lenient
}).

-spec test() -> _.

test() ->
    {setup, fun setup/0, fun cleanup/1, [
        ?_test(noop_when_hooks_absent_test()),
        ?_test(explicit_fun_overrides_context_binding_test())
    ]}.

-spec noop_when_hooks_absent_test() -> _.

noop_when_hooks_absent_test() ->
    ok = ensure_woody_available(),
    ok = prg_machine_env_mock_context:reset(),
    _ = run_process(#{ns => ?NS}),
    ?assertEqual([], prg_machine_env_mock_context:events()).

-spec explicit_fun_overrides_context_binding_test() -> _.

explicit_fun_overrides_context_binding_test() ->
    ok = ensure_woody_available(),
    ok = prg_machine_env_mock_context:reset(),
    Enter = fun(_) ->
        prg_machine_env_mock_context:record(explicit_enter),
        ok
    end,
    Leave = fun() ->
        prg_machine_env_mock_context:record(explicit_leave),
        ok
    end,
    Opts = #{
        ns => ?NS,
        env_enter => Enter,
        env_leave => Leave,
        context_binding => ?TEST_BINDING
    },
    _ = run_process(Opts),
    ?assertEqual([explicit_enter, explicit_leave], prg_machine_env_mock_context:events()).

-spec setup() -> ok.

setup() ->
    _ = application:load(prg_machine),
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(snowflake),
    {ok, _} = application:ensure_all_started(woody),
    {ok, _} = application:ensure_all_started(scoper),
    {ok, _} = application:ensure_all_started(party_client),
    {ok, _} = application:ensure_all_started(opentelemetry_api),
    {ok, _} = application:ensure_all_started(opentelemetry),
    {ok, _} = application:ensure_all_started(operation_context),
    _ = ensure_dispatch_table(),
    true = ets:insert(?TABLE, {?NS, prg_machine_env_mock_handler}),
    ok = prg_machine_env_mock_context:reset(),
    ok.

-spec cleanup(_) -> ok.

cleanup(_) ->
    _ = ets:delete(?TABLE, ?NS),
    _ = catch operation_context:cleanup(?TEST_REGISTRY_KEY, lenient),
    ok.

-spec ensure_woody_available() -> ok.

ensure_woody_available() ->
    {ok, _} = application:ensure_all_started(snowflake),
    _ = woody_context:new(),
    ok.

-spec ensure_dispatch_table() -> atom().

ensure_dispatch_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, {read_concurrency, true}]);
        _ ->
            ?TABLE
    end.

-spec run_process(prg_machine:processor_opts()) -> _.
run_process(Opts) ->
    run_process(Opts, <<>>).

-spec run_process(prg_machine:processor_opts(), binary()) -> _.

run_process(Opts, BinCtx) ->
    Process = #{
        process_id => <<"env-hook-test">>,
        last_event_id => 0,
        history => [],
        aux_state => undefined
    },
    prg_machine:process({init, term_to_binary(#{}), Process}, Opts, BinCtx).
