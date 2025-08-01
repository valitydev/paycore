-module(party_client_base_pm_tests_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include("party_domain_fixtures.hrl").

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([compute_provider_ok/1]).
-export([compute_provider_not_found/1]).
-export([compute_provider_terminal_terms_ok/1]).
-export([compute_provider_terminal_terms_not_found/1]).
-export([compute_globals_ok/1]).
-export([compute_routing_ruleset_ok/1]).
-export([compute_routing_ruleset_unreducable/1]).
-export([compute_routing_ruleset_not_found/1]).
-export([compute_terms_ok/1]).
-export([compute_terms_hierarchy_not_found/1]).

%% Internal types

-type test_entry() :: atom() | {group, atom()}.
-type group() :: {atom(), [Opts :: atom()], [test_entry()]}.
-type config() :: [{atom(), any()}].

-define(WRONG_DMT_OBJ_ID, 99999).

%% CT description

-spec all() -> [test_entry()].
all() ->
    [
        {group, party_management_api},
        {group, party_management_compute_api}
    ].

-spec groups() -> [group()].
groups() ->
    [
        {party_management_api, [parallel], [
            %% TODO Add shop, wallet and accounts test
        ]},
        {party_management_compute_api, [parallel], [
            compute_provider_ok,
            compute_provider_not_found,
            compute_provider_terminal_terms_ok,
            compute_provider_terminal_terms_not_found,
            compute_globals_ok,
            compute_routing_ruleset_ok,
            compute_routing_ruleset_unreducable,
            compute_routing_ruleset_not_found,
            compute_terms_ok,
            compute_terms_hierarchy_not_found
        ]}
    ].

-spec init_per_suite(config()) -> config().
init_per_suite(Config) ->
    % _ = dbg:tracer(),
    % _ = dbg:p(all, c),
    % _ = dbg:tpl({'scoper_woody_event_handler', 'handle_event', '_'}, x),
    AppConfig = [
        {dmt_client, [
            % milliseconds
            {cache_update_interval, 5000},
            {max_cache_size, #{
                elements => 1,
                % 2Kb
                memory => 2048
            }},
            {service_urls, #{
                'AuthorManagement' => <<"http://dmt:8022/v1/domain/author">>,
                'Repository' => <<"http://dmt:8022/v1/domain/repository">>,
                'RepositoryClient' => <<"http://dmt:8022/v1/domain/repository_client">>
            }}
        ]},
        {party_client, []}
    ],
    Apps = lists:flatten([genlib_app:start_application_with(A, C) || {A, C} <- AppConfig]),
    {ok, Revision} = init_domain(),
    Client = party_client:create_client(),
    {ok, ClientPid} = party_client:start_link(Client),
    true = erlang:unlink(ClientPid),
    [{apps, Apps}, {client, Client}, {client_pid, ClientPid}, {test_id, genlib:to_binary(Revision)} | Config].

-spec end_per_suite(config()) -> ok.
end_per_suite(C) ->
    true = erlang:exit(conf(client_pid, C), shutdown),
    genlib_app:stop_unload_applications(proplists:get_value(apps, C)).

-spec init_per_group(atom(), config()) -> config().
init_per_group(Group, Config) ->
    [{test_id, genlib:to_binary(Group)} | Config].

-spec end_per_group(atom(), config()) -> ok.
end_per_group(_Group, _Config) ->
    ok.

-spec init_per_testcase(atom(), config()) -> config().
init_per_testcase(Name, Config) ->
    [{test_id, genlib:to_binary(Name)} | Config].

-spec end_per_testcase(atom(), config()) -> ok.
end_per_testcase(_Name, _Config) ->
    ok.

%% Tests

-spec compute_provider_ok(config()) -> any().
compute_provider_ok(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    Varset = #payproc_Varset{
        currency = ?cur(<<"RUB">>)
    },
    CashFlow = make_test_cashflow(),
    {ok, #domain_Provider{
        terms = #domain_ProvisionTermSet{
            payments = #domain_PaymentsProvisionTerms{
                cash_flow = {value, [CashFlow]}
            },
            recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
                cash_value = {value, ?cash(1000, <<"RUB">>)}
            }
        }
    }} = party_client_thrift:compute_provider(?prv(1), DomainRevision, Varset, Client, Context).

-spec compute_provider_not_found(config()) -> any().
compute_provider_not_found(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    {error, #payproc_ProviderNotFound{}} =
        party_client_thrift:compute_provider(
            ?prv(2),
            DomainRevision,
            #payproc_Varset{},
            Client,
            Context
        ).

-spec compute_provider_terminal_terms_ok(config()) -> any().
compute_provider_terminal_terms_ok(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    Varset = #payproc_Varset{
        currency = ?cur(<<"RUB">>)
    },
    CashFlow = make_test_cashflow(),
    PaymentMethods = ?ordset([?pmt_bank_card(visa)]),
    {ok, #domain_ProvisionTermSet{
        payments = #domain_PaymentsProvisionTerms{
            cash_flow = {value, [CashFlow]},
            payment_methods = {value, PaymentMethods}
        }
    }} = party_client_thrift:compute_provider_terminal_terms(
        ?prv(1),
        ?trm(1),
        DomainRevision,
        Varset,
        Client,
        Context
    ).

