-module(party_client_thrift).

-export([create/4]).
-export([get/3]).
-export([get_revision/3]).
-export([checkout/4]).
-export([block/4]).
-export([unblock/4]).
-export([suspend/3]).
-export([activate/3]).

-export([get_meta/3]).
-export([get_metadata/4]).
-export([set_metadata/5]).
-export([remove_metadata/4]).

-export([get_contract/4]).
-export([compute_contract_terms/8]).
-export([get_shop/4]).
-export([get_shop_contract/4]).
-export([compute_shop_terms/7]).
-export([compute_provider/5]).
-export([compute_provider_terminal_terms/6]).
-export([compute_globals/4]).
-export([compute_routing_ruleset/5]).
-export([compute_payment_institution_terms/4]).
-export([compute_payment_institution/5]).

-export([block_shop/5]).
-export([unblock_shop/5]).
-export([suspend_shop/4]).
-export([activate_shop/4]).

-export([get_claim/4]).
-export([get_claims/3]).
-export([create_claim/4]).
-export([update_claim/6]).
-export([accept_claim/5]).
-export([deny_claim/6]).
-export([revoke_claim/6]).

-export([get_account_state/4]).
-export([get_shop_account/4]).
-export([get_events/4]).

%% Domain types

-type party() :: dmsl_domain_thrift:'Party'().
-type party_id() :: dmsl_domain_thrift:'PartyID'().
-type party_params() :: dmsl_payproc_thrift:'PartyParams'().
-type party_revision() :: dmsl_domain_thrift:'PartyRevision'().
-type contract_id() :: dmsl_domain_thrift:'ContractID'().
-type contract() :: dmsl_domain_thrift:'Contract'().
-type shop_id() :: dmsl_domain_thrift:'ShopID'().
-type shop() :: dmsl_domain_thrift:'Shop'().
-type shop_contract() :: dmsl_payproc_thrift:'ShopContract'().
-type claim_id() :: dmsl_payproc_thrift:'ClaimID'().
-type claim() :: dmsl_payproc_thrift:'Claim'().
-type claim_revision() :: dmsl_payproc_thrift:'ClaimRevision'().
-type changeset() :: dmsl_payproc_thrift:'PartyChangeset'().
-type account_id() :: dmsl_domain_thrift:'AccountID'().
-type account_state() :: dmsl_payproc_thrift:'AccountState'().
-type shop_account() :: dmsl_domain_thrift:'ShopAccount'().
-type meta() :: dmsl_domain_thrift:'PartyMeta'().
-type meta_ns() :: dmsl_domain_thrift:'PartyMetaNamespace'().
-type meta_data() :: dmsl_domain_thrift:'PartyMetaData'().
-type timestamp() :: dmsl_base_thrift:'Timestamp'().
-type party_revision_param() :: dmsl_payproc_thrift:'PartyRevisionParam'().
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
-type varset() :: dmsl_payproc_thrift:'Varset'().
-type contract_terms_varset() :: dmsl_payproc_thrift:'ComputeContractTermsVarset'().
-type shop_terms_varset() :: dmsl_payproc_thrift:'ComputeShopTermsVarset'().
-type terms() :: dmsl_domain_thrift:'TermSet'().
-type domain_revision() :: dmsl_domain_thrift:'DataRevision'().
-type final_cash_flow() :: dmsl_domain_thrift:'FinalCashFlow'().
-type event_range() :: dmsl_payproc_thrift:'EventRange'().
-type block_reason() :: binary().
-type unblock_reason() :: binary().
-type deny_reason() :: binary() | undefined.
-type revoke_reason() :: binary() | undefined.

-export_type([party/0]).
-export_type([party_id/0]).
-export_type([party_params/0]).
-export_type([party_revision/0]).
-export_type([contract_id/0]).
-export_type([contract/0]).
-export_type([shop_id/0]).
-export_type([claim_id/0]).
-export_type([claim/0]).
-export_type([claim_revision/0]).
-export_type([changeset/0]).
-export_type([account_id/0]).
-export_type([account_state/0]).
-export_type([shop_account/0]).
-export_type([meta/0]).
-export_type([meta_ns/0]).
-export_type([meta_data/0]).
-export_type([timestamp/0]).
-export_type([party_revision_param/0]).
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
-export_type([event_range/0]).
-export_type([block_reason/0]).
-export_type([unblock_reason/0]).
-export_type([deny_reason/0]).
-export_type([revoke_reason/0]).

%% Error types

