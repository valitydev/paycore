-module(prg_machine).

%%% Public facade for the unified progressor machine runtime. The implementation
%%% is split by role: client API, processor, env/context, codec and event fold.

-include_lib("progressor/include/progressor.hrl").

%% Types

-type namespace() :: namespace_id().
-type args() :: term().
-type call() :: term().
-type response() :: ok | {ok, term()} | {error, term()} | {exception, term()}.

%% Machinery timestamp format: a UTC datetime plus a microsecond remainder.
-type timestamp() :: {calendar:datetime(), non_neg_integer()}.
-type event_body() :: term().
%% Domain history tuple (not progressor storage event() map).
-type machine_event() :: {event_id(), timestamp(), event_body()}.
-type history() :: [machine_event()].
-type processor_error() :: {exception, atom(), term()}.

-type get_error() ::
    notfound
    | {unknown_namespace, namespace()}
    | processor_error().

-type repair_error() ::
    notfound
    | working
    | failed
    | processor_error()
    | {repair, {failed, term()}}.

-type machine() :: #{
    namespace := namespace(),
    id := id(),
    history := history(),
    aux_state := term(),
    range => history_range()
}.

-type signal() :: timeout.
-type result() :: #{
    events => [event_body()],
    action => action(),
    auxst => term()
}.

-type env_enter_fun() :: fun(() -> ok) | fun((woody_context:ctx()) -> ok).

-type context_binding() :: op_context:binding().

-type process_options() :: #{
    ns := namespace(),
    env_enter => env_enter_fun(),
    env_leave => fun(() -> ok),
    context_binding => context_binding(),
    default_handling_timeout => timeout()
}.

-export_type([
    namespace/0,
    id/0,
    event_id/0,
    history_range/0,
    args/0,
    call/0,
    response/0,
    timestamp/0,
    event_body/0,
    machine_event/0,
    history/0,
    machine/0,
    get_error/0,
    processor_error/0,
    repair_error/0,
    signal/0,
    result/0,
    process_options/0
]).

%% Domain behaviour

-callback namespace() -> namespace().

-callback init(args(), machine()) -> result().

-callback process_signal(signal(), machine()) -> result().

-callback process_call(call(), machine()) -> {response(), result()}.

-callback process_repair(args(), machine()) -> result() | {error, term()}.

-callback process_notification(args(), machine()) -> result().

-callback marshal_event_body(event_body()) -> {undefined | pos_integer(), binary()}.

-callback unmarshal_event_body(undefined | pos_integer(), binary()) -> event_body().

-callback marshal_aux_state(term()) -> binary().

-callback unmarshal_aux_state(binary()) -> term().

%% Canonical collapse callback. Domain modules passed to collapse/2 adapt legacy
%% event folds at their boundary and expose only this arity to the runtime.
-callback apply_event(event_id(), timestamp(), event_body(), term()) -> term().

-optional_callbacks([
    process_notification/2,
    marshal_event_body/1,
    unmarshal_event_body/2,
    marshal_aux_state/1,
    unmarshal_aux_state/1,
    apply_event/4
]).

%% Client API

-export([start/3]).
-export([call/3]).
-export([call/6]).
-export([repair/3]).
-export([get/2]).
-export([get/3]).
-export([get_history/2]).
-export([get_history/4]).
-export([get_history/5]).
-export([notify/3]).
-export([remove/2]).
-export([history_range/3]).

%% Progressor processor

-export([process/3]).

%% Registry (namespace -> handler module)

-export([get_child_spec/1]).
-export([handler_namespace/1]).
-export([unmarshal_event_body/3]).

%% Callback dispatch. Keep dynamic behaviour calls in this module: Elvis allows
%% them here because this is the module that defines the callbacks.

-export([callback_init/3]).
-export([callback_process_signal/3]).
-export([callback_process_call/3]).
-export([callback_process_repair/3]).
-export([callback_process_notification/3]).
-export([callback_apply_event/5]).
-export([callback_marshal_event_body/2]).
-export([callback_marshal_aux_state/2]).
-export([callback_unmarshal_aux_state/2]).

%% Event-sourcing helpers (replaces ff_machine)

-export([collapse/2]).
-export([emit_event/1]).
-export([emit_events/1]).
-export([timestamp/0]).

%%

-spec start(namespace(), id(), args()) -> {ok, ok} | {error, exists | term()}.
start(NS, ID, Args) ->
    prg_machine_client:start(NS, ID, Args).

