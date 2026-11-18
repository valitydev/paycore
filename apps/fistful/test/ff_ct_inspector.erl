-module(ff_ct_inspector).

%% -include_lib("damsel/include/dmsl_domain_thrift.hrl").
%% -include_lib("damsel/include/dmsl_proxy_inspector_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").

%% Processing callbacks
-export([inspect_withdrawal/5]).

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
