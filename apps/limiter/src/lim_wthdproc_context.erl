-module(lim_wthdproc_context).

-include_lib("limiter_proto/include/limproto_context_withdrawal_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-behaviour(lim_context).
-export([get_operation/1]).
-export([make_change_context/1]).
-export([get_value/2]).

-type context() :: limproto_context_withdrawal_thrift:'Context'().

-type operation() ::
    withdrawal.

-export_type([operation/0]).
-export_type([context/0]).

%%

-spec get_operation(context()) -> {ok, operation()} | {error, notfound}.
get_operation(#context_withdrawal_Context{op = {Operation, _}}) ->
    {ok, Operation};
get_operation(#context_withdrawal_Context{op = undefined}) ->
    {error, notfound}.

-spec make_change_context(context()) -> {ok, lim_context:change_context()}.
make_change_context(#context_withdrawal_Context{op = undefined}) ->
    {ok, #{}};
make_change_context(
    #context_withdrawal_Context{
        op = {Operation, _}
    } = Context
) ->
    {ok,
        genlib_map:compact(#{
            <<"Context.op">> => genlib:to_binary(Operation),
            <<"Context.owner_id">> => try_get_value(owner_id, Context, undefined),
            <<"Context.wallet_id">> => try_get_value(wallet_id, Context, undefined)
        })}.

-spec get_value(atom(), context()) -> {ok, term()} | {error, notfound | {unsupported, _}}.
get_value(ValueName, Context) ->
    case get_operation(Context) of
        {ok, Operation} ->
            get_value(ValueName, Operation, Context);
        {error, _} = Error ->
            Error
    end.

try_get_value(ValueName, Context, Default) ->
    case get_operation(Context) of
        {ok, Operation} ->
            case get_value(ValueName, Operation, Context) of
                {ok, Value} ->
                    Value;
                {error, _} ->
                    Default
            end;
        {error, _} ->
            Default
    end.

get_value(owner_id, _Operation, Context) ->
    get_owner_id(Context);
get_value(created_at, Operation, Context) ->
    get_created_at(Operation, Context);
get_value(cost, Operation, Context) ->
    get_cost(Operation, Context);
get_value(payment_tool, Operation, Context) ->
    get_payment_tool(Operation, Context);
get_value(wallet_id, Operation, Context) ->
    get_wallet_id(Operation, Context);
get_value(provider_id, Operation, Context) ->
    get_provider_id(Operation, Context);
get_value(terminal_id, Operation, Context) ->
    get_terminal_id(Operation, Context);
get_value(sender, Operation, Context) ->
    get_destination_sender(Operation, Context);
get_value(receiver, Operation, Context) ->
    get_destination_receiver(Operation, Context);
get_value(ValueName, _Operation, _Context) ->
    {error, {unsupported, ValueName}}.

-define(WITHDRAWAL(V), #context_withdrawal_Context{
    withdrawal = #context_withdrawal_Withdrawal{
        withdrawal = V = #wthd_domain_Withdrawal{}
    }
}).

-define(WALLET_ID(V), #context_withdrawal_Context{
    withdrawal = #context_withdrawal_Withdrawal{
        wallet_id = V
    }
}).

-define(ROUTE(V), #context_withdrawal_Context{
    withdrawal = #context_withdrawal_Withdrawal{
        route = V = #base_Route{}
    }
}).

-define(AUTH_DATA(V), #context_withdrawal_Context{
    withdrawal = #context_withdrawal_Withdrawal{
        withdrawal = #wthd_domain_Withdrawal{auth_data = V}
    }
}).

-define(SENDER_RECEIVER(V), ?AUTH_DATA({sender_receiver, V})).

get_owner_id(?WITHDRAWAL(Wthd)) ->
    {ok, Wthd#wthd_domain_Withdrawal.sender#domain_PartyConfigRef.id};
get_owner_id(_CtxWithdrawal) ->
    {error, notfound}.

get_created_at(withdrawal, ?WITHDRAWAL(Wthd)) ->
    {ok, Wthd#wthd_domain_Withdrawal.created_at};
get_created_at(_, _CtxWithdrawal) ->
    {error, notfound}.

get_cost(withdrawal, ?WITHDRAWAL(Wthd)) ->
    Body = Wthd#wthd_domain_Withdrawal.body,
    lim_payproc_utils:cash(Body);
get_cost(_, _CtxWithdrawal) ->
    {error, notfound}.

get_payment_tool(withdrawal, ?WITHDRAWAL(Wthd)) ->
    Destination = Wthd#wthd_domain_Withdrawal.destination,
    lim_payproc_utils:payment_tool(Destination);
get_payment_tool(_, _CtxWithdrawal) ->
    {error, notfound}.

get_wallet_id(withdrawal, ?WALLET_ID(WalletID)) ->
    {ok, WalletID};
get_wallet_id(_, _CtxWithdrawal) ->
    {error, notfound}.

get_provider_id(withdrawal, ?ROUTE(Route)) ->
    lim_context_utils:route_provider_id(Route);
get_provider_id(_, _CtxWithdrawal) ->
    {error, notfound}.

get_terminal_id(withdrawal, ?ROUTE(Route)) ->
    lim_context_utils:route_terminal_id(Route);
get_terminal_id(_, _CtxWithdrawal) ->
    {error, notfound}.

get_destination_sender(withdrawal, ?SENDER_RECEIVER(#wthd_domain_SenderReceiverAuthData{sender = Token})) ->
    {ok, lim_context_utils:base61_hash(Token)};
get_destination_sender(_, _CtxWithdrawal) ->
    {error, notfound}.

get_destination_receiver(withdrawal, ?SENDER_RECEIVER(#wthd_domain_SenderReceiverAuthData{receiver = Token})) ->
    {ok, lim_context_utils:base61_hash(Token)};
get_destination_receiver(_, _CtxWithdrawal) ->
    {error, notfound}.
