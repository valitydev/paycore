-module(ff_inspector).

-export([get/2]).
-export([inspect_withdrawal/2]).

-export([compare_risk_score/2]).

-export_type([risk_score/0]).
-export_type([inspector_ref/0]).
-export_type([inspector/0]).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_proxy_inspector_thrift.hrl").

-type inspector_ref() :: dmsl_domain_thrift:'InspectorRef'().
-type inspector() :: dmsl_domain_thrift:'Inspector'().
-type risk_score() :: dmsl_domain_thrift:'RiskScore'().
-type risk_magnitude() :: integer().

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%%

-spec get(inspector_ref(), ff_domain_config:revision()) ->
    {ok, inspector()}
    | {error, notfound}.
get(InspectorRef, DomainRevision) ->
    do(fun() ->
        unwrap(ff_domain_config:object(DomainRevision, {inspector, InspectorRef}))
    end).

-spec inspect_withdrawal(ff_withdrawal:withdrawal_state(), inspector()) -> risk_score().
inspect_withdrawal(
    Withdrawal,
    #domain_Inspector{
        fallback_risk_score = FallBackRiskScore,
        proxy = #domain_Proxy{ref = ProxyRef, additional = ProxyAdditional}
    }
) ->
    %% TODO Rewrite with pipeline do+unwrap
    InspectorConfig = genlib_app:env(ff_transfer, inspector, #{}),
    #domain_ProxyDefinition{url = URL, options = ProxyOpts} =
        unwrap(ff_domain_config:object({proxy, ProxyRef})),
    WithdrawalContext = #proxy_inspector_WithdrawalContext{
        party = #proxy_inspector_Party{party_ref = #domain_PartyConfigRef{id = ff_withdrawal:party_id(Withdrawal)}},
        wallet_ref = #domain_WalletConfigRef{id = ff_withdrawal:wallet_id(Withdrawal)},
        withdrawal_id = ff_withdrawal:id(Withdrawal),
        withdrawal = ff_limiter:marshal_withdrawal(Withdrawal),
        options = maps:merge(ProxyOpts, ProxyAdditional)
    },
    Default =
        case FallBackRiskScore of
            undefined -> maps:get(default_score, InspectorConfig, high);
            Score -> Score
        end,
    try
        ff_woody_client:call(
            ff_woody_client:new(#{
                url => URL,
                transport_opts => maps:get(transport_opts, InspectorConfig, #{})
            }),
            {{dmsl_proxy_inspector_thrift, 'InspectorProxy'}, 'InspectWithdrawal', {WithdrawalContext}},
            woody_context:set_deadline(
                woody_deadline:from_timeout(maps:get(timeout, InspectorConfig, 3000)),
                op_context:get_woody_context(op_context:load(op_context:key(fistful)))
            )
        )
    of
        {ok, RiskScore} ->
            RiskScore;
        {exception, Error} ->
            _ = logger:error("Fail to get RiskScore with error ~p", [Error]),
            Default
    catch
        error:{woody_error, {_Source, Class, _Details}} = Reason when
            Class =:= resource_unavailable orelse
                Class =:= result_unknown
        ->
            _ = logger:warning("Fail to get RiskScore with error ~p:~p", [error, Reason]),
            Default;
        error:{woody_error, {_Source, result_unexpected, _Details}} = Reason ->
            _ = logger:error("Fail to get RiskScore with error ~p:~p", [error, Reason]),
            Default
    end.

%%

-spec compare_risk_score(risk_score(), risk_score()) -> risk_magnitude().
compare_risk_score(RS1, RS2) ->
    get_risk_magnitude(RS1) - get_risk_magnitude(RS2).

get_risk_magnitude(RiskScore) ->
    {enum, Info} = dmsl_domain_thrift:enum_info('RiskScore'),
    {RiskScore, Magnitude} = lists:keyfind(RiskScore, 1, Info),
    Magnitude.
