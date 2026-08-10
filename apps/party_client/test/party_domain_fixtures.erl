-module(party_domain_fixtures).

-include("party_domain_fixtures.hrl").

-include_lib("damsel/include/dmsl_domain_conf_v2_thrift.hrl").

-export([construct_domain_fixture/0]).
-export([apply_domain_fixture/0]).
-export([apply_domain_fixture/1]).
-export([cleanup/0]).

%% Internal types

-type name() :: binary().
-type category() :: dmsl_domain_thrift:'CategoryRef'().
-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type proxy() :: dmsl_domain_thrift:'ProxyRef'().
-type inspector() :: dmsl_domain_thrift:'InspectorRef'().
-type routing_ruleset_ref() :: dmsl_domain_thrift:'RoutingRulesetRef'().

-type system_account_set() :: dmsl_domain_thrift:'SystemAccountSetRef'().
-type external_account_set() :: dmsl_domain_thrift:'ExternalAccountSetRef'().

-type business_schedule() :: dmsl_domain_thrift:'BusinessScheduleRef'().

%% API

-spec apply_domain_fixture() -> ok.
apply_domain_fixture() ->
    apply_domain_fixture(construct_domain_fixture()).

-spec apply_domain_fixture([dmsl_domain_thrift:'DomainObject'()]) -> ok.
apply_domain_fixture(Fixture) ->
    _NextRevision = dmt_client:insert(Fixture, ensure_stub_author()),
    ok.