-type party_exists() :: dmsl_payproc_thrift:'PartyExists'().
-type party_not_exists_yet() :: dmsl_payproc_thrift:'PartyNotExistsYet'().
-type party_not_found() :: dmsl_payproc_thrift:'PartyNotFound'().
-type invalid_party_revision() :: dmsl_payproc_thrift:'InvalidPartyRevision'().
-type invalid_party_status() :: dmsl_payproc_thrift:'InvalidPartyStatus'().
-type meta_ns_not_found() :: dmsl_payproc_thrift:'PartyMetaNamespaceNotFound'().
-type contract_not_found() :: dmsl_payproc_thrift:'ContractNotFound'().
-type shop_not_found() :: dmsl_payproc_thrift:'ShopNotFound'().
-type invalid_shop_status() :: dmsl_payproc_thrift:'InvalidShopStatus'().
-type changeset_conflict() :: dmsl_payproc_thrift:'ChangesetConflict'().
-type invalid_changeset() :: dmsl_payproc_thrift:'InvalidChangeset'().
-type claim_not_found() :: dmsl_payproc_thrift:'ClaimNotFound'().
-type invalid_claim_status() :: dmsl_payproc_thrift:'InvalidClaimStatus'().
-type invalid_claim_revision() :: dmsl_payproc_thrift:'InvalidClaimRevision'().
-type shop_account_not_found() :: dmsl_payproc_thrift:'ShopAccountNotFound'().
-type account_not_found() :: dmsl_payproc_thrift:'AccountNotFound'().
-type payment_institution_not_found() :: dmsl_payproc_thrift:'PaymentInstitutionNotFound'().
-type event_not_found() :: dmsl_payproc_thrift:'EventNotFound'().
-type invalid_request() :: dmsl_base_thrift:'InvalidRequest'().
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
-type void(Error) :: ok | {error, error(Error)}.

-type result(Success) :: {ok, Success} | {error, error(none())} | no_return().
-type void() :: ok | {error, error(none())} | no_return().

-type event() :: tuple().
-type events() :: [event()].

%% Party API

-spec create(party_id(), party_params(), client(), context()) -> ok | {error, error(Error)} | no_return() when
    Error :: party_exists().
create(PartyId, PartyParams, Client, Context) ->
    call('Create', [PartyId, PartyParams], Client, Context).

-spec get(party_id(), client(), context()) -> result(party()).
get(PartyId, Client, Context) ->
    case get_revision(PartyId, Client, Context) of
        {ok, Revision} ->
            call('Checkout', [PartyId, {revision, Revision}], Client, Context);
        Error ->
            Error
    end.

-spec get_revision(party_id(), client(), context()) -> result(party_revision()).
get_revision(PartyId, Client, Context) ->
    call('GetRevision', [PartyId], Client, Context).

-spec checkout(party_id(), party_revision_param(), client(), context()) -> result(party(), invalid_party_revision()).
checkout(PartyId, PartyRevisionParam, Client, Context) ->
    call('Checkout', [PartyId, PartyRevisionParam], Client, Context).

-spec block(party_id(), unblock_reason(), client(), context()) -> void(Error) when Error :: invalid_party_status().
block(PartyId, Reason, Client, Context) ->
    call('Block', [PartyId, Reason], Client, Context).

-spec unblock(party_id(), block_reason(), client(), context()) -> void(Error) when Error :: invalid_party_status().
unblock(PartyId, Reason, Client, Context) ->
    call('Unblock', [PartyId, Reason], Client, Context).

-spec suspend(party_id(), client(), context()) -> void(Error) when Error :: invalid_party_status().
suspend(PartyId, Client, Context) ->
    call('Suspend', [PartyId], Client, Context).

-spec activate(party_id(), client(), context()) -> void(Error) when Error :: invalid_party_status().
activate(PartyId, Client, Context) ->
    call('Activate', [PartyId], Client, Context).

-spec get_meta(party_id(), client(), context()) -> result(meta()).
get_meta(PartyId, Client, Context) ->
    call('GetMeta', [PartyId], Client, Context).

-spec get_metadata(party_id(), meta_ns(), client(), context()) -> result(meta_data(), Error) when
    Error :: meta_ns_not_found().
get_metadata(PartyId, Ns, Client, Context) ->
    call('GetMetaData', [PartyId, Ns], Client, Context).

-spec set_metadata(party_id(), meta_ns(), meta_data(), client(), context()) -> void().
set_metadata(PartyId, Ns, Data, Client, Context) ->
    call('SetMetaData', [PartyId, Ns, Data], Client, Context).

-spec remove_metadata(party_id(), meta_ns(), client(), context()) -> void(Error) when Error :: meta_ns_not_found().
remove_metadata(PartyId, Ns, Client, Context) ->
    call('RemoveMetaData', [PartyId, Ns], Client, Context).

