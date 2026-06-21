-module(hg_invoice_dummy_data).

%-include_lib("hellgate/include/hg_invoice.hrl").
-include("hg_ct_domain.hrl").

-export([construct_domain_fixture/0]).

-spec construct_domain_fixture() -> _.
construct_domain_fixture() ->
    [
        hg_ct_fixture:construct_currency(?cur(<<"RUB">>)),
        hg_ct_fixture:construct_currency(?cur(<<"USD">>)),
        hg_ct_fixture:construct_currency(?cur(<<"EUR">>)),
        hg_ct_fixture:construct_currency(?cur(<<"JPY">>)),
        hg_ct_fixture:construct_currency(?cur(<<"CNY">>)),

        hg_ct_fixture:construct_category(?cat(1), <<"Test category">>, test),
        hg_ct_fixture:construct_category(?cat(2), <<"Generic Store">>, live),
        hg_ct_fixture:construct_category(?cat(3), <<"Guns & Booze">>, live),
        hg_ct_fixture:construct_category(?cat(4), <<"Flowers & Meat">>, live),
        hg_ct_fixture:construct_category(?cat(5), <<"Horns & Hooves">>, live),

        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"visa-ref">>))),

        hg_ct_fixture:construct_proxy(?prx(1), <<"Dummy proxy">>),
        hg_ct_fixture:construct_proxy(?prx(2), <<"Inspector proxy">>),

        hg_ct_fixture:construct_inspector(?insp(1), <<"Rejector">>, ?prx(2), #{<<"risk_score">> => <<"trusted">>}),

        hg_ct_fixture:construct_system_account_set(?sas(1)),
        hg_ct_fixture:construct_external_account_set(?eas(1)),

        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(1),
            <<"SubMain">>,
            {candidates, [
                ?candidate({condition, {category_is, ?cat(1)}}, ?trm(1)),
                ?candidate({condition, {category_is, ?cat(2)}}, ?trm(2)),
                ?candidate({condition, {category_is, ?cat(3)}}, ?trm(3)),
                ?candidate({condition, {category_is, ?cat(4)}}, ?trm(4)),
                ?candidate({condition, {category_is, ?cat(5)}}, ?trm(5))
            ]}
        ),
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(2),
            <<"Prohibitions">>,
            {candidates, []}
        ),

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Test Inc.">>,
                system_account_set = {value, ?sas(1)},
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(1),
                    prohibitions = ?ruleset(2)
                },
                inspector = {value, ?insp(1)},
                residences = [],
                realm = test
            }
        }},

        {globals, #domain_GlobalsObject{
            ref = #domain_GlobalsRef{},
            data = #domain_Globals{
                external_account_set = {value, ?eas(1)},
                payment_institutions = ?ordset([?pinst(1)])
            }
        }},

        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                term_set = #domain_TermSet{payments = payment_service_terms()}
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
                    additional = #{}
                },
                accounts = hg_ct_fixture:construct_provider_account_set([
                    ?cur(<<"RUB">>),
                    ?cur(<<"USD">>),
                    ?cur(<<"EUR">>),
                    ?cur(<<"JPY">>),
                    ?cur(<<"CNY">>)
                ]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        cash_limit = {
                            decisions,
                            [
                                #domain_CashLimitDecision{
                                    if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                                    then_ = {
                                        value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"RUB">>)},
                                            {exclusive, ?cash(420000000, <<"RUB">>)}
                                        )
                                    }
                                },
                                #domain_CashLimitDecision{
                                    if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                                    then_ = {
                                        value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"USD">>)},
                                            {exclusive, ?cash(420000000, <<"USD">>)}
                                        )
                                    }
                                },
                                #domain_CashLimitDecision{
                                    if_ = {condition, {currency_is, ?cur(<<"EUR">>)}},
                                    then_ = {
                                        value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"EUR">>)},
                                            {exclusive, ?cash(420000000, <<"EUR">>)}
                                        )
                                    }
                                },
                                #domain_CashLimitDecision{
                                    if_ = {condition, {currency_is, ?cur(<<"JPY">>)}},
                                    then_ = {
                                        value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"JPY">>)},
                                            {exclusive, ?cash(420000000, <<"JPY">>)}
                                        )
                                    }
                                },
                                #domain_CashLimitDecision{
                                    if_ = {condition, {currency_is, ?cur(<<"CNY">>)}},
                                    then_ = {
                                        value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"CNY">>)},
                                            {exclusive, ?cash(420000000, <<"CNY">>)}
                                        )
                                    }
                                }
                            ]
                        }
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
                terms = #domain_ProvisionTermSet{
                    payments = payment_provision_terms(<<"RUB">>, 1)
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
                    payments = payment_provision_terms(<<"USD">>, 2)
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
                    payments = payment_provision_terms(<<"EUR">>, 3)
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(4),
            data = #domain_Terminal{
                name = <<"Brominal 4">>,
                description = <<"Brominal 4">>,
                provider_ref = ?prv(1),
                terms = #domain_ProvisionTermSet{
                    payments = payment_provision_terms(<<"JPY">>, 4)
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(5),
            data = #domain_Terminal{
                name = <<"Brominal 5">>,
                description = <<"Brominal 5">>,
                provider_ref = ?prv(1),
                terms = #domain_ProvisionTermSet{
                    payments = payment_provision_terms(<<"CNY">>, 5)
                }
            }
        }},

        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"visa-ref">>), <<"visa payment system">>)
    ].

