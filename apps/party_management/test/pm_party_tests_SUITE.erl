-module(pm_party_tests_SUITE).

-include_lib("party_management/test/pm_ct_domain.hrl").
-include_lib("party_management/include/domain.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_limiter_config_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_conf_v2_thrift.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([get_shop_account_simple/1]).
-export([get_wallet_account_simple/1]).
-export([get_account_state_simple/1]).
-export([get_shop_account/1]).
-export([get_shop_account_non_existant_version/1]).
-export([get_wallet_account/1]).
-export([get_wallet_account_non_existant_version/1]).
-export([get_account_state/1]).
-export([get_account_state_non_existant_version/1]).
-export([get_account_state_account_notfound/1]).

-export([compute_terms_ok/1]).
-export([compute_terms_hierarchy_not_found/1]).
-export([compute_payment_institution/1]).

-export([compute_provider_ok/1]).
-export([compute_provider_not_found/1]).
-export([compute_provider_terminal_terms_ok/1]).
-export([compute_provider_terminal_terms_global_allow_ok/1]).
-export([compute_provider_terminal_terms_not_found/1]).
-export([compute_provider_terminal_terms_undefined_terms/1]).
-export([compute_provider_terminal_ok/1]).
-export([compute_provider_terminal_empty_varset_ok/1]).
-export([compute_provider_terminal_not_found/1]).
-export([compute_globals_ok/1]).
-export([compute_payment_routing_ruleset_ok/1]).
-export([compute_payment_routing_ruleset_irreducible/1]).
-export([compute_payment_routing_ruleset_not_found/1]).
-export([compute_payment_routing_ruleset_with_trust_level_ok/1]).

-export([compute_pred_w_partial_all_of/1]).
-export([compute_pred_w_irreducible_criterion/1]).
-export([compute_pred_w_partially_irreducible_criterion/1]).

%% tests descriptions

-type config() :: pm_ct_helper:config().
-type test_case_name() :: pm_ct_helper:test_case_name().
-type group_name() :: pm_ct_helper:group_name().

-define(assert_different_term_sets(T1, T2),
    case T1 =:= T2 of
        true -> error({equal_term_sets, T1, T2});
        false -> ok
    end
).

cfg(Key, C) ->
    pm_ct_helper:cfg(Key, C).

-spec all() -> [{group, group_name()}].
all() ->
    [
        {group, accounts},
        {group, compute},
        {group, terms}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {accounts, [parallel], [
            get_shop_account_simple,
            get_wallet_account_simple,
            get_account_state_simple,
            get_shop_account,
            get_shop_account_non_existant_version,
            get_wallet_account,
            get_wallet_account_non_existant_version,
            get_account_state,
            get_account_state_non_existant_version,
            get_account_state_account_notfound
        ]},
        {compute, [parallel], [
            compute_terms_ok,
            compute_terms_hierarchy_not_found,
            compute_payment_institution,
            compute_provider_ok,
            compute_provider_not_found,
            compute_provider_terminal_terms_ok,
            compute_provider_terminal_terms_global_allow_ok,
            compute_provider_terminal_terms_not_found,
            compute_provider_terminal_terms_undefined_terms,
            compute_provider_terminal_ok,
            compute_provider_terminal_empty_varset_ok,
            compute_provider_terminal_not_found,
            compute_globals_ok,
            compute_payment_routing_ruleset_ok,
            compute_payment_routing_ruleset_with_trust_level_ok,
            compute_payment_routing_ruleset_irreducible,
            compute_payment_routing_ruleset_not_found
        ]},
        {terms, [sequence], [
            compute_pred_w_partial_all_of,
            compute_pred_w_irreducible_criterion,
            compute_pred_w_partially_irreducible_criterion
        ]}
    ].

%% starting/stopping

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    {Apps, _Ret} = pm_ct_helper:start_apps([woody, scoper, dmt_client, party_management]),
    PartyRef = ?party(list_to_binary(lists:concat(["party.", erlang:system_time()]))),
    LimitsRev = pm_domain:upsert(constuct_limits_domain_fixture()),
    _Rev = pm_domain:upsert(construct_domain_fixture(PartyRef, LimitsRev)),
    [{apps, Apps}, {party_ref, PartyRef} | C].

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    [application:stop(App) || App <- cfg(apps, C)].

%% tests

-spec init_per_group(group_name(), config()) -> config().
init_per_group(_Group, C) ->
    ApiClient = pm_ct_helper:create_client(),
    Client = pm_client_party:start(cfg(party_ref, C), ApiClient),
    [{client, Client} | C].

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, C) ->
    pm_client_party:stop(cfg(client, C)).

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(_Name, C) ->
    C.

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(_Name, _C) ->
    ok.

%%

-define(SHOP_ID, <<"SHOP1">>).
-define(WALLET_ID, <<"WALLET1">>).

-define(WRONG_DMT_OBJ_ID, 99999).

-spec get_shop_account_simple(config()) -> _ | no_return().
-spec get_wallet_account_simple(config()) -> _ | no_return().
-spec get_account_state_simple(config()) -> _ | no_return().
-spec get_shop_account(config()) -> _ | no_return().
-spec get_shop_account_non_existant_version(config()) -> _ | no_return().
-spec get_wallet_account(config()) -> _ | no_return().
-spec get_wallet_account_non_existant_version(config()) -> _ | no_return().
-spec get_account_state(config()) -> _ | no_return().
-spec get_account_state_non_existant_version(config()) -> _ | no_return().
-spec get_account_state_account_notfound(config()) -> _ | no_return().

-spec compute_terms_ok(config()) -> _ | no_return().
-spec compute_terms_hierarchy_not_found(config()) -> _ | no_return().
-spec compute_payment_institution(config()) -> _ | no_return().

