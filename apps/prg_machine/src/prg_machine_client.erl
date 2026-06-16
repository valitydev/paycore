-module(prg_machine_client).

-include_lib("progressor/include/progressor.hrl").

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

-spec start(prg_machine:namespace(), id(), prg_machine:args()) -> {ok, ok} | {error, exists | term()}.
start(NS, ID, Args) ->
    Req = #{
        ns => NS,
        id => ID,
        args => prg_machine_codec:encode_term(Args),
        context => prg_machine_env:encode_rpc_context()
    },
    case progressor:init(Req) of
        {ok, ok} = Ok ->
            Ok;
        {error, <<"process already exists">>} ->
            {error, exists};
        {error, _} = Error ->
            Error
    end.

-spec call(prg_machine:namespace(), id(), prg_machine:call()) ->
    {ok, prg_machine:response()} | {error, notfound | failed | term()}.
call(NS, ID, CallArgs) ->
    call(NS, ID, CallArgs, undefined, undefined, forward).

-spec call(
    prg_machine:namespace(),
    id(),
    prg_machine:call(),
    prg_machine:event_id() | undefined,
    non_neg_integer() | undefined,
    forward | backward
) ->
    {ok, prg_machine:response()} | {error, notfound | failed | term()}.
call(NS, ID, CallArgs, After, Limit, Direction) ->
    Req = request(NS, ID, CallArgs, encode_range(After, Limit, Direction)),
    case progressor:call(Req) of
        {ok, Response} ->
            {ok, prg_machine_codec:decode_term(Response)};
        {error, <<"process not found">>} ->
            {error, notfound};
        {error, <<"process is init">>} ->
            {error, notfound};
        {error, <<"process is error">>} ->
            {error, failed};
        {error, {exception, _Class, _Reason} = Exception} ->
            {error, Exception};
        {error, {exception, Class, Reason, _Stacktrace}} ->
            {error, {exception, Class, Reason}};
        {error, _} = Error ->
            Error
    end.

-spec repair(prg_machine:namespace(), id(), prg_machine:args()) ->
    {ok, term()} | {error, prg_machine:repair_error()}.
repair(NS, ID, Args) ->
    Req = #{
        ns => NS,
        id => ID,
        args => prg_machine_codec:encode_term(Args),
        context => prg_machine_env:encode_rpc_context()
    },
    case progressor:repair(Req) of
        {ok, Response} ->
            {ok, prg_machine_codec:decode_term(Response)};
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
            {error, {repair, {failed, prg_machine_codec:decode_term(Reason)}}}
    end.

-spec get(prg_machine:namespace(), id(), history_range()) ->
    {ok, prg_machine:machine()} | {error, prg_machine:get_error()}.
get(NS, ID, Range) ->
    Req = request(NS, ID, undefined, Range),
    case progressor:get(Req) of
        {ok, Process} ->
            case prg_machine_registry:lookup(NS) of
                {ok, Handler} ->
                    {ok, prg_machine_events:unmarshal_machine(Handler, NS, Process)};
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

-spec get(prg_machine:namespace(), id()) -> {ok, prg_machine:machine()} | {error, prg_machine:get_error()}.
get(NS, ID) ->
    get(NS, ID, #{direction => forward}).

-spec get_history(prg_machine:namespace(), id()) -> {ok, prg_machine:history()} | {error, prg_machine:get_error()}.
get_history(NS, ID) ->
    get_history(NS, ID, undefined, undefined, forward).

-spec get_history(
    prg_machine:namespace(),
    id(),
    prg_machine:event_id() | undefined,
    non_neg_integer() | undefined
) ->
    {ok, prg_machine:history()} | {error, prg_machine:get_error()}.
get_history(NS, ID, After, Limit) ->
    get_history(NS, ID, After, Limit, forward).

-spec get_history(
    prg_machine:namespace(),
    id(),
    prg_machine:event_id() | undefined,
    non_neg_integer() | undefined,
    forward | backward
) ->
    {ok, prg_machine:history()} | {error, prg_machine:get_error()}.
get_history(NS, ID, After, Limit, Direction) ->
    case get(NS, ID, history_range(After, Limit, Direction)) of
        {ok, #{history := History}} ->
            {ok, History};
        Error ->
            Error
    end.

-spec notify(prg_machine:namespace(), id(), prg_machine:args()) ->
    ok | {error, notfound | failed | prg_machine:processor_error() | term()}.
notify(NS, ID, Args) ->
    case call(NS, ID, {notify, Args}) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

-spec remove(prg_machine:namespace(), id()) ->
    ok | {error, notfound | failed | prg_machine:processor_error() | term()}.
remove(NS, ID) ->
    case call(NS, ID, remove) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

-spec history_range(undefined | prg_machine:event_id(), undefined | non_neg_integer(), forward | backward) ->
    history_range().
history_range(Offset, Limit, Direction) ->
    encode_range(Offset, Limit, Direction).

request(NS, ID, Args, Range) ->
    genlib_map:compact(#{
        ns => NS,
        id => ID,
        args => prg_machine_codec:encode_term(Args),
        context => prg_machine_env:encode_rpc_context(),
        range => Range
    }).

encode_range(After, Limit, Direction) ->
    genlib_map:compact(#{
        offset => After,
        limit => Limit,
        direction => Direction
    }).