-spec cleanup() -> ok.
cleanup() ->
    Version = dmt_client:get_latest_version(),
    Objects = lists:map(
        fun(#domain_conf_v2_VersionedObject{object = Object}) -> Object end, dmt_client:checkout_all(Version)
    ),
    _NextRevision = dmt_client:remove(Version, Objects, ensure_stub_author()),
    ok.

ensure_stub_author() ->
    %% TODO DISCUSS Stubs and fallback authors
    ensure_author(~b"unknown", ~b"unknown@local").

ensure_author(Name, Email) ->
    try
        #domain_conf_v2_Author{id = ID} = dmt_client:get_author_by_email(Email),
        ID
    catch
        throw:#domain_conf_v2_AuthorNotFound{} ->
            dmt_client:create_author(Name, Email)
    end.

-spec construct_domain_fixture() -> [dmsl_domain_thrift:'DomainObject'()].
construct_domain_fixture() ->
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
                        ?pmt_bank_card(visa)
                    ])}
        }
    },
    TermSet = #domain_TermSet{
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
            currencies = {value, ordsets:from_list([?cur(<<"RUB">>)])}
        }
    },
    Decision1 =
        {delegates, [
            #domain_RoutingDelegate{
                allowed =
                    {condition, {party, #domain_PartyCondition{party_ref = #domain_PartyConfigRef{id = <<"12345">>}}}},
                ruleset = ?ruleset(2)
            },
            #domain_RoutingDelegate{
                allowed =
                    {condition, {party, #domain_PartyCondition{party_ref = #domain_PartyConfigRef{id = <<"67890">>}}}},
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
                    {condition, {party, #domain_PartyCondition{party_ref = #domain_PartyConfigRef{id = <<"67890">>}}}},
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
    [
        construct_currency(?cur(<<"RUB">>)),
        construct_currency(?cur(<<"USD">>)),

        construct_category(?cat(1), <<"Test category">>, test),
        construct_category(?cat(2), <<"Generic Store">>, live),
        construct_category(?cat(3), <<"Guns & Booze">>, live),

        construct_payment_method(visa, ?pmt_bank_card(visa)),
        construct_payment_method(mastercard, ?pmt_bank_card(mastercard)),
        construct_payment_method(maestro, ?pmt_bank_card(maestro)),
        construct_payment_method(euroset, ?pmt(payment_terminal, #domain_PaymentServiceRef{id = <<"euroset">>})),

        construct_proxy(?prx(1), <<"Dummy proxy">>),
        construct_inspector(?insp(1), <<"Dummy Inspector">>, ?prx(1)),
        construct_system_account_set(?sas(1)),
        construct_system_account_set(?sas(2)),
        construct_external_account_set(?eas(1)),

        construct_business_schedule(?bussched(1)),

        construct_routing_ruleset(?ruleset(1), <<"Rule#1">>, Decision1),
        construct_routing_ruleset(?ruleset(2), <<"Rule#2">>, Decision2),
        construct_routing_ruleset(?ruleset(3), <<"Rule#3">>, Decision3),
        construct_routing_ruleset(?ruleset(4), <<"Rule#4">>, Decision4),

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

        {globals, #domain_GlobalsObject{
            ref = #domain_GlobalsRef{},
            data = #domain_Globals{
                external_account_set = {value, ?eas(1)},
                payment_institutions = ?ordset([?pinst(1), ?pinst(2)])
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                parent_terms = undefined,
                term_set = TestTermSet
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(2),
            data = #domain_TermSetHierarchy{
                parent_terms = undefined,
                term_set = DefaultTermSet
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(3),
            data = #domain_TermSetHierarchy{
                parent_terms = ?trms(2),
                term_set = TermSet
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(4),
            data = #domain_TermSetHierarchy{
                parent_terms = ?trms(3),
                term_set =
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
                                        ?pmt_bank_card(visa)
                                    ])}
                        }
                    }
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Brovider">>,
                realm = test,
                description = <<"A provider but bro">>,
                proxy = #domain_Proxy{ref = ?prx(1), additional = #{}},
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies = {value, ?ordset([?cur(<<"RUB">>)])},
                        categories = {value, ?ordset([?cat(1)])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt_bank_card(visa),
                                    ?pmt_bank_card(mastercard)
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
                            ]}
                    },
                    recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
                        categories = {value, ?ordset([?cat(1)])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt_bank_card(visa),
                                    ?pmt_bank_card(mastercard)
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
                    }
                }
            }
        }},

        {terminal, #domain_TerminalObject{
            ref = ?trm(1),
            data = #domain_Terminal{
                name = <<"Brominal 1">>,
                description = <<"Brominal 1">>,
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt_bank_card(visa)
                                ])}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(2),
            data = #domain_Terminal{
                name = <<"Brominal 2">>,
                description = <<"Brominal 2">>,
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt_bank_card(visa)
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
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt_bank_card(visa)
                                ])}
                    }
                }
            }
        }},
        {party_config, #domain_PartyConfigObject{
            ref = #domain_PartyConfigRef{id = <<"12345">>},
            data = #domain_PartyConfig{
                name = <<"12345">>,
                block = {unblocked, #domain_Unblocked{reason = ~"whatever reason", since = ~"1970-01-01T00:00:00Z"}},
                suspension = {active, #domain_Active{since = ~"1970-01-01T00:00:00Z"}},
                contact_info = #domain_PartyContactInfo{registration_email = <<"party@example.com">>}
            }
        }},
        {party_config, #domain_PartyConfigObject{
            ref = #domain_PartyConfigRef{id = <<"67890">>},
            data = #domain_PartyConfig{
                name = <<"67890">>,
                block = {unblocked, #domain_Unblocked{reason = ~"whatever reason", since = ~"1970-01-01T00:00:00Z"}},
                suspension = {active, #domain_Active{since = ~"1970-01-01T00:00:00Z"}},
                contact_info = #domain_PartyContactInfo{registration_email = <<"party@example.com">>}
            }
        }}
    ].

%% Internal functions

-spec construct_currency(currency()) -> {currency, dmsl_domain_thrift:'CurrencyObject'()}.
construct_currency(Ref) ->
    construct_currency(Ref, 2).

-spec construct_currency(currency(), Exponent :: pos_integer()) -> {currency, dmsl_domain_thrift:'CurrencyObject'()}.
construct_currency(?cur(SymbolicCode) = Ref, Exponent) ->
    {currency, #domain_CurrencyObject{
        ref = Ref,
        data = #domain_Currency{
            name = SymbolicCode,
            numeric_code = 666,
            symbolic_code = SymbolicCode,
            exponent = Exponent
        }
    }}.

-spec construct_category(category(), name(), test | live) -> {category, dmsl_domain_thrift:'CategoryObject'()}.
construct_category(Ref, Name, Type) ->
    {category, #domain_CategoryObject{
        ref = Ref,
        data = #domain_Category{
            name = Name,
            description = Name,
            type = Type
        }
    }}.

-spec construct_payment_method(atom(), dmsl_domain_thrift:'PaymentMethodRef'()) ->
    {payment_method, dmsl_domain_thrift:'PaymentMethodObject'()}.
