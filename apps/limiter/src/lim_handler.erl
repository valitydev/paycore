-module(lim_handler).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("liminator_proto/include/liminator_liminator_thrift.hrl").

%% Woody handler

-behaviour(woody_server_thrift_handler).

-export([handle_function/4]).

%%

-type lim_context() :: lim_context:t().

-define(LIMIT_REQUEST(ID, Changes), #limiter_LimitRequest{operation_id = ID, limit_changes = Changes}).

%%

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) -> {ok, woody:result()}.
handle_function(Fn, Args, WoodyCtx, Opts) ->
    LimitContext = lim_context:create(WoodyCtx),
    scoper:scope(
        limiter,
        fun() -> handle_function_(Fn, Args, LimitContext, Opts) end
    ).

-spec handle_function_(woody:func(), woody:args(), lim_context(), woody:options()) -> {ok, woody:result()}.
handle_function_('GetValues', {?LIMIT_REQUEST(OperationID, Changes), Context}, LimitContext, _Opts) ->
    scoper:add_meta(#{operation_id => OperationID}),
    case
        lim_config_machine:get_values(
            Changes,
            lim_context:set_context(Context, LimitContext)
        )
    of
        {ok, Responses} ->
            {ok, convert_responses(Responses)};
        {error, Error} ->
            handle_get_error(Error)
    end;
handle_function_('GetBatch', {?LIMIT_REQUEST(OperationID, Changes), Context}, LimitContext, _Opts) ->
    scoper:add_meta(#{operation_id => OperationID}),
    case
        lim_config_machine:get_batch(
            OperationID,
            Changes,
            lim_context:set_context(Context, LimitContext)
        )
    of
        {ok, Responses} ->
            {ok, convert_responses(Responses)};
        {error, Error} ->
            handle_get_error(Error)
    end;
handle_function_('HoldBatch', {?LIMIT_REQUEST(OperationID, Changes), Context}, LimitContext, _Opts) ->
    scoper:add_meta(#{operation_id => OperationID}),
    case
        lim_config_machine:hold_batch(
            OperationID,
            Changes,
            lim_context:set_context(Context, LimitContext)
        )
    of
        {ok, Responses} ->
            {ok, convert_responses(Responses)};
        {error, Error} ->
            handle_hold_error(Error)
    end;
handle_function_('CommitBatch', {?LIMIT_REQUEST(OperationID, Changes), Context}, LimitContext, _Opts) ->
    scoper:add_meta(#{operation_id => OperationID}),
    case
        lim_config_machine:commit_batch(
            OperationID,
            Changes,
            lim_context:set_context(Context, LimitContext)
        )
    of
        ok ->
            {ok, ok};
        {error, Error} ->
            handle_commit_error(Error)
    end;
handle_function_('RollbackBatch', {?LIMIT_REQUEST(OperationID, Changes), Context}, LimitContext, _Opts) ->
    scoper:add_meta(#{operation_id => OperationID}),
    case
        lim_config_machine:rollback_batch(
            OperationID,
            Changes,
            lim_context:set_context(Context, LimitContext)
        )
    of
        ok ->
            {ok, ok};
        {error, Error} ->
            handle_rollback_error(Error)
    end.

convert_responses([]) ->
    [];
convert_responses([Response | Other]) ->
    [convert_response(Response) | convert_responses(Other)].

convert_response(#liminator_LimitResponse{
    limit_id = LimitID,
    total_value = Value
}) ->
    #limiter_Limit{
        id = LimitID,
        amount = Value
    }.

-spec handle_get_error(_) -> no_return().
handle_get_error(Error) ->
    handle_default_error(Error).

-spec handle_hold_error(_) -> no_return().
handle_hold_error({_, {invalid_request, Errors}}) ->
    woody_error:raise(business, #base_InvalidRequest{errors = Errors});
handle_hold_error(Error) ->
    handle_business_error(Error).

-spec handle_business_error(_) -> no_return().
handle_business_error({_, {invalid_operation_currency, {Currency, ExpectedCurrency}}}) ->
    woody_error:raise(business, #limiter_InvalidOperationCurrency{
        currency = Currency,
        expected_currency = ExpectedCurrency
    });
handle_business_error({_, {operation_context_not_supported, ContextType}}) ->
    woody_error:raise(business, #limiter_OperationContextNotSupported{
        context_type = ContextType
    });
handle_business_error({_, {unsupported, {payment_tool, Type}}}) ->
    woody_error:raise(business, #limiter_PaymentToolNotSupported{
        payment_tool = atom_to_binary(Type)
    });
handle_business_error(Error) ->
    handle_default_error(Error).

-spec handle_commit_error(_) -> no_return().
handle_commit_error({_, {forbidden_operation_amount, Error}}) ->
    handle_forbidden_operation_amount_error(Error);
handle_commit_error({_, {invalid_request, Errors}}) ->
    woody_error:raise(business, #base_InvalidRequest{errors = Errors});
handle_commit_error(Error) ->
    handle_default_error(Error).

-spec handle_rollback_error(_) -> no_return().
handle_rollback_error({_, {invalid_request, Errors}}) ->
    woody_error:raise(business, #base_InvalidRequest{errors = Errors});
handle_rollback_error(Error) ->
    handle_business_error(Error).

-spec handle_default_error(_) -> no_return().
handle_default_error({config, notfound}) ->
    woody_error:raise(business, #limiter_LimitNotFound{});
handle_default_error(Error) ->
    handle_unknown_error(Error).

-spec handle_unknown_error(_) -> no_return().
handle_unknown_error(Error) ->
    erlang:error({unknown_error, Error}).

-spec handle_forbidden_operation_amount_error(_) -> no_return().
handle_forbidden_operation_amount_error(#{
    type := Type,
    partial := Partial,
    full := Full
}) ->
    case Type of
        positive ->
            woody_error:raise(business, #limiter_ForbiddenOperationAmount{
                amount = Partial,
                allowed_range = #base_AmountRange{
                    upper = {inclusive, Full},
                    lower = {inclusive, 0}
                }
            });
        negative ->
            woody_error:raise(business, #limiter_ForbiddenOperationAmount{
                amount = Partial,
                allowed_range = #base_AmountRange{
                    upper = {inclusive, 0},
                    lower = {inclusive, Full}
                }
            })
    end.