-spec call(namespace(), id(), call()) -> {ok, response()} | {error, notfound | failed | term()}.
call(NS, ID, CallArgs) ->
    prg_machine_client:call(NS, ID, CallArgs).

-spec call(namespace(), id(), call(), event_id() | undefined, non_neg_integer() | undefined, forward | backward) ->
    {ok, response()} | {error, notfound | failed | term()}.
call(NS, ID, CallArgs, After, Limit, Direction) ->
    prg_machine_client:call(NS, ID, CallArgs, After, Limit, Direction).

-spec repair(namespace(), id(), args()) ->
    {ok, term()} | {error, repair_error()}.
repair(NS, ID, Args) ->
    prg_machine_client:repair(NS, ID, Args).

-spec get(namespace(), id(), history_range()) -> {ok, machine()} | {error, get_error()}.
get(NS, ID, Range) ->
    prg_machine_client:get(NS, ID, Range).

-spec get(namespace(), id()) -> {ok, machine()} | {error, get_error()}.
get(NS, ID) ->
    prg_machine_client:get(NS, ID).

-spec get_history(namespace(), id()) -> {ok, history()} | {error, get_error()}.
get_history(NS, ID) ->
    prg_machine_client:get_history(NS, ID).

-spec get_history(namespace(), id(), event_id() | undefined, non_neg_integer() | undefined) ->
    {ok, history()} | {error, get_error()}.
get_history(NS, ID, After, Limit) ->
    prg_machine_client:get_history(NS, ID, After, Limit).

-spec get_history(namespace(), id(), event_id() | undefined, non_neg_integer() | undefined, forward | backward) ->
    {ok, history()} | {error, get_error()}.
get_history(NS, ID, After, Limit, Direction) ->
    prg_machine_client:get_history(NS, ID, After, Limit, Direction).

-spec notify(namespace(), id(), args()) ->
    ok | {error, notfound | failed | processor_error() | term()}.
notify(NS, ID, Args) ->
    prg_machine_client:notify(NS, ID, Args).

-spec remove(namespace(), id()) ->
    ok | {error, notfound | failed | processor_error() | term()}.
remove(NS, ID) ->
    prg_machine_client:remove(NS, ID).

-spec history_range(undefined | event_id(), undefined | non_neg_integer(), forward | backward) ->
    history_range().
history_range(Offset, Limit, Direction) ->
    prg_machine_client:history_range(Offset, Limit, Direction).

%% Progressor processor callback.
%% progressor config: #{client => prg_machine, options => #{ns => invoice, ...}}

-spec process({init | call | repair | notify | timeout, binary(), map()}, process_options(), binary()) ->
    {ok, map()} | {error, term()}.
process(Call, Opts, BinCtx) ->
    prg_machine_processor:process(Call, Opts, BinCtx).

%% Registry

-spec get_child_spec([module()]) -> supervisor:child_spec().
get_child_spec(Handlers) ->
    prg_machine_registry:get_child_spec(Handlers).

-spec handler_namespace(module()) -> namespace().
handler_namespace(Handler) ->
    Handler:namespace().

-spec callback_init(module(), args(), machine()) -> result().
callback_init(Handler, Args, Machine) ->
    Handler:init(Args, Machine).

-spec callback_process_signal(module(), signal(), machine()) -> result().
callback_process_signal(Handler, Signal, Machine) ->
    Handler:process_signal(Signal, Machine).

-spec callback_process_call(module(), call(), machine()) -> {response(), result()}.
callback_process_call(Handler, Call, Machine) ->
    Handler:process_call(Call, Machine).

-spec callback_process_repair(module(), args(), machine()) -> result() | {error, term()}.
callback_process_repair(Handler, Args, Machine) ->
    Handler:process_repair(Args, Machine).

-spec callback_process_notification(module(), args(), machine()) -> result().
callback_process_notification(Handler, Args, Machine) ->
    case erlang:function_exported(Handler, process_notification, 2) of
        true ->
            Handler:process_notification(Args, Machine);
        false ->
            #{}
    end.

-spec callback_apply_event(module(), event_id(), timestamp(), event_body(), term()) -> term().
callback_apply_event(Handler, EventID, Ts, Body, Model) ->
    Handler:apply_event(EventID, Ts, Body, Model).

-spec callback_marshal_event_body(module(), event_body()) -> {undefined | pos_integer(), binary()}.
callback_marshal_event_body(Handler, Body) ->
    case erlang:function_exported(Handler, marshal_event_body, 1) of
        true ->
            Handler:marshal_event_body(Body);
        false ->
            {undefined, term_to_binary(Body)}
    end.

