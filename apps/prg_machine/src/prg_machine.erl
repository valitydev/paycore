-module(prg_machine).

%%% Unified runtime: HTTP/woody handlers -> domain (-behaviour(prg_machine)) -> progressor.
%%% Replaces hg_machine, ff_machine, machinery client/backend stack for progressor.

-include_lib("progressor/include/progressor.hrl").

-define(TABLE, prg_machine_dispatch).
-define(PROCESSOR_EXCEPTION(Class, Reason, _Stacktrace), {exception, Class, Reason}).

%% Types

-type namespace() :: namespace_id().
-type args() :: term().
-type call() :: term().
-type response() :: ok | {ok, term()} | {error, term()} | {exception, term()}.

-type timestamp() :: calendar:datetime().
-type event_body() :: term().
%% Domain history tuple (not progressor storage event() map).
-type machine_event() :: {event_id(), timestamp(), event_body()}.
-type history() :: [machine_event()].

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
    action => progressor_action:t(),
    auxst => term()
}.

-type env_enter_fun() :: fun(() -> ok) | fun((woody_context:ctx()) -> ok).

-type context_binding() :: operation_context:binding().

-type process_options() :: #{
    ns := namespace(),
    env_enter => env_enter_fun(),
    env_leave => fun(() -> ok),
    context_binding => context_binding()
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
-export([start_link/1]).
-export([init/1]).

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
        {error, {exception, _, _} = Exception} ->
            raise_exception(Exception)
    end.

-spec call(namespace(), id(), call()) -> {ok, response()} | {error, notfound | term()}.
call(NS, ID, CallArgs) ->
    call(NS, ID, CallArgs, undefined, undefined, forward).

-spec call(namespace(), id(), call(), event_id() | undefined, non_neg_integer() | undefined, forward | backward) ->
    {ok, response()} | {error, notfound | term()}.
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
        {error, {exception, _, _} = Exception} ->
            raise_exception(Exception);
        {error, _} = Error ->
            Error
    end.

-spec repair(namespace(), id(), args()) ->
    {ok, term()} | {error, notfound | working | failed | {repair, {failed, binary()}}}.
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
        {error, {exception, _, _} = Exception} ->
            raise_exception(Exception);
        {error, Reason} ->
            {error, {repair, {failed, Reason}}}
    end.

-spec get(namespace(), id(), history_range()) -> {ok, machine()} | {error, notfound}.
get(NS, ID, Range) ->
    Req = request(NS, ID, undefined, Range),
    case progressor:get(Req) of
        {ok, Process} ->
            Handler = get_handler_module(NS),
            {ok, unmarshal_machine(Handler, NS, Process)};
        {error, <<"process not found">>} ->
            {error, notfound};
        {error, {exception, _, _} = Exception} ->
            raise_exception(Exception)
    end.

