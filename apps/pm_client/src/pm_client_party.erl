-module(pm_client_party).

-export([start/2]).
-export([stop/1]).

-export([compute_terms/4]).
-export([compute_payment_institution/4]).

-export([get_shop_account_simple/2]).
-export([get_wallet_account_simple/2]).
-export([get_account_state_simple/2]).
-export([get_shop_account/3]).
-export([get_wallet_account/3]).
-export([get_account_state/3]).

-export([compute_provider/4]).
-export([compute_provider_terminal/4]).
-export([compute_provider_terminal_terms/5]).
-export([compute_globals/3]).
-export([compute_routing_ruleset/4]).

%% GenServer

-behaviour(gen_server).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).

%%

-type party_ref() :: dmsl_domain_thrift:'PartyConfigRef'().
-type domain_revision() :: dmsl_domain_thrift:'DataRevision'().
-type shop_ref() :: dmsl_domain_thrift:'ShopConfigRef'().
-type wallet_ref() :: dmsl_domain_thrift:'WalletConfigRef'().
-type shop_account_id() :: dmsl_domain_thrift:'AccountID'().

-type termset_hierarchy_ref() :: dmsl_domain_thrift:'TermSetHierarchyRef'().
-type payment_intitution_ref() :: dmsl_domain_thrift:'PaymentInstitutionRef'().
-type varset() :: dmsl_payproc_thrift:'Varset'().

-type provider_ref() :: dmsl_domain_thrift:'ProviderRef'().
-type terminal_ref() :: dmsl_domain_thrift:'TerminalRef'().
-type routing_ruleset_ref() :: dmsl_domain_thrift:'RoutingRulesetRef'().

-spec start(party_ref(), pm_client_api:t()) -> pid().
start(PartyRef, ApiClient) ->
    {ok, Pid} = gen_server:start(?MODULE, {PartyRef, ApiClient}, []),
    Pid.

-spec stop(pid()) -> ok.
stop(Client) ->
    _ = exit(Client, shutdown),
    ok.

%%

-spec compute_terms(termset_hierarchy_ref(), domain_revision(), varset(), pid()) ->
    dmsl_domain_thrift:'TermSet'() | woody_error:business_error().
compute_terms(Ref, DomainRevision, Varset, Client) ->
    call(Client, 'ComputeTerms', [Ref, DomainRevision, Varset]).

-spec compute_payment_institution(payment_intitution_ref(), domain_revision(), varset(), pid()) ->
    dmsl_domain_thrift:'PaymentInstitution'() | woody_error:business_error().
compute_payment_institution(Ref, DomainRevision, Varset, Client) ->
    call(Client, 'ComputePaymentInstitution', [Ref, DomainRevision, Varset]).

-spec get_account_state_simple(shop_account_id(), pid()) ->
    dmsl_payproc_thrift:'AccountState'() | woody_error:business_error().
get_account_state_simple(AccountID, Client) ->
    call(Client, 'GetAccountStateSimple', with_party_ref([AccountID])).

-spec get_account_state(shop_account_id(), domain_revision(), pid()) ->
    dmsl_payproc_thrift:'AccountState'() | woody_error:business_error().
get_account_state(AccountID, DomainRevision, Client) ->
    call(Client, 'GetAccountState', with_party_ref([AccountID, DomainRevision])).

-spec get_shop_account_simple(shop_ref(), pid()) ->
    dmsl_domain_thrift:'ShopAccount'() | woody_error:business_error().
get_shop_account_simple(ShopRef, Client) ->
    call(Client, 'GetShopAccountSimple', with_party_ref([ShopRef])).

-spec get_shop_account(shop_ref(), domain_revision(), pid()) ->
    dmsl_domain_thrift:'ShopAccount'() | woody_error:business_error().
get_shop_account(ShopRef, DomainRevision, Client) ->
    call(Client, 'GetShopAccount', with_party_ref([ShopRef, DomainRevision])).