-spec get_contract(party_id(), contract_id(), client(), context()) -> result(contract(), Error) when
    Error :: contract_not_found().
get_contract(PartyId, ContractID, Client, Context) ->
    call('GetContract', [PartyId, ContractID], Client, Context).

-spec compute_contract_terms(ID, ContractID, TS, Revision, Domain, VS, client(), context()) ->
    result(terms(), Error)
when
    ID :: party_id(),
    ContractID :: contract_id(),
    TS :: timestamp(),
    Revision :: party_revision_param(),
    Domain :: domain_revision(),
    VS :: contract_terms_varset(),
    Error :: party_not_exists_yet() | contract_not_found().
compute_contract_terms(PartyId, ContractID, Timestamp, PartyRevision, DomainRevision, Varset, Client, Context) ->
    Args = [PartyId, ContractID, Timestamp, PartyRevision, DomainRevision, Varset],
    call('ComputeContractTerms', Args, Client, Context).

-spec compute_provider(Ref, Domain, Varset, client(), context()) -> result(provider(), Error) when
    Ref :: provider_ref(),
    Domain :: domain_revision(),
    Varset :: varset(),
    Error :: provider_not_found().
compute_provider(Ref, Domain, Varset, Client, Context) ->
    call('ComputeProvider', [Ref, Domain, Varset], Client, Context).

-spec compute_provider_terminal_terms(Ref, TerminalRef, Domain, Varset, client(), context()) ->
    result(provision_term_set(), Error)
when
    Ref :: provider_ref(),
    TerminalRef :: terminal_ref(),
    Domain :: domain_revision(),
    Varset :: varset(),
    Error :: provider_not_found() | terminal_not_found() | provision_term_set_undef().
compute_provider_terminal_terms(Ref, TerminalRef, Domain, Varset, Client, Context) ->
    call('ComputeProviderTerminalTerms', [Ref, TerminalRef, Domain, Varset], Client, Context).

-spec compute_globals(Domain, Varset, client(), context()) -> result(globals(), Error) when
    Domain :: domain_revision(),
    Varset :: varset(),
    Error :: globals_not_found().
compute_globals(Domain, Varset, Client, Context) ->
    call('ComputeGlobals', [Domain, Varset], Client, Context).

-spec compute_routing_ruleset(Ref, Domain, Varset, client(), context()) -> result(routing_ruleset(), Error) when
    Ref :: routing_ruleset_ref(),
    Domain :: domain_revision(),
    Varset :: varset(),
    Error :: ruleset_not_found().
compute_routing_ruleset(Ref, Domain, Varset, Client, Context) ->
    call('ComputeRoutingRuleset', [Ref, Domain, Varset], Client, Context).

-spec compute_payment_institution_terms(payment_institution_ref(), varset(), client(), context()) ->
    result(terms(), Error)
when
    Error :: payment_institution_not_found().
compute_payment_institution_terms(Ref, Varset, Client, Context) ->
    call('ComputePaymentInstitutionTerms', [Ref, Varset], Client, Context).

-spec compute_payment_institution(Ref, Domain, Varset, client(), context()) -> result(payment_institution(), Error) when
    Ref :: payment_institution_ref(),
    Domain :: domain_revision(),
    Varset :: varset(),
    Error :: payment_institution_not_found().
compute_payment_institution(Ref, Domain, Varset, Client, Context) ->
    call('ComputePaymentInstitution', [Ref, Domain, Varset], Client, Context).

-spec get_shop(party_id(), shop_id(), client(), context()) -> result(shop(), Error) when
    Error :: party_not_found() | shop_not_found().
get_shop(PartyId, ShopID, Client, Context) ->
    call('GetShop', [PartyId, ShopID], Client, Context).

-spec get_shop_contract(party_id(), shop_id(), client(), context()) -> result(shop_contract(), Error) when
    Error :: party_not_found() | shop_not_found() | contract_not_found().
get_shop_contract(PartyId, ShopID, Client, Context) ->
    call('GetShopContract', [PartyId, ShopID], Client, Context).

-spec block_shop(party_id(), shop_id(), block_reason(), client(), context()) -> void(Error) when
    Error :: shop_not_found() | invalid_shop_status().
block_shop(PartyId, ShopID, Reason, Client, Context) ->
    call('BlockShop', [PartyId, ShopID, Reason], Client, Context).

-spec unblock_shop(party_id(), shop_id(), unblock_reason(), client(), context()) -> void(Error) when
    Error :: shop_not_found() | invalid_shop_status().