-spec get(namespace(), id()) -> {ok, machine()} | {error, notfound}.
get(NS, ID) ->
    get(NS, ID, #{direction => forward}).

-spec get_history(namespace(), id()) -> {ok, history()} | {error, notfound}.
get_history(NS, ID) ->
    get_history(NS, ID, undefined, undefined, forward).

-spec get_history(namespace(), id(), event_id() | undefined, non_neg_integer() | undefined) ->
    {ok, history()} | {error, notfound}.
get_history(NS, ID, After, Limit) ->
    get_history(NS, ID, After, Limit, forward).

-spec get_history(namespace(), id(), event_id() | undefined, non_neg_integer() | undefined, forward | backward) ->
    {ok, history()} | {error, notfound}.
get_history(NS, ID, After, Limit, Direction) ->
    case get(NS, ID, history_range(After, Limit, Direction)) of
        {ok, #{history := History}} ->
            {ok, History};
        Error ->
            Error
    end.

-spec notify(namespace(), id(), args()) -> ok | {error, notfound}.
notify(NS, ID, Args) ->
    case call(NS, ID, {notify, Args}) of
        {ok, _} -> ok;
        {error, notfound} = Error -> Error
    end.

-spec remove(namespace(), id()) -> ok | {error, notfound}.
remove(NS, ID) ->
    case call(NS, ID, remove) of
        {ok, _} -> ok;
        {error, notfound} = Error -> Error
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
        {WoodyCtx, OtelCtx} = decode_rpc_context(BinCtx),
        ok = woody_rpc_helper:attach_otel_context(OtelCtx),
        ok = run_env_enter(Enter, WoodyCtx),
        Handler = get_handler_module(NS),
        LastEventID = maps:get(last_event_id, Process),
        Machine = unmarshal_machine(Handler, NS, Process),
        Result = dispatch(Handler, CallType, BinArgs, Machine),
        marshal_process_result(Handler, LastEventID, Result)
    catch
        Class:Reason:Stacktrace ->
            logger:error("prg_machine process failed: ~p:~p~n~p", [Class, Reason, Stacktrace]),
            {error, ?PROCESSOR_EXCEPTION(Class, Reason, Stacktrace)}
    after
        Leave()
    end.

%% Registry

-spec get_child_spec([module()]) -> supervisor:child_spec().
get_child_spec(Handlers) ->
    #{
        id => prg_machine_dispatch,
        start => {?MODULE, start_link, [Handlers]},
        type => supervisor
    }.

-spec start_link([module()]) -> {ok, pid()}.
start_link(Handlers) ->
    supervisor:start_link(?MODULE, Handlers).

-spec init([module()]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Handlers) ->
    _ = ets:new(?TABLE, [named_table, {read_concurrency, true}]),
    true = ets:insert_new(?TABLE, [{H:namespace(), H} || H <- Handlers]),
    {ok, {#{}, []}}.

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
    calendar:universal_time().

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
            #{events => [], action => progressor_action:remove(), auxst => maps:get(aux_state, Machine)};
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

marshal_intent(Handler, LastEventID, #{events := Events, action := Action, auxst := AuxSt}) ->
    genlib_map:compact(#{
        events => marshal_new_events(Handler, LastEventID, Events),
        action => Action,
        aux_state => marshal_aux_state(Handler, AuxSt)
    });
marshal_intent(Handler, LastEventID, Result) ->
    marshal_intent(Handler, LastEventID, maps:merge(#{events => [], auxst => undefined}, Result)).

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
    Format = maps:get(<<"format">>, Meta, maps:get(format, Meta, undefined)),
    Body = unmarshal_event_body(Handler, Format, Payload),
    {EventID, event_timestamp_to_datetime(TsSec), Body};
unmarshal_event(_Handler, #{event_id := EventID} = Ev) ->
    erlang:error({missing_event_payload, EventID, maps:keys(Ev)}).

marshal_new_events(Handler, LastEventID, Bodies) ->
    Ts = erlang:system_time(microsecond),
    lists:zipwith(
        fun(EventID, Body) ->
            {Format, Bin} = marshal_event_body(Handler, Body),
            #{
                event_id => EventID,
                timestamp => Ts div 1000000,
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

unmarshal_event_body(Handler, Format, Payload) ->
    case erlang:function_exported(Handler, unmarshal_event_body, 2) of
        true ->
            Handler:unmarshal_event_body(Format, Payload);
        false ->
            binary_to_term(Payload, [safe])
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
            binary_to_term(Bin, [safe])
    end.

event_metadata(undefined) ->
    #{<<"format">> => 0};
event_metadata(Format) when is_integer(Format) ->
    #{<<"format">> => Format}.

event_timestamp_to_datetime({{_, _, _}, {_, _, _}} = Dt) ->
    Dt;
event_timestamp_to_datetime(Ts) when is_integer(Ts) ->
    TsSeconds = prg_utils:to_seconds(Ts),
    calendar:system_time_to_universal_time(TsSeconds, second).

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

initial_model(_Handler, AuxState) ->
    maps:get(model, AuxState, undefined).

get_handler_module(NS) ->
    ets:lookup_element(?TABLE, NS, 2).

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
    WoodyContext =
        try application:get_env(prg_machine, woody_context_loader, undefined) of
            {M, F} when is_atom(M), is_atom(F) ->
                M:F();
            Loader when is_function(Loader, 0) ->
                Loader();
            undefined ->
                woody_context:new()
        catch
            _:_ ->
                woody_context:new()
        end,
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
                    fun(WoodyCtx) -> operation_context:env_enter(WoodyCtx, Binding) end;
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
                    fun() -> operation_context:env_leave(Binding) end;
                _ ->
                    fun() -> ok end
            end
    end.

run_env_enter(Enter, WoodyCtx) when is_function(Enter, 1) ->
    Enter(WoodyCtx);
run_env_enter(Enter, _WoodyCtx) when is_function(Enter, 0) ->
    Enter().

encode_term(Term) ->
    term_to_binary(Term).

decode_term(Term) when is_binary(Term) ->
    binary_to_term(Term, [safe]);
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

-spec raise_exception({exception, atom(), term()}) -> no_return().
raise_exception({exception, Class, Reason}) ->
    erlang:raise(Class, Reason, []).

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
    {ok, _} = application:ensure_all_started(operation_context),
    _ = ensure_env_hook_dispatch_table(),
    true = ets:insert(?TABLE, {?TEST_NS, prg_machine_env_mock_handler}),
    ok = prg_machine_env_mock_context:reset(),
    ok.

-spec cleanup_env_hook_test(_) -> ok.
cleanup_env_hook_test(_) ->
    _ = ets:delete(?TABLE, ?TEST_NS),
    operation_context:cleanup(?TEST_REGISTRY_KEY, lenient),
    ok.

-spec ensure_woody_available() -> ok.
ensure_woody_available() ->
    {ok, _} = application:ensure_all_started(snowflake),
    _ = woody_context:new(),
    ok.

-spec ensure_env_hook_dispatch_table() -> atom().
ensure_env_hook_dispatch_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, {read_concurrency, true}]);
        _ ->
            ?TABLE
    end.

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

-endif.