-spec compute_provider_ok(config()) -> _ | no_return().
-spec compute_provider_not_found(config()) -> _ | no_return().
-spec compute_provider_terminal_terms_ok(config()) -> _ | no_return().
-spec compute_provider_terminal_terms_global_allow_ok(config()) -> _ | no_return().
-spec compute_provider_terminal_terms_not_found(config()) -> _ | no_return().
-spec compute_provider_terminal_terms_undefined_terms(config()) -> _ | no_return().
-spec compute_provider_terminal_ok(config()) -> _ | no_return().
-spec compute_provider_terminal_empty_varset_ok(config()) -> _ | no_return().
-spec compute_provider_terminal_not_found(config()) -> _ | no_return().
-spec compute_globals_ok(config()) -> _ | no_return().
-spec compute_payment_routing_ruleset_ok(config()) -> _ | no_return().
-spec compute_payment_routing_ruleset_irreducible(config()) -> _ | no_return().
-spec compute_payment_routing_ruleset_not_found(config()) -> _ | no_return().

-spec compute_pred_w_partial_all_of(config()) -> _ | no_return().
-spec compute_pred_w_irreducible_criterion(config()) -> _ | no_return().
-spec compute_pred_w_partially_irreducible_criterion(config()) -> _ | no_return().

%% Accounts

-define(NON_EXISTANT_DOMAIN_REVISION, 42_000_000).
-define(NON_EXISTANT_ACCOUNT_ID, 42_000).

get_shop_account_simple(C) ->
    Client = cfg(client, C),
    ?assertMatch(
        #domain_ShopAccount{},
        pm_client_party:get_shop_account_simple(?shop(?SHOP_ID), Client)
    ).

get_wallet_account_simple(C) ->
    Client = cfg(client, C),
    ?assertMatch(
        #domain_WalletAccount{},
        pm_client_party:get_wallet_account_simple(?wallet(?WALLET_ID), Client)
    ).

get_account_state_simple(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    #domain_ShopAccount{settlement = AccountID} =
        pm_client_party:get_shop_account(?shop(?SHOP_ID), DomainRevision, Client),
    ?assertMatch(
        #payproc_AccountState{account_id = AccountID},
        pm_client_party:get_account_state_simple(AccountID, Client)
    ).

get_shop_account(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    ?assertMatch(
        #domain_ShopAccount{},
        pm_client_party:get_shop_account(?shop(?SHOP_ID), DomainRevision, Client)
    ).

get_shop_account_non_existant_version(C) ->
    Client = cfg(client, C),
    ?assertMatch(
        {exception, #payproc_PartyNotFound{}},
        pm_client_party:get_shop_account(?shop(?SHOP_ID), ?NON_EXISTANT_DOMAIN_REVISION, Client)
    ).

get_wallet_account(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    ?assertMatch(
        #domain_WalletAccount{},
        pm_client_party:get_wallet_account(?wallet(?WALLET_ID), DomainRevision, Client)
    ).

get_wallet_account_non_existant_version(C) ->
    Client = cfg(client, C),
    ?assertMatch(
        {exception, #payproc_PartyNotFound{}},
        pm_client_party:get_wallet_account(?wallet(?WALLET_ID), ?NON_EXISTANT_DOMAIN_REVISION, Client)
    ).

get_account_state(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    #domain_ShopAccount{settlement = AccountID} =
        pm_client_party:get_shop_account(?shop(?SHOP_ID), DomainRevision, Client),
    ?assertMatch(
        #payproc_AccountState{account_id = AccountID},
        pm_client_party:get_account_state(AccountID, DomainRevision, Client)
    ).

get_account_state_non_existant_version(C) ->
    Client = cfg(client, C),
    ?assertMatch(
        {exception, #payproc_PartyNotFound{}},
        pm_client_party:get_account_state(42, ?NON_EXISTANT_DOMAIN_REVISION, Client)
    ).

get_account_state_account_notfound(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    ?assertMatch(
        {exception, #payproc_AccountNotFound{}},
        pm_client_party:get_account_state(?NON_EXISTANT_ACCOUNT_ID, DomainRevision, Client)
    ).

%%

compute_terms_ok(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    Varset = #payproc_Varset{
        payment_tool = {bank_card, #domain_BankCard{token = <<>>, bin = <<>>, last_digits = <<>>}},
        currency = ?cur(<<"RUB">>),
        amount = ?cash(100, <<"RUB">>),
        party_ref = ?party(<<"PARTYID1">>)
    },
    ?assertMatch(
        #domain_TermSet{
            payments = #domain_PaymentsServiceTerms{
                currencies = {value, _},
                categories = {value, _},
                payment_methods = {value, _},
                cash_limit = {value, _}
            }
        },
        pm_client_party:compute_terms(?trms(4), DomainRevision, Varset, Client)
    ).

compute_terms_hierarchy_not_found(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    ?assertMatch(
        {exception, #payproc_TermSetHierarchyNotFound{}},
        pm_client_party:compute_terms(?trms(42), DomainRevision, #payproc_Varset{}, Client)
    ).

compute_payment_institution(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    TermsFun = fun(PartyRef) ->
        #domain_PaymentInstitution{} =
            pm_client_party:compute_payment_institution(
                ?pinst(4),
                DomainRevision,
                #payproc_Varset{party_ref = PartyRef},
                Client
            )
    end,
    T1 = TermsFun(?party(<<"12345">>)),
    T2 = TermsFun(?party(<<"67890">>)),
    ?assert_different_term_sets(T1, T2).

%% Compute providers

compute_provider_ok(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    Varset = #payproc_Varset{
        currency = ?cur(<<"RUB">>)
    },
    CashFlow = ?cfpost(
        {system, settlement},
        {provider, settlement},
        {product,
            {min_of,
                ?ordset([
                    ?fixed(10, <<"RUB">>),
                    ?share(5, 100, operation_amount, round_half_towards_zero)
                ])}}
    ),
    #domain_Provider{
        terms = #domain_ProvisionTermSet{
            payments = #domain_PaymentsProvisionTerms{
                allow = {constant, true},
                cash_flow = {value, [CashFlow]}
            },
            recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
                cash_value = {value, ?cash(1000, <<"RUB">>)}
            },
            extension = #domain_ExtendedProvisionTerms{
                skip_recurrent = true
            }
        }
    } = pm_client_party:compute_provider(?prv(1), DomainRevision, Varset, Client).

compute_provider_not_found(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    {exception, #payproc_ProviderNotFound{}} =
        (catch pm_client_party:compute_provider(
            ?prv(?WRONG_DMT_OBJ_ID), DomainRevision, #payproc_Varset{}, Client
        )).

compute_provider_terminal_terms_ok(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    Varset = #payproc_Varset{
        payment_tool = {bank_card, #domain_BankCard{token = <<>>, bin = <<>>, last_digits = <<>>}},
        currency = ?cur(<<"RUB">>)
    },
    CashFlow = ?cfpost(
        {system, settlement},
        {provider, settlement},
        {product,
            {min_of,
                ?ordset([
                    ?fixed(10, <<"RUB">>),
                    ?share(5, 100, operation_amount, round_half_towards_zero)
                ])}}
    ),
    PaymentMethods = ?ordset([?pmt(bank_card, ?bank_card(<<"visa">>))]),
    #domain_ProvisionTermSet{
        payments = #domain_PaymentsProvisionTerms{
            cash_flow = {value, [CashFlow]},
            payment_methods = {value, PaymentMethods},
            turnover_limits =
                {value, [
                    %% In ordset fashion
                    #domain_TurnoverLimit{
                        ref = ?lim(<<"p_card_day_count">>),
                        upper_boundary = 1,
                        domain_revision = _
                    },
                    #domain_TurnoverLimit{
                        ref = ?lim(<<"payment_card_month_amount_rub">>),
                        upper_boundary = 7500000,
                        domain_revision = _
                    },
                    #domain_TurnoverLimit{
                        ref = ?lim(<<"payment_card_month_count">>),
                        upper_boundary = 10,
                        domain_revision = _
                    },
                    #domain_TurnoverLimit{
                        ref = ?lim(<<"payment_day_amount_rub">>),
                        upper_boundary = 5000000,
                        domain_revision = _
                    }
                ]},
            allow_exchange = {constant, true}
        },
        recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
            cash_value = {value, ?cash(1000, <<"RUB">>)}
        },
        extension = #domain_ExtendedProvisionTerms{
            skip_recurrent = true
        }
    } = pm_client_party:compute_provider_terminal_terms(
        ?prv(1), ?trm(1), DomainRevision, Varset, Client
    ).

compute_provider_terminal_terms_global_allow_ok(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    Varset0 = #payproc_Varset{
        amount = ?cash(100, <<"RUB">>),
        party_ref = ?party(<<"PARTYID1">>)
    },
    ?assertEqual(
        #domain_ProvisionTermSet{
            payments = #domain_PaymentsProvisionTerms{
                allow = {constant, false},
                global_allow = {constant, false}
            }
        },
        pm_client_party:compute_provider_terminal_terms(
            ?prv(3), ?trm(5), DomainRevision, Varset0, Client
        )
    ),
    Varset1 = Varset0#payproc_Varset{party_ref = ?party(<<"PARTYID2">>)},
    ?assertEqual(
        #domain_ProvisionTermSet{
            payments = #domain_PaymentsProvisionTerms{
                allow = {constant, true},
                global_allow = {constant, false}
            }
        },
        pm_client_party:compute_provider_terminal_terms(
            ?prv(3), ?trm(5), DomainRevision, Varset1, Client
        )
    ),
    Varset2 = Varset0#payproc_Varset{amount = ?cash(101, <<"RUB">>)},
    ?assertEqual(
        #domain_ProvisionTermSet{
            payments = #domain_PaymentsProvisionTerms{
                allow = {constant, false},
                global_allow = {constant, true}
            }
        },
        pm_client_party:compute_provider_terminal_terms(
            ?prv(3), ?trm(5), DomainRevision, Varset2, Client
        )
    ).

