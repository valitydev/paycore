-module(pm_ct_fixture).

-include("pm_ct_domain.hrl").

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%%

-export([construct_party/1]).
-export([construct_shop_account/1]).
-export([construct_shop/7]).
-export([construct_wallet_account/1]).
-export([construct_wallet/5]).
-export([construct_currency/1]).
-export([construct_currency/2]).
-export([construct_category/2]).
-export([construct_category/3]).
-export([construct_payment_method/1]).
-export([construct_proxy/2]).
-export([construct_proxy/4]).
-export([construct_inspector/3]).
-export([construct_inspector/4]).
-export([construct_inspector/5]).
-export([construct_provider_account_set/1]).
-export([construct_system_account_set/1]).
-export([construct_system_account_set/3]).
-export([construct_external_account_set/1]).
-export([construct_external_account_set/3]).
-export([construct_business_schedule/1]).
-export([construct_criterion/3]).
-export([construct_term_set_hierarchy/3]).
-export([construct_payment_routing_ruleset/3]).
-export([construct_payment_system/2]).
-export([construct_mobile_operator/2]).
-export([construct_payment_service/2]).
-export([construct_crypto_currency/2]).
-export([construct_tokenized_service/2]).

%%

-type name() :: binary().
-type category() :: dmsl_domain_thrift:'CategoryRef'().
-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type proxy() :: dmsl_domain_thrift:'ProxyRef'().
-type inspector() :: dmsl_domain_thrift:'InspectorRef'().
-type risk_score() :: dmsl_domain_thrift:'RiskScore'().
-type payment_routing_ruleset() :: dmsl_domain_thrift:'RoutingRulesetRef'().

-type payment_system() :: dmsl_domain_thrift:'PaymentSystemRef'().
-type mobile_operator() :: dmsl_domain_thrift:'MobileOperatorRef'().
-type payment_service() :: dmsl_domain_thrift:'PaymentServiceRef'().
-type crypto_currency() :: dmsl_domain_thrift:'CryptoCurrencyRef'().
-type tokenized_service() :: dmsl_domain_thrift:'BankCardTokenServiceRef'().

-type system_account_set() :: dmsl_domain_thrift:'SystemAccountSetRef'().
-type external_account_set() :: dmsl_domain_thrift:'ExternalAccountSetRef'().

-type business_schedule() :: dmsl_domain_thrift:'BusinessScheduleRef'().

-type criterion() :: dmsl_domain_thrift:'CriterionRef'().
-type predicate() :: dmsl_domain_thrift:'Predicate'().

-type term_set() :: dmsl_domain_thrift:'TermSet'().
-type term_set_hierarchy() :: dmsl_domain_thrift:'TermSetHierarchyRef'().

%%

-define(EVERY, {every, #'base_ScheduleEvery'{}}).

%%

-spec construct_party(dmsl_domain_thrift:'PartyConfigRef'()) ->
    {party_config, dmsl_domain_thrift:'PartyConfigObject'()}.
construct_party(PartyRef) ->
    {party_config, #domain_PartyConfigObject{
        ref = PartyRef,
        data = #domain_PartyConfig{
            name = PartyRef#domain_PartyConfigRef.id,
            block = make_unblocked(),
            suspension = make_active(),
            contact_info = #domain_PartyContactInfo{registration_email = <<"party@example.com">>}
        }
    }}.

-spec construct_shop_account(dmsl_domain_thrift:'CurrencySymbolicCode'()) -> dmsl_domain_thrift:'ShopAccount'().
construct_shop_account(CurrencyCode) ->
    ok = pm_context:save(pm_context:create()),
    Settlement = pm_accounting:create_account(CurrencyCode),
    Guarantee = pm_accounting:create_account(CurrencyCode),
    _ = pm_context:cleanup(),
    #domain_ShopAccount{
        currency = ?cur(CurrencyCode),
        settlement = Settlement,
        guarantee = Guarantee
    }.

-spec construct_shop(
    dmsl_domain_thrift:'ShopConfigRef'(),
    dmsl_domain_thrift:'PaymentInstitutionRef'(),
    dmsl_domain_thrift:'TermSetHierarchyRef'(),
    dmsl_domain_thrift:'ShopAccount'(),
    dmsl_domain_thrift:'PartyConfigRef'(),
    binary(),
    dmsl_domain_thrift:'CategoryRef'()
) -> {shop_config, dmsl_domain_thrift:'ShopConfigObject'()}.
construct_shop(ShopRef, PaymentInstitutionRef, TermSetHierarchyRef, ShopAccount, PartyRef, ShopLocation, CategoryRef) ->
    {shop_config, #domain_ShopConfigObject{
        ref = ShopRef,
        data = #domain_ShopConfig{
            name = ShopRef#domain_ShopConfigRef.id,
            block = make_unblocked(),
            suspension = make_active(),
            payment_institution = PaymentInstitutionRef,
            terms = TermSetHierarchyRef,
            account = ShopAccount,
            party_ref = PartyRef,
            location = {url, ShopLocation},
            category = CategoryRef
        }
    }}.