unblock_shop(PartyId, ShopID, Reason, Client, Context) ->
    call('UnblockShop', [PartyId, ShopID, Reason], Client, Context).

-spec suspend_shop(party_id(), shop_id(), client(), context()) -> void(Error) when
    Error :: shop_not_found() | invalid_shop_status().
suspend_shop(PartyId, ShopID, Client, Context) ->
    call('SuspendShop', [PartyId, ShopID], Client, Context).

-spec activate_shop(party_id(), shop_id(), client(), context()) -> void(Error) when
    Error :: shop_not_found() | invalid_shop_status().
activate_shop(PartyId, ShopID, Client, Context) ->
    call('ActivateShop', [PartyId, ShopID], Client, Context).

-spec compute_shop_terms(
    party_id(),
    shop_id(),
    timestamp(),
    party_revision_param(),
    shop_terms_varset(),
    client(),
    context()
) -> result(terms(), Error) when
    Error :: shop_not_found() | invalid_shop_status() | party_not_exists_yet().
compute_shop_terms(PartyId, ShopID, Timestamp, PartyRevision, Varset, Client, Context) ->
    call('ComputeShopTerms', [PartyId, ShopID, Timestamp, PartyRevision, Varset], Client, Context).

-spec get_claim(party_id(), claim_id(), client(), context()) -> result(claim(), Error) when Error :: claim_not_found().
get_claim(PartyId, ClaimId, Client, Context) ->
    call('GetClaim', [PartyId, ClaimId], Client, Context).

-spec get_claims(party_id(), client(), context()) -> result([claim()]).
get_claims(PartyId, Client, Context) ->
    call('GetClaims', [PartyId], Client, Context).

-spec create_claim(party_id(), changeset(), client(), context()) -> result(claim(), Error) when
    Error :: invalid_party_status() | changeset_conflict() | invalid_changeset() | invalid_request().
create_claim(PartyId, Changeset, Client, Context) ->
    call('CreateClaim', [PartyId, Changeset], Client, Context).

-spec update_claim(party_id(), claim_id(), claim_revision(), changeset(), client(), context()) -> void(Error) when
    Error ::
        invalid_party_status()
        | changeset_conflict()
        | invalid_changeset()
        | invalid_request()
        | claim_not_found()
        | invalid_claim_status()
        | invalid_claim_revision().
update_claim(PartyId, ClaimId, Revision, Changeset, Client, Context) ->
    call('UpdateClaim', [PartyId, ClaimId, Revision, Changeset], Client, Context).

-spec accept_claim(party_id(), claim_id(), claim_revision(), client(), context()) -> void(Error) when
    Error :: claim_not_found() | invalid_changeset() | invalid_claim_revision() | invalid_claim_status().
accept_claim(PartyId, ClaimId, Revision, Client, Context) ->
    call('AcceptClaim', [PartyId, ClaimId, Revision], Client, Context).

-spec deny_claim(party_id(), claim_id(), claim_revision(), deny_reason(), client(), context()) -> void(Error) when
    Error :: claim_not_found() | invalid_claim_revision() | invalid_claim_status().
deny_claim(PartyId, ClaimId, Revision, Reason, Client, Context) ->
    call('DenyClaim', [PartyId, ClaimId, Revision, Reason], Client, Context).

-spec revoke_claim(party_id(), claim_id(), claim_revision(), revoke_reason(), client(), context()) -> void(Error) when
    Error :: invalid_party_status() | claim_not_found() | invalid_claim_revision() | invalid_claim_status().
revoke_claim(PartyId, ClaimId, Revision, Reason, Client, Context) ->
    call('RevokeClaim', [PartyId, ClaimId, Revision, Reason], Client, Context).

-spec get_account_state(party_id(), account_id(), client(), context()) -> result(account_state(), Error) when
    Error :: account_not_found().
get_account_state(PartyId, AccountID, Client, Context) ->
    call('GetAccountState', [PartyId, AccountID], Client, Context).

-spec get_shop_account(party_id(), shop_id(), client(), context()) -> result(shop_account(), Error) when
    Error :: shop_account_not_found() | shop_account_not_found().
get_shop_account(PartyId, ShopID, Client, Context) ->
    call('GetShopAccount', [PartyId, ShopID], Client, Context).

-spec get_events(party_id(), event_range(), client(), context()) -> result(events(), Error) when
    Error :: event_not_found() | invalid_request().
get_events(PartyId, Range, Client, Context) ->
    call('GetEvents', [PartyId, Range], Client, Context).

%% Internal functions

call(Function, Args, Client, Context) ->
    party_client_woody:call(Function, erlang:list_to_tuple(Args), Client, Context).