-spec get_wallet_account_simple(wallet_ref(), pid()) ->
    dmsl_domain_thrift:'WalletAccount'() | woody_error:business_error().
get_wallet_account_simple(WalletRef, Client) ->
    call(Client, 'GetWalletAccountSimple', with_party_ref([WalletRef])).

-spec get_wallet_account(wallet_ref(), domain_revision(), pid()) ->
    dmsl_domain_thrift:'WalletAccount'() | woody_error:business_error().
get_wallet_account(WalletRef, DomainRevision, Client) ->
    call(Client, 'GetWalletAccount', with_party_ref([WalletRef, DomainRevision])).

-spec compute_provider(provider_ref(), domain_revision(), varset(), pid()) ->
    dmsl_domain_thrift:'Provider'() | woody_error:business_error().
compute_provider(ProviderRef, Revision, Varset, Client) ->
    call(Client, 'ComputeProvider', [ProviderRef, Revision, Varset]).

-spec compute_provider_terminal(
    terminal_ref(),
    domain_revision(),
    varset() | undefined,
    pid()
) -> dmsl_payproc_thrift:'ProviderTerminal'() | woody_error:business_error().
compute_provider_terminal(TerminalRef, Revision, Varset, Client) ->
    call(Client, 'ComputeProviderTerminal', [TerminalRef, Revision, Varset]).

-spec compute_provider_terminal_terms(
    provider_ref(),
    terminal_ref(),
    domain_revision(),
    varset(),
    pid()
) -> dmsl_domain_thrift:'ProvisionTermSet'() | woody_error:business_error().
compute_provider_terminal_terms(ProviderRef, TerminalRef, Revision, Varset, Client) ->
    Args = [ProviderRef, TerminalRef, Revision, Varset],
    call(Client, 'ComputeProviderTerminalTerms', Args).

-spec compute_globals(domain_revision(), varset(), pid()) ->
    dmsl_domain_thrift:'Globals'() | woody_error:business_error().
compute_globals(Revision, Varset, Client) ->
    call(Client, 'ComputeGlobals', [Revision, Varset]).

-spec compute_routing_ruleset(routing_ruleset_ref(), domain_revision(), varset(), pid()) ->
    dmsl_domain_thrift:'RoutingRuleset'() | woody_error:business_error().
compute_routing_ruleset(RoutingRuleSetRef, Revision, Varset, Client) ->
    call(Client, 'ComputeRoutingRuleset', [RoutingRuleSetRef, Revision, Varset]).

call(Client, Function, Args) ->
    map_result_error(gen_server:call(Client, {call, Function, Args})).

map_result_error({ok, Result}) ->
    Result;
map_result_error({exception, _} = Exception) ->
    Exception;
map_result_error({error, Error}) ->
    error(Error).

%%

-record(state, {
    party_ref :: party_ref(),
    client :: pm_client_api:t()
}).

-type state() :: #state{}.
-type callref() :: {pid(), Tag :: reference()}.

-spec init({party_ref(), pm_client_api:t()}) -> {ok, state()}.
init({PartyRef, ApiClient}) ->
    {ok, #state{
        party_ref = PartyRef,
        client = ApiClient
    }}.

-spec handle_call(term(), callref(), state()) -> {reply, term(), state()} | {noreply, state()}.
handle_call({call, Function, ArgsIn}, _From, St = #state{client = Client}) ->
    Args = lists:map(
        fun
            (Fun) when is_function(Fun, 1) -> Fun(St);
            (Arg) -> Arg
        end,
        ArgsIn
    ),
    Result = pm_client_api:call(party_management, Function, Args, Client),
    {reply, Result, St};
handle_call(Call, _From, State) ->
    _ = logger:warning("unexpected call received: ~tp", [Call]),
    {noreply, State}.

-spec handle_cast(_, state()) -> {noreply, state()}.
handle_cast(Cast, State) ->
    _ = logger:warning("unexpected cast received: ~tp", [Cast]),
    {noreply, State}.

with_party_ref(Args) ->
    [fun(St) -> St#state.party_ref end | Args].
