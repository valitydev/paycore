-module(lim_liminator).

-include_lib("liminator_proto/include/liminator_liminator_thrift.hrl").

-export([get_name/1]).
-export([construct_change/4]).

-export([get_values/2]).
-export([get/3]).
-export([hold/3]).
-export([commit/3]).
-export([rollback/3]).

-type operation_id() :: liminator_liminator_thrift:'OperationId'().
-type limit_change() :: liminator_liminator_thrift:'LimitChange'().
-type limit_name() :: liminator_liminator_thrift:'LimitName'().
-type limit_id() :: liminator_liminator_thrift:'LimitId'().
-type change_context() :: liminator_liminator_thrift:'Context'().
-type limit_response() :: liminator_liminator_thrift:'LimitResponse'().
-type amount() :: liminator_liminator_thrift:'Value'().
-type lim_context() :: lim_context:t().

-type invalid_request_error() :: {invalid_request, list(binary())}.

-export_type([amount/0]).
-export_type([invalid_request_error/0]).
-export_type([limit_response/0]).
-export_type([limit_change/0]).
-export_type([change_context/0]).

-spec construct_change(limit_id(), limit_name(), amount(), change_context()) -> limit_change().
construct_change(ID, Name, Value, ChangeContext) ->
    #liminator_LimitChange{
        limit_id = ID,
        limit_name = Name,
        value = Value,
        context = ChangeContext
    }.

-spec get_name(limit_change()) -> limit_name().
get_name(#liminator_LimitChange{limit_name = Name}) ->
    Name.

-spec get_values([limit_name()], lim_context()) ->
    {ok, [limit_response()]} | {error, invalid_request_error()}.
get_values(Names, LimitContext) ->
    do('GetLastLimitsValues', Names, LimitContext).

-spec get(operation_id(), [limit_change()], lim_context()) ->
    {ok, [limit_response()]} | {error, invalid_request_error()}.
get(OperationID, Changes, LimitContext) ->
    do('Get', #liminator_LimitRequest{operation_id = OperationID, limit_changes = Changes}, LimitContext).

-spec hold(operation_id(), [limit_change()], lim_context()) ->
    {ok, [limit_response()]} | {error, invalid_request_error()}.
hold(OperationID, Changes, LimitContext) ->
    do('Hold', #liminator_LimitRequest{operation_id = OperationID, limit_changes = Changes}, LimitContext).

-spec commit(operation_id(), [limit_change()], lim_context()) -> {ok, ok} | {error, invalid_request_error()}.
commit(OperationID, Changes, LimitContext) ->
    do('Commit', #liminator_LimitRequest{operation_id = OperationID, limit_changes = Changes}, LimitContext).

-spec rollback(operation_id(), [limit_change()], lim_context()) -> {ok, ok} | {error, invalid_request_error()}.
rollback(OperationID, Changes, LimitContext) ->
    do('Rollback', #liminator_LimitRequest{operation_id = OperationID, limit_changes = Changes}, LimitContext).

do(Op, Arg, LimitContext) ->
    case call(Op, {Arg}, LimitContext) of
        {ok, Result} ->
            {ok, Result};
        {exception, Exception} ->
            {error, {invalid_request, convert_exception(Exception)}}
    end.

%%

-spec call(woody:func(), woody:args(), lim_context()) -> woody:result().
call(Function, Args, LimitContext) ->
    WoodyContext = lim_context:woody_context(LimitContext),
    lim_client_woody:call(liminator, Function, Args, WoodyContext).

convert_exception(#liminator_OperationNotFound{}) ->
    [<<"OperationNotFound">>];
convert_exception(#liminator_LimitNotFound{}) ->
    [<<"LimitNotFound">>];
convert_exception(#liminator_OperationAlreadyInFinalState{}) ->
    [<<"OperationAlreadyInFinalState">>];
convert_exception(#liminator_DuplicateOperation{}) ->
    [<<"DuplicateOperation">>];
convert_exception(#liminator_DuplicateLimitName{}) ->
    [<<"DuplicateLimitName">>];
convert_exception(#liminator_LimitsValuesReadingException{}) ->
    [<<"LimitsValuesReadingException">>].
