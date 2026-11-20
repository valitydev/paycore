-module(ff_ct_inspector_handler).

-behaviour(woody_server_thrift_handler).

-include_lib("damsel/include/dmsl_proxy_inspector_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").

%% woody_server_thrift_handler callbacks
-export([handle_function/4]).

%% Processing callbacks
-export([inspect_withdrawal/5]).

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

-spec inspect_withdrawal(
    dmsl_proxy_inspector_thrift:'ID'(),
    dmsl_wthd_domain_thrift:'Withdrawal'(),
    dmsl_domain_thrift:'PartyConfigRef'(),
    dmsl_domain_thrift:'WalletConfigRef'(),
    dmsl_domain_thrift:'ProxyOptions'() | undefined
) -> dmsl_domain_thrift:'RiskScore'() | no_return().
inspect_withdrawal(_, Withdrawal, _, _, _) when
    Withdrawal#wthd_domain_Withdrawal.contact_info#wthd_domain_ContactInfo.email =:= <<"shang.tsung@out.world">>
->
    'fatal';
inspect_withdrawal(_, _, _, _, Options) ->
    binary_to_existing_atom(maps:get(<<"risk_score">>, Options, <<"high">>)).

%%
%% Internals
%%

get_handler(Opts) ->
    proplists:get_value(handler, Opts, ?MODULE).
