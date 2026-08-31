-module(party_client_thrift).

-export([compute_provider/5]).
-export([compute_provider_terminal_terms/6]).
-export([compute_globals/4]).
-export([compute_routing_ruleset/5]).
-export([compute_payment_institution/5]).
-export([compute_terms/5]).

-export([get_account_state/5]).
-export([get_shop_account/5]).
-export([get_wallet_account/5]).

%% Domain types

-type party_id() :: dmsl_base_thrift:'ID'().
-type shop_id() :: dmsl_domain_thrift:'ShopID'().
-type wallet_id() :: dmsl_domain_thrift:'WalletID'().
-type account_id() :: dmsl_domain_thrift:'AccountID'().
-type account_state() :: dmsl_payproc_thrift:'AccountState'().
-type shop_account() :: dmsl_domain_thrift:'ShopAccount'().
-type wallet_account() :: dmsl_domain_thrift:'WalletAccount'().
-type timestamp() :: dmsl_base_thrift:'Timestamp'().
-type provider_ref() :: dmsl_domain_thrift:'ProviderRef'().
-type provider() :: dmsl_domain_thrift:'Provider'().
-type terminal_ref() :: dmsl_domain_thrift:'TerminalRef'().
-type provision_term_set() :: dmsl_domain_thrift:'ProvisionTermSet'().
-type globals_ref() :: dmsl_domain_thrift:'GlobalsRef'().
-type globals() :: dmsl_domain_thrift:'Globals'().
-type routing_ruleset_ref() :: dmsl_domain_thrift:'RoutingRulesetRef'().
-type routing_ruleset() :: dmsl_domain_thrift:'RoutingRuleset'().
-type payment_institution() :: dmsl_domain_thrift:'PaymentInstitution'().
-type payment_institution_ref() :: dmsl_domain_thrift:'PaymentInstitutionRef'().
-type term_set() :: dmsl_domain_thrift:'TermSet'().
-type termset_hierarchy_ref() :: dmsl_domain_thrift:'TermSetHierarchyRef'().
-type varset() :: dmsl_payproc_thrift:'Varset'().
-type terms() :: dmsl_domain_thrift:'TermSet'().
-type domain_revision() :: dmsl_domain_thrift:'DataRevision'().
-type final_cash_flow() :: dmsl_domain_thrift:'FinalCashFlow'().

-export_type([party_id/0]).
-export_type([shop_id/0]).
-export_type([account_id/0]).
-export_type([account_state/0]).
-export_type([shop_account/0]).
-export_type([timestamp/0]).
-export_type([provider_ref/0]).
-export_type([provider/0]).
-export_type([terminal_ref/0]).
-export_type([provision_term_set/0]).
-export_type([globals_ref/0]).
-export_type([globals/0]).
-export_type([routing_ruleset_ref/0]).
-export_type([routing_ruleset/0]).
-export_type([payment_institution_ref/0]).
-export_type([varset/0]).
-export_type([terms/0]).
-export_type([final_cash_flow/0]).

%% Error types

-type party_not_found() :: dmsl_payproc_thrift:'PartyNotFound'().
-type shop_not_found() :: dmsl_payproc_thrift:'ShopNotFound'().
-type shop_account_not_found() :: dmsl_payproc_thrift:'ShopAccountNotFound'().
-type wallet_not_found() :: dmsl_payproc_thrift:'ShopNotFound'().
-type wallet_account_not_found() :: dmsl_payproc_thrift:'WalletAccountNotFound'().
-type account_not_found() :: dmsl_payproc_thrift:'AccountNotFound'().
-type payment_institution_not_found() :: dmsl_payproc_thrift:'PaymentInstitutionNotFound'().
-type termset_hierarchy_not_found() :: dmsl_payproc_thrift:'TermSetHierarchyNotFound'().
-type provider_not_found() :: dmsl_payproc_thrift:'ProviderNotFound'().
-type terminal_not_found() :: dmsl_payproc_thrift:'TerminalNotFound'().
-type provision_term_set_undef() :: dmsl_payproc_thrift:'ProvisionTermSetUndefined'().
-type globals_not_found() :: dmsl_payproc_thrift:'GlobalsNotFound'().
-type ruleset_not_found() :: dmsl_payproc_thrift:'RuleSetNotFound'().

