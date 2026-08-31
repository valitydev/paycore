-module(pm_party_handler).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_conf_v2_thrift.hrl").

%% Woody handler called by pm_woody_wrapper

-behaviour(pm_woody_wrapper).

-export([handle_function/3]).

%%

-spec handle_function(woody:func(), woody:args(), pm_woody_wrapper:handler_opts()) -> term() | no_return().
handle_function(Func, Args, Opts) ->
    scoper:scope(partymgmt, fun() ->
        handle_function_(Func, Args, Opts)
    end).

-spec handle_function_(woody:func(), woody:args(), pm_woody_wrapper:handler_opts()) -> term() | no_return().
%% Accounts
handle_function_('GetShopAccountSimple', {PartyRef, ShopRef}, Opts) ->
    DomainRevision = dmt_client:get_latest_version(),
    handle_function('GetShopAccount', {PartyRef, ShopRef, DomainRevision}, Opts);
handle_function_('GetWalletAccountSimple', {PartyRef, WalletRef}, Opts) ->
    DomainRevision = dmt_client:get_latest_version(),
    handle_function_('GetWalletAccount', {PartyRef, WalletRef, DomainRevision}, Opts);
handle_function_('GetAccountStateSimple', {PartyRef, AccountID}, Opts) ->
    DomainRevision = dmt_client:get_latest_version(),
    handle_function_('GetAccountState', {PartyRef, AccountID, DomainRevision}, Opts);
handle_function_('GetShopAccount', {PartyRef, ShopRef, DomainRevision}, _Opts) ->
    _ = set_party_mgmt_meta(PartyRef),
    pm_party:get_shop_account(ShopRef, PartyRef, DomainRevision);
handle_function_('GetWalletAccount', {PartyRef, WalletRef, DomainRevision}, _Opts) ->
    _ = set_party_mgmt_meta(PartyRef),
    pm_party:get_wallet_account(WalletRef, PartyRef, DomainRevision);
handle_function_('GetAccountState', {PartyRef, AccountID, DomainRevision}, _Opts) ->
    _ = set_party_mgmt_meta(PartyRef),
    pm_party:get_account_state(AccountID, PartyRef, DomainRevision);
%% Providers
handle_function_('ComputeProvider', Args, _Opts) ->
    {ProviderRef, DomainRevision, Varset} = Args,
    Provider = get_provider(ProviderRef, DomainRevision),
    VS = pm_varset:decode_varset(Varset),
    ComputedProvider = pm_provider:reduce_provider(Provider, VS, DomainRevision),
    _ = assert_provider_reduced(ComputedProvider),
    ComputedProvider;
handle_function_('ComputeProviderTerminalTerms', Args, _Opts) ->
    {ProviderRef, TerminalRef, DomainRevision, Varset} = Args,
    Provider = get_provider(ProviderRef, DomainRevision),
    Terminal = get_terminal(TerminalRef, DomainRevision),
    VS = pm_varset:decode_varset(Varset),
    Terms = pm_provider:reduce_provider_terminal_terms(Provider, Terminal, VS, DomainRevision),
    _ = assert_provider_terms_reduced(Terms),
    Terms;
handle_function_('ComputeProviderTerminal', {TerminalRef, DomainRevision, VarsetIn}, _Opts) ->
    Terminal = get_terminal(TerminalRef, DomainRevision),
    ProviderRef = Terminal#domain_Terminal.provider_ref,
    Provider = get_provider(ProviderRef, DomainRevision),
    Proxy = pm_provider:compute_proxy(Provider, Terminal, DomainRevision),
    ComputedTerms = pm_maybe:apply(
        fun(Varset) ->
            VS = pm_varset:decode_varset(Varset),
            pm_provider:reduce_provider_terminal_terms(Provider, Terminal, VS, DomainRevision)
        end,
        VarsetIn
    ),
    #payproc_ProviderTerminal{
        ref = TerminalRef,
        name = Terminal#domain_Terminal.name,
        description = Terminal#domain_Terminal.description,
        proxy = Proxy,
        provider = #payproc_ProviderDetails{
            ref = ProviderRef,
            name = Provider#domain_Provider.name,
            description = Provider#domain_Provider.description
        },
        terms = ComputedTerms
    };
%% Globals
handle_function_('ComputeGlobals', Args, _Opts) ->
    {DomainRevision, Varset} = Args,
    Globals = get_globals(DomainRevision),
    VS = pm_varset:decode_varset(Varset),
    pm_globals:reduce_globals(Globals, VS, DomainRevision);
%% RuleSets
handle_function_('ComputeRoutingRuleset', Args, _Opts) ->
    {RuleSetRef, DomainRevision, Varset} = Args,
    RuleSet = get_payment_routing_ruleset(RuleSetRef, DomainRevision),
    VS = pm_varset:decode_varset(Varset),
    pm_ruleset:reduce_payment_routing_ruleset(RuleSet, VS, DomainRevision);
%% Payment Institutions
handle_function_('ComputePaymentInstitution', Args, _Opts) ->
    {PaymentInstitutionRef, DomainRevision, Varset} = Args,
    PaymentInstitution = get_payment_institution(PaymentInstitutionRef, DomainRevision),
    VS = pm_varset:decode_varset(Varset),
    pm_payment_institution:reduce_payment_institution(PaymentInstitution, VS, DomainRevision);
handle_function_('ComputeTerms', Args, _Opts) ->
    {Ref, Revision, Varset} = Args,
    VS = pm_varset:decode_varset(Varset),
    Terms = pm_party:get_term_set(Ref, Revision),
    pm_party:reduce_terms(Terms, VS, Revision).

%%

assert_provider_reduced(#domain_Provider{terms = Terms}) ->
    assert_provider_terms_reduced(Terms).

assert_provider_terms_reduced(#domain_ProvisionTermSet{}) ->
    ok;
assert_provider_terms_reduced(undefined) ->
    throw(#payproc_ProvisionTermSetUndefined{}).

set_party_mgmt_meta(#domain_PartyConfigRef{id = PartyID}) ->
    scoper:add_meta(#{party_id => PartyID});
set_party_mgmt_meta(_PartyRef) ->
    ok.

get_payment_institution(PaymentInstitutionRef, Revision) ->
    case pm_domain:find(Revision, {payment_institution, PaymentInstitutionRef}) of
        #domain_PaymentInstitution{} = P ->
            P;
        notfound ->
            throw(#payproc_PaymentInstitutionNotFound{})
    end.

get_provider(ProviderRef, DomainRevision) ->
    try
        pm_domain:get(DomainRevision, {provider, ProviderRef})
    catch
        error:{object_not_found, {DomainRevision, {provider, ProviderRef}}} ->
            throw(#payproc_ProviderNotFound{})
    end.

get_terminal(TerminalRef, DomainRevision) ->
    try
        pm_domain:get(DomainRevision, {terminal, TerminalRef})
    catch
        error:{object_not_found, {DomainRevision, {terminal, TerminalRef}}} ->
            throw(#payproc_TerminalNotFound{})
    end.

get_globals(DomainRevision) ->
    Globals = {globals, #domain_GlobalsRef{}},
    try
        pm_domain:get(DomainRevision, Globals)
    catch
        error:{object_not_found, {DomainRevision, Globals}} ->
            throw(#payproc_GlobalsNotFound{})
    end.

get_payment_routing_ruleset(RuleSetRef, DomainRevision) ->
    try
        pm_domain:get(DomainRevision, {routing_rules, RuleSetRef})
    catch
        error:{object_not_found, {DomainRevision, {routing_rules, RuleSetRef}}} ->
            throw(#payproc_RuleSetNotFound{})
    end.