-spec compute_provider_terminal_terms_not_found(config()) -> any().
compute_provider_terminal_terms_not_found(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    {error, #payproc_TerminalNotFound{}} =
        party_client_thrift:compute_provider_terminal_terms(
            ?prv(1),
            ?trm(?WRONG_DMT_OBJ_ID),
            DomainRevision,
            #payproc_Varset{},
            Client,
            Context
        ),
    {error, #payproc_ProviderNotFound{}} =
        party_client_thrift:compute_provider_terminal_terms(
            ?prv(2),
            ?trm(1),
            DomainRevision,
            #payproc_Varset{},
            Client,
            Context
        ),
    {error, #payproc_ProviderNotFound{}} =
        party_client_thrift:compute_provider_terminal_terms(
            ?prv(2),
            ?trm(?WRONG_DMT_OBJ_ID),
            DomainRevision,
            #payproc_Varset{},
            Client,
            Context
        ).

-spec compute_globals_ok(config()) -> any().
compute_globals_ok(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    Varset = #payproc_Varset{},
    {ok, #domain_Globals{
        external_account_set = {value, ?eas(1)}
    }} = party_client_thrift:compute_globals(DomainRevision, Varset, Client, Context).

-spec compute_routing_ruleset_ok(config()) -> any().
compute_routing_ruleset_ok(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    Varset = #payproc_Varset{
        party_id = <<"67890">>
    },
    {ok, #domain_RoutingRuleset{
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
    }} = party_client_thrift:compute_routing_ruleset(?ruleset(1), DomainRevision, Varset, Client, Context).

-spec compute_routing_ruleset_unreducable(config()) -> any().
compute_routing_ruleset_unreducable(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    Varset = #payproc_Varset{},
    {ok, #domain_RoutingRuleset{
        name = <<"Rule#1">>,
        decisions =
            {delegates, [
                #domain_RoutingDelegate{
                    allowed = {condition, {party, #domain_PartyCondition{id = <<"12345">>}}},
                    ruleset = ?ruleset(2)
                },
                #domain_RoutingDelegate{
                    allowed = {condition, {party, #domain_PartyCondition{id = <<"67890">>}}},
                    ruleset = ?ruleset(3)
                },
                #domain_RoutingDelegate{
                    allowed = {constant, true},
                    ruleset = ?ruleset(4)
                }
            ]}
    }} = party_client_thrift:compute_routing_ruleset(?ruleset(1), DomainRevision, Varset, Client, Context).

-spec compute_routing_ruleset_not_found(config()) -> any().
compute_routing_ruleset_not_found(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    {error, #payproc_RuleSetNotFound{}} =
        (catch party_client_thrift:compute_routing_ruleset(
            ?ruleset(5),
            DomainRevision,
            #payproc_Varset{},
            Client,
            Context
        )).

-spec compute_terms_hierarchy_not_found(config()) -> any().
compute_terms_hierarchy_not_found(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    ?assertMatch(
        {error, #payproc_TermSetHierarchyNotFound{}},
        party_client_thrift:compute_terms(?trms(42), DomainRevision, #payproc_Varset{}, Client, Context)
    ).

-spec compute_terms_ok(config()) -> any().
compute_terms_ok(C) ->
    {ok, _PartyId, Client, Context} = test_init_info(C),
    {ok, DomainRevision} = ensure_latest_version_checked_out(),
    Varset = #payproc_Varset{
        currency = ?cur(<<"RUB">>)
    },
    ?assertMatch(
        {ok, #domain_TermSet{
            payments = #domain_PaymentsServiceTerms{
                currencies = {value, _},
                categories = {value, _},
                payment_methods = {value, _},
                cash_limit = {value, _}
            }
        }},
        party_client_thrift:compute_terms(?trms(3), DomainRevision, Varset, Client, Context)
    ).

%% Internal functions

%% Environment confirators

-spec init_domain() -> {ok, integer()}.
init_domain() ->
    {ok, _} = ensure_latest_version_checked_out(),
    ok = party_domain_fixtures:cleanup(),
    {ok, _} = ensure_latest_version_checked_out(),
    ok = party_domain_fixtures:apply_domain_fixture(),
    {ok, _Revision} = ensure_latest_version_checked_out().

ensure_latest_version_checked_out() ->
    Version = dmt_client:get_latest_version(),
    %% NOTE This call updates local cache under with checked out objects of a version
    _ = dmt_client:checkout_all(Version),
    {ok, Version}.

%% Config helpers

-spec get_test_id(config()) -> binary().
get_test_id(Config) ->
    AllId = lists:reverse(proplists:append_values(test_id, Config)),
    erlang:iolist_to_binary([[<<".">> | I] || I <- AllId]).

conf(Key, Config) ->
    proplists:get_value(Key, Config).

%% Domain objects constructors

create_context() ->
    party_client:create_context().

test_init_info(C) ->
    PartyId = get_test_id(C),
    Client = conf(client, C),
    Context = create_context(),
    {ok, PartyId, Client, Context}.

-spec make_test_cashflow() -> dmsl_domain_thrift:'CashFlowPosting'().
make_test_cashflow() ->
    ?cfpost(
        {system, settlement},
        {provider, settlement},
        {product,
            {min_of,
                ?ordset([
                    ?fixed(10, <<"RUB">>),
                    ?share(5, 100, operation_amount, round_half_towards_zero)
                ])}}
    ).
