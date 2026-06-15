-module(prg_machine).

%%% Unified runtime: HTTP/woody handlers -> domain (-behaviour(prg_machine)) -> progressor.
%%% Replaces hg_machine, ff_machine, machinery client/backend stack for progressor.

-include_lib("progressor/include/progressor.hrl").

-define(TABLE, prg_machine_dispatch).

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
-type get_error() ::
    notfound
    | {unknown_namespace, namespace()}
    | {exception, atom(), term()}.

-type processor_error() ::
    {exception, atom(), term()}
    | {exception, atom(), term(), list()}.

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

-type signal() :: timeout | {repair, args()}.
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

%% Optional: collapse passes event_id and timestamp (HG invoice). Default: apply_event/2.
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

%% Event-sourcing helpers (replaces ff_machine)

-export([collapse/2]).
-export([emit_event/1]).
-export([emit_events/1]).
-export([timestamp/0]).

%%

-spec start(namespace(), id(), args()) -> {ok, ok} | {error, exists | term()}.
start(NS, ID, Args) ->
    Req = #{
        ns => NS,
        id => ID,
        args => encode_term(Args),
        context => encode_rpc_context()
    },
    case progressor:init(Req) of
        {ok, ok} = Ok ->
            Ok;
        {error, <<"process already exists">>} ->
            {error, exists};
        {error, _} = Error ->
            Error
    end.

-spec call(namespace(), id(), call()) -> {ok, response()} | {error, notfound | failed | term()}.
call(NS, ID, CallArgs) ->
    call(NS, ID, CallArgs, undefined, undefined, forward).

-spec call(namespace(), id(), call(), event_id() | undefined, non_neg_integer() | undefined, forward | backward) ->
    {ok, response()} | {error, notfound | failed | term()}.
call(NS, ID, CallArgs, After, Limit, Direction) ->
    Req = request(NS, ID, CallArgs, encode_range(After, Limit, Direction)),
    case progressor:call(Req) of
        {ok, Response} ->
            {ok, decode_term(Response)};
        {error, <<"process not found">>} ->
            {error, notfound};
        {error, <<"process is init">>} ->
            {error, notfound};
        {error, <<"process is error">>} ->
            {error, failed};
        {error, _} = Error ->
            Error
    end.

-spec repair(namespace(), id(), args()) ->
    {ok, term()} | {error, repair_error()}.
repair(NS, ID, Args) ->
    Req = #{
        ns => NS,
        id => ID,
        args => encode_term(Args),
        context => encode_rpc_context()
    },
    case progressor:repair(Req) of
        {ok, Response} ->
            {ok, decode_term(Response)};
        {error, <<"process not found">>} ->
            {error, notfound};
        {error, <<"process is init">>} ->
            {error, notfound};
        {error, <<"process is running">>} ->
            {error, working};
        {error, <<"process is error">>} ->
            {error, failed};
        {error, {exception, _Class, _Reason} = Exception} ->
            {error, Exception};
        {error, {exception, Class, Reason, _Stacktrace}} ->
            {error, {exception, Class, Reason}};
        {error, Reason} ->
            %% The repair-failed reason is our own term encoded by process/3
            %% (marshal_process_result -> encode_term); hand it back as a term.
            {error, {repair, {failed, decode_term(Reason)}}}
    end.

-spec get(namespace(), id(), history_range()) -> {ok, machine()} | {error, get_error()}.
get(NS, ID, Range) ->
    Req = request(NS, ID, undefined, Range),
    case progressor:get(Req) of
        {ok, Process} ->
            case get_handler_module(NS) of
                {ok, Handler} ->
                    {ok, unmarshal_machine(Handler, NS, Process)};
                {error, _} = Error ->
                    Error
            end;
        {error, <<"process not found">>} ->
            {error, notfound};
        {error, {exception, _Class, _Reason} = Exception} ->
            {error, Exception};
        {error, {exception, Class, Reason, _Stacktrace}} ->
            {error, {exception, Class, Reason}}
    end.