compute_provider_terminal_terms_not_found(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    {exception, #payproc_TerminalNotFound{}} =
        pm_client_party:compute_provider_terminal_terms(
            ?prv(1),
            ?trm(?WRONG_DMT_OBJ_ID),
            DomainRevision,
            #payproc_Varset{},
            Client
        ),
    {exception, #payproc_ProviderNotFound{}} =
        pm_client_party:compute_provider_terminal_terms(
            ?prv(?WRONG_DMT_OBJ_ID),
            ?trm(1),
            DomainRevision,
            #payproc_Varset{},
            Client
        ),
    {exception, #payproc_ProviderNotFound{}} =
        pm_client_party:compute_provider_terminal_terms(
            ?prv(?WRONG_DMT_OBJ_ID),
            ?trm(?WRONG_DMT_OBJ_ID),
            DomainRevision,
            #payproc_Varset{},
            Client
        ).

compute_provider_terminal_terms_undefined_terms(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    ?assertMatch(
        {exception, #payproc_ProvisionTermSetUndefined{}},
        pm_client_party:compute_provider_terminal_terms(
            ?prv(2),
            ?trm(4),
            DomainRevision,
            #payproc_Varset{},
            Client
        )
    ).

compute_provider_terminal_ok(C) ->
    Client = cfg(client, C),
    Revision = pm_domain:head(),
    Varset = #payproc_Varset{
        currency = ?cur(<<"RUB">>)
    },
    ExpectedCashflow = ?cfpost(
        {system, settlement},
        {provider, settlement},
        {product,
            {min_of,
                ?ordset([
                    ?fixed(10, <<"RUB">>),
                    ?share(5, 100, operation_amount, round_half_towards_zero)
                ])}}
    ),
    ExpectedPaymentMethods = ?ordset([
        ?pmt(bank_card, ?bank_card(<<"visa">>))
    ]),
    ?assertMatch(
        #payproc_ProviderTerminal{
            ref = ?trm(1),
            name = <<"Brominal 1">>,
            description = <<"Brominal 1">>,
            provider = #payproc_ProviderDetails{
                ref = ?prv(1),
                name = <<"Brovider">>,
                description = <<"A provider but bro">>
            },
            proxy = #domain_ProxyDefinition{
                name = <<"Dummy proxy">>,
                url = <<"http://dummy.proxy/">>,
                options = #{
                    <<"proxy">> := <<"def">>,
                    <<"pro">> := <<"vader">>,
                    <<"term">> := <<"inal">>,
                    <<"override_proxy">> := <<"proxydef">>,
                    <<"override_provider">> := <<"provider">>,
                    <<"override_terminal">> := <<"terminal">>
                }
            },
            terms = #domain_ProvisionTermSet{
                payments = #domain_PaymentsProvisionTerms{
                    cash_flow = {value, [ExpectedCashflow]},
                    payment_methods = {value, ExpectedPaymentMethods}
                },
                recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
                    cash_value = {value, ?cash(1000, <<"RUB">>)}
                }
            }
        },
        pm_client_party:compute_provider_terminal(?trm(1), Revision, Varset, Client)
    ).

