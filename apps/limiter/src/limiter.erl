-module(limiter).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("liminator_proto/include/liminator_liminator_thrift.hrl").

%% Woody handler

-export([get_values/3]).
-export([get_batch/3]).
-export([hold_batch/3]).
-export([commit_batch/3]).
-export([rollback_batch/3]).

-define(LIMIT_REQUEST(ID, Changes), #limiter_LimitRequest{operation_id = ID, limit_changes = Changes}).

%% TODO Retire limproto use in API

-type exception() ::
    limproto_limiter_thrift:'LimitNotFound'()
    | limproto_limiter_thrift:'LimitChangeNotFound'()
    | limproto_limiter_thrift:'ForbiddenOperationAmount'()
    | limproto_limiter_thrift:'InvalidOperationCurrency'()
    | limproto_limiter_thrift:'OperationContextNotSupported'()
    | limproto_limiter_thrift:'PaymentToolNotSupported'()
    | dmsl_base_thrift:'InvalidRequest'().

%% API

-spec get_values(
    limproto_limiter_thrift:'LimitRequest'(),
    limproto_limiter_thrift:'LimitContext'(),
    woody_context:ctx()
) ->
    {ok, [limproto_limiter_thrift:'Limit'()]} | {error, exception()} | no_return().
get_values(?LIMIT_REQUEST(_OperationID, Changes), Context, WoodyCtx) ->
    LimitContext = lim_context:create(WoodyCtx),
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
    end.

-spec get_batch(
    limproto_limiter_thrift:'LimitRequest'(),
    limproto_limiter_thrift:'LimitContext'(),
    woody_context:ctx()
) ->
    {ok, [limproto_limiter_thrift:'Limit'()]} | {error, exception()} | no_return().
get_batch(?LIMIT_REQUEST(OperationID, Changes), Context, WoodyCtx) ->
    LimitContext = lim_context:create(WoodyCtx),
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
    end.

-spec hold_batch(
    limproto_limiter_thrift:'LimitRequest'(),
    limproto_limiter_thrift:'LimitContext'(),
    woody_context:ctx()
) ->
    {ok, [limproto_limiter_thrift:'Limit'()]} | {error, exception()} | no_return().
hold_batch(?LIMIT_REQUEST(OperationID, Changes), Context, WoodyCtx) ->
    LimitContext = lim_context:create(WoodyCtx),
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
    end.

-spec commit_batch(
    limproto_limiter_thrift:'LimitRequest'(),
    limproto_limiter_thrift:'LimitContext'(),
    woody_context:ctx()
) ->
    ok | {error, exception()} | no_return().
commit_batch(?LIMIT_REQUEST(OperationID, Changes), Context, WoodyCtx) ->
    LimitContext = lim_context:create(WoodyCtx),
    case
        lim_config_machine:commit_batch(
            OperationID,
            Changes,
            lim_context:set_context(Context, LimitContext)
        )
    of
        ok ->
            ok;
        {error, Error} ->
            handle_commit_error(Error)
    end.

-spec rollback_batch(
    limproto_limiter_thrift:'LimitRequest'(),
    limproto_limiter_thrift:'LimitContext'(),
    woody_context:ctx()
) ->
    ok | {error, exception()} | no_return().
rollback_batch(?LIMIT_REQUEST(OperationID, Changes), Context, WoodyCtx) ->
    LimitContext = lim_context:create(WoodyCtx),
    case
        lim_config_machine:rollback_batch(
            OperationID,
            Changes,
            lim_context:set_context(Context, LimitContext)
        )
    of
        ok ->
            ok;
        {error, Error} ->
            handle_rollback_error(Error)
    end.

%% Internal

convert_responses([]) ->
    [];
convert_responses([Response | Other]) ->
    [convert_response(Response) | convert_responses(Other)].

convert_response(#liminator_LimitResponse{limit_id = LimitID, total_value = Value}) ->
    #limiter_Limit{id = LimitID, amount = Value}.

-spec handle_get_error(_) -> {error, exception()} | no_return().
handle_get_error(Error) ->
    handle_default_error(Error).

-spec handle_hold_error(_) -> {error, exception()} | no_return().
handle_hold_error({_, {invalid_request, Errors}}) ->
    {error, #base_InvalidRequest{errors = Errors}};
handle_hold_error(Error) ->
    handle_business_error(Error).

-spec handle_business_error(_) -> {error, exception()} | no_return().
handle_business_error({_, {invalid_operation_currency, {Currency, ExpectedCurrency}}}) ->
    {error, #limiter_InvalidOperationCurrency{
        currency = Currency,
        expected_currency = ExpectedCurrency
    }};
handle_business_error({_, {operation_context_not_supported, ContextType}}) ->
    {error, #limiter_OperationContextNotSupported{
        context_type = ContextType
    }};
handle_business_error({_, {unsupported, {payment_tool, Type}}}) ->
    {error, #limiter_PaymentToolNotSupported{
        payment_tool = atom_to_binary(Type)
    }};
handle_business_error(Error) ->
    handle_default_error(Error).

-spec handle_commit_error(_) -> {error, exception()} | no_return().
handle_commit_error({_, {forbidden_operation_amount, Error}}) ->
    handle_forbidden_operation_amount_error(Error);
handle_commit_error({_, {invalid_request, Errors}}) ->
    {error, #base_InvalidRequest{errors = Errors}};
handle_commit_error(Error) ->
    handle_default_error(Error).

-spec handle_rollback_error(_) -> {error, exception()} | no_return().
handle_rollback_error({_, {invalid_request, Errors}}) ->
    {error, #base_InvalidRequest{errors = Errors}};
handle_rollback_error(Error) ->
    handle_business_error(Error).

-spec handle_default_error(_) -> {error, exception()} | no_return().
handle_default_error({config, notfound}) ->
    {error, #limiter_LimitNotFound{}};
handle_default_error(Error) ->
    handle_unknown_error(Error).

-spec handle_unknown_error(_) -> no_return().
handle_unknown_error(Error) ->
    erlang:error({unknown_error, Error}).

-spec handle_forbidden_operation_amount_error(_) -> {error, exception()} | no_return().
handle_forbidden_operation_amount_error(#{
    type := Type,
    partial := Partial,
    full := Full
}) ->
    case Type of
        positive ->
            {error, #limiter_ForbiddenOperationAmount{
                amount = Partial,
                allowed_range = #base_AmountRange{
                    upper = {inclusive, Full},
                    lower = {inclusive, 0}
                }
            }};
        negative ->
            {error, #limiter_ForbiddenOperationAmount{
                amount = Partial,
                allowed_range = #base_AmountRange{
                    upper = {inclusive, 0},
                    lower = {inclusive, Full}
                }
            }}
    end.
