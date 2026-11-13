-module(ff_ct_inspector_handler).

-behaviour(woody_server_thrift_handler).

-include_lib("damsel/include/dmsl_proxy_inspector_thrift.hrl").

%% woody_server_thrift_handler callbacks
-export([handle_function/4]).

%%
%% woody_server_thrift_handler callbacks
%%

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) ->
    {ok, woody:result()} | no_return().
handle_function('InspectWithdrawal', {WithdrawalContext}, _Context, Opts) ->
    #proxy_inspector_WithdrawalContext{
        party = #proxy_inspector_Party{party_ref = PartyConfigRef},
        wallet_ref = WalletConfigRef,
        withdrawal_id = ID,
        withdrawal = Withdrawal,
        options = Options
    } = WithdrawalContext,
    Handler = get_handler(Opts),
    {ok, Handler:inspect_withdrawal(ID, Withdrawal, PartyConfigRef, WalletConfigRef, Options)};
handle_function('InspectPayment', {_PaymentContext}, _Context, _Opts) ->
    erlang:error(not_implemented);
handle_function('InspectUser', {_UserContext}, _Context, _Opts) ->
    erlang:error(not_implemented);
handle_function('IsBlacklisted', {_BlackListContext}, _Context, _Opts) ->
    erlang:error(not_implemented).

%%
%% Internals
%%

get_handler(Opts) ->
    proplists:get_value(handler, Opts, ff_ct_provider).
