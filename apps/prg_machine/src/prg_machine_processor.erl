-module(prg_machine_processor).

-export([process/3]).

-ifdef(TEST).
-export([marshal_intent/3]).
-endif.

-spec process({init | call | repair | notify | timeout, binary(), map()}, prg_machine:process_options(), binary()) ->
    {ok, map()} | {error, term()}.
process({CallType, BinArgs, Process}, #{ns := NS} = Opts, BinCtx) ->
    try
        case prg_machine_registry:lookup(NS) of
            {error, _} = Error ->
                Error;
            {ok, Handler} ->
                prg_machine_env:run(BinCtx, Opts, fun() ->
                    LastEventID = maps:get(last_event_id, Process),
                    Machine = prg_machine_events:unmarshal_machine(Handler, NS, Process),
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

dispatch(Handler, init, BinArgs, Machine) ->
    Args = prg_machine_codec:decode_term(BinArgs),
    prg_machine:callback_init(Handler, Args, Machine);
dispatch(Handler, timeout, _BinArgs, Machine) ->
    prg_machine:callback_process_signal(Handler, timeout, Machine);
dispatch(Handler, notify, BinArgs, Machine) ->
    Args = prg_machine_codec:decode_term(BinArgs),
    dispatch_notification(Handler, Args, Machine);
dispatch(Handler, call, BinArgs, Machine) ->
    case prg_machine_codec:decode_term(BinArgs) of
        {notify, Args} ->
            dispatch_notification(Handler, Args, Machine);
        remove ->
            #{events => [], action => remove, auxst => maps:get(aux_state, Machine)};
        Call ->
            prg_machine:callback_process_call(Handler, Call, Machine)
    end;
dispatch(Handler, repair, BinArgs, Machine) ->
    Args = prg_machine_codec:decode_term(BinArgs),
    case prg_machine:callback_process_repair(Handler, Args, Machine) of
        {error, Reason} ->
            {error, Reason};
        Result when is_map(Result) ->
            Result
    end.

dispatch_notification(Handler, Args, Machine) ->
    prg_machine:callback_process_notification(Handler, Args, Machine).

marshal_process_result(Handler, LastEventID, {Response, Result}) when is_map(Result) ->
    Intent = marshal_intent(Handler, LastEventID, Result),
    {ok, Intent#{response => prg_machine_codec:encode_term(Response)}};
marshal_process_result(Handler, LastEventID, Result) when is_map(Result) ->
    {ok, marshal_intent(Handler, LastEventID, Result)};
marshal_process_result(_Handler, _LastEventID, {error, Reason}) ->
    {error, prg_machine_codec:encode_term(Reason)}.

-spec marshal_intent(module(), non_neg_integer(), prg_machine:result()) -> map().
marshal_intent(Handler, LastEventID, Result) when is_map(Result) ->
    Base0 = #{events => prg_machine_events:marshal_new_events(Handler, LastEventID, maps:get(events, Result, []))},
    Base1 =
        case maps:get(action, Result, idle) of
            idle ->
                Base0;
            Action ->
                Base0#{action => Action}
        end,
    case maps:is_key(auxst, Result) of
        true ->
            Base1#{aux_state => prg_machine_events:marshal_aux_state(Handler, maps:get(auxst, Result))};
        false ->
            Base1
    end.