-spec construct_wallet_account(dmsl_domain_thrift:'CurrencySymbolicCode'()) -> dmsl_domain_thrift:'WalletAccount'().
construct_wallet_account(CurrencyCode) ->
    ok = pm_context:save(pm_context:create()),
    Settlement = pm_accounting:create_account(CurrencyCode),
    _ = pm_context:cleanup(),
    #domain_WalletAccount{
        currency = ?cur(CurrencyCode),
        settlement = Settlement
    }.

-spec construct_wallet(
    dmsl_domain_thrift:'WalletConfigRef'(),
    dmsl_domain_thrift:'PaymentInstitutionRef'(),
    dmsl_domain_thrift:'TermSetHierarchyRef'(),
    dmsl_domain_thrift:'WalletAccount'(),
    dmsl_domain_thrift:'PartyConfigRef'()
) -> {wallet_config, dmsl_domain_thrift:'WalletConfigObject'()}.
construct_wallet(WalletRef, PaymentInstitutionRef, TermSetHierarchyRef, WalletAccount, PartyRef) ->
    {wallet_config, #domain_WalletConfigObject{
        ref = WalletRef,
        data = #domain_WalletConfig{
            name = WalletRef#domain_WalletConfigRef.id,
            block = make_unblocked(),
            suspension = make_active(),
            payment_institution = PaymentInstitutionRef,
            terms = TermSetHierarchyRef,
            account = WalletAccount,
            party_ref = PartyRef
        }
    }}.

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

-spec construct_category(category(), name()) -> {category, dmsl_domain_thrift:'CategoryObject'()}.
construct_category(Ref, Name) ->
    construct_category(Ref, Name, test).

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

-spec construct_payment_method(dmsl_domain_thrift:'PaymentMethodRef'()) ->
    {payment_method, dmsl_domain_thrift:'PaymentMethodObject'()}.
construct_payment_method(?pmt(generic, ?gnrc(?pmt_srv(Name))) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(mobile, ?mob(Name)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(_, ?pmt_srv(Name)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(crypto_currency, ?crypta(Name)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(bank_card, ?token_bank_card(Name, _)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(bank_card, ?bank_card(Name)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(_Type, #domain_BankCardPaymentMethod{} = Card) = Ref) ->
    construct_payment_method(Card#domain_BankCardPaymentMethod.payment_system, Ref).

construct_payment_method(Name, Ref) when is_atom(Name) ->
    construct_payment_method(atom_to_binary(Name, unicode), Ref);
construct_payment_method(Name, Ref) when is_binary(Name) ->
    {payment_method, #domain_PaymentMethodObject{
        ref = Ref,
        data = #domain_PaymentMethodDefinition{
            name = Name,
            description = Name
        }
    }}.

-spec construct_payment_system(payment_system(), name()) ->
    {payment_system, dmsl_domain_thrift:'PaymentSystemObject'()}.
construct_payment_system(Ref, Name) ->
    {payment_system, #domain_PaymentSystemObject{
        ref = Ref,
        data = #domain_PaymentSystem{
            name = Name
        }
    }}.

-spec construct_mobile_operator(mobile_operator(), name()) ->
    {mobile_operator, dmsl_domain_thrift:'MobileOperatorObject'()}.
construct_mobile_operator(Ref, Name) ->
    {mobile_operator, #domain_MobileOperatorObject{
        ref = Ref,
        data = #domain_MobileOperator{
            name = Name
        }
    }}.

-spec construct_payment_service(payment_service(), name()) ->
    {payment_service, dmsl_domain_thrift:'PaymentServiceObject'()}.
construct_payment_service(Ref, Name) ->
    {payment_service, #domain_PaymentServiceObject{
        ref = Ref,
        data = #domain_PaymentService{
            name = Name
        }
    }}.

-spec construct_crypto_currency(crypto_currency(), name()) ->
    {crypto_currency, dmsl_domain_thrift:'CryptoCurrencyObject'()}.
construct_crypto_currency(Ref, Name) ->
    {crypto_currency, #domain_CryptoCurrencyObject{
        ref = Ref,
        data = #domain_CryptoCurrency{
            name = Name
        }
    }}.

-spec construct_tokenized_service(tokenized_service(), name()) ->
    {payment_token, dmsl_domain_thrift:'BankCardTokenServiceObject'()}.
construct_tokenized_service(Ref, Name) ->
    {payment_token, #domain_BankCardTokenServiceObject{
        ref = Ref,
        data = #domain_BankCardTokenService{
            name = Name
        }
    }}.

-spec construct_proxy(proxy(), name()) -> {proxy, dmsl_domain_thrift:'ProxyObject'()}.
construct_proxy(Ref, Name) ->
    construct_proxy(Ref, Name, <<>>, #{}).

-spec construct_proxy(proxy(), name(), binary(), Opts :: map()) -> {proxy, dmsl_domain_thrift:'ProxyObject'()}.
construct_proxy(Ref, Name, Url, Opts) ->
    {proxy, #domain_ProxyObject{
        ref = Ref,
        data = #domain_ProxyDefinition{
            name = Name,
            description = Name,
            url = Url,
            options = Opts
        }
    }}.