-spec get(namespace(), id()) -> {ok, machine()} | {error, get_error()}.
get(NS, ID) ->
    get(NS, ID, #{direction => forward}).

-spec get_history(namespace(), id()) -> {ok, history()} | {error, get_error()}.
get_history(NS, ID) ->
    get_history(NS, ID, undefined, undefined, forward).

-spec get_history(namespace(), id(), event_id() | undefined, non_neg_integer() | undefined) ->
    {ok, history()} | {error, get_error()}.
get_history(NS, ID, After, Limit) ->
    get_history(NS, ID, After, Limit, forward).

-spec get_history(namespace(), id(), event_id() | undefined, non_neg_integer() | undefined, forward | backward) ->
    {ok, history()} | {error, get_error()}.
get_history(NS, ID, After, Limit, Direction) ->
    case get(NS, ID, history_range(After, Limit, Direction)) of
        {ok, #{history := History}} ->
            {ok, History};
        Error ->
            Error
    end.

-spec notify(namespace(), id(), args()) ->
    ok | {error, notfound | failed | {exception, atom(), term()} | term()}.
notify(NS, ID, Args) ->
    case call(NS, ID, {notify, Args}) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

-spec remove(namespace(), id()) ->
    ok | {error, notfound | failed | {exception, atom(), term()} | term()}.
remove(NS, ID) ->
    case call(NS, ID, remove) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

-spec history_range(undefined | event_id(), undefined | non_neg_integer(), forward | backward) ->
    history_range().
history_range(Offset, Limit, Direction) ->
    encode_range(Offset, Limit, Direction).

%% Progressor processor callback.
%% progressor config: #{client => prg_machine, options => #{ns => invoice, ...}}

-spec process({init | call | repair | notify | timeout, binary(), map()}, process_options(), binary()) ->
    {ok, map()} | {error, term()}.
process({CallType, BinArgs, Process}, #{ns := NS} = Opts, BinCtx) ->
    Enter = resolve_env_enter(Opts),
    Leave = resolve_env_leave(Opts),
    try
        case get_handler_module(NS) of
            {error, _} = Error ->
                Error;
            {ok, Handler} ->
                {WoodyCtx0, OtelCtx} = decode_rpc_context(BinCtx),
                ok = woody_rpc_helper:attach_otel_context(OtelCtx),
                WoodyCtx = ensure_deadline_set(WoodyCtx0, Opts),
                ok = run_env_enter(Enter, WoodyCtx),
                %% Enter succeeded: from here Leave must run exactly once. Errors
                %% raised before this point fall through to the outer catch and are
                %% returned as {error, _} without being masked by a Leave exception.
                run_with_env_leave(Leave, fun() ->
                    LastEventID = maps:get(last_event_id, Process),
                    Machine = unmarshal_machine(Handler, NS, Process),
                    Result = dispatch(Handler, CallType, BinArgs, Machine),
                    marshal_process_result(Handler, LastEventID, Result)
                end)
        end
    catch
        Class:Reason:Stacktrace ->
            Exception = {exception, Class, Reason},
            logger:error(
                "prg_machine process failed: ~p:~p",
                [Class, Reason],
                #{stacktrace => Stacktrace, exception => Exception}
            ),
            {error, Exception}
    end.

%% Default woody deadline (30s, configurable per namespace via opts), restoring the
%% old hg_progressor behaviour (hg_woody_service_wrapper:ensure_woody_deadline_set/2).
-define(DEFAULT_HANDLING_TIMEOUT, 30000).

ensure_deadline_set(WoodyCtx, Opts) ->
    case woody_context:get_deadline(WoodyCtx) of
        undefined ->
            Timeout = maps:get(default_handling_timeout, Opts, ?DEFAULT_HANDLING_TIMEOUT),
            woody_context:set_deadline(woody_deadline:from_timeout(Timeout), WoodyCtx);
        _Set ->
            WoodyCtx
    end.

%% Registry

-spec get_child_spec([module()]) -> supervisor:child_spec().
get_child_spec(Handlers) ->
    prg_machine_registry:get_child_spec(Handlers).

-spec handler_namespace(module()) -> namespace().
handler_namespace(Handler) ->
    Handler:namespace().

%% Event-sourcing (replaces ff_machine collapse/emit)

-spec collapse(module(), machine()) -> term().
collapse(Handler, #{history := History, aux_state := AuxState}) ->
    lists:foldl(
        fun({EventID, Ts, Body}, Model) ->
            dispatch_apply_event(Handler, EventID, Ts, Body, Model)
        end,
        initial_model(Handler, AuxState),
        History
    ).

-spec emit_event(term()) -> [{ev, timestamp(), term()}].
emit_event(Event) ->
    emit_events([Event]).

-spec emit_events([term()]) -> [{ev, timestamp(), term()}].
emit_events(Events) ->
    Ts = timestamp(),
    [{ev, Ts, Body} || Body <- Events].

-spec timestamp() -> timestamp().
timestamp() ->
    Now = erlang:system_time(microsecond),
    {Seconds, Micro} = prg_utils:split_timestamp(Now),
    {calendar:system_time_to_universal_time(Seconds, second), Micro}.

%% Internals — dispatch

dispatch(Handler, init, BinArgs, Machine) ->
    Args = decode_term(BinArgs),
    Handler:init(Args, Machine);
dispatch(Handler, timeout, _BinArgs, Machine) ->
    Handler:process_signal(timeout, Machine);
dispatch(Handler, notify, BinArgs, Machine) ->
    Args = decode_term(BinArgs),
    dispatch_notification(Handler, Args, Machine);
dispatch(Handler, call, BinArgs, Machine) ->
    case decode_term(BinArgs) of
        {notify, Args} ->
            dispatch_notification(Handler, Args, Machine);
        remove ->
            #{events => [], action => remove, auxst => maps:get(aux_state, Machine)};
        Call ->
            Handler:process_call(Call, Machine)
    end;
dispatch(Handler, repair, BinArgs, Machine) ->
    Args = decode_term(BinArgs),
    case Handler:process_repair(Args, Machine) of
        {error, Reason} ->
            {error, Reason};
        Result when is_map(Result) ->
            Result
    end.

dispatch_notification(Handler, Args, Machine) ->
    case erlang:function_exported(Handler, process_notification, 2) of
        true ->
            Handler:process_notification(Args, Machine);
        false ->
            #{}
    end.

marshal_process_result(Handler, LastEventID, {Response, Result}) when is_map(Result) ->
    Intent = marshal_intent(Handler, LastEventID, Result),
    {ok, Intent#{response => encode_term(Response)}};
marshal_process_result(Handler, LastEventID, Result) when is_map(Result) ->
    {ok, marshal_intent(Handler, LastEventID, Result)};
marshal_process_result(_Handler, _LastEventID, {error, Reason}) ->
    {error, encode_term(Reason)}.

marshal_intent(Handler, LastEventID, Result) when is_map(Result) ->
    Base0 = #{events => marshal_new_events(Handler, LastEventID, maps:get(events, Result, []))},
    Base1 =
        case maps:get(action, Result, idle) of
            idle ->
                Base0;
            Action ->
                Base0#{action => Action}
        end,
    case maps:is_key(auxst, Result) of
        true ->
            Base1#{aux_state => marshal_aux_state(Handler, maps:get(auxst, Result))};
        false ->
            Base1
    end.

%% Internals — progressor <-> machine

unmarshal_machine(Handler, NS, #{process_id := ID, history := RawHistory} = Process) ->
    Range = range_from_process(Process),
    History = [unmarshal_event(Handler, Ev) || Ev <- RawHistory],
    AuxState = unmarshal_aux_state(Handler, maps:get(aux_state, Process, undefined)),
    #{
        namespace => NS,
        id => ID,
        history => History,
        aux_state => AuxState,
        range => Range
    }.

unmarshal_event(Handler, #{
    event_id := EventID,
    timestamp := TsSec,
    metadata := Meta,
    payload := Payload
}) ->
    Format = unmarshal_event_format(Meta),
    Body = unmarshal_event_body(Handler, Format, Payload),
    {EventID, event_timestamp_to_datetime(TsSec), Body};
unmarshal_event(_Handler, #{event_id := EventID} = Ev) ->
    erlang:error({missing_event_payload, EventID, maps:keys(Ev)}).

marshal_new_events(Handler, LastEventID, Bodies) ->
    %% One microsecond timestamp for the whole batch (as the old emit_events did).
    %% The PG backend stores timestamptz with microseconds and auto-detects units.
    Ts = erlang:system_time(microsecond),
    lists:zipwith(
        fun(EventID, Body) ->
            {Format, Bin} = marshal_event_body(Handler, Body),
            #{
                event_id => EventID,
                timestamp => Ts,
                metadata => event_metadata(Format),
                payload => Bin
            }
        end,
        lists:seq(LastEventID + 1, LastEventID + length(Bodies)),
        Bodies
    ).

marshal_event_body(Handler, Body) ->
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

marshal_aux_state(Handler, AuxSt) ->
    case erlang:function_exported(Handler, marshal_aux_state, 1) of
        true ->
            Handler:marshal_aux_state(AuxSt);
        false ->
            term_to_binary(AuxSt)
    end.

unmarshal_aux_state(_Handler, undefined) ->
    undefined;
unmarshal_aux_state(Handler, Bin) when is_binary(Bin) ->
    case erlang:function_exported(Handler, unmarshal_aux_state, 1) of
        true ->
            Handler:unmarshal_aux_state(Bin);
        false ->
            binary_to_term(Bin)
    end.

%% Write both legacy keys: old HG reader expects <<"format_version">>,
%% old FF reader expects <<"format">>. Keeping both keeps rollback safe for
%% both stacks and feeds the event sink (prg_notifier reads <<"format_version">>).
event_metadata(undefined) ->
    event_metadata(0);
event_metadata(Format) when is_integer(Format) ->
    #{<<"format_version">> => Format, <<"format">> => Format}.

%% Read order: legacy HG <<"format_version">> → legacy FF <<"format">> →
%% atom format (defensive) → undefined.
unmarshal_event_format(Meta) ->
    maps:get(
        <<"format_version">>,
        Meta,
        maps:get(<<"format">>, Meta, maps:get(format, Meta, undefined))
    ).

%% Already in machinery format {datetime, micro}.
event_timestamp_to_datetime({{{_, _, _}, {_, _, _}}, Micro} = DtMicro) when is_integer(Micro) ->
    DtMicro;
%% Bare datetime (defensive) — assume zero microseconds.
event_timestamp_to_datetime({{_, _, _}, {_, _, _}} = Dt) ->
    {Dt, 0};
%% Integer timestamp stored by progressor — split into seconds + microseconds.
event_timestamp_to_datetime(Ts) when is_integer(Ts) ->
    {Seconds, Micro} = prg_utils:split_timestamp(Ts),
    {calendar:system_time_to_universal_time(Seconds, second), Micro}.

dispatch_apply_event(Handler, EventID, Ts, Body, Model) ->
    case erlang:function_exported(Handler, apply_event, 4) of
        true ->
            Handler:apply_event(EventID, Ts, Body, Model);
        false ->
            case erlang:function_exported(Handler, apply_event, 2) of
                true ->
                    Handler:apply_event(Body, Model);
                false ->
                    erlang:error({apply_event_not_defined, Handler})
            end
    end.

initial_model(_Handler, AuxState) when is_map(AuxState) ->
    maps:get(model, AuxState, undefined);
initial_model(_Handler, _AuxState) ->
    undefined.

get_handler_module(NS) ->
    prg_machine_registry:lookup(NS).

%% RPC / terms

request(NS, ID, Args, Range) ->
    genlib_map:compact(#{
        ns => NS,
        id => ID,
        args => encode_term(Args),
        context => encode_rpc_context(),
        range => Range
    }).

encode_rpc_context() ->
    WoodyContext = op_context:current_woody_context(),
    encode_term(woody_rpc_helper:encode_rpc_context(WoodyContext, otel_ctx:get_current())).

decode_rpc_context(<<>>) ->
    woody_rpc_helper:decode_rpc_context(#{});
decode_rpc_context(Bin) ->
    woody_rpc_helper:decode_rpc_context(decode_term(Bin)).

resolve_env_enter(Opts) ->
    case maps:is_key(env_enter, Opts) of
        true ->
            maps:get(env_enter, Opts);
        false ->
            case maps:get(context_binding, Opts, undefined) of
                Binding when is_map(Binding) ->
                    fun(WoodyCtx) -> op_context:env_enter(WoodyCtx, Binding) end;
                _ ->
                    fun(_) -> ok end
            end
    end.

resolve_env_leave(Opts) ->
    case maps:is_key(env_leave, Opts) of
        true ->
            maps:get(env_leave, Opts);
        false ->
            case maps:get(context_binding, Opts, undefined) of
                Binding when is_map(Binding) ->
                    fun() -> op_context:env_leave(Binding) end;
                _ ->
                    fun() -> ok end
            end
    end.

run_env_enter(Enter, WoodyCtx) when is_function(Enter, 1) ->
    Enter(WoodyCtx);
run_env_enter(Enter, _WoodyCtx) when is_function(Enter, 0) ->
    Enter().

run_with_env_leave(Leave, Fun) when is_function(Leave, 0), is_function(Fun, 0) ->
    try Fun() of
        Result ->
            safe_env_leave(Leave),
            Result
    catch
        Class:Reason:Stacktrace ->
            safe_env_leave(Leave),
            erlang:raise(Class, Reason, Stacktrace)
    end.

safe_env_leave(Leave) ->
    try
        Leave()
    catch
        Class:Reason:Stacktrace ->
            logger:error(
                "prg_machine env_leave failed: ~p:~p",
                [Class, Reason],
                #{stacktrace => Stacktrace}
            )
    end.

encode_term(Term) ->
    term_to_binary(Term).

decode_term(Term) when is_binary(Term) ->
    case binary_to_term(Term) of
        %% Legacy double envelope: old hg_machine wrote
        %% term_to_binary({bin, term_to_binary(Args)}) for call/init args.
        {bin, Bin} when is_binary(Bin) ->
            binary_to_term(Bin);
        Decoded ->
            Decoded
    end;
decode_term(Term) ->
    Term.

encode_range(After, Limit, Direction) ->
    genlib_map:compact(#{
        offset => After,
        limit => Limit,
        direction => Direction
    }).

range_from_process(#{range := Range = #{}}) ->
    Range;
range_from_process(_) ->
    #{direction => forward}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

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
    Intent = marshal_intent(prg_machine_aux_state_test_handler, 0, #{}),
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
    ?assertEqual(#{<<"format_version">> => 1, <<"format">> => 1}, event_metadata(1)),
    ?assertEqual(#{<<"format_version">> => 0, <<"format">> => 0}, event_metadata(undefined)).

-spec unmarshal_event_format_reads_legacy_keys_test() -> _.
unmarshal_event_format_reads_legacy_keys_test() ->
    %% New (both keys).
    ?assertEqual(2, unmarshal_event_format(#{<<"format_version">> => 2, <<"format">> => 2})),
    %% Legacy HG metadata: only <<"format_version">>.
    ?assertEqual(1, unmarshal_event_format(#{<<"format_version">> => 1})),
    %% Legacy FF metadata: only <<"format">>.
    ?assertEqual(1, unmarshal_event_format(#{<<"format">> => 1})),
    %% Defensive atom key and absence.
    ?assertEqual(3, unmarshal_event_format(#{format => 3})),
    ?assertEqual(undefined, unmarshal_event_format(#{})).

-spec decode_term_reads_legacy_double_envelope_test() -> _.
decode_term_reads_legacy_double_envelope_test() ->
    Args = #{<<"some">> => <<"args">>, n => 42},
    %% Legacy hg_machine wrapped call/init args as
    %% term_to_binary({bin, term_to_binary(Args)}).
    Legacy = term_to_binary({bin, term_to_binary(Args)}),
    ?assertEqual(Args, decode_term(Legacy)),
    %% New single envelope still works (rollback/forward invariant).
    ?assertEqual(Args, decode_term(encode_term(Args))),
    %% A genuine {bin, Bin} payload that is not double-wrapped term is returned
    %% as the inner term only when the inner binary decodes — guard keeps us safe
    %% for non-binary tuples.
    ?assertEqual({bin, not_a_binary}, decode_term(term_to_binary({bin, not_a_binary}))).

-endif.
