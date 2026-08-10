%%% Domain selectors manipulation
%%%
%%% TODO
%%%  - Manipulating predicates w/o respect to their struct infos is dangerous
%%%  - Decide on semantics
%%%     - First satisfiable predicate wins?
%%%       If not, it would be harder to join / overlay selectors
%%%  - Domain revision is out of place. An `Opts`, anyone?

-module(pm_selector).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%%

-type t() ::
    dmsl_domain_thrift:'CurrencySelector'()
    | dmsl_domain_thrift:'CategorySelector'()
    | dmsl_domain_thrift:'CashLimitSelector'()
    | dmsl_domain_thrift:'CashFlowSelector'()
    | dmsl_domain_thrift:'PaymentMethodSelector'()
    | dmsl_domain_thrift:'SystemAccountSetSelector'()
    | dmsl_domain_thrift:'ExternalAccountSetSelector'()
    | dmsl_domain_thrift:'HoldLifetimeSelector'()
    | dmsl_domain_thrift:'CashValueSelector'()
    | dmsl_domain_thrift:'TurnoverLimitSelector'()
    | dmsl_domain_thrift:'TimeSpanSelector'()
    | dmsl_domain_thrift:'FeeSelector'()
    | dmsl_domain_thrift:'InspectorSelector'().

-type value() ::
    %% FIXME
    _.

-type varset() :: #{
    category => dmsl_domain_thrift:'CategoryRef'(),
    currency => dmsl_domain_thrift:'CurrencyRef'(),
    cost => dmsl_domain_thrift:'Cash'(),
    payment_tool => dmsl_domain_thrift:'PaymentTool'(),
    party_ref => dmsl_domain_thrift:'PartyConfigRef'(),
    shop_id => dmsl_domain_thrift:'ShopID'(),
    risk_score => dmsl_domain_thrift:'RiskScore'(),
    flow => instant | {hold, dmsl_domain_thrift:'HoldLifetime'()},
    wallet_id => dmsl_domain_thrift:'WalletID'()
}.

-type predicate() :: dmsl_domain_thrift:'Predicate'().

-export_type([varset/0]).

-export([reduce/3]).
-export([reduce_to_value/3]).
-export([reduce_predicate/3]).

-define(const(Bool), {constant, Bool}).

%%

-spec reduce_to_value(t(), varset(), pm_domain:revision()) -> value() | no_return().
reduce_to_value(Selector, VS, Revision) ->
    case reduce(Selector, VS, Revision) of
        {value, Value} ->
            Value;
        _ ->
            error({misconfiguration, {'Can\'t reduce selector to value', Selector, VS, Revision}})
    end.

-spec reduce(t(), varset(), pm_domain:revision()) -> t().
reduce({value, _} = V, _, _) ->
    V;
reduce({decisions, Decisions}, VS, Rev) ->
    case reduce_decisions(Decisions, VS, Rev) of
        %% Return value only if topmost decision's predicate resolved to true:
        %% otherwise,
        %% the decision was either dropped (predicate reduced to false)
        %% or there's not enough info to reduce a predicate (the result is undefined)
        [{_Type, ?const(true), Selector} | _] ->
            Selector;
        Ps1 ->
            {decisions, Ps1}
    end.

%% domain structs in form #domain_SomeDecision { Predicate if_; SomeSelector then_ };
reduce_decisions([{Type, Predicate, Selector} | Rest], VS, Rev) ->
    case reduce_predicate(Predicate, VS, Rev) of
        ?const(false) ->
            reduce_decisions(Rest, VS, Rev);
        NewPredicate ->
            case reduce(Selector, VS, Rev) of
                {decisions, []} ->
                    reduce_decisions(Rest, VS, Rev);
                NewSelector ->
                    [{Type, NewPredicate, NewSelector} | reduce_decisions(Rest, VS, Rev)]
            end
    end;
reduce_decisions([], _, _) ->
    [].

-spec reduce_predicate(predicate(), varset(), pm_domain:revision()) ->
    predicate().
reduce_predicate(?const(B), _, _) ->
    ?const(B);
reduce_predicate({condition, C0}, VS, Rev) ->
    case reduce_condition(C0, VS, Rev) of
        ?const(B) ->
            ?const(B);
        C1 ->
            {condition, C1}
    end;
reduce_predicate({is_not, P0}, VS, Rev) ->
    case reduce_predicate(P0, VS, Rev) of
        ?const(B) ->
            ?const(not B);
        P1 ->
            {is_not, P1}
    end;
reduce_predicate({all_of, Ps}, VS, Rev) ->
    reduce_combination(all_of, false, Ps, VS, Rev, []);
reduce_predicate({any_of, Ps}, VS, Rev) ->
    reduce_combination(any_of, true, Ps, VS, Rev, []);
reduce_predicate({criterion, CriterionRef = #domain_CriterionRef{}}, VS, Rev) ->
    Criterion = pm_domain:get(Rev, {criterion, CriterionRef}),
    Predicate = Criterion#domain_Criterion.predicate,
    case reduce_predicate(Predicate, VS, Rev) of
        ?const(B) ->
            ?const(B);
        Predicate ->
            {criterion, CriterionRef};
        NewPredicate ->
            NewPredicate
    end.

reduce_combination(Type, Fix, [P | Ps], VS, Rev, PAcc) ->
    case reduce_predicate(P, VS, Rev) of
        ?const(Fix) ->
            ?const(Fix);
        ?const(_) ->
            reduce_combination(Type, Fix, Ps, VS, Rev, PAcc);
        P1 ->
            reduce_combination(Type, Fix, Ps, VS, Rev, [P1 | PAcc])
    end;
reduce_combination(_, Fix, [], _, _, []) ->
    ?const(not Fix);
reduce_combination(_, _, [], _, _, [P]) ->
    P;
reduce_combination(Type, _, [], _, _, PAcc) ->
    {Type, ordsets:from_list(lists:reverse(PAcc))}.

reduce_condition(C, VS, Rev) ->
    case pm_condition:test(C, VS, Rev) of
        B when is_boolean(B) ->
            ?const(B);
        undefined ->
            % Irreducible, return as is for further possible reduce
            C
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-spec test() -> _.

-spec bin_data_allow_test() -> _.
bin_data_allow_test() ->
    VS = pm_varset:decode_varset(#payproc_Varset{
        bin_data = #domain_BinData{
            payment_system = <<"payment_system">>,
            bank_name = <<"bank_name">>
        }
    }),
    CondFun = fun(PS, BN) ->
        {any_of, [
            {condition,
                {bin_data, #domain_BinDataCondition{
                    payment_system = PS,
                    bank_name = BN
                }}}
        ]}
    end,

    ?assertEqual(?const(true), reduce_predicate(CondFun({matches, <<"pay">>}, {matches, <<"ban">>}), VS, 1)),
    ?assertEqual(?const(true), reduce_predicate(CondFun({matches, <<"_system">>}, {matches, <<"_name">>}), VS, 1)),
    ?assertEqual(?const(false), reduce_predicate(CondFun({equals, <<"system">>}, undefined), VS, 1)),
    ?assertEqual(?const(false), reduce_predicate(CondFun(undefined, {equals, <<"bank">>}), VS, 1)),
    ?assertEqual(?const(true), reduce_predicate(CondFun(undefined, undefined), VS, 1)).

-endif.
