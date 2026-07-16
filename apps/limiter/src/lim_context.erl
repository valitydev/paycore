-module(lim_context).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([create/1]).
-export([woody_context/1]).
-export([get_operation/2]).
-export([make_change_context/2]).
-export([get_value/3]).

-export([set_context/2]).

-type woody_context() :: woody_context:ctx().
-type limit_context() :: limproto_limiter_thrift:'LimitContext'().

-type t() :: #{
    woody_context => woody_context(),
    context => limit_context()
}.

-type context_type() :: payment_processing | withdrawal_processing.
-type change_context() :: #{binary() => binary()}.
-type context_inner() :: lim_payproc_context:context() | lim_wthdproc_context:context().
-type context_operation() :: lim_payproc_context:operation() | lim_wthdproc_context:operation().

-type unsupported_error(T) :: {unsupported, T}.
-type operation_context_not_supported_error() ::
    {operation_context_not_supported, limproto_limiter_thrift:'LimitContextType'()}.
-type context_error() :: notfound | unsupported_error(_) | operation_context_not_supported_error().

-export_type([t/0]).
-export_type([context_type/0]).
-export_type([change_context/0]).
-export_type([context_operation/0]).
-export_type([unsupported_error/1]).
-export_type([operation_context_not_supported_error/0]).
-export_type([context_error/0]).

-callback get_operation(context_inner()) -> {ok, context_operation()} | {error, notfound}.
-callback make_change_context(context_inner()) -> {ok, change_context()}.
-callback get_value(_Name :: atom(), context_inner()) -> {ok, term()} | {error, notfound | unsupported_error(_)}.

-spec create(woody_context()) -> t().
create(WoodyContext) ->
    #{woody_context => WoodyContext}.

-spec woody_context(t()) -> woody_context().
woody_context(Context) ->
    maps:get(woody_context, Context).

-spec set_context(limit_context(), t()) -> t().
set_context(Context, LimContext) ->
    LimContext#{context => Context}.

-spec get_operation(context_type(), t()) ->
    {ok, context_operation()} | {error, notfound | operation_context_not_supported_error()}.
get_operation(Type, Context) ->
    case get_operation_context(Type, Context) of
        {error, _} = Error -> Error;
        {ok, Mod, OperationContext} -> Mod:get_operation(OperationContext)
    end.

-spec make_change_context(context_type(), t()) ->
    {ok, change_context()} | {error, operation_context_not_supported_error()}.
make_change_context(Type, Context) ->
    case get_operation_context(Type, Context) of
        {error, _} = Error -> Error;
        {ok, Mod, OperationContext} -> Mod:make_change_context(OperationContext)
    end.

-spec get_value(context_type(), atom(), t()) -> {ok, term()} | {error, context_error()}.
get_value(Type, ValueName, Context) ->
    case get_operation_context(Type, Context) of
        {error, _} = Error -> Error;
        {ok, Mod, OperationContext} -> Mod:get_value(ValueName, OperationContext)
    end.

get_operation_context(payment_processing, #{context := #limiter_LimitContext{payment_processing = undefined}}) ->
    {error,
        {operation_context_not_supported, {withdrawal_processing, #limiter_LimitContextTypeWithdrawalProcessing{}}}};
get_operation_context(
    payment_processing,
    #{context := #limiter_LimitContext{payment_processing = PayprocContext}}
) ->
    {ok, lim_payproc_context, PayprocContext};
get_operation_context(withdrawal_processing, #{context := #limiter_LimitContext{withdrawal_processing = undefined}}) ->
    {error, {operation_context_not_supported, {payment_processing, #limiter_LimitContextTypePaymentProcessing{}}}};
get_operation_context(
    withdrawal_processing,
    #{context := #limiter_LimitContext{withdrawal_processing = WithdrawalContext}}
) ->
    {ok, lim_wthdproc_context, WithdrawalContext}.
