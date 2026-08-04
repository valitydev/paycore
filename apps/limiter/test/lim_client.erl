-module(lim_client).

%% TODO Refactor with or into src/limiter.erl

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([new/0]).
-export([get/4]).
-export([hold/3]).
-export([commit/3]).
-export([rollback/3]).

-export([get_values/3]).
-export([get_batch/3]).
-export([hold_batch/3]).
-export([commit_batch/3]).
-export([rollback_batch/3]).

-type client() :: woody_context:ctx().

-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit() :: limproto_limiter_thrift:'Limit'().
-type limit_version() :: limproto_limiter_thrift:'Version'().
-type limit_change() :: limproto_limiter_thrift:'LimitChange'().
-type limit_request() :: limproto_limiter_thrift:'LimitRequest'().
-type limit_context() :: limproto_limiter_thrift:'LimitContext'().

%%% API

-spec new() -> client().
new() ->
    woody_context:new().

-spec get(limit_id(), limit_version(), limit_context(), client()) ->
    {ok, limit()} | {error, woody_error:business_error()} | no_return().
get(LimitID, Version, Context, Client) ->
    LimitRequest = construct_request(#limiter_LimitChange{id = LimitID, version = Version}),
    case limiter:get_values(LimitRequest, Context, Client) of
        {ok, [Limit]} ->
            {ok, Limit};
        {ok, []} ->
            {ok, #limiter_Limit{id = LimitID, amount = 0}};
        {error, _} = Exception ->
            Exception
    end.

-spec hold(limit_change(), limit_context(), client()) -> ok | {exception, woody_error:business_error()} | no_return().
hold(#limiter_LimitChange{} = LimitChange, Context, Client) ->
    LimitRequest = construct_request(LimitChange),
    case limiter:hold_batch(LimitRequest, Context, Client) of
        {ok, _} ->
            ok;
        {error, _} = Exception ->
            Exception
    end.

-spec commit(limit_change(), limit_context(), client()) -> ok | {exception, woody_error:business_error()} | no_return().
commit(#limiter_LimitChange{} = LimitChange, Context, Client) ->
    LimitRequest = construct_request(LimitChange),
    limiter:commit_batch(LimitRequest, Context, Client).

-spec rollback(limit_change(), limit_context(), client()) ->
    ok | {exception, woody_error:business_error()} | no_return().
rollback(#limiter_LimitChange{} = LimitChange, Context, Client) ->
    LimitRequest = construct_request(LimitChange),
    limiter:rollback_batch(LimitRequest, Context, Client).

-spec get_values(limit_request(), limit_context(), client()) ->
    {ok, [limit()]} | {error, woody_error:business_error()} | no_return().
get_values(LimitRequest, Context, Client) ->
    limiter:get_values(LimitRequest, Context, Client).

-spec get_batch(limit_request(), limit_context(), client()) ->
    {ok, [limit()]} | {error, woody_error:business_error()} | no_return().
get_batch(LimitRequest, Context, Client) ->
    limiter:get_batch(LimitRequest, Context, Client).

-spec hold_batch(limit_request(), limit_context(), client()) ->
    {ok, [limit()]} | {error, woody_error:business_error()} | no_return().
hold_batch(LimitRequest, Context, Client) ->
    limiter:hold_batch(LimitRequest, Context, Client).

-spec commit_batch(limit_request(), limit_context(), client()) ->
    ok | {error, woody_error:business_error()} | no_return().
commit_batch(LimitRequest, Context, Client) ->
    limiter:commit_batch(LimitRequest, Context, Client).

-spec rollback_batch(limit_request(), limit_context(), client()) ->
    ok | {error, woody_error:business_error()} | no_return().
rollback_batch(LimitRequest, Context, Client) ->
    limiter:rollback_batch(LimitRequest, Context, Client).

%%% Internal functions

construct_request(#limiter_LimitChange{id = LimitID} = LimitChange) ->
    #limiter_LimitRequest{
        operation_id = <<"operation.single-change.", LimitID/binary>>,
        limit_changes = [LimitChange]
    }.