-spec unmarshal_event_body(module(), undefined | pos_integer(), binary()) -> event_body().
unmarshal_event_body(Handler, Format, Payload) ->
    case erlang:function_exported(Handler, unmarshal_event_body, 2) of
        true ->
            Handler:unmarshal_event_body(Format, Payload);
        false ->
            binary_to_term(Payload)
    end.

-spec callback_marshal_aux_state(module(), term()) -> binary().
callback_marshal_aux_state(Handler, AuxSt) ->
    case erlang:function_exported(Handler, marshal_aux_state, 1) of
        true ->
            Handler:marshal_aux_state(AuxSt);
        false ->
            term_to_binary(AuxSt)
    end.

-spec callback_unmarshal_aux_state(module(), undefined | binary()) -> term().
callback_unmarshal_aux_state(_Handler, undefined) ->
    undefined;
callback_unmarshal_aux_state(Handler, Bin) when is_binary(Bin) ->
    case erlang:function_exported(Handler, unmarshal_aux_state, 1) of
        true ->
            Handler:unmarshal_aux_state(Bin);
        false ->
            binary_to_term(Bin)
    end.

%% Event-sourcing (replaces ff_machine collapse/emit)

-spec collapse(module(), machine()) -> term().
collapse(Handler, Machine) ->
    prg_machine_events:collapse(Handler, Machine).

-spec emit_event(term()) -> [{ev, timestamp(), term()}].
emit_event(Event) ->
    prg_machine_events:emit_event(Event).

-spec emit_events([term()]) -> [{ev, timestamp(), term()}].
emit_events(Events) ->
    prg_machine_events:emit_events(Events).

-spec timestamp() -> timestamp().
timestamp() ->
    prg_machine_events:timestamp().

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, prg_machine_dispatch).
-define(TEST_NS, env_test_ns).
-define(TEST_REGISTRY_KEY, {p, l, prg_machine_env_test_context}).
-define(TEST_BINDING, #{
    registry_key => ?TEST_REGISTRY_KEY,
    cleanup_mode => lenient
}).

-spec test() -> _.

-spec noop_when_hooks_absent_test_() -> _.
noop_when_hooks_absent_test_() ->
    {setup, fun setup_env_hook_test/0, fun cleanup_env_hook_test/1, [
        ?_test(noop_when_hooks_absent())
    ]}.

-spec explicit_fun_overrides_context_binding_test_() -> _.
explicit_fun_overrides_context_binding_test_() ->
    {setup, fun setup_env_hook_test/0, fun cleanup_env_hook_test/1, [
        ?_test(explicit_fun_overrides_context_binding())
    ]}.

-spec aux_state_runtime_test_() -> _.
aux_state_runtime_test_() ->
    {setup, fun setup_aux_state_test/0, fun cleanup_aux_state_test/1, [
        ?_test(marshal_intent_omits_aux_state_without_auxst()),
        ?_test(collapse_survives_non_map_aux_state()),
        ?_test(business_exception_then_signal_does_not_corrupt_aux_state()),
        ?_test(notify_without_handler_omits_aux_state())
    ]}.

-spec registry_runtime_test_() -> _.
registry_runtime_test_() ->
    {setup, fun setup_registry_test/0, fun cleanup_registry_test/1, [
        ?_test(lookup_unknown_namespace_returns_error()),
        ?_test(process_unknown_namespace_returns_error())
    ]}.

-spec process_exception_test_() -> _.
process_exception_test_() ->
    {setup, fun setup_aux_state_test/0, fun cleanup_aux_state_test/1, [
        ?_test(process_crash_conforms_progressor_exception())
    ]}.

-spec noop_when_hooks_absent() -> _.
noop_when_hooks_absent() ->
    ok = ensure_woody_available(),
    ok = prg_machine_env_mock_context:reset(),
    _ = run_env_hook_process(#{ns => ?TEST_NS}),
    ?assertEqual([], prg_machine_env_mock_context:events()).

-spec explicit_fun_overrides_context_binding() -> _.
explicit_fun_overrides_context_binding() ->
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
        ns => ?TEST_NS,
        env_enter => Enter,
        env_leave => Leave,
        context_binding => ?TEST_BINDING
    },
    _ = run_env_hook_process(Opts),
    ?assertEqual([explicit_enter, explicit_leave], prg_machine_env_mock_context:events()).