construct_payment_method(Name, ?pmt(_, _) = Ref) when is_atom(Name) ->
    Def = erlang:atom_to_binary(Name, unicode),
    {payment_method, #domain_PaymentMethodObject{
        ref = Ref,
        data = #domain_PaymentMethodDefinition{
            name = Def,
            description = Def
        }
    }}.

-spec construct_proxy(proxy(), name()) -> {proxy, dmsl_domain_thrift:'ProxyObject'()}.
construct_proxy(Ref, Name) ->
    construct_proxy(Ref, Name, #{}).

-spec construct_proxy(proxy(), name(), Opts :: map()) -> {proxy, dmsl_domain_thrift:'ProxyObject'()}.
construct_proxy(Ref, Name, Opts) ->
    {proxy, #domain_ProxyObject{
        ref = Ref,
        data = #domain_ProxyDefinition{
            name = Name,
            description = Name,
            url = <<>>,
            options = Opts
        }
    }}.

-spec construct_inspector(inspector(), name(), proxy()) -> {inspector, dmsl_domain_thrift:'InspectorObject'()}.
construct_inspector(Ref, Name, ProxyRef) ->
    construct_inspector(Ref, Name, ProxyRef, #{}).

-spec construct_inspector(inspector(), name(), proxy(), Additional :: map()) ->
    {inspector, dmsl_domain_thrift:'InspectorObject'()}.
construct_inspector(Ref, Name, ProxyRef, Additional) ->
    {inspector, #domain_InspectorObject{
        ref = Ref,
        data = #domain_Inspector{
            name = Name,
            description = Name,
            proxy = #domain_Proxy{
                ref = ProxyRef,
                additional = Additional
            }
        }
    }}.

-spec construct_system_account_set(system_account_set()) ->
    {system_account_set, dmsl_domain_thrift:'SystemAccountSetObject'()}.
construct_system_account_set(Ref) ->
    construct_system_account_set(Ref, <<"Primaries">>, ?cur(<<"RUB">>)).

-spec construct_system_account_set(system_account_set(), name(), currency()) ->
    {system_account_set, dmsl_domain_thrift:'SystemAccountSetObject'()}.
construct_system_account_set(Ref, Name, ?cur(CurrencyCode)) ->
    AccountID = 3,
    {system_account_set, #domain_SystemAccountSetObject{
        ref = Ref,
        data = #domain_SystemAccountSet{
            name = Name,
            description = Name,
            accounts = #{
                ?cur(CurrencyCode) => #domain_SystemAccount{
                    settlement = AccountID
                }
            }
        }
    }}.

-spec construct_external_account_set(external_account_set()) ->
    {external_account_set, dmsl_domain_thrift:'ExternalAccountSetObject'()}.
construct_external_account_set(Ref) ->
    construct_external_account_set(Ref, <<"Primaries">>, ?cur(<<"RUB">>)).

-spec construct_external_account_set(external_account_set(), name(), currency()) ->
    {external_account_set, dmsl_domain_thrift:'ExternalAccountSetObject'()}.
construct_external_account_set(Ref, Name, ?cur(CurrencyCode)) ->
    AccountID1 = 1,
    AccountID2 = 2,
    {external_account_set, #domain_ExternalAccountSetObject{
        ref = Ref,
        data = #domain_ExternalAccountSet{
            name = Name,
            description = Name,
            accounts = #{
                ?cur(CurrencyCode) => #domain_ExternalAccount{
                    income = AccountID1,
                    outcome = AccountID2
                }
            }
        }
    }}.

-spec construct_business_schedule(business_schedule()) ->
    {business_schedule, dmsl_domain_thrift:'BusinessScheduleObject'()}.
construct_business_schedule(Ref) ->
    {business_schedule, #domain_BusinessScheduleObject{
        ref = Ref,
        data = #domain_BusinessSchedule{
            name = <<"Every day at 7:40">>,
            schedule = #base_Schedule{
                year = ?every,
                month = ?every,
                day_of_month = ?every,
                day_of_week = ?every,
                hour = {on, [7]},
                minute = {on, [40]},
                second = {on, [0]}
            }
        }
    }}.

-spec construct_routing_ruleset(routing_ruleset_ref(), name(), _) ->
    {routing_rules, dmsl_domain_thrift:'RoutingRulesObject'()}.
construct_routing_ruleset(Ref, Name, Decisions) ->
    {routing_rules, #domain_RoutingRulesObject{
        ref = Ref,
        data = #domain_RoutingRuleset{
            name = Name,
            decisions = Decisions
        }
    }}.
