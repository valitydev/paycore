-module(prg_machine_env).

-export([encode_rpc_context/0]).
-export([run/3]).

%% Default woody deadline (30s, configurable per namespace via opts), restoring
%% the old hg_progressor behaviour.
-define(DEFAULT_HANDLING_TIMEOUT, 30000).

-spec encode_rpc_context() -> binary().
encode_rpc_context() ->
    WoodyContext = op_context:current_woody_context(),
    prg_machine_codec:encode_term(woody_rpc_helper:encode_rpc_context(WoodyContext, otel_ctx:get_current())).

-spec run(binary(), prg_machine:process_options(), fun(() -> Result)) -> Result.
run(BinCtx, Opts, Fun) when is_function(Fun, 0) ->
    Enter = resolve_env_enter(Opts),
    Leave = resolve_env_leave(Opts),
    {WoodyCtx0, OtelCtx} = decode_rpc_context(BinCtx),
    ok = woody_rpc_helper:attach_otel_context(OtelCtx),
    WoodyCtx = ensure_deadline_set(WoodyCtx0, Opts),
    ok = run_env_enter(Enter, WoodyCtx),
    %% Enter succeeded: from here Leave must run exactly once. Errors raised
    %% before this point fall through to the processor catch unchanged.
    run_with_env_leave(Leave, Fun).

decode_rpc_context(<<>>) ->
    woody_rpc_helper:decode_rpc_context(#{});
decode_rpc_context(Bin) ->
    woody_rpc_helper:decode_rpc_context(prg_machine_codec:decode_term(Bin)).

ensure_deadline_set(WoodyCtx, Opts) ->
    case woody_context:get_deadline(WoodyCtx) of
        undefined ->
            Timeout = maps:get(default_handling_timeout, Opts, ?DEFAULT_HANDLING_TIMEOUT),
            woody_context:set_deadline(woody_deadline:from_timeout(Timeout), WoodyCtx);
        _Set ->
            WoodyCtx
    end.

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