-spec setup_env_hook_test() -> ok.
setup_env_hook_test() ->
    _ = application:load(prg_machine),
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(snowflake),
    {ok, _} = application:ensure_all_started(woody),
    {ok, _} = application:ensure_all_started(scoper),
    {ok, _} = application:ensure_all_started(party_client),
    {ok, _} = application:ensure_all_started(opentelemetry_api),
    {ok, _} = application:ensure_all_started(opentelemetry),
    {ok, _} = application:ensure_all_started(op_context),
    _ = ensure_env_hook_dispatch_table(),
    true = ets:insert(?TABLE, {?TEST_NS, prg_machine_env_mock_handler}),
    ok = prg_machine_env_mock_context:reset(),
    ok.

-spec cleanup_env_hook_test(_) -> ok.
cleanup_env_hook_test(_) ->
    _ = ets:delete(?TABLE, ?TEST_NS),
    op_context:cleanup(?TEST_REGISTRY_KEY, lenient),
    ok.

-spec ensure_woody_available() -> ok.
ensure_woody_available() ->
    {ok, _} = application:ensure_all_started(snowflake),
    _ = woody_context:new(),
    ok.

-spec ensure_env_hook_dispatch_table() -> ok.
ensure_env_hook_dispatch_table() ->
    prg_machine_registry:ensure_table().

-spec run_env_hook_process(process_options()) -> _.
run_env_hook_process(Opts) ->
    run_env_hook_process(Opts, <<>>).