compute_provider_terminal_empty_varset_ok(C) ->
    Client = cfg(client, C),
    Revision = pm_domain:head(),
    ?assertMatch(
        #payproc_ProviderTerminal{
            ref = ?trm(1),
            provider = #payproc_ProviderDetails{
                ref = ?prv(1)
            },
            proxy = #domain_ProxyDefinition{
                url = <<"http://dummy.proxy/">>,
                options = #{
                    <<"override_proxy">> := <<"proxydef">>,
                    <<"override_provider">> := <<"provider">>,
                    <<"override_terminal">> := <<"terminal">>
                }
            },
            terms = undefined
        },
        pm_client_party:compute_provider_terminal(?trm(1), Revision, undefined, Client)
    ).

compute_provider_terminal_not_found(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    ?assertMatch(
        {exception, #payproc_TerminalNotFound{}},
        pm_client_party:compute_provider_terminal(
            ?trm(?WRONG_DMT_OBJ_ID),
            DomainRevision,
            #payproc_Varset{},
            Client
        )
    ).

compute_globals_ok(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    Varset = #payproc_Varset{},
    #domain_Globals{
        external_account_set = {value, ?eas(1)}
    } = pm_client_party:compute_globals(DomainRevision, Varset, Client).

compute_payment_routing_ruleset_ok(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    Varset = #payproc_Varset{
        party_ref = ?party(<<"67890">>)
    },
    #domain_RoutingRuleset{
        name = <<"Rule#1">>,
        decisions =
            {candidates, [
                #domain_RoutingCandidate{
                    terminal = ?trm(2),
                    allowed = {constant, true}
                },
                #domain_RoutingCandidate{
                    terminal = ?trm(3),
                    allowed = {constant, true}
                },
                #domain_RoutingCandidate{
                    terminal = ?trm(1),
                    allowed = {constant, true}
                }
            ]}
    } = pm_client_party:compute_routing_ruleset(?ruleset(1), DomainRevision, Varset, Client).

-spec compute_payment_routing_ruleset_with_trust_level_ok(_) -> _.
compute_payment_routing_ruleset_with_trust_level_ok(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    Varset = #payproc_Varset{
        trust_level = well_known
    },
    #domain_RoutingRuleset{
        name = <<"Rule#10">>,
        decisions =
            {candidates, [
                #domain_RoutingCandidate{
                    terminal = ?trm(1),
                    allowed = {constant, true}
                }
            ]}
    } = pm_client_party:compute_routing_ruleset(?ruleset(10), DomainRevision, Varset, Client).