%% Internals

payment_service_terms() ->
    #domain_PaymentsServiceTerms{
        currencies =
            {value, ?ordset([?cur(<<"RUB">>), ?cur(<<"USD">>), ?cur(<<"EUR">>), ?cur(<<"JPY">>), ?cur(<<"CNY">>)])},
        categories = {value, ?ordset([?cat(1), ?cat(2), ?cat(3), ?cat(4), ?cat(5)])},
        payment_methods = {value, ?ordset([?pmt(bank_card, ?bank_card(<<"visa-ref">>))])},
        fees = {
            value,
            [
                ?cfpost(
                    {merchant, settlement},
                    {system, settlement},
                    ?share(45, 1000, operation_amount)
                )
            ]
        },
        refunds = #domain_PaymentRefundsServiceTerms{
            payment_methods = {
                value,
                ?ordset([
                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                ])
            },
            eligibility_time = {value, #base_TimeSpan{minutes = 1}},
            fees = {
                value,
                [
                    ?cfpost(
                        {merchant, settlement},
                        {system, settlement},
                        ?fixed(100, <<"RUB">>)
                    )
                ]
            }
        },
        chargebacks = #domain_PaymentChargebackServiceTerms{
            allow = {constant, true},
            fees = {
                value,
                [
                    ?cfpost(
                        {merchant, settlement},
                        {system, settlement},
                        ?share(1, 1, surplus)
                    )
                ]
            }
        },
        cash_limit = {
            value,
            ?cashrng(
                {inclusive, ?cash(10, <<"RUB">>)},
                {exclusive, ?cash(420000000, <<"RUB">>)}
            )
        },
        attempt_limit = {value, #domain_AttemptLimit{attempts = 2}}
    }.

payment_provision_terms(Currency, Category) ->
    #domain_PaymentsProvisionTerms{
        currencies = {value, ?ordset([?cur(Currency)])},
        categories = {value, ?ordset([?cat(Category)])},
        payment_methods = {
            value,
            ?ordset([
                ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
            ])
        },
        cash_flow = {
            value,
            [
                ?cfpost(
                    {provider, settlement},
                    {merchant, settlement},
                    ?share(1, 1, operation_amount)
                ),
                ?cfpost(
                    {system, settlement},
                    {provider, settlement},
                    ?fixed(10, Currency)
                )
            ]
        },
        refunds = #domain_PaymentRefundsProvisionTerms{
            cash_flow = {
                value,
                [
                    ?cfpost(
                        {merchant, settlement},
                        {provider, settlement},
                        ?share(1, 1, operation_amount)
                    ),
                    ?cfpost(
                        {system, settlement},
                        {provider, settlement},
                        ?fixed(10, Currency)
                    )
                ]
            }
        },
        chargebacks = #domain_PaymentChargebackProvisionTerms{
            cash_flow = {
                value,
                [
                    ?cfpost(
                        {merchant, settlement},
                        {provider, settlement},
                        ?share(1, 1, operation_amount)
                    ),
                    ?cfpost(
                        {system, settlement},
                        {provider, settlement},
                        ?fixed(10, Currency)
                    )
                ]
            }
        }
    }.