%% Client types

-type context() :: party_client_context:context().
-type client() :: party_client_config:client().

-export_type([context/0]).
-export_type([client/0]).

%% Internal types

-type error(Error) :: party_not_found() | Error.

-type result(Success, Error) :: {ok, Success} | {error, error(Error)}.

%% Party API

-spec compute_provider(Ref, DomainRevision, Varset, client(), context()) -> result(provider(), Error) when
    Ref :: provider_ref(),
    DomainRevision :: domain_revision(),
    Varset :: varset(),
    Error :: provider_not_found().
compute_provider(Ref, DomainRevision, Varset, Client, Context) ->
    call('ComputeProvider', [Ref, DomainRevision, Varset], Client, Context).

-spec compute_provider_terminal_terms(Ref, TerminalRef, DomainRevision, Varset, client(), context()) ->
    result(provision_term_set(), Error)
when
    Ref :: provider_ref(),
    TerminalRef :: terminal_ref(),
    DomainRevision :: domain_revision(),
    Varset :: varset(),
    Error :: provider_not_found() | terminal_not_found() | provision_term_set_undef().
compute_provider_terminal_terms(Ref, TerminalRef, DomainRevision, Varset, Client, Context) ->
    call('ComputeProviderTerminalTerms', [Ref, TerminalRef, DomainRevision, Varset], Client, Context).

-spec compute_globals(DomainRevision, Varset, client(), context()) -> result(globals(), Error) when
    DomainRevision :: domain_revision(),
    Varset :: varset(),
    Error :: globals_not_found().
compute_globals(DomainRevision, Varset, Client, Context) ->
    call('ComputeGlobals', [DomainRevision, Varset], Client, Context).

-spec compute_routing_ruleset(Ref, DomainRevision, Varset, client(), context()) -> result(routing_ruleset(), Error) when
    Ref :: routing_ruleset_ref(),
    DomainRevision :: domain_revision(),
    Varset :: varset(),
    Error :: ruleset_not_found().
compute_routing_ruleset(Ref, DomainRevision, Varset, Client, Context) ->
    call('ComputeRoutingRuleset', [Ref, DomainRevision, Varset], Client, Context).

-spec compute_payment_institution(Ref, DomainRevision, Varset, client(), context()) ->
    result(payment_institution(), Error)
when
    Ref :: payment_institution_ref(),
    DomainRevision :: domain_revision(),
    Varset :: varset(),
    Error :: payment_institution_not_found().
compute_payment_institution(Ref, DomainRevision, Varset, Client, Context) ->
    call('ComputePaymentInstitution', [Ref, DomainRevision, Varset], Client, Context).

-spec compute_terms(Ref, DomainRevision, Varset, client(), context()) ->
    result(term_set(), Error)
when
    Ref :: termset_hierarchy_ref(),
    DomainRevision :: domain_revision(),
    Varset :: varset(),
    Error :: termset_hierarchy_not_found().
compute_terms(Ref, DomainRevision, Varset, Client, Context) ->
    call('ComputeTerms', [Ref, DomainRevision, Varset], Client, Context).

-spec get_account_state(party_id(), account_id(), domain_revision(), client(), context()) ->
    result(account_state(), Error)
when
    Error :: account_not_found().
get_account_state(PartyID, AccountID, DomainRevision, Client, Context) ->
    call('GetAccountState', [PartyID, AccountID, DomainRevision], Client, Context).

-spec get_shop_account(party_id(), shop_id(), domain_revision(), client(), context()) ->
    result(shop_account(), Error)
when
    Error :: shop_not_found() | shop_account_not_found().
get_shop_account(PartyID, ShopID, DomainRevision, Client, Context) ->
    call('GetShopAccount', [PartyID, ShopID, DomainRevision], Client, Context).

-spec get_wallet_account(party_id(), wallet_id(), domain_revision(), client(), context()) ->
    result(wallet_account(), Error)
when
    Error :: wallet_not_found() | wallet_account_not_found().
get_wallet_account(PartyID, WalletID, DomainRevision, Client, Context) ->
    call('GetWalletAccount', [PartyID, WalletID, DomainRevision], Client, Context).

%% Internal functions

call(Function, Args, Client, Context) ->
    party_client_woody:call(Function, erlang:list_to_tuple(Args), Client, Context).