-spec run_env_hook_process(process_options(), binary()) -> _.
run_env_hook_process(Opts, BinCtx) ->
    Process = #{
        process_id => <<"env-hook-test">>,
        last_event_id => 0,
        history => [],
        aux_state => undefined
    },
    process({init, term_to_binary(#{}), Process}, Opts, BinCtx).

-define(AUX_STATE_TEST_NS, aux_state_test_ns).

-spec setup_aux_state_test() -> ok.
setup_aux_state_test() ->
    _ = application:load(prg_machine),
    {ok, _} = application:ensure_all_started(progressor),
    _ = ensure_env_hook_dispatch_table(),
    true = ets:insert(?TABLE, {?AUX_STATE_TEST_NS, prg_machine_aux_state_test_handler}),
    ok.

-spec cleanup_aux_state_test(_) -> ok.
cleanup_aux_state_test(_) ->
    _ = ets:delete(?TABLE, ?AUX_STATE_TEST_NS),
    ok.

-spec marshal_intent_omits_aux_state_without_auxst() -> _.
marshal_intent_omits_aux_state_without_auxst() ->
    Intent = prg_machine_processor:marshal_intent(prg_machine_aux_state_test_handler, 0, #{}),
    ?assertNot(maps:is_key(aux_state, Intent)),
    ?assertEqual([], maps:get(events, Intent)).

-spec collapse_survives_non_map_aux_state() -> _.
collapse_survives_non_map_aux_state() ->
    Machine = #{
        namespace => ?AUX_STATE_TEST_NS,
        id => <<"collapse-test">>,
        history => [],
        aux_state => {corrupt, undefined}
    },
    ?assertEqual(undefined, collapse(prg_machine_aux_state_test_handler, Machine)).

-spec business_exception_then_signal_does_not_corrupt_aux_state() -> _.
business_exception_then_signal_does_not_corrupt_aux_state() ->
    Opts = #{ns => ?AUX_STATE_TEST_NS},
    Process0 = #{
        process_id => <<"invoice-exception-test">>,
        last_event_id => 0,
        history => [],
        aux_state => undefined
    },
    {ok, InitIntent} = process({init, term_to_binary(#{}), Process0}, Opts, <<>>),
    ?assert(maps:is_key(aux_state, InitIntent)),
    AuxAfterInit = maps:get(aux_state, InitIntent),
    Process1 = Process0#{
        aux_state => AuxAfterInit,
        last_event_id => 0
    },
    {ok, ExceptionIntent} = process(
        {call, term_to_binary(business_exception), Process1},
        Opts,
        <<>>
    ),
    ?assertNot(maps:is_key(aux_state, ExceptionIntent)),
    Process2 = Process1#{aux_state => AuxAfterInit},
    {ok, TimeoutIntent} = process({timeout, <<>>, Process2}, Opts, <<>>),
    ?assertNot(maps:is_key(aux_state, TimeoutIntent)),
    {ok, RecheckIntent} = process(
        {call, term_to_binary(recheck), Process2},
        Opts,
        <<>>
    ),
    ?assert(maps:is_key(aux_state, RecheckIntent)),
    Rechecked = binary_to_term(maps:get(aux_state, RecheckIntent), [safe]),
    ?assertEqual(#{model => initialized}, Rechecked).

-spec notify_without_handler_omits_aux_state() -> _.
notify_without_handler_omits_aux_state() ->
    Opts = #{ns => ?AUX_STATE_TEST_NS},
    AuxBin = prg_machine_aux_state_test_handler:marshal_aux_state(#{model => initialized}),
    Process = #{
        process_id => <<"notify-test">>,
        last_event_id => 0,
        history => [],
        aux_state => AuxBin
    },
    {ok, NotifyIntent} = process({notify, term_to_binary(#{payload => test}), Process}, Opts, <<>>),
    ?assertNot(maps:is_key(aux_state, NotifyIntent)).

-spec setup_registry_test() -> ok.
setup_registry_test() ->
    ok = prg_machine_registry:ensure_table(),
    ok.

-spec cleanup_registry_test(_) -> ok.
cleanup_registry_test(_) ->
    ok.

-spec lookup_unknown_namespace_returns_error() -> _.
lookup_unknown_namespace_returns_error() ->
    ?assertEqual(
        {error, {unknown_namespace, unknown_ns}},
        prg_machine_registry:lookup(unknown_ns)
    ).

-spec process_unknown_namespace_returns_error() -> _.
process_unknown_namespace_returns_error() ->
    Opts = #{ns => unknown_ns},
    Process = #{
        process_id => <<"unknown-ns-test">>,
        last_event_id => 0,
        history => [],
        aux_state => undefined
    },
    ?assertEqual(
        {error, {unknown_namespace, unknown_ns}},
        process({init, term_to_binary(#{}), Process}, Opts, <<>>)
    ).

-spec process_crash_conforms_progressor_exception() -> _.
process_crash_conforms_progressor_exception() ->
    Opts = #{ns => ?AUX_STATE_TEST_NS},
    Process = #{
        process_id => <<"crash-test">>,
        last_event_id => 0,
        history => [],
        aux_state => undefined
    },
    {ok, _} = process({init, term_to_binary(#{}), Process}, Opts, <<>>),
    ?assertEqual(
        {error, {exception, error, deliberate_crash}},
        process({call, term_to_binary(crash), Process}, Opts, <<>>)
    ).

%% --- Golden tests: legacy format compatibility (stage 1) -------------------

-spec event_metadata_writes_both_keys_test() -> _.
event_metadata_writes_both_keys_test() ->
    %% Old HG reader expects <<"format_version">>, old FF reader expects
    %% <<"format">>; we must keep both so a rollback to either stack still reads.
    ?assertEqual(#{<<"format_version">> => 1, <<"format">> => 1}, prg_machine_events:event_metadata(1)),
    ?assertEqual(#{<<"format_version">> => 0, <<"format">> => 0}, prg_machine_events:event_metadata(undefined)).

-spec unmarshal_event_format_reads_legacy_keys_test() -> _.
unmarshal_event_format_reads_legacy_keys_test() ->
    %% New (both keys).
    ?assertEqual(2, prg_machine_events:unmarshal_event_format(#{<<"format_version">> => 2, <<"format">> => 2})),
    %% Legacy HG metadata: only <<"format_version">>.
    ?assertEqual(1, prg_machine_events:unmarshal_event_format(#{<<"format_version">> => 1})),
    %% Legacy FF metadata: only <<"format">>.
    ?assertEqual(1, prg_machine_events:unmarshal_event_format(#{<<"format">> => 1})),
    %% Defensive atom key and absence.
    ?assertEqual(3, prg_machine_events:unmarshal_event_format(#{format => 3})),
    ?assertEqual(undefined, prg_machine_events:unmarshal_event_format(#{})).

-spec decode_term_reads_legacy_double_envelope_test() -> _.
decode_term_reads_legacy_double_envelope_test() ->
    Args = #{<<"some">> => <<"args">>, n => 42},
    %% Legacy hg_machine wrapped call/init args as
    %% term_to_binary({bin, term_to_binary(Args)}).
    Legacy = term_to_binary({bin, term_to_binary(Args)}),
    ?assertEqual(Args, prg_machine_codec:decode_term(Legacy)),
    %% New single envelope still works (rollback/forward invariant).
    ?assertEqual(Args, prg_machine_codec:decode_term(prg_machine_codec:encode_term(Args))),
    %% A genuine {bin, Bin} payload that is not double-wrapped term is returned
    %% as the inner term only when the inner binary decodes — guard keeps us safe
    %% for non-binary tuples.
    ?assertEqual({bin, not_a_binary}, prg_machine_codec:decode_term(term_to_binary({bin, not_a_binary}))).

-endif.
