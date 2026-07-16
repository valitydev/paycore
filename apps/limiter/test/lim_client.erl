-module(lim_client).

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
    {ok, limit()} | {exception, woody_error:business_error()} | no_return().
get(LimitID, Version, Context, Client) ->
    LimitRequest = construct_request(#limiter_LimitChange{id = LimitID, version = Version}),
    case get_values(LimitRequest, Context, Client) of
        {ok, [Limit]} ->
            {ok, Limit};
        {ok, []} ->
            {ok, #limiter_Limit{id = LimitID, amount = 0}};
        {exception, _} = Exception ->
            Exception
    end.

-spec hold(limit_change(), limit_context(), client()) -> ok | {exception, woody_error:business_error()} | no_return().
hold(#limiter_LimitChange{} = LimitChange, Context, Client) ->
    LimitRequest = construct_request(LimitChange),
    case hold_batch(LimitRequest, Context, Client) of
        {ok, _} ->
            ok;
        {exception, _} = Exception ->
            Exception
    end.

-spec commit(limit_change(), limit_context(), client()) -> ok | {exception, woody_error:business_error()} | no_return().
commit(#limiter_LimitChange{} = LimitChange, Context, Client) ->
    LimitRequest = construct_request(LimitChange),
    unwrap_ok(commit_batch(LimitRequest, Context, Client)).

-spec rollback(limit_change(), limit_context(), client()) ->
    ok | {exception, woody_error:business_error()} | no_return().
rollback(#limiter_LimitChange{} = LimitChange, Context, Client) ->
    LimitRequest = construct_request(LimitChange),
    unwrap_ok(rollback_batch(LimitRequest, Context, Client)).

-spec get_values(limit_request(), limit_context(), client()) ->
    {ok, [limit()]} | {exception, woody_error:business_error()} | no_return().
get_values(LimitRequest, Context, Client) ->
    call('GetValues', {LimitRequest, Context}, Client).

-spec get_batch(limit_request(), limit_context(), client()) ->
    {ok, [limit()]} | {exception, woody_error:business_error()} | no_return().
get_batch(LimitRequest, Context, Client) ->
    call('GetBatch', {LimitRequest, Context}, Client).

-spec hold_batch(limit_request(), limit_context(), client()) ->
    {ok, [limit()]} | {exception, woody_error:business_error()} | no_return().
hold_batch(LimitRequest, Context, Client) ->
    call('HoldBatch', {LimitRequest, Context}, Client).

-spec commit_batch(limit_request(), limit_context(), client()) ->
    ok | {exception, woody_error:business_error()} | no_return().
commit_batch(LimitRequest, Context, Client) ->
    unwrap_ok(call('CommitBatch', {LimitRequest, Context}, Client)).

-spec rollback_batch(limit_request(), limit_context(), client()) ->
    ok | {exception, woody_error:business_error()} | no_return().
rollback_batch(LimitRequest, Context, Client) ->
    unwrap_ok(call('RollbackBatch', {LimitRequest, Context}, Client)).

%%% Internal functions

construct_request(#limiter_LimitChange{id = LimitID} = LimitChange) ->
    #limiter_LimitRequest{
        operation_id = <<"operation.single-change.", LimitID/binary>>,
        limit_changes = [LimitChange]
    }.

-spec call(atom(), tuple(), client()) -> woody:result() | no_return().
call(Function, Args, Client) ->
    Call = {{limproto_limiter_thrift, 'Limiter'}, Function, Args},
    Opts = #{
        url => <<"http://limiter:8022/v1/limiter">>,
        event_handler => {scoper_woody_event_handler, #{}},
        transport_opts => #{
            max_connections => 10000
        }
    },
    woody_client:call(Call, Opts, Client).

unwrap_ok({ok, ok}) -> ok;
unwrap_ok(ResultOrException) -> ResultOrException.
