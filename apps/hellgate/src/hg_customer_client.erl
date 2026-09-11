-module(hg_customer_client).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
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

%% cubasty is part of the core: a failure is not swallowed but fails the caller, so that the
%% machine step is retried or repaired. Only answers a retry would not change are handled
-spec find_or_create_customer_by_email(dmsl_domain_thrift:'PartyConfigRef'(), binary()) ->
    dmsl_customer_thrift:'CustomerID'() | undefined.
find_or_create_customer_by_email(PartyRef, Email) ->
    case call(customer_management, 'FindOrCreateByEmail', {PartyRef, Email}) of
        {ok, #customer_Customer{id = ID}} ->
            ID;
        %% An address cubasty does not accept identifies no payer
        {exception, #base_InvalidRequest{}} ->
            undefined
    end.

-spec get_terminal_affinities(dmsl_customer_thrift:'CustomerID'()) -> [dmsl_customer_thrift:'TerminalAffinity'()].
get_terminal_affinities(CustomerID) ->
    case call(customer_management, 'GetTerminalAffinities', {CustomerID}) of
        {ok, Affinities} ->
            Affinities;
        %% Deleting a Customer releases its bindings, so a deleted one has none
        {exception, #customer_CustomerNotFound{}} ->
            []
    end.

%% The payment reference is the binding's idempotency key: a repeat call by the same
%% payment returns the existing record without moving it to the tail of the history.
%% The field is required, so an incomplete reference fails here, not in the serialiser
-spec bind_terminal_affinity(
    dmsl_customer_thrift:'CustomerID'(),
    dmsl_domain_thrift:'PaymentRoute'(),
    dmsl_domain_thrift:'RoutingAffinityTtl'() | undefined,
    payment_ref()
) -> ok.
bind_terminal_affinity(
    CustomerID,
    #domain_PaymentRoute{provider = Provider, terminal = Terminal},
    Ttl,
    {InvoiceID, PaymentID}
) when is_binary(InvoiceID), is_binary(PaymentID) ->
    {ok, _} = call(
        customer_management,
        'BindTerminalAffinity',
        {#customer_TerminalAffinityParams{
            customer_id = CustomerID,
            provider_ref = Provider,
            terminal_ref = Terminal,
            ttl = Ttl,
            payment = #customer_PaymentRef{invoice_id = InvoiceID, payment_id = PaymentID}
        }}
    ),
    ok.

-spec add_payment(dmsl_customer_thrift:'CustomerID'(), invoice_id(), payment_id()) -> ok.
add_payment(CustomerID, InvoiceID, PaymentID) ->
    {ok, ok} = call(customer_management, 'AddPayment', {CustomerID, InvoiceID, PaymentID}),
    ok.

-spec link_bank_card(dmsl_customer_thrift:'CustomerID'(), token()) -> ok.
link_bank_card(CustomerID, BankCardToken) ->
    {ok, _} = call(
        customer_management,
        'AddBankCard',
        {CustomerID, #customer_BankCardParams{bank_card_token = BankCardToken}}
    ),
    ok.

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

call(ServiceName, Function, Args) ->
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
        WoodyContext
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
            ?_test(customer_calls_fail()),
            ?_test(customer_calls_answers()),
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

%% Nothing is swallowed: a failing cubasty and an answer nobody expects both fail the caller
-dialyzer({nowarn_function, customer_calls_fail/0}).
customer_calls_fail() ->
    Calls = [
        fun() -> find_or_create_customer_by_email(#domain_PartyConfigRef{id = <<"party">>}, <<"a@b.c">>) end,
        fun() -> get_terminal_affinities(<<"customer">>) end,
        fun() -> bind_affinity(undefined) end,
        fun() -> add_payment(<<"customer">>, <<"invoice">>, <<"payment">>) end,
        fun() -> link_bank_card(<<"customer">>, <<"card">>) end
    ],
    lists:foreach(
        fun(Call) ->
            lists:foreach(
                fun(Error) ->
                    ok = meck:expect(woody_client, call, fun(_, _, _) -> error(Error) end),
                    ?assertError(Error, Call())
                end,
                [
                    {woody_error, {internal, resource_unavailable, <<"timeout">>}},
                    {woody_error, {external, result_unexpected, <<"crash">>}}
                ]
            ),
            ok = meck:expect(woody_client, call, fun(_, _, _) -> {exception, #customer_InvalidRecurrentParent{}} end),
            ?assertException(error, _, Call())
        end,
        Calls
    ).

customer_calls_answers() ->
    ok = meck:expect(woody_client, call, fun(_, _, _) ->
        {exception, #base_InvalidRequest{errors = [<<"invalid email">>]}}
    end),
    ?assertEqual(undefined, find_or_create_customer_by_email(#domain_PartyConfigRef{id = <<"party">>}, <<"a@b.c">>)),
    ok = meck:expect(woody_client, call, fun(_, _, _) -> {exception, #customer_CustomerNotFound{}} end),
    ?assertEqual([], get_terminal_affinities(<<"customer">>)).

-endif.