compute_payment_routing_ruleset_irreducible(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    Varset = #payproc_Varset{},
    #domain_RoutingRuleset{
        name = <<"Rule#1">>,
        decisions =
            {delegates, [
                #domain_RoutingDelegate{
                    allowed =
                        {condition, {party, #domain_PartyCondition{party_ref = ?party(<<"12345">>)}}},
                    ruleset = ?ruleset(2)
                },
                #domain_RoutingDelegate{
                    allowed =
                        {condition, {party, #domain_PartyCondition{party_ref = ?party(<<"67890">>)}}},
                    ruleset = ?ruleset(3)
                },
                #domain_RoutingDelegate{
                    allowed = {constant, true},
                    ruleset = ?ruleset(4)
                }
            ]}
    } = pm_client_party:compute_routing_ruleset(?ruleset(1), DomainRevision, Varset, Client).

compute_payment_routing_ruleset_not_found(C) ->
    Client = cfg(client, C),
    DomainRevision = pm_domain:head(),
    {exception, #payproc_RuleSetNotFound{}} =
        (catch pm_client_party:compute_routing_ruleset(
            ?ruleset(5), DomainRevision, #payproc_Varset{}, Client
        )).

%%

compute_pred_w_partial_all_of(_) ->
    Revision = pm_domain:head(),
    Predicate =
        {all_of, [
            {constant, true},
            {condition, {currency_is, ?cur(<<"CNY">>)}},
            Cond1 = {condition, {category_is, ?cat(42)}},
            Cond2 = {condition, {shop_location_is, {url, <<"https://thisiswhyimbroke.com">>}}}
        ]},
    ?assertMatch(
        {all_of, [Cond1, Cond2]},
        pm_selector:reduce_predicate(
            Predicate,
            #{currency => ?cur(<<"CNY">>)},
            Revision
        )
    ).

compute_pred_w_irreducible_criterion(_) ->
    CriterionRef = ?crit(1),
    pm_ct_domain:with(
        [
            pm_ct_fixture:construct_criterion(
                CriterionRef,
                <<"HAHA">>,
                {condition, {currency_is, ?cur(<<"KZT">>)}}
            )
        ],
        fun(Revision) ->
            ?assertMatch(
                {criterion, CriterionRef},
                pm_selector:reduce_predicate({criterion, CriterionRef}, #{}, Revision)
            )
        end
    ).

compute_pred_w_partially_irreducible_criterion(_) ->
    CriterionRef = ?crit(1),
    pm_ct_domain:with(
        [
            pm_ct_fixture:construct_criterion(
                CriterionRef,
                <<"HAHA GOT ME">>,
                {all_of, [
                    {constant, true},
                    {is_not, {condition, {currency_is, ?cur(<<"KZT">>)}}}
                ]}
            )
        ],
        fun(Revision) ->
            ?assertMatch(
                {is_not, {condition, {currency_is, ?cur(<<"KZT">>)}}},
                pm_selector:reduce_predicate({criterion, CriterionRef}, #{}, Revision)
            )
        end
    ).

%%

-spec constuct_limits_domain_fixture() -> [pm_domain:object()].
constuct_limits_domain_fixture() ->
    [
        {limit_config, #domain_LimitConfigObject{
            ref = #domain_LimitConfigRef{id = LimitID},
            data = #limiter_config_LimitConfig{
                processor_type = <<"TurnoverProcessor">>,
                started_at = <<"2000-01-01T00:00:00Z">>,
                shard_size = 12,
                time_range_type = {calendar, {month, #limiter_config_TimeRangeTypeCalendarMonth{}}},
                context_type = {payment_processing, #limiter_config_LimitContextTypePaymentProcessing{}},
                type =
                    {turnover, #limiter_config_LimitTypeTurnover{
                        metric = {amount, #limiter_config_LimitTurnoverAmount{currency = <<"RUB">>}}
                    }},
                scopes = ordsets:from_list([{shop, #limiter_config_LimitScopeEmptyDetails{}}]),
                description = <<"description">>,
                op_behaviour = #limiter_config_OperationLimitBehaviour{
                    invoice_payment_refund = {subtraction, #limiter_config_Subtraction{}}
                }
            }
        }}
     || LimitID <- [
            <<"payment_card_month_count">>,
            <<"payment_card_month_amount_rub">>,
            <<"payment_day_amount_rub">>,
            <<"p_card_day_count">>
        ]
    ].

-spec construct_domain_fixture(dmsl_domain_thrift:'PartyConfigRef'(), dmsl_domain_conf_v2_thrift:'Version'()) ->
    [pm_domain:object()].
construct_domain_fixture(PartyRef, PrevRev) ->
    TestTermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            currencies = {value, ordsets:from_list([?cur(<<"RUB">>)])},
            categories = {value, ordsets:from_list([?cat(1)])}
        }
    },
    DefaultTermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            currencies =
                {value,
                    ordsets:from_list([
                        ?cur(<<"RUB">>),
                        ?cur(<<"USD">>)
                    ])},
            categories =
                {value,
                    ordsets:from_list([
                        ?cat(2),
                        ?cat(3)
                    ])},
            payment_methods =
                {value,
                    ordsets:from_list([
                        ?pmt(bank_card, ?bank_card(<<"visa">>))
                    ])}
        }
    },

    TermSet = #domain_TermSet{
        recurrent_paytools = #domain_RecurrentPaytoolsServiceTerms{
            payment_methods =
                {decisions, [
                    mk_payment_decision(
                        {bank_card, #domain_BankCardCondition{
                            definition = {issuer_bank_is, ?bank(1)}
                        }},
                        [
                            ?pmt(bank_card, ?bank_card(<<"visa">>)),
                            ?pmt(crypto_currency, ?crypta(<<"bitcoin">>))
                        ]
                    ),
                    mk_payment_decision(
                        {bank_card, #domain_BankCardCondition{definition = {empty_cvv_is, true}}},
                        []
                    ),
                    mk_payment_decision(
                        {bank_card, #domain_BankCardCondition{}},
                        [?pmt(bank_card, ?bank_card(<<"visa">>))]
                    ),
                    mk_payment_decision(
                        {payment_terminal, #domain_PaymentTerminalCondition{}},
                        [?pmt(crypto_currency, ?crypta(<<"bitcoin">>))]
                    ),
                    #domain_PaymentMethodDecision{
                        if_ = {constant, true},
                        then_ = {value, ordsets:from_list([])}
                    }
                ]}
        },
        payments = #domain_PaymentsServiceTerms{
            cash_limit =
                {value, #domain_CashRange{
                    lower = {inclusive, #domain_Cash{amount = 1000, currency = ?cur(<<"RUB">>)}},
                    upper = {exclusive, #domain_Cash{amount = 4200000, currency = ?cur(<<"RUB">>)}}
                }},
            fees =
                {value, [
                    ?cfpost(
                        {merchant, settlement},
                        {system, settlement},
                        ?share(45, 1000, operation_amount)
                    )
                ]}
        },
        wallets = #domain_WalletServiceTerms{
            currencies = {value, ordsets:from_list([?cur(<<"RUB">>)])},
            wallet_limit =
                {decisions, [
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(0, <<"RUB">>)},
                                    {exclusive, ?cash(5000001, <<"RUB">>)}
                                )}
                    },
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(0, <<"USD">>)},
                                    {exclusive, ?cash(10000001, <<"USD">>)}
                                )}
                    }
                ]},
            withdrawals = #domain_WithdrawalServiceTerms{
                methods =
                    {decisions, [
                        mk_payment_decision(
                            {bank_card, #domain_BankCardCondition{
                                definition = {
                                    payment_system,
                                    #domain_PaymentSystemCondition{
                                        payment_system_is = ?pmt_sys(<<"visa">>)
                                    }
                                }
                            }},
                            [?pmt(bank_card, ?bank_card(<<"visa">>))]
                        ),
                        mk_payment_decision(
                            {digital_wallet, #domain_DigitalWalletCondition{
                                definition =
                                    {payment_service_is, ?pmt_srv(<<"qiwi">>)}
                            }},
                            [?pmt(bank_card, ?bank_card(<<"visa">>))]
                        ),
                        mk_payment_decision(
                            {mobile_commerce, #domain_MobileCommerceCondition{
                                definition = {operator_is, ?mob(<<"mts">>)}
                            }},
                            [?pmt(bank_card, ?bank_card(<<"visa">>))]
                        ),
                        mk_payment_decision(
                            {crypto_currency, #domain_CryptoCurrencyCondition{
                                definition = {crypto_currency_is, ?crypta(<<"bitcoin">>)}
                            }},
                            [?pmt(bank_card, ?bank_card(<<"visa">>))]
                        ),
                        #domain_PaymentMethodDecision{
                            if_ = {constant, true},
                            then_ = {value, ordsets:from_list([])}
                        }
                    ]}
            }
        }
    },
    Decision1 =
        {delegates, [
            #domain_RoutingDelegate{
                allowed =
                    {condition, {party, #domain_PartyCondition{party_ref = ?party(<<"12345">>)}}},
                ruleset = ?ruleset(2)
            },
            #domain_RoutingDelegate{
                allowed =
                    {condition, {party, #domain_PartyCondition{party_ref = ?party(<<"67890">>)}}},
                ruleset = ?ruleset(3)
            },
            #domain_RoutingDelegate{
                allowed = {constant, true},
                ruleset = ?ruleset(4)
            }
        ]},
    Decision2 =
        {candidates, [
            #domain_RoutingCandidate{
                allowed = {constant, true},
                terminal = ?trm(1)
            }
        ]},
    Decision3 =
        {candidates, [
            #domain_RoutingCandidate{
                allowed =
                    {condition, {party, #domain_PartyCondition{party_ref = ?party(<<"67890">>)}}},
                terminal = ?trm(2)
            },
            #domain_RoutingCandidate{
                allowed = {constant, true},
                terminal = ?trm(3)
            },
            #domain_RoutingCandidate{
                allowed = {constant, true},
                terminal = ?trm(1)
            }
        ]},
    Decision4 =
        {candidates, [
            #domain_RoutingCandidate{
                allowed = {constant, true},
                terminal = ?trm(3)
            }
        ]},
    Decision10 =
        {candidates, [
            #domain_RoutingCandidate{
                allowed = {condition, {trust_level_is, well_known}},
                terminal = ?trm(1)
            }
        ]},
    [
        pm_ct_fixture:construct_currency(?cur(<<"RUB">>)),
        pm_ct_fixture:construct_currency(?cur(<<"USD">>)),
        pm_ct_fixture:construct_currency(?cur(<<"KZT">>)),

        pm_ct_fixture:construct_category(?cat(1), <<"Test category">>, test),
        pm_ct_fixture:construct_category(?cat(2), <<"Generic Store">>, live),
        pm_ct_fixture:construct_category(?cat(3), <<"Guns & Booze">>, live),
        pm_ct_fixture:construct_category(?cat(4), <<"Tech Store">>, live),
        pm_ct_fixture:construct_category(?cat(5), <<"Burger Boutique">>, live),

        pm_ct_fixture:construct_payment_system(?pmt_sys(<<"visa">>), <<"Visa">>),
        pm_ct_fixture:construct_payment_system(?pmt_sys(<<"mastercard">>), <<"Mastercard">>),
        pm_ct_fixture:construct_payment_system(?pmt_sys(<<"maestro">>), <<"Maestro">>),
        pm_ct_fixture:construct_payment_system(?pmt_sys(<<"jcb">>), <<"JCB">>),
        pm_ct_fixture:construct_payment_service(?pmt_srv(<<"alipay">>), <<"Euroset">>),
        pm_ct_fixture:construct_payment_service(?pmt_srv(<<"qiwi">>), <<"Qiwi">>),
        pm_ct_fixture:construct_mobile_operator(?mob(<<"mts">>), <<"MTS">>),
        pm_ct_fixture:construct_crypto_currency(?crypta(<<"bitcoin">>), <<"Bitcoin">>),
        pm_ct_fixture:construct_tokenized_service(?token_srv(<<"applepay">>), <<"Apple Pay">>),
        pm_ct_fixture:construct_payment_service(?pmt_srv(<<"generic">>), <<"Generic">>),
        pm_ct_fixture:construct_payment_service(?pmt_srv(<<"generic1">>), <<"Generic1">>),

        pm_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"visa">>))),
        pm_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"mastercard">>))),
        pm_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"maestro">>))),
        pm_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"jcb">>))),
        pm_ct_fixture:construct_payment_method(
            ?pmt(bank_card, ?token_bank_card(<<"visa">>, <<"applepay">>))
        ),
        pm_ct_fixture:construct_payment_method(?pmt(payment_terminal, ?pmt_srv(<<"alipay">>))),
        pm_ct_fixture:construct_payment_method(?pmt(digital_wallet, ?pmt_srv(<<"qiwi">>))),
        pm_ct_fixture:construct_payment_method(?pmt(mobile, ?mob(<<"mts">>))),
        pm_ct_fixture:construct_payment_method(?pmt(crypto_currency, ?crypta(<<"bitcoin">>))),
        pm_ct_fixture:construct_payment_method(?pmt(generic, ?gnrc(?pmt_srv(<<"generic">>)))),
        pm_ct_fixture:construct_payment_method(?pmt(generic, ?gnrc(?pmt_srv(<<"generic1">>)))),

        pm_ct_fixture:construct_payment_method(?pmt(payment_terminal, ?pmt_srv(<<"euroset">>))),
        pm_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card_no_cvv(<<"visa">>))),

        pm_ct_fixture:construct_proxy(
            ?prx(1),
            <<"Dummy proxy">>,
            <<"http://dummy.proxy/">>,
            #{
                <<"proxy">> => <<"def">>,
                <<"override_proxy">> => <<"proxydef">>,
                <<"override_provider">> => <<"proxydef">>,
                <<"override_terminal">> => <<"proxydef">>
            }
        ),

        pm_ct_fixture:construct_inspector(?insp(1), <<"Dummy Inspector">>, ?prx(1)),
        pm_ct_fixture:construct_system_account_set(?sas(1)),
        pm_ct_fixture:construct_system_account_set(?sas(2)),
        pm_ct_fixture:construct_external_account_set(?eas(1)),

        pm_ct_fixture:construct_business_schedule(?bussched(1)),

        pm_ct_fixture:construct_payment_routing_ruleset(?ruleset(1), <<"Rule#1">>, Decision1),
        pm_ct_fixture:construct_payment_routing_ruleset(?ruleset(2), <<"Rule#2">>, Decision2),
        pm_ct_fixture:construct_payment_routing_ruleset(?ruleset(3), <<"Rule#3">>, Decision3),
        pm_ct_fixture:construct_payment_routing_ruleset(?ruleset(4), <<"Rule#4">>, Decision4),
        pm_ct_fixture:construct_payment_routing_ruleset(?ruleset(10), <<"Rule#10">>, Decision10),

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Test Inc.">>,
                system_account_set = {value, ?sas(1)},
                inspector = {value, ?insp(1)},
                residences = [],
                realm = test
            }
        }},

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(2),
            data = #domain_PaymentInstitution{
                name = <<"Chetky Payments Inc.">>,
                system_account_set = {value, ?sas(2)},
                inspector = {value, ?insp(1)},
                residences = [],
                realm = live
            }
        }},

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(3),
            data = #domain_PaymentInstitution{
                name = <<"Chetky Payments Inc.">>,
                system_account_set = {value, ?sas(2)},
                inspector = {value, ?insp(1)},
                residences = [],
                realm = live
            }
        }},

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(4),
            data = #domain_PaymentInstitution{
                name = <<"Chetky Payments Inc.">>,
                system_account_set =
                    {decisions, [
                        #domain_SystemAccountSetDecision{
                            if_ = ?partycond(<<"12345">>, undefined),
                            then_ =
                                {value, ?sas(2)}
                        },
                        #domain_SystemAccountSetDecision{
                            if_ = ?partycond(<<"67890">>, undefined),
                            then_ =
                                {value, ?sas(1)}
                        }
                    ]},
                inspector = {value, ?insp(1)},
                residences = [],
                realm = live
            }
        }},

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(5),
            data = #domain_PaymentInstitution{
                name = <<"N.E. Chetky Payments GmbH">>,
                system_account_set = {value, ?sas(2)},
                inspector = {value, ?insp(1)},
                residences = [],
                realm = live
            }
        }},

        %% Party, shop and wallet
        pm_ct_fixture:construct_party(?party(<<"12345">>)),
        pm_ct_fixture:construct_party(?party(<<"67890">>)),
        pm_ct_fixture:construct_party(?party(<<"PARTYID1">>)),
        pm_ct_fixture:construct_party(?party(<<"PARTYID2">>)),
        pm_ct_fixture:construct_party(PartyRef),
        pm_ct_fixture:construct_shop(
            ?shop(?SHOP_ID),
            ?pinst(1),
            ?trms(2),
            pm_ct_fixture:construct_shop_account(<<"RUB">>),
            PartyRef,
            <<"http://example.com">>,
            ?cat(1)
        ),
        pm_ct_fixture:construct_wallet(
            ?wallet(?WALLET_ID),
            ?pinst(1),
            ?trms(2),
            pm_ct_fixture:construct_wallet_account(<<"RUB">>),
            PartyRef
        ),

        {globals, #domain_GlobalsObject{
            ref = #domain_GlobalsRef{},
            data = #domain_Globals{
                external_account_set =
                    {decisions, [
                        #domain_ExternalAccountSetDecision{
                            if_ = {constant, true},
                            then_ = {value, ?eas(1)}
                        }
                    ]},
                payment_institutions = ?ordset([?pinst(1), ?pinst(2), ?pinst(5)])
            }
        }},
        pm_ct_fixture:construct_term_set_hierarchy(?trms(1), undefined, TestTermSet),
        pm_ct_fixture:construct_term_set_hierarchy(?trms(2), undefined, DefaultTermSet),
        pm_ct_fixture:construct_term_set_hierarchy(?trms(3), ?trms(2), TermSet),
        pm_ct_fixture:construct_term_set_hierarchy(
            ?trms(4),
            ?trms(3),
            #domain_TermSet{
                payments = #domain_PaymentsServiceTerms{
                    currencies =
                        {value,
                            ordsets:from_list([
                                ?cur(<<"RUB">>)
                            ])},
                    categories =
                        {value,
                            ordsets:from_list([
                                ?cat(2)
                            ])},
                    payment_methods =
                        {value,
                            ordsets:from_list([
                                ?pmt(bank_card, ?bank_card(<<"visa">>))
                            ])}
                }
            }
        ),

        {bank, #domain_BankObject{
            ref = ?bank(1),
            data = #domain_Bank{
                name = <<"Test BIN range">>,
                description = <<"Test BIN range">>,
                bins = ordsets:from_list([<<"1234">>, <<"5678">>])
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Brovider">>,
                description = <<"A provider but bro">>,
                realm = test,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"pro">> => <<"vader">>,
                        <<"override_provider">> => <<"provider">>,
                        <<"override_terminal">> => <<"provider">>
                    }
                },
                accounts = pm_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        allow = {constant, true},
                        currencies = {value, ?ordset([?cur(<<"RUB">>)])},
                        categories = {value, ?ordset([?cat(1)])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa">>)),
                                    ?pmt(bank_card, ?bank_card(<<"mastercard">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(1000000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {decisions, [
                                #domain_CashFlowDecision{
                                    if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                {product,
                                                    {min_of,
                                                        ?ordset([
                                                            ?fixed(10, <<"RUB">>),
                                                            ?share(
                                                                5,
                                                                100,
                                                                operation_amount,
                                                                round_half_towards_zero
                                                            )
                                                        ])}}
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                {product,
                                                    {min_of,
                                                        ?ordset([
                                                            ?fixed(10, <<"USD">>),
                                                            ?share(
                                                                5,
                                                                100,
                                                                operation_amount,
                                                                round_half_towards_zero
                                                            )
                                                        ])}}
                                            )
                                        ]}
                                }
                            ]},
                        turnover_limits =
                            {decisions, [
                                #domain_TurnoverLimitDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {issuer_bank_is, #domain_BankRef{id = 1}}
                                                }}}},
                                    then_ =
                                        {value,
                                            ?ordset([
                                                #domain_TurnoverLimit{
                                                    ref = ?lim(<<"payment_card_month_count">>),
                                                    upper_boundary = 5,
                                                    domain_revision = PrevRev
                                                },
                                                %% Common limits
                                                #domain_TurnoverLimit{
                                                    ref = ?lim(<<"payment_card_month_amount_rub">>),
                                                    upper_boundary = 7500000,
                                                    domain_revision = PrevRev
                                                },
                                                #domain_TurnoverLimit{
                                                    ref = ?lim(<<"payment_day_amount_rub">>),
                                                    upper_boundary = 5000000,
                                                    domain_revision = PrevRev
                                                },
                                                #domain_TurnoverLimit{
                                                    ref = ?lim(<<"p_card_day_count">>),
                                                    upper_boundary = 1,
                                                    domain_revision = PrevRev
                                                }
                                            ])}
                                },
                                #domain_TurnoverLimitDecision{
                                    if_ =
                                        {is_not,
                                            {condition,
                                                {payment_tool,
                                                    {bank_card, #domain_BankCardCondition{
                                                        definition =
                                                            {issuer_bank_is, #domain_BankRef{
                                                                id = 1
                                                            }}
                                                    }}}}},
                                    then_ =
                                        {value,
                                            ?ordset([
                                                #domain_TurnoverLimit{
                                                    ref = ?lim(<<"payment_card_month_count">>),
                                                    upper_boundary = 10,
                                                    domain_revision = PrevRev
                                                },
                                                %% Common limits
                                                #domain_TurnoverLimit{
                                                    ref = ?lim(<<"payment_card_month_amount_rub">>),
                                                    upper_boundary = 7500000,
                                                    domain_revision = PrevRev
                                                },
                                                #domain_TurnoverLimit{
                                                    ref = ?lim(<<"payment_day_amount_rub">>),
                                                    upper_boundary = 5000000,
                                                    domain_revision = PrevRev
                                                },
                                                #domain_TurnoverLimit{
                                                    ref = ?lim(<<"p_card_day_count">>),
                                                    upper_boundary = 1,
                                                    domain_revision = PrevRev
                                                }
                                            ])}
                                }
                            ]}
                    },
                    recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
                        categories = {value, ?ordset([?cat(1)])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa">>)),
                                    ?pmt(bank_card, ?bank_card(<<"mastercard">>))
                                ])},
                        cash_value =
                            {decisions, [
                                #domain_CashValueDecision{
                                    if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                                    then_ = {value, ?cash(1000, <<"RUB">>)}
                                },
                                #domain_CashValueDecision{
                                    if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                                    then_ = {value, ?cash(1000, <<"USD">>)}
                                }
                            ]}
                    },
                    extension = #domain_ExtendedProvisionTerms{
                        skip_recurrent = true
                    }
                }
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(2),
            data = #domain_Provider{
                name = <<"Provider 2">>,
                description = <<"Provider without terms">>,
                realm = test,
                proxy = #domain_Proxy{ref = ?prx(1), additional = #{}},
                accounts = pm_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)])
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(3),
            data = #domain_Provider{
                name = <<"Brovider">>,
                description = <<"A provider but bro">>,
                realm = test,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"pro">> => <<"vader">>
                    }
                },
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        allow = ?partycond(<<"PARTYID1">>, undefined),
                        global_allow =
                            {condition,
                                {cost_in,
                                    ?cashrng(
                                        {inclusive, ?cash(100, <<"RUB">>)},
                                        {inclusive, ?cash(100, <<"RUB">>)}
                                    )}}
                    }
                }
            }
        }},

        {terminal, #domain_TerminalObject{
            ref = ?trm(1),
            data = #domain_Terminal{
                name = <<"Brominal 1">>,
                description = <<"Brominal 1">>,
                provider_ref = ?prv(1),
                options = #{
                    <<"term">> => <<"inal">>,
                    <<"override_terminal">> => <<"terminal">>
                },
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa">>))
                                ])},
                        allow_exchange = {constant, true}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(2),
            data = #domain_Terminal{
                name = <<"Brominal 2">>,
                description = <<"Brominal 2">>,
                provider_ref = ?prv(1),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa">>))
                                ])}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(3),
            data = #domain_Terminal{
                name = <<"Brominal 3">>,
                description = <<"Brominal 3">>,
                provider_ref = ?prv(1),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa">>))
                                ])}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(4),
            data = #domain_Terminal{
                name = <<"Terminal 4">>,
                description = <<"Terminal without terms">>,
                provider_ref = ?prv(2)
            }
        }},

        {terminal, #domain_TerminalObject{
            ref = ?trm(5),
            data = #domain_Terminal{
                name = <<"Brominal 5">>,
                description = <<"Brominal 5">>,
                provider_ref = ?prv(3),
                options = #{
                    <<"term">> => <<"inal">>,
                    <<"override_terminal">> => <<"terminal">>
                },
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        allow = ?partycond(<<"PARTYID2">>, undefined),
                        global_allow =
                            {condition,
                                {cost_in,
                                    ?cashrng(
                                        {inclusive, ?cash(101, <<"RUB">>)},
                                        {inclusive, ?cash(101, <<"RUB">>)}
                                    )}}
                    }
                }
            }
        }}
    ].

mk_payment_decision(PaymentTool, PaymentMethods) ->
    #domain_PaymentMethodDecision{
        if_ = {condition, {payment_tool, PaymentTool}},
        then_ = {value, ordsets:from_list(PaymentMethods)}
    }.
