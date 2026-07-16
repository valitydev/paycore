-module(lim_body).

-export([get/3]).

-type amount() :: integer().
-type cash() :: #{
    amount := amount(),
    currency := currency()
}.

-type currency() :: dmsl_domain_thrift:'CurrencySymbolicCode'().
-type config() :: lim_config_machine:config().
-type body_type() :: full | partial.

-export_type([amount/0]).
-export_type([currency/0]).
-export_type([cash/0]).

-import(lim_pipeline, [do/1, unwrap/1]).

-spec get(body_type(), config(), lim_context:t()) ->
    {ok, cash()} | {error, notfound}.
get(BodyType, Config, LimitContext) ->
    do(fun() ->
        ContextType = lim_config_machine:context_type(Config),
        Operation = unwrap(lim_context:get_operation(ContextType, LimitContext)),
        Body = unwrap(get_body_for_operation(BodyType, ContextType, LimitContext)),
        apply_op_behaviour(Operation, Body, Config)
    end).

-spec get_body_for_operation(body_type(), lim_context:context_type(), lim_context:t()) ->
    {ok, cash()} | {error, notfound}.
get_body_for_operation(full, ContextType, LimitContext) ->
    lim_context:get_value(ContextType, cost, LimitContext);
get_body_for_operation(partial, ContextType, LimitContext) ->
    lim_context:get_value(ContextType, capture_cost, LimitContext).

apply_op_behaviour(Operation, Body, #{op_behaviour := ComputationConfig}) ->
    case maps:get(Operation, ComputationConfig, undefined) of
        addition ->
            Body;
        subtraction ->
            invert_body(Body);
        undefined ->
            Body
    end;
apply_op_behaviour(_Operation, Body, _Config) ->
    Body.

invert_body(#{amount := Amount} = Cash) ->
    Cash#{amount := -Amount}.