-spec construct_inspector(inspector(), name(), proxy()) -> {inspector, dmsl_domain_thrift:'InspectorObject'()}.
construct_inspector(Ref, Name, ProxyRef) ->
    construct_inspector(Ref, Name, ProxyRef, #{}).

-spec construct_inspector(inspector(), name(), proxy(), Additional :: map()) ->
    {inspector, dmsl_domain_thrift:'InspectorObject'()}.
construct_inspector(Ref, Name, ProxyRef, Additional) ->
    construct_inspector(Ref, Name, ProxyRef, Additional, undefined).

-spec construct_inspector(inspector(), name(), proxy(), Additional :: map(), undefined | risk_score()) ->
    {inspector, dmsl_domain_thrift:'InspectorObject'()}.
construct_inspector(Ref, Name, ProxyRef, Additional, FallBackScore) ->
    {inspector, #domain_InspectorObject{
        ref = Ref,
        data = #domain_Inspector{
            name = Name,
            description = Name,
            proxy = #domain_Proxy{
                ref = ProxyRef,
                additional = Additional
            },
            fallback_risk_score = FallBackScore
        }
    }}.

-spec construct_provider_account_set([currency()]) -> dmsl_domain_thrift:'ProviderAccountSet'().
construct_provider_account_set(Currencies) ->
    ok = pm_context:save(pm_context:create()),
    AccountSet = lists:foldl(
        fun(Cur = ?cur(Code), Acc) ->
            Acc#{Cur => ?prvacc(pm_accounting:create_account(Code))}
        end,
        #{},
        Currencies
    ),
    _ = pm_context:cleanup(),
    AccountSet.

-spec construct_system_account_set(system_account_set()) ->
    {system_account_set, dmsl_domain_thrift:'SystemAccountSetObject'()}.
construct_system_account_set(Ref) ->
    construct_system_account_set(Ref, <<"Primaries">>, ?cur(<<"RUB">>)).

-spec construct_system_account_set(system_account_set(), name(), currency()) ->
    {system_account_set, dmsl_domain_thrift:'SystemAccountSetObject'()}.
construct_system_account_set(Ref, Name, ?cur(CurrencyCode)) ->
    ok = pm_context:save(pm_context:create()),
    SettlementAccountID = pm_accounting:create_account(CurrencyCode),
    SubagentAccountID = pm_accounting:create_account(CurrencyCode),
    pm_context:cleanup(),
    {system_account_set, #domain_SystemAccountSetObject{
        ref = Ref,
        data = #domain_SystemAccountSet{
            name = Name,
            description = Name,
            accounts = #{
                ?cur(CurrencyCode) => #domain_SystemAccount{
                    settlement = SettlementAccountID,
                    subagent = SubagentAccountID
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
    ok = pm_context:save(pm_context:create()),
    AccountID1 = pm_accounting:create_account(CurrencyCode),
    AccountID2 = pm_accounting:create_account(CurrencyCode),
    pm_context:cleanup(),
    {external_account_set, #domain_ExternalAccountSetObject{
        ref = Ref,
        data = #domain_ExternalAccountSet{
            name = Name,
            description = Name,
            accounts = #{
                ?cur(<<"RUB">>) => #domain_ExternalAccount{
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
            schedule = #'base_Schedule'{
                year = ?EVERY,
                month = ?EVERY,
                day_of_month = ?EVERY,
                day_of_week = ?EVERY,
                hour = {on, [7]},
                minute = {on, [40]},
                second = {on, [0]}
            }
        }
    }}.

-spec construct_criterion(criterion(), name(), predicate()) -> {criterion, dmsl_domain_thrift:'CriterionObject'()}.
construct_criterion(Ref, Name, Pred) ->
    {criterion, #domain_CriterionObject{
        ref = Ref,
        data = #domain_Criterion{
            name = Name,
            predicate = Pred
        }
    }}.

-spec construct_term_set_hierarchy(term_set_hierarchy(), undefined | term_set_hierarchy(), term_set()) ->
    {term_set_hierarchy, dmsl_domain_thrift:'TermSetHierarchyObject'()}.
construct_term_set_hierarchy(Ref, ParentRef, TermSet) ->
    {term_set_hierarchy, #domain_TermSetHierarchyObject{
        ref = Ref,
        data = #domain_TermSetHierarchy{
            parent_terms = ParentRef,
            term_set = TermSet
        }
    }}.

-spec construct_payment_routing_ruleset(payment_routing_ruleset(), name(), _) -> dmsl_domain_thrift:'DomainObject'().
construct_payment_routing_ruleset(Ref, Name, Decisions) ->
    {routing_rules, #domain_RoutingRulesObject{
        ref = Ref,
        data = #domain_RoutingRuleset{
            name = Name,
            decisions = Decisions
        }
    }}.

%%

make_unblocked() ->
    {unblocked, #domain_Unblocked{reason = ~"whatever reason", since = ~"1970-01-01T00:00:00Z"}}.

make_active() ->
    {active, #domain_Active{since = ~"1970-01-01T00:00:00Z"}}.
