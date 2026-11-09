-module(lim_turnover_processor).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-behaviour(lim_config_machine).

-export([make_change/4]).

-type lim_context() :: lim_context:t().
-type lim_change() :: lim_config_machine:lim_change().
-type config() :: lim_config_machine:config().
-type amount() :: integer().

-type forbidden_operation_amount_error() :: #{
    type := positive | negative,
    partial := amount(),
    full := amount()
}.

-type get_limit_error() :: {range, notfound}.
-type make_change_error() ::
    lim_rates:conversion_error()
    | lim_context:operation_context_not_supported_error()
    | lim_turnover_metric:invalid_operation_currency_error().

-type hold_error() ::
    lim_rates:conversion_error()
    | lim_turnover_metric:invalid_operation_currency_error()
    | lim_context:operation_context_not_supported_error()
    | lim_context:unsupported_error({payment_tool, atom()}).

-type commit_error() ::
    {forbidden_operation_amount, forbidden_operation_amount_error()}
    | lim_rates:conversion_error().

-type rollback_error() ::
    lim_rates:conversion_error().

-export_type([make_change_error/0]).
-export_type([get_limit_error/0]).
-export_type([hold_error/0]).
-export_type([commit_error/0]).
-export_type([rollback_error/0]).

-import(lim_pipeline, [do/1, unwrap/1]).

-spec make_change(lim_turnover_metric:stage(), lim_change(), config(), lim_context()) ->
    {ok, lim_liminator:limit_change()} | {error, make_change_error()}.
make_change(Stage, #limiter_LimitChange{id = LimitID, version = Version}, Config, LimitContext) ->
    do(fun() ->
        {LimitRangeID, ScopeChangeContext} = unwrap(compute_limit_range_id(LimitID, Version, Config, LimitContext)),
        ChangeContext = unwrap(lim_context:make_change_context(lim_config_machine:context_type(Config), LimitContext)),
        Metric = unwrap(compute_metric(Stage, Config, LimitContext)),
        lim_liminator:construct_change(LimitID, LimitRangeID, Metric, maps:merge(ChangeContext, ScopeChangeContext))
    end).

compute_limit_range_id(LimitID, Version, Config, LimitContext) ->
    do(fun() ->
        Timestamp = unwrap(get_timestamp(Config, LimitContext)),
        unwrap(construct_range_id(Timestamp, LimitID, Version, Config, LimitContext))
    end).

get_timestamp(Config, LimitContext) ->
    ContextType = lim_config_machine:context_type(Config),
    lim_context:get_value(ContextType, created_at, LimitContext).

construct_range_id(Timestamp, LimitID, Version, Config, LimitContext) ->
    BinaryVersion = genlib:to_binary(Version),
    case lim_config_machine:mk_scope_prefix(Config, LimitContext) of
        {ok, {Prefix, ChangeContext}} ->
            ShardID = lim_config_machine:calculate_shard_id(Timestamp, Config),
            {ok, {<<LimitID/binary, "/", BinaryVersion/binary, Prefix/binary, "/", ShardID/binary>>, ChangeContext}};
        {error, _} = Error ->
            Error
    end.

compute_metric(Stage, Config, LimitContext) ->
    {turnover, Metric} = lim_config_machine:type(Config),
    lim_turnover_metric:compute(Metric, Stage, Config, LimitContext).
