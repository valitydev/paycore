-module(hg_customer_client).

-include_lib("damsel/include/dmsl_customer_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%% BankCard operations
-export([find_or_create_bank_card/2]).
-export([get_recurrent_tokens_by_card/2]).
-export([save_recurrent_token_by_card/3]).
-export([tokens_to_map/1]).

%% Customer operations
-export([create_customer/1]).
-export([get_by_parent_payment/2]).
-export([get_recurrent_tokens/2]).
-export([add_payment/3]).
-export([link_bank_card/2]).
-export([find_or_create_customer_by_email/2]).
-export([get_terminal_affinities/1]).
-export([bind_terminal_affinity/4]).

-export_type([cascade_tokens/0]).
-export_type([payment_ref/0]).

-type invoice_id() :: dmsl_domain_thrift:'InvoiceID'().
-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type payment_ref() :: {invoice_id(), payment_id()}.
-type provider_terminal_key() :: dmsl_customer_thrift:'ProviderTerminalKey'().
-type token() :: dmsl_domain_thrift:'Token'().
-type recurrent_token() :: dmsl_customer_thrift:'RecurrentToken'().
-type cascade_tokens() :: #{provider_terminal_key() => token()}.

%% BankCard operations

-spec find_or_create_bank_card(dmsl_domain_thrift:'PartyConfigRef'(), token()) ->
    dmsl_customer_thrift:'BankCard'().
find_or_create_bank_card(PartyConfigRef, BankCardToken) ->
    case find_bank_card(PartyConfigRef, BankCardToken) of
        {ok, BankCard} ->
            BankCard;
        {exception, #customer_BankCardNotFound{}} ->
            {ok, BankCard} = call(
                bank_card_storage,
                'Create',
                {PartyConfigRef, #customer_BankCardParams{bank_card_token = BankCardToken}}
            ),
            BankCard
    end.

-spec get_recurrent_tokens_by_card(dmsl_domain_thrift:'PartyConfigRef'(), token()) ->
    [recurrent_token()].
get_recurrent_tokens_by_card(PartyConfigRef, BankCardToken) ->
    case find_bank_card(PartyConfigRef, BankCardToken) of
        {ok, #customer_BankCard{id = BankCardID}} ->
            {ok, Tokens} = call(bank_card_storage, 'GetRecurrentTokens', {BankCardID}),
            Tokens;
        {exception, #customer_BankCardNotFound{}} ->
            []
    end.

-spec save_recurrent_token_by_card(
    dmsl_domain_thrift:'PartyConfigRef'(),
    token(),
    {dmsl_domain_thrift:'PaymentRoute'(), token()}
) -> recurrent_token().
save_recurrent_token_by_card(
    PartyConfigRef,
    BankCardToken,
    {#domain_PaymentRoute{provider = ProviderRef, terminal = TerminalRef}, RecToken}
) ->
    #customer_BankCard{id = BankCardID} = find_or_create_bank_card(PartyConfigRef, BankCardToken),
    {ok, SavedToken} = call(
        bank_card_storage,
        'AddRecurrentToken',
        {#customer_RecurrentTokenParams{
            bank_card_id = BankCardID,
            provider_ref = ProviderRef,
            terminal_ref = TerminalRef,
            token = RecToken
        }}
    ),
    SavedToken.

-spec tokens_to_map([recurrent_token()]) -> cascade_tokens().
tokens_to_map(Tokens) ->
    lists:foldl(fun token_to_map_entry/2, #{}, Tokens).

%% Customer operations

-spec create_customer(dmsl_domain_thrift:'PartyConfigRef'()) -> dmsl_customer_thrift:'Customer'().
create_customer(PartyConfigRef) ->
    {ok, Customer} = call(customer_management, 'Create', {#customer_CustomerParams{party_ref = PartyConfigRef}}),
    Customer.

-spec get_by_parent_payment(invoice_id(), payment_id()) ->
    {ok, dmsl_customer_thrift:'CustomerState'()} | {exception, term()}.
get_by_parent_payment(InvoiceID, PaymentID) ->
    call(customer_management, 'GetByParentPayment', {InvoiceID, PaymentID}).

-spec get_recurrent_tokens(invoice_id(), payment_id()) -> [recurrent_token()].
get_recurrent_tokens(InvoiceID, PaymentID) ->
    case call(customer_management, 'GetByParentPayment', {InvoiceID, PaymentID}) of
        {ok, #customer_CustomerState{bank_card_refs = BankCardRefs}} ->
            lists:flatmap(fun collect_bank_card_tokens/1, BankCardRefs);
        {exception, #customer_CustomerNotFound{}} ->
            [];
        {exception, #customer_InvalidRecurrentParent{}} ->
            []
    end.

-spec find_or_create_customer_by_email(dmsl_domain_thrift:'PartyConfigRef'(), binary()) ->
    {ok, dmsl_customer_thrift:'CustomerID'()} | {error, unavailable}.
find_or_create_customer_by_email(PartyRef, Email) ->
    case customer_call('FindOrCreateByEmail', {PartyRef, Email}) of
        {ok, #customer_Customer{id = ID}} -> {ok, ID};
        {error, unavailable} = Error -> Error
    end.

-spec get_terminal_affinities(dmsl_customer_thrift:'CustomerID'()) ->
    {ok, [dmsl_customer_thrift:'TerminalAffinity'()]} | {error, unavailable}.
get_terminal_affinities(CustomerID) ->
    customer_call('GetTerminalAffinities', {CustomerID}).

%% The payment reference is the binding's idempotency key: a repeat call by the same
%% payment returns the existing record without moving it to the tail of the history.
%% The field is required, so an incomplete reference fails here, not in the serialiser
-spec bind_terminal_affinity(
    dmsl_customer_thrift:'CustomerID'(),
    dmsl_domain_thrift:'PaymentRoute'(),
    dmsl_domain_thrift:'RoutingAffinityTtl'() | undefined,
    payment_ref()
) -> ok | {error, unavailable}.
bind_terminal_affinity(
    CustomerID,
    #domain_PaymentRoute{provider = Provider, terminal = Terminal},
    Ttl,
    {InvoiceID, PaymentID}
) when is_binary(InvoiceID), is_binary(PaymentID) ->
    case
        customer_call(
            'BindTerminalAffinity',
            {#customer_TerminalAffinityParams{
                customer_id = CustomerID,
                provider_ref = Provider,
                terminal_ref = Terminal,
                ttl = Ttl,
                payment = #customer_PaymentRef{invoice_id = InvoiceID, payment_id = PaymentID}
            }}
        )
    of
        {ok, _} -> ok;
        {error, unavailable} = Error -> Error
    end.

-spec add_payment(dmsl_customer_thrift:'CustomerID'(), invoice_id(), payment_id()) -> ok | {error, unavailable}.
add_payment(CustomerID, InvoiceID, PaymentID) ->
    case customer_call('AddPayment', {CustomerID, InvoiceID, PaymentID}) of
        {ok, ok} -> ok;
        {error, unavailable} = Error -> Error
    end.

-spec link_bank_card(dmsl_customer_thrift:'CustomerID'(), token()) -> ok | {error, unavailable}.
link_bank_card(CustomerID, BankCardToken) ->
    case customer_call('AddBankCard', {CustomerID, #customer_BankCardParams{bank_card_token = BankCardToken}}) of
        {ok, _} -> ok;
        {error, unavailable} = Error -> Error
    end.

%% Internal

find_bank_card(PartyConfigRef, BankCardToken) ->
    SearchParams = #customer_BankCardSearchParams{
        bank_card_token = BankCardToken,
        party_ref = PartyConfigRef
    },
    call(bank_card_storage, 'Find', {SearchParams}).

collect_bank_card_tokens(#customer_BankCardRef{id = BankCardID}) ->
    {ok, Tokens} = call(bank_card_storage, 'GetRecurrentTokens', {BankCardID}),
    Tokens.

token_to_map_entry(
    #customer_RecurrentToken{
        provider_ref = ProviderRef,
        terminal_ref = TerminalRef,
        token = Token
    },
    Acc
) ->
    Key = #customer_ProviderTerminalKey{
        provider_ref = ProviderRef,
        terminal_ref = TerminalRef
    },
    Acc#{Key => Token}.

customer_call(Function, Args) ->
    try
        case call(customer_management, Function, Args, own_deadline) of
            {exception, #customer_CustomerNotFound{}} when Function =:= 'GetTerminalAffinities' ->
                {ok, []};
            {exception, Exception} ->
                %% A service failing and a service rejecting the request are different
                %% things: counting the latter as unavailability pollutes the downtime metric
                customer_rejected(Function, Exception);
            {ok, _} = Result ->
                Result
        end
    catch
        %% woody_error:raise(system, {Source, Class, _}) surfaces as
        %% {woody_error, {Source, Class, Details}}, where Source is internal | external
        error:{woody_error, {Source, _Class, _Details}} when Source =:= internal; Source =:= external ->
            customer_unavailable(Function)
    end.

customer_unavailable(Function) ->
    hg_customer_metrics:unavailable(Function),
    {error, unavailable}.

customer_rejected(Function, Exception) ->
    _ = logger:warning("Customer service rejected ~p: ~p", [Function, Exception]),
    hg_customer_metrics:rejected(Function),
    {error, unavailable}.

%% A deadline of our own may only shorten the step's budget: woody_context:set_deadline/2
%% assigns the value as given, so we take the minimum ourselves
customer_deadline(WoodyContext) ->
    Own = woody_deadline:from_timeout(genlib_app:env(hellgate, customer_timeout, 1000)),
    case woody_context:get_deadline(WoodyContext) of
        undefined -> Own;
        Inherited -> erlang:min(Inherited, Own)
    end.

call(ServiceName, Function, Args) ->
    call(ServiceName, Function, Args, undefined).

call(ServiceName, Function, Args, Deadline) ->
    Service = hg_proto:get_service(ServiceName),
    Opts = hg_woody_wrapper:get_service_options(ServiceName),
    WoodyContext =
        try
            op_context:get_woody_context(op_context:load(op_context:key(hellgate)))
        catch
            error:badarg -> woody_context:new()
        end,
    Request = {Service, Function, Args},
    woody_client:call(
        Request,
        Opts#{
            event_handler => {
                scoper_woody_event_handler,
                genlib_app:env(hellgate, scoper_event_handler_options, #{})
            }
        },
        case Deadline of
            undefined -> WoodyContext;
            own_deadline -> woody_context:set_deadline(customer_deadline(WoodyContext), WoodyContext)
        end
    ).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec customer_calls_test_() -> _.
customer_calls_test_() ->
    {setup,
        fun() ->
            %% woody pulls in snowflake, without which woody_context:new/0 cannot build a
            %% req_id: otherwise the tests are green only when run after someone else's,
            %% which have already started woody
            {ok, _} = application:ensure_all_started(woody),
            {ok, _} = application:ensure_all_started(prometheus),
            ok = hg_customer_metrics:setup(),
            ok = meck:new(woody_client, [passthrough]),
            ok = meck:new(hg_woody_wrapper, [passthrough]),
            ok = meck:expect(hg_woody_wrapper, get_service_options, fun(_) ->
                #{url => <<"http://localhost/unused">>}
            end)
        end,
        fun(_) ->
            ok = meck:unload([woody_client, hg_woody_wrapper])
        end,
        [
            ?_test(customer_calls_fallback()),
            ?_test(customer_call_deadline()),
            ?_test(bind_terminal_affinity_payment_ref())
        ]}.

bind_affinity(Ttl) ->
    bind_terminal_affinity(
        <<"customer">>,
        #domain_PaymentRoute{
            provider = #domain_ProviderRef{id = 1}, terminal = #domain_TerminalRef{id = 1}
        },
        Ttl,
        {<<"invoice">>, <<"payment">>}
    ).

%% The payment reference is the idempotency key on the cubasty side: if it does not
%% arrive in the params, a retried machine step becomes indistinguishable from a new
%% successful payment
-dialyzer({nowarn_function, bind_terminal_affinity_payment_ref/0}).
bind_terminal_affinity_payment_ref() ->
    Self = self(),
    ok = meck:expect(woody_client, call, fun({_Service, 'BindTerminalAffinity', {Params}}, _, _) ->
        Self ! {params, Params},
        {ok, #customer_TerminalAffinity{
            provider_ref = #domain_ProviderRef{id = 1},
            terminal_ref = #domain_TerminalRef{id = 1},
            bind_seq = 1,
            bound_at = <<"2026-01-01T00:00:00Z">>,
            last_used_at = <<"2026-01-01T00:00:00Z">>
        }}
    end),
    ?assertEqual(ok, bind_affinity({since_bound, 3600})),
    receive
        {params, Params} ->
            ?assertEqual(
                #customer_TerminalAffinityParams{
                    customer_id = <<"customer">>,
                    provider_ref = #domain_ProviderRef{id = 1},
                    terminal_ref = #domain_TerminalRef{id = 1},
                    ttl = {since_bound, 3600},
                    payment = #customer_PaymentRef{invoice_id = <<"invoice">>, payment_id = <<"payment">>}
                },
                Params
            )
    after 0 -> error(bind_not_called)
    end,
    %% A required field: the client does not send an incomplete reference at all
    ?assertError(
        function_clause,
        bind_terminal_affinity(
            <<"customer">>,
            #domain_PaymentRoute{provider = #domain_ProviderRef{id = 1}, terminal = #domain_TerminalRef{id = 1}},
            undefined,
            {<<"invoice">>, undefined}
        )
    ).

-dialyzer({nowarn_function, customer_calls_fallback/0}).
customer_calls_fallback() ->
    Calls = [
        {'FindOrCreateByEmail', fun() ->
            find_or_create_customer_by_email(#domain_PartyConfigRef{id = <<"party">>}, <<"a@b.c">>)
        end},
        {'GetTerminalAffinities', fun() -> get_terminal_affinities(<<"customer">>) end},
        {'BindTerminalAffinity', fun() -> bind_affinity(undefined) end},
        {'AddPayment', fun() -> add_payment(<<"customer">>, <<"invoice">>, <<"payment">>) end}
    ],
    lists:foreach(
        fun({Op, Call}) ->
            lists:foreach(
                fun(Class) ->
                    Before = prometheus_counter:value(customer_unavailable, [Op]),
                    ok = meck:expect(woody_client, call, fun(_, _, _) ->
                        error({woody_error, {internal, Class, <<"unavailable">>}})
                    end),
                    ?assertEqual({error, unavailable}, Call()),
                    ?assertEqual(genlib:define(Before, 0) + 1, prometheus_counter:value(customer_unavailable, [Op]))
                end,
                [resource_unavailable, result_unknown, result_unexpected]
            ),
            BeforeExternal = prometheus_counter:value(customer_unavailable, [Op]),
            ok = meck:expect(woody_client, call, fun(_, _, _) ->
                error({woody_error, {external, result_unexpected, <<"unavailable">>}})
            end),
            ?assertEqual({error, unavailable}, Call()),
            ?assertEqual(genlib:define(BeforeExternal, 0) + 1, prometheus_counter:value(customer_unavailable, [Op])),
            %% A request the service rejected is not downtime: the unavailability counter stays put
            BeforeRejected = prometheus_counter:value(customer_unavailable, [Op]),
            ok = meck:expect(woody_client, call, fun(_, _, _) -> {exception, #customer_CustomerNotFound{}} end),
            Expected =
                case Op of
                    'GetTerminalAffinities' -> {ok, []};
                    _ -> {error, unavailable}
                end,
            ?assertEqual(Expected, Call()),
            ?assertEqual(
                genlib:define(BeforeRejected, 0),
                genlib:define(
                    prometheus_counter:value(customer_unavailable, [Op]), 0
                )
            )
        end,
        Calls
    ).

customer_call_deadline() ->
    ok = meck:expect(woody_client, call, fun(_, _, Context) ->
        Deadline = woody_context:get_deadline(Context),
        ?assert(woody_deadline:to_timeout(Deadline) =< 1000),
        ?assert(woody_deadline:to_timeout(Deadline) > 0),
        {ok, #customer_Customer{
            id = <<"customer">>,
            party_ref = #domain_PartyConfigRef{id = <<"party">>},
            created_at = <<"2026-01-01T00:00:00Z">>,
            status = {active, #customer_CustomerActive{}}
        }}
    end),
    ?assertEqual(
        {ok, <<"customer">>}, find_or_create_customer_by_email(#domain_PartyConfigRef{id = <<"party">>}, <<"a@b.c">>)
    ).

-endif.
