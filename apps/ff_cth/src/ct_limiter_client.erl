-module(ct_limiter_client).

%% TODO Clean up and update with librarized limiter

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([get/4]).

-type client() :: woody_context:ctx().

-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit_version() :: limproto_limiter_thrift:'Version'().
-type limit_context() :: limproto_limiter_thrift:'LimitContext'().

%%% API

-define(PLACEHOLDER_OPERATION_GET_LIMIT_VALUES, <<"get values">>).

-spec get(limit_id(), limit_version(), limit_context(), client()) -> woody:result() | no_return().
get(LimitID, Version, Context, Client) ->
    LimitRequest = #limiter_LimitRequest{
        operation_id = ?PLACEHOLDER_OPERATION_GET_LIMIT_VALUES,
        limit_changes = [#limiter_LimitChange{id = LimitID, version = Version}]
    },
    case limiter:get_values(LimitRequest, Context, Client) of
        {ok, [L]} ->
            {ok, L};
        {ok, []} ->
            {error, #limiter_LimitNotFound{}};
        {error, _} = Exception ->
            Exception
    end.
