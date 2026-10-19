-module(hg_limiter_client).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([get_values/2]).
-export([get_batch/2]).
-export([hold_batch/2]).
-export([commit_batch/2]).
-export([rollback_batch/2]).

-type limit() :: limproto_limiter_thrift:'Limit'().
-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit_change() :: limproto_limiter_thrift:'LimitChange'().
-type context() :: limproto_limiter_thrift:'LimitContext'().
-type request() :: limproto_limiter_thrift:'LimitRequest'().

-export_type([limit/0]).
-export_type([limit_id/0]).
-export_type([limit_change/0]).
-export_type([context/0]).

-spec get_values(request(), context()) -> [limit()] | no_return().
get_values(Request, Context) ->
    handle_result(limiter:get_values(Request, Context, woody_ctx())).

-spec get_batch(request(), context()) -> [limit()] | no_return().
get_batch(Request, Context) ->
    handle_result(limiter:get_batch(Request, Context, woody_ctx())).

-spec hold_batch(request(), context()) -> [limit()] | no_return().
hold_batch(Request, Context) ->
    handle_result(limiter:hold_batch(Request, Context, woody_ctx())).

-spec commit_batch(request(), context()) -> ok | no_return().
commit_batch(Request, Context) ->
    handle_result(limiter:commit_batch(Request, Context, woody_ctx())).

-spec rollback_batch(request(), context()) -> ok | no_return().
rollback_batch(Request, Context) ->
    handle_result(limiter:rollback_batch(Request, Context, woody_ctx())).

%%

woody_ctx() ->
    op_context:get_woody_context(op_context:load(op_context:key(hellgate))).

handle_result({error, #limiter_LimitNotFound{}}) ->
    error(not_found);
handle_result({error, #base_InvalidRequest{errors = Errors}}) ->
    error({invalid_request, Errors});
handle_result({error, Exception}) ->
    %% NOTE Uniform handling of more specific exceptions:
    %% LimitChangeNotFound
    %% InvalidOperationCurrency
    %% OperationContextNotSupported
    %% PaymentToolNotSupported
    error(Exception);
handle_result(ok) ->
    ok;
handle_result({ok, Result}) ->
    Result.
