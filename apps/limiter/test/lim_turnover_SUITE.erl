-module(lim_turnover_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_limiter_config_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_conf_v2_thrift.hrl").
-include("lim_ct_helper.hrl").

-export([all/0]).

-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([commit_with_default_exchange/1]).
-export([partial_commit_with_exchange/1]).
-export([commit_with_exchange/1]).
-export([hold_with_disabled_exchange/1]).
-export([rollback_with_wrong_currency/1]).
-export([hold_with_wrong_operation_context/1]).
-export([rollback_with_wrong_operation_context/1]).
-export([hold_with_wrong_payment_tool/1]).
-export([rollback_with_wrong_payment_tool/1]).
-export([get_limit_ok/1]).
-export([get_limit_notfound/1]).
-export([hold_ok/1]).
-export([commit_ok/1]).
-export([rollback_ok/1]).
-export([refund_ok/1]).
-export([commit_inexistent_hold_fails/1]).
-export([partial_commit_inexistent_hold_fails/1]).
-export([commit_multirange_limit_ok/1]).
-export([commit_with_payment_tool_scope_ok/1]).

-export([commit_processes_idempotently/1]).
-export([full_commit_processes_idempotently/1]).
-export([partial_commit_processes_idempotently/1]).
-export([rollback_processes_idempotently/1]).

-export([commit_number_ok/1]).
-export([rollback_number_ok/1]).
-export([commit_refund_keep_number_unchanged/1]).
-export([partial_commit_number_counts_as_single_op/1]).

-export([commit_with_party_scope_ok/1]).
-export([commit_with_provider_scope_ok/1]).
-export([commit_with_terminal_scope_ok/1]).
-export([commit_with_email_scope_ok/1]).

-export([commit_with_wallet_scope_ok/1]).
-export([commit_with_multi_scope_ok/1]).
-export([hold_with_sender_notfound/1]).
-export([hold_with_receiver_notfound/1]).
-export([hold_with_destination_field_not_found/1]).
-export([hold_with_destination_field_not_supported/1]).
-export([commit_with_sender_scope_ok/1]).
-export([commit_with_receiver_scope_ok/1]).
-export([commit_with_sender_receiver_scope_ok/1]).
-export([commit_with_destination_field_scope_ok/1]).

-export([batch_hold_ok/1]).
-export([batch_commit_ok/1]).
-export([batch_rollback_ok/1]).
-export([two_batch_hold_ok/1]).
-export([two_batch_commit_ok/1]).
-export([two_batch_rollback_ok/1]).
-export([retry_batch_hold_ok/1]).
-export([batch_commit_less_ok/1]).
-export([batch_commit_more_ok/1]).
-export([batch_commit_negative_ok/1]).
-export([batch_commit_negative_less_ok/1]).
-export([batch_commit_negative_more_ok/1]).

-export([batch_with_invertable_rollback_ok/1]).
-export([batch_with_invertable_rollback_with_session_ok/1]).
-export([batch_with_invertable_commit_ok/1]).
-export([batch_with_invertable_commit_with_session_ok/1]).

-type group_name() :: atom().
-type test_case_name() :: atom().

%% tests descriptions

-spec all() -> [{group, group_name()}].
all() ->
    [
        {group, default},
        {group, withdrawals},
        {group, cashless},
        {group, idempotency},
        {group, finalization_behaviour}
    ].

-spec groups() -> [{atom(), list(), [test_case_name()]}].
groups() ->
    [
        {base, [], [
            commit_with_default_exchange,
            partial_commit_with_exchange,
            commit_with_exchange,
            hold_with_disabled_exchange,
            rollback_with_wrong_currency,
            hold_with_wrong_operation_context,
            rollback_with_wrong_operation_context,
            hold_with_wrong_payment_tool,
            rollback_with_wrong_payment_tool,
            get_limit_ok,
            get_limit_notfound,
            hold_ok,
            commit_ok,
            rollback_ok,
            refund_ok,
            commit_inexistent_hold_fails,
            partial_commit_inexistent_hold_fails,
            commit_with_payment_tool_scope_ok,
            commit_with_party_scope_ok,
            commit_with_provider_scope_ok,
            commit_with_terminal_scope_ok,
            commit_with_email_scope_ok,
            commit_with_multi_scope_ok,
            hold_with_sender_notfound,
            hold_with_receiver_notfound,
            hold_with_destination_field_not_found,
            hold_with_destination_field_not_supported
        ]},
        {default, [], [
            {group, base},
            batch_hold_ok,
            batch_commit_ok,
            batch_rollback_ok,
            two_batch_hold_ok,
            two_batch_commit_ok,
            two_batch_rollback_ok,
            retry_batch_hold_ok,
            batch_commit_less_ok,
            batch_commit_more_ok,
            batch_commit_negative_ok,
            batch_commit_negative_less_ok,
            batch_commit_negative_more_ok
        ]},
        {withdrawals, [parallel], [
            get_limit_ok,
            hold_ok,
            commit_ok,
            rollback_ok,
            commit_with_party_scope_ok,
            commit_with_provider_scope_ok,
            commit_with_terminal_scope_ok,
            commit_with_wallet_scope_ok,
            commit_with_sender_scope_ok,
            commit_with_receiver_scope_ok,
            commit_with_sender_receiver_scope_ok,
            commit_with_destination_field_scope_ok,
            hold_with_destination_field_not_supported
        ]},
        {cashless, [parallel], [
            commit_number_ok,
            rollback_number_ok,
            commit_refund_keep_number_unchanged,
            partial_commit_number_counts_as_single_op
        ]},
        {idempotency, [parallel], [
            commit_processes_idempotently,
            full_commit_processes_idempotently,
            partial_commit_processes_idempotently,
            rollback_processes_idempotently
        ]},
        {finalization_behaviour, [], [
            batch_with_invertable_rollback_ok,
            batch_with_invertable_rollback_with_session_ok,
            batch_with_invertable_commit_ok,
            batch_with_invertable_commit_with_session_ok
        ]}
    ].

-type config() :: [{atom(), any()}].

-spec init_per_suite(config()) -> config().
init_per_suite(Config) ->
    % dbg:tracer(), dbg:p(all, c),
    % dbg:tpl({lim_handler, '_', '_'}, x),
    Apps =
        genlib_app:start_application_with(dmt_client, [
            % milliseconds
            {cache_update_interval, 5000},
            {max_cache_size, #{
                elements => 20,
                % 50Mb
                memory => 52428800
            }},
            {woody_event_handlers, [
                {scoper_woody_event_handler, #{
                    event_handler_opts => #{
                        formatter_opts => #{
                            max_length => 1000
                        }
                    }
                }}
            ]},
            {service_urls, #{
                'AuthorManagement' => <<"http://dmt:8022/v1/domain/author">>,
                'Repository' => <<"http://dmt:8022/v1/domain/repository">>,
                'RepositoryClient' => <<"http://dmt:8022/v1/domain/repository_client">>
            }}
        ]) ++
            genlib_app:start_application_with(limiter, [
                {service_clients, #{
                    liminator => #{
                        url => <<"http://liminator:8022/liminator/v1">>
                    },
                    xrates => #{
                        url => <<"http://xrates:8022/xrates">>
                    }
                }},
                {exchange_factors, #{
                    <<"DEFAULT">> => {1, 1},
                    <<"USD">> => {105, 100},
                    <<"EUR">> => {12, 10}
                }}
            ]),
    [{apps, Apps}] ++ Config.

-spec end_per_suite(config()) -> _.
end_per_suite(Config) ->
    genlib_app:test_application_stop(?config(apps, Config)).

-spec init_per_group(test_case_name(), config()) -> config().
init_per_group(_Name, C) ->
    C.

-spec end_per_group(test_case_name(), config()) -> ok.
end_per_group(_Name, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) ->
    [
        {id, gen_unique_id(Name)},
        {client, lim_client:new()},
        {test_sup, lim_mock:start_mocked_service_sup()}
        | C
    ].

-spec end_per_testcase(test_case_name(), config()) -> ok.
end_per_testcase(_Name, C) ->
    _ = lim_mock:stop_mocked_service_sup(?config(test_sup, C)),
    ok.

%%

-define(LIMIT_CHANGE(ID, Version), #limiter_LimitChange{id = ID, version = Version}).
-define(LIMIT_REQUEST(ID, Changes), #limiter_LimitRequest{operation_id = ID, limit_changes = Changes}).

-spec commit_with_default_exchange(config()) -> _.
commit_with_default_exchange(C) ->
    Rational = #base_Rational{p = 1000000, q = 100},
    _ = mock_exchange(Rational, C),
    {ID, Version} = configure_limit(
        ?time_range_month(), ?global(), ?turnover_metric_amount(<<"RUB">>), ?currency_conversion(), C
    ),
    Cost = ?cash(10000, <<"SOME_CURRENCY">>),
    Context = ?payproc_ctx_invoice(Cost),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)),
    {ok, #limiter_Limit{amount = 10000}} = lim_client:get(ID, Version, Context, ?config(client, C)).

-spec partial_commit_with_exchange(config()) -> _.
partial_commit_with_exchange(C) ->
    Rational = #base_Rational{p = 800000, q = 100},
    _ = mock_exchange(Rational, C),
    {ID, Version} = configure_limit(
        ?time_range_month(), ?global(), ?turnover_metric_amount(<<"RUB">>), ?currency_conversion(), C
    ),
    Cost = ?cash(1000, <<"USD">>),
    CaptureCost = ?cash(800, <<"USD">>),
    Context = ?payproc_ctx_payment(Cost, CaptureCost),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)),
    {ok, #limiter_Limit{amount = 8400}} = lim_client:get(ID, Version, Context, ?config(client, C)).

-spec commit_with_exchange(config()) -> _.
commit_with_exchange(C) ->
    Rational = #base_Rational{p = 1000000, q = 100},
    _ = mock_exchange(Rational, C),
    {ID, Version} = configure_limit(
        ?time_range_month(), ?global(), ?turnover_metric_amount(<<"RUB">>), ?currency_conversion(), C
    ),
    Cost = ?cash(10000, <<"USD">>),
    Context = ?payproc_ctx_invoice(Cost),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)),
    {ok, #limiter_Limit{amount = 10500}} = lim_client:get(ID, Version, Context, ?config(client, C)).

-spec hold_with_disabled_exchange(config()) -> _.
hold_with_disabled_exchange(C) ->
    Rational = #base_Rational{p = 1000000, q = 100},
    _ = mock_exchange(Rational, C),
    ConfiguredCurrency = <<"RUB">>,
    {ID, Version} = configure_limit(?time_range_month(), ?global(), ?turnover_metric_amount(ConfiguredCurrency), C),
    Currency = <<"USD">>,
    Cost = ?cash(10000, Currency),
    Context = ?payproc_ctx_invoice(Cost),
    {exception, #limiter_InvalidOperationCurrency{currency = Currency, expected_currency = ConfiguredCurrency}} =
        lim_client:hold(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)).

-spec rollback_with_wrong_currency(config()) -> _.
rollback_with_wrong_currency(C) ->
    Rational = #base_Rational{p = 1000000, q = 100},
    _ = mock_exchange(Rational, C),
    ConfiguredCurrency = <<"RUB">>,
    {ID, Version} = configure_limit(?time_range_month(), ?global(), ?turnover_metric_amount(ConfiguredCurrency), C),
    Currency = <<"USD">>,
    Cost = ?cash(10000, Currency),
    Context = ?payproc_ctx_invoice(Cost),
    {exception, #limiter_InvalidOperationCurrency{currency = Currency, expected_currency = ConfiguredCurrency}} =
        lim_client:rollback(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)).

-spec hold_with_wrong_operation_context(config()) -> _.
hold_with_wrong_operation_context(C) ->
    Rational = #base_Rational{p = 1000000, q = 100},
    _ = mock_exchange(Rational, C),
    {ID, Version} = configure_limit(?time_range_month(), ?global(), C),
    Cost = ?cash(10000),
    Context = ?wthdproc_ctx_withdrawal(Cost),
    {exception, #limiter_OperationContextNotSupported{
        context_type = {withdrawal_processing, #limiter_LimitContextTypeWithdrawalProcessing{}}
    }} =
        lim_client:hold(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)).

-spec rollback_with_wrong_operation_context(config()) -> _.
rollback_with_wrong_operation_context(C) ->
    Rational = #base_Rational{p = 1000000, q = 100},
    _ = mock_exchange(Rational, C),
    {ID, Version} = configure_limit(?time_range_month(), ?global(), C),
    Cost = ?cash(10000),
    Context = ?wthdproc_ctx_withdrawal(Cost),
    {exception, #limiter_OperationContextNotSupported{
        context_type = {withdrawal_processing, #limiter_LimitContextTypeWithdrawalProcessing{}}
    }} =
        lim_client:rollback(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)).

-spec hold_with_wrong_payment_tool(config()) -> _.
hold_with_wrong_payment_tool(C) ->
    Rational = #base_Rational{p = 1000000, q = 100},
    _ = mock_exchange(Rational, C),
    {ID, Version} = configure_limit(?time_range_week(), ?scopes([?scope_payment_tool()]), ?turnover_metric_number(), C),
    NotSupportedPaymentTool = {crypto_currency, #domain_CryptoCurrencyRef{id = <<"wow;so-cryptic;much-hidden">>}},
    Context = ?payproc_ctx_payment(?invoice_payment(?cash(10000), ?cash(10000), NotSupportedPaymentTool)),
    {exception, #limiter_PaymentToolNotSupported{payment_tool = <<"crypto_currency">>}} =
        lim_client:hold(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)).

-spec rollback_with_wrong_payment_tool(config()) -> _.
rollback_with_wrong_payment_tool(C) ->
    Rational = #base_Rational{p = 1000000, q = 100},
    _ = mock_exchange(Rational, C),
    {ID, Version} = configure_limit(?time_range_week(), ?scopes([?scope_payment_tool()]), ?turnover_metric_number(), C),
    NotSupportedPaymentTool = {crypto_currency, #domain_CryptoCurrencyRef{id = <<"wow;so-cryptic;much-hidden">>}},
    Context = ?payproc_ctx_payment(?invoice_payment(?cash(10000), ?cash(10000), NotSupportedPaymentTool)),
    {exception, #limiter_PaymentToolNotSupported{payment_tool = <<"crypto_currency">>}} =
        lim_client:rollback(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)).

-spec get_limit_ok(config()) -> _.
get_limit_ok(C) ->
    {ID, Version} = configure_limit(?time_range_month(), ?global(), C),
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(0));
            _Default -> ?payproc_ctx_invoice(?cash(0))
        end,
    ?assertMatch(
        {ok, #limiter_Limit{amount = 0}},
        lim_client:get(ID, Version, Context, ?config(client, C))
    ).

-spec get_limit_notfound(config()) -> _.
get_limit_notfound(C) ->
    Version = 0,
    Context = ?payproc_ctx_invoice(?cash(0)),
    ?assertEqual(
        {exception, #limiter_LimitNotFound{}},
        lim_client:get(<<"NOSUCHLIMITID">>, Version, Context, ?config(client, C))
    ).

-spec hold_ok(config()) -> _.
hold_ok(C) ->
    {ID, Version} = configure_limit(?time_range_month(), ?global(), C),
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10));
            _Default -> ?payproc_ctx_invoice(?cash(10))
        end,
    ok = lim_client:hold(
        ?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)
    ),
    {ok, #limiter_Limit{}} = lim_client:get(ID, Version, Context, ?config(client, C)).

-spec commit_ok(config()) -> _.
commit_ok(C) ->
    {ID, Version} = configure_limit(?time_range_month(), ?global(), C),
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10, <<"RUB">>));
            _Default -> ?payproc_ctx_invoice(?cash(10, <<"RUB">>))
        end,
    ok = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)),
    {ok, #limiter_Limit{}} = lim_client:get(ID, Version, Context, ?config(client, C)).

-spec rollback_ok(config()) -> _.
rollback_ok(C) ->
    {ID, Version} = configure_limit(?time_range_week(), ?global(), C),
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10, <<"RUB">>));
            _Default -> ?payproc_ctx_invoice(?cash(10, <<"RUB">>))
        end,
    Change = ?LIMIT_CHANGE(ID, Version),
    ok = lim_client:hold(Change, Context, ?config(client, C)),
    ok = lim_client:rollback(Change, Context, ?config(client, C)).

-spec refund_ok(config()) -> _.
refund_ok(C) ->
    Client = ?config(client, C),
    OwnerID = <<"WWWcool Ltd">>,
    ShopID = <<"shop">>,
    {ID, Version} = configure_limit(?time_range_day(), ?scopes([?scope_party(), ?scope_shop()]), C),
    Context0 = ?payproc_ctx_payment(OwnerID, ShopID, ?cash(15), ?cash(15)),
    RefundContext1 = ?payproc_ctx_refund(OwnerID, ShopID, ?cash(10), ?cash(10), ?cash(10)),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context0, Client),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, Version), RefundContext1, Client),
    {ok, #limiter_Limit{} = Limit2} = lim_client:get(ID, Version, RefundContext1, Client),
    ?assertEqual(Limit2#limiter_Limit.amount, 5).

-spec commit_inexistent_hold_fails(config()) -> _.
commit_inexistent_hold_fails(C) ->
    {ID, Version} = configure_limit(?time_range_week(), ?global(), C),
    Context = ?payproc_ctx_payment(?cash(42), undefined),
    % NOTE
    % We do not expect `LimitChangeNotFound` here because we no longer reconcile with accounter
    % before requesting him to hold / commit.
    {exception, #base_InvalidRequest{}} =
        lim_client:commit(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)).

-spec partial_commit_inexistent_hold_fails(config()) -> _.
partial_commit_inexistent_hold_fails(C) ->
    {ID, Version} = configure_limit(?time_range_week(), ?global(), C),
    Context = ?payproc_ctx_payment(?cash(42), ?cash(21)),
    % NOTE
    % We do not expect `LimitChangeNotFound` here because we no longer reconcile with accounter
    % before requesting him to hold / commit.
    {exception, #base_InvalidRequest{}} =
        lim_client:commit(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)).

-spec commit_multirange_limit_ok(config()) -> _.
commit_multirange_limit_ok(C) ->
    ID = ?config(id, C),
    Client = ?config(client, C),
    Version = dmt_client:get_latest_version(),
    _ = create_limit_config(ID, #limiter_config_LimitConfig{
        processor_type = <<"TurnoverProcessor">>,
        started_at = <<"2000-01-01T00:00:00Z">>,
        shard_size = 12,
        time_range_type = ?time_range_month(),
        context_type = ?ctx_type_payproc(),
        type = ?lim_type_turnover(?turnover_metric_amount(<<"RUB">>)),
        scopes = ?scopes([]),
        description = <<"Description">>,
        op_behaviour = #limiter_config_OperationLimitBehaviour{}
    }),
    % NOTE
    % Expecting those 3 changes will be accounted in the same limit range machine.
    % We have no way to verify it here though.
    PaymentJan = ?invoice_payment(?cash(42), ?cash(42), ?bank_card(), <<"2020-01-01T00:00:00Z">>),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, 1), ?payproc_ctx_payment(PaymentJan), Client),
    PaymentFeb = ?invoice_payment(?cash(43), ?cash(43), ?bank_card(), <<"2020-02-01T00:00:00Z">>),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, 2), ?payproc_ctx_payment(PaymentFeb), Client),
    PaymentApr = ?invoice_payment(?cash(44), ?cash(44), ?bank_card(), <<"2020-04-01T00:00:00Z">>),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, 3), ?payproc_ctx_payment(PaymentApr), Client),
    {ok, #limiter_Limit{amount = 42}} = lim_client:get(ID, Version, ?payproc_ctx_payment(PaymentJan), Client),
    {ok, #limiter_Limit{amount = 43}} = lim_client:get(ID, Version, ?payproc_ctx_payment(PaymentFeb), Client),
    {ok, #limiter_Limit{amount = 44}} = lim_client:get(ID, Version, ?payproc_ctx_payment(PaymentApr), Client).

-spec commit_with_payment_tool_scope_ok(config()) -> _.
commit_with_payment_tool_scope_ok(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?scopes([?scope_payment_tool()]), ?turnover_metric_number(), C),
    Context1 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?bank_card(<<"Token">>, 2, 2022))
    ),
    Context2 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?bank_card(<<"OtherToken">>, 2, 2022))
    ),
    Context3 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?bank_card(?string, 3, 2022))
    ),
    Context4 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?bank_card(?string))
    ),
    Context5 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?digital_wallet(<<"ID42">>, <<"Pepal">>))
    ),
    {ok, LimitState0} = lim_client:get(ID, Version, Context1, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context1, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context2, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context3, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context4, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context5, Client),
    {ok, LimitState1} = lim_client:get(ID, Version, Context1, Client),
    ?assertEqual(
        LimitState1#limiter_Limit.amount,
        LimitState0#limiter_Limit.amount + 1
    ).

%%

-spec commit_processes_idempotently(config()) -> _.
commit_processes_idempotently(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?global(), C),
    Context = ?payproc_ctx_payment(?cash(42), undefined),
    Change = ?LIMIT_CHANGE(ID, Version),
    ok = lim_client:hold(Change, Context, Client),
    ok = lim_client:hold(Change, Context, Client),
    ok = lim_client:commit(Change, Context, Client),
    {ok, Limit = #limiter_Limit{amount = 42}} = lim_client:get(ID, Version, Context, Client),
    ok = lim_client:commit(Change, Context, Client),
    {ok, Limit} = lim_client:get(ID, Version, Context, Client).

-spec full_commit_processes_idempotently(config()) -> _.
full_commit_processes_idempotently(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?global(), C),
    Cost = ?cash(42),
    Context = ?payproc_ctx_payment(Cost, Cost),
    Change = ?LIMIT_CHANGE(ID, Version),
    ok = lim_client:hold(Change, Context, Client),
    ok = lim_client:hold(Change, Context, Client),
    ok = lim_client:commit(Change, Context, Client),
    {ok, Limit = #limiter_Limit{amount = 42}} = lim_client:get(ID, Version, Context, Client),
    ok = lim_client:commit(Change, Context, Client),
    {ok, Limit} = lim_client:get(ID, Version, Context, Client).

-spec partial_commit_processes_idempotently(config()) -> _.
partial_commit_processes_idempotently(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?global(), C),
    Context = ?payproc_ctx_payment(?cash(42), ?cash(40)),
    Change = ?LIMIT_CHANGE(ID, Version),
    ok = lim_client:hold(Change, Context, Client),
    ok = lim_client:hold(Change, Context, Client),
    ok = lim_client:commit(Change, Context, Client),
    {ok, Limit = #limiter_Limit{amount = 40}} = lim_client:get(ID, Version, Context, Client),
    ok = lim_client:commit(Change, Context, Client),
    {ok, Limit = #limiter_Limit{amount = 40}} = lim_client:get(ID, Version, Context, Client).

-spec rollback_processes_idempotently(config()) -> _.
rollback_processes_idempotently(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?global(), C),
    Context = ?payproc_ctx_payment(?cash(42), ?cash(0)),
    Change = ?LIMIT_CHANGE(ID, Version),
    ok = lim_client:hold(Change, Context, Client),
    ok = lim_client:hold(Change, Context, Client),
    ok = lim_client:commit(Change, Context, Client),
    {ok, Limit = #limiter_Limit{amount = 0}} = lim_client:get(ID, Version, Context, Client),
    ok = lim_client:commit(Change, Context, Client),
    {ok, Limit = #limiter_Limit{amount = 0}} = lim_client:get(ID, Version, Context, Client).

%%

-spec commit_number_ok(config()) -> _.
commit_number_ok(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?global(), ?turnover_metric_number(), C),
    Context = ?payproc_ctx_payment(?cash(10), ?cash(10)),
    {ok, LimitState0} = lim_client:get(ID, Version, Context, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, Client),
    {ok, LimitState1} = lim_client:get(ID, Version, Context, Client),
    ?assertEqual(
        LimitState1#limiter_Limit.amount,
        LimitState0#limiter_Limit.amount + 1
    ).

-spec rollback_number_ok(config()) -> _.
rollback_number_ok(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?global(), ?turnover_metric_number(), C),
    Context = ?payproc_ctx_payment(?cash(10), ?cash(10)),
    ContextRollback = ?payproc_ctx_payment(?cash(10), ?cash(0)),
    {ok, LimitState0} = lim_client:get(ID, Version, Context, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, ContextRollback, Client),
    {ok, LimitState1} = lim_client:get(ID, Version, Context, Client),
    ?assertEqual(
        LimitState1#limiter_Limit.amount,
        LimitState0#limiter_Limit.amount
    ).

-spec commit_refund_keep_number_unchanged(config()) -> _.
commit_refund_keep_number_unchanged(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?global(), ?turnover_metric_number(), C),
    Cost = ?cash(10),
    CaptureCost = ?cash(8),
    RefundCost = ?cash(5),
    PaymentContext = ?payproc_ctx_payment(<<"OWNER">>, <<"SHOP">>, Cost, CaptureCost),
    RefundContext = ?payproc_ctx_refund(<<"OWNER">>, <<"SHOP">>, Cost, CaptureCost, RefundCost),
    {ok, LimitState0} = lim_client:get(ID, Version, PaymentContext, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), PaymentContext, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), RefundContext, Client),
    {ok, LimitState1} = lim_client:get(ID, Version, PaymentContext, Client),
    ?assertEqual(
        % Expected to be the same because refund decreases counter given limit config
        LimitState1#limiter_Limit.amount,
        LimitState0#limiter_Limit.amount
    ).

-spec partial_commit_number_counts_as_single_op(config()) -> _.
partial_commit_number_counts_as_single_op(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?global(), ?turnover_metric_number(), C),
    Context = ?payproc_ctx_payment(?cash(10), ?cash(10)),
    ContextPartial = ?payproc_ctx_payment(?cash(10), ?cash(5)),
    {ok, LimitState0} = lim_client:get(ID, Version, Context, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, ContextPartial, Client),
    {ok, LimitState1} = lim_client:get(ID, Version, Context, Client),
    ?assertEqual(
        LimitState1#limiter_Limit.amount,
        LimitState0#limiter_Limit.amount + 1
    ).

%%

-spec commit_with_party_scope_ok(config()) -> _.
commit_with_party_scope_ok(C) ->
    _ = commit_with_some_scope(?scopes([?scope_party()]), C).

-spec commit_with_provider_scope_ok(config()) -> _.
commit_with_provider_scope_ok(C) ->
    _ = commit_with_some_scope(?scopes([?scope_provider()]), C).

-spec commit_with_terminal_scope_ok(config()) -> _.
commit_with_terminal_scope_ok(C) ->
    _ = commit_with_some_scope(?scopes([?scope_terminal()]), C).

commit_with_some_scope(Scope, C) ->
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal_w_auth_data(?cash(10, <<"RUB">>), ?token, ?token);
            _Default -> ?payproc_ctx_payment(?cash(10, <<"RUB">>), ?cash(10, <<"RUB">>))
        end,
    commit_with_some_scope(Scope, Context, C).

commit_with_some_scope(Scope, Context, C) ->
    {ID, Version} = configure_limit(?time_range_month(), Scope, C),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)),
    {ok, #limiter_Limit{}} = lim_client:get(ID, Version, Context, ?config(client, C)).

-spec commit_with_email_scope_ok(config()) -> _.
commit_with_email_scope_ok(C) ->
    {ID, Version} = configure_limit(?time_range_month(), ?scopes([?scope_payer_contact_email()]), C),
    Context = ?payproc_ctx_payment(?cash(10, <<"RUB">>), ?cash(10, <<"RUB">>)),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)),
    {ok, #limiter_Limit{}} = lim_client:get(ID, Version, Context, ?config(client, C)).

-spec commit_with_wallet_scope_ok(config()) -> _.
commit_with_wallet_scope_ok(C) ->
    {ID, Version} = configure_limit(?time_range_month(), ?scopes([?scope_party(), ?scope_wallet()]), C),
    Context = ?wthdproc_ctx_withdrawal(?cash(10, <<"RUB">>)),
    ok = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C)),
    {ok, #limiter_Limit{}} = lim_client:get(ID, Version, Context, ?config(client, C)).

-spec commit_with_multi_scope_ok(config()) -> _.
commit_with_multi_scope_ok(C) ->
    Client = ?config(client, C),
    {ID, Version} = configure_limit(?time_range_week(), ?scopes([?scope_provider(), ?scope_payment_tool()]), C),
    Context1 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?bank_card(<<"Token">>, 2, 2022))
    ),
    Context2 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?bank_card(<<"OtherToken">>, 2, 2022))
    ),
    Context3 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?bank_card(?string, 3, 2022))
    ),
    Context4 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?bank_card(?string))
    ),
    Context5 = ?payproc_ctx_payment(
        ?invoice_payment(?cash(10), ?cash(10), ?digital_wallet(<<"ID42">>, <<"Pepal">>))
    ),
    {ok, LimitState0} = lim_client:get(ID, Version, Context1, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context1, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context2, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context3, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context4, Client),
    _ = hold_and_commit(?LIMIT_CHANGE(ID, Version), Context5, Client),
    {ok, LimitState1} = lim_client:get(ID, Version, Context1, Client),
    ?assertEqual(
        LimitState1#limiter_Limit.amount,
        LimitState0#limiter_Limit.amount + 10
    ).

-spec hold_with_sender_notfound(config()) -> _.
hold_with_sender_notfound(C) ->
    hold_with_scope_notfound([?scope_sender()], C).

-spec hold_with_receiver_notfound(config()) -> _.
hold_with_receiver_notfound(C) ->
    hold_with_scope_notfound([?scope_receiver()], C).

-spec hold_with_destination_field_not_found(config()) -> _.
hold_with_destination_field_not_found(C) ->
    Scopes = [?scope_destination_field([<<"not">>, <<"existing">>, <<"field">>])],
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx(?withdrawal(?cash(0), ?generic_pt(), ?string));
            _Default -> ?payproc_ctx(?invoice(?string, ?string, ?cash(0)), undefined)
        end,
    hold_with_scope_notfound(Scopes, Context, C).

-spec hold_with_destination_field_not_supported(config()) -> _.
hold_with_destination_field_not_supported(C) ->
    Scopes = [?scope_destination_field([<<"opaque">>, <<"payload">>, <<"data">>])],
    hold_with_scope_unsupported(Scopes, C).

hold_with_scope_notfound(Scopes, C) ->
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(0));
            _Default -> ?payproc_ctx_invoice(?cash(0))
        end,
    hold_with_scope_notfound(Scopes, Context, C).

hold_with_scope_notfound(Scopes, Context, C) ->
    {ID, Version} = configure_limit(?time_range_month(), ?scopes(Scopes), C),
    ?assertException(
        error,
        {woody_error,
            {external, result_unexpected, <<"error:{unknown_error,{lim_turnover_processor,notfound}}", _/binary>>}},
        lim_client:hold(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C))
    ).

hold_with_scope_unsupported(Scopes, C) ->
    {ID, Version} = configure_limit(?time_range_month(), ?scopes(Scopes), C),
    Context =
        case get_group_name(C) of
            withdrawals ->
                ?wthdproc_ctx(?withdrawal(?cash(10, <<"RUB">>), ?bank_card(), ?string));
            _Default ->
                ?payproc_ctx(
                    ?op_payment, ?invoice(?string, ?string, ?cash(10, <<"RUB">>)), #context_payproc_InvoicePayment{
                        payment = ?invoice_payment(?cash(10, <<"RUB">>), ?cash(10, <<"RUB">>)),
                        route = ?route()
                    }
                )
        end,
    ?assertException(
        error,
        {woody_error,
            {external, result_unexpected,
                <<"error:{unknown_error,{lim_turnover_processor,{unsupported,bank_card}}}", _/binary>>}},
        lim_client:hold(?LIMIT_CHANGE(ID, Version), Context, ?config(client, C))
    ).

-spec commit_with_sender_scope_ok(config()) -> _.
commit_with_sender_scope_ok(C) ->
    _ = commit_with_some_scope(?scopes([?scope_sender()]), C).

-spec commit_with_receiver_scope_ok(config()) -> _.
commit_with_receiver_scope_ok(C) ->
    _ = commit_with_some_scope(?scopes([?scope_receiver()]), C).

-spec commit_with_sender_receiver_scope_ok(config()) -> _.
commit_with_sender_receiver_scope_ok(C) ->
    _ = commit_with_some_scope(?scopes([?scope_sender(), ?scope_receiver()]), C).

-spec commit_with_destination_field_scope_ok(config()) -> _.
commit_with_destination_field_scope_ok(C) ->
    Scopes = [?scope_destination_field([<<"opaque">>, <<"payload">>, <<"data">>])],
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx(?withdrawal(?cash(10, <<"RUB">>), ?generic_pt(), ?string));
            _Default -> ?payproc_ctx_payment(?cash(10, <<"RUB">>), ?cash(10, <<"RUB">>))
        end,
    _ = commit_with_some_scope(?scopes(Scopes), Context, C).

%%

construct_request(C) ->
    ID = ?config(id, C),
    ?LIMIT_REQUEST(ID, [
        construct_for_limit_change(ID, 0, ?turnover_metric_amount(<<"RUB">>), undefined, C),
        construct_for_limit_change(ID, 1, ?turnover_metric_amount(<<"RUB">>), undefined, C),
        construct_for_limit_change(ID, 2, ?turnover_metric_amount(<<"RUB">>), undefined, C)
    ]).

-spec batch_hold_ok(config()) -> _.
batch_hold_ok(C) ->
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10));
            _Default -> ?payproc_ctx_payment(?cash(10), ?cash(10))
        end,
    Request = construct_request(C),
    ok = hold_and_assert_batch(10, Request, Context, C).

-spec batch_commit_ok(config()) -> _.
batch_commit_ok(C) ->
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10));
            _Default -> ?payproc_ctx_payment(?cash(10), ?cash(10))
        end,
    Request = construct_request(C),
    ok = hold_and_assert_batch(10, Request, Context, C),
    ok = lim_client:commit_batch(Request, Context, ?config(client, C)),
    ok = assert_values(10, Request, Context, C).

-spec batch_rollback_ok(config()) -> _.
batch_rollback_ok(C) ->
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10));
            _Default -> ?payproc_ctx_payment(?cash(10), ?cash(10))
        end,
    Request = construct_request(C),
    ok = hold_and_assert_batch(10, Request, Context, C),
    ok = lim_client:rollback_batch(Request, Context, ?config(client, C)),
    ok = assert_values(0, Request, Context, C).

-spec two_batch_hold_ok(config()) -> _.
two_batch_hold_ok(C) ->
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10));
            _Default -> ?payproc_ctx_payment(?cash(10), ?cash(10))
        end,
    ?LIMIT_REQUEST(RequestID, Changes) = Request0 = construct_request(C),
    Request1 = ?LIMIT_REQUEST(genlib:format("~s/~B", [RequestID, 1000]), Changes),
    ok = hold_and_assert_batch(10, Request0, Context, C),
    ok = hold_and_assert_batch(20, Request1, Context, C).

-spec two_batch_commit_ok(config()) -> _.
two_batch_commit_ok(C) ->
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10));
            _Default -> ?payproc_ctx_payment(?cash(10), ?cash(10))
        end,
    ?LIMIT_REQUEST(RequestID, Changes) = Request0 = construct_request(C),
    Request1 = ?LIMIT_REQUEST(genlib:format("~s/~B", [RequestID, 1000]), Changes),
    ok = hold_and_assert_batch(10, Request0, Context, C),
    ok = lim_client:commit_batch(Request0, Context, ?config(client, C)),
    ok = hold_and_assert_batch(20, Request1, Context, C),
    ok = lim_client:commit_batch(Request1, Context, ?config(client, C)),
    ok = assert_values(20, Request1, Context, C).

-spec two_batch_rollback_ok(config()) -> _.
two_batch_rollback_ok(C) ->
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10));
            _Default -> ?payproc_ctx_payment(?cash(10), ?cash(10))
        end,
    ?LIMIT_REQUEST(RequestID, Changes) = Request0 = construct_request(C),
    Request1 = ?LIMIT_REQUEST(genlib:format("~s/~B", [RequestID, 1000]), Changes),
    ok = hold_and_assert_batch(10, Request0, Context, C),
    ok = hold_and_assert_batch(20, Request1, Context, C),
    ok = lim_client:rollback_batch(Request0, Context, ?config(client, C)),
    ok = assert_values(10, Request1, Context, C),
    ok = lim_client:rollback_batch(Request1, Context, ?config(client, C)),
    ok = assert_values(0, Request1, Context, C).

-spec retry_batch_hold_ok(config()) -> _.
retry_batch_hold_ok(C) ->
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(?cash(10));
            _Default -> ?payproc_ctx_payment(?cash(10), ?cash(10))
        end,
    ?LIMIT_REQUEST(RequestID, Changes) = Request0 = construct_request(C),
    Request1 = ?LIMIT_REQUEST(genlib:format("~s/~B", [RequestID, 1000]), Changes),
    Request2 = ?LIMIT_REQUEST(genlib:format("~s/~B", [RequestID, 2000]), Changes),
    ok = hold_and_assert_batch(10, Request0, Context, C),
    ok = assert_batch(10, Request0, Context, C),
    ok = hold_and_assert_batch(20, Request1, Context, C),
    ok = assert_batch(10, Request0, Context, C),
    ok = assert_batch(20, Request1, Context, C),
    ok = hold_and_assert_batch(30, Request2, Context, C),
    ok = assert_batch(10, Request0, Context, C),
    ok = assert_batch(20, Request1, Context, C),
    ok = assert_batch(30, Request2, Context, C),
    ok = lim_client:commit_batch(Request2, Context, ?config(client, C)),
    ok = assert_values(30, Request1, Context, C),
    ok = assert_batch(10, Request0, Context, C),
    ok = assert_batch(20, Request1, Context, C),
    ok = lim_client:rollback_batch(Request1, Context, ?config(client, C)),
    ok = assert_values(20, Request1, Context, C),
    ok = assert_batch(10, Request0, Context, C),
    ok = lim_client:commit_batch(Request0, Context, ?config(client, C)),
    ok = assert_values(20, Request1, Context, C).

-spec batch_commit_less_ok(config()) -> _.
batch_commit_less_ok(C) ->
    Cost = ?cash(1000, <<"RUB">>),
    CaptureCost = ?cash(800, <<"RUB">>),
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(Cost);
            _Default -> ?payproc_ctx_payment(Cost, CaptureCost)
        end,
    Request = construct_request(C),
    ok = hold_and_assert_batch(1000, Request, Context, C),
    ok = lim_client:commit_batch(Request, Context, ?config(client, C)),
    ok = assert_values(800, Request, Context, C).

-spec batch_commit_more_ok(config()) -> _.
batch_commit_more_ok(C) ->
    Cost = ?cash(1000, <<"RUB">>),
    CaptureCost = ?cash(1200, <<"RUB">>),
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(Cost);
            _Default -> ?payproc_ctx_payment(Cost, CaptureCost)
        end,
    Request = construct_request(C),
    ok = hold_and_assert_batch(1000, Request, Context, C),
    {exception, #base_InvalidRequest{errors = [<<"OperationNotFound">>]}} = lim_client:commit_batch(
        Request, Context, ?config(client, C)
    ).

-spec batch_commit_negative_ok(config()) -> _.
batch_commit_negative_ok(C) ->
    Cost = ?cash(-1000, <<"RUB">>),
    CaptureCost = ?cash(-1000, <<"RUB">>),
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(Cost);
            _Default -> ?payproc_ctx_payment(Cost, CaptureCost)
        end,
    Request = construct_request(C),
    ok = hold_and_assert_batch(-1000, Request, Context, C),
    ok = lim_client:commit_batch(Request, Context, ?config(client, C)),
    ok = assert_values(-1000, Request, Context, C).

-spec batch_commit_negative_less_ok(config()) -> _.
batch_commit_negative_less_ok(C) ->
    Cost = ?cash(-1000, <<"RUB">>),
    CaptureCost = ?cash(-800, <<"RUB">>),
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(Cost);
            _Default -> ?payproc_ctx_payment(Cost, CaptureCost)
        end,
    Request = construct_request(C),
    ok = hold_and_assert_batch(-1000, Request, Context, C),
    ok = lim_client:commit_batch(Request, Context, ?config(client, C)),
    ok = assert_values(-800, Request, Context, C).

-spec batch_commit_negative_more_ok(config()) -> _.
batch_commit_negative_more_ok(C) ->
    Cost = ?cash(-1000, <<"RUB">>),
    CaptureCost = ?cash(-1200, <<"RUB">>),
    Context =
        case get_group_name(C) of
            withdrawals -> ?wthdproc_ctx_withdrawal(Cost);
            _Default -> ?payproc_ctx_payment(Cost, CaptureCost)
        end,
    Request = construct_request(C),
    ok = hold_and_assert_batch(-1000, Request, Context, C),
    {exception, #base_InvalidRequest{errors = [<<"OperationNotFound">>]}} = lim_client:commit_batch(
        Request, Context, ?config(client, C)
    ).

%% Finalization behaviour group

-spec batch_with_invertable_rollback_ok(config()) -> _.
batch_with_invertable_rollback_ok(C) ->
    Context0 = ?payproc_ctx_payment(?string, ?string, ?cash(10), ?cash(10), undefined),
    ?LIMIT_REQUEST(_RequestID, _Changes) = Request0 = construct_request_with_invertable(C),
    ok = hold_and_assert_batch_with_invertable({1, 1, 10}, Request0, Context0, C),
    Context1 = ?payproc_ctx_payment(?string, ?string, ?cash(10), ?cash(10), undefined),
    ok = lim_client:rollback_batch(Request0, Context1, ?config(client, C)),
    ok = assert_values_with_invertable({0, 0, 0}, Request0, Context1, C).

-spec batch_with_invertable_rollback_with_session_ok(config()) -> _.
batch_with_invertable_rollback_with_session_ok(C) ->
    Context0 = ?payproc_ctx_payment(?string, ?string, ?cash(10), ?cash(10), undefined),
    ?LIMIT_REQUEST(_RequestID, _Changes) = Request0 = construct_request_with_invertable(C),
    ok = hold_and_assert_batch_with_invertable({1, 1, 10}, Request0, Context0, C),
    Context1 = ?payproc_ctx_payment(?string, ?string, ?cash(10), ?cash(10), ?payproc_ctx_session),
    ok = lim_client:rollback_batch(Request0, Context1, ?config(client, C)),
    ok = assert_values_with_invertable({1, 0, 0}, Request0, Context1, C).

-spec batch_with_invertable_commit_ok(config()) -> _.
batch_with_invertable_commit_ok(C) ->
    Context0 = ?payproc_ctx_payment(?string, ?string, ?cash(10), ?cash(10), undefined),
    ?LIMIT_REQUEST(_RequestID, _Changes) = Request0 = construct_request_with_invertable(C),
    ok = hold_and_assert_batch_with_invertable({1, 1, 10}, Request0, Context0, C),
    Context1 = ?payproc_ctx_payment(?string, ?string, ?cash(10), ?cash(10), undefined),
    ok = lim_client:commit_batch(Request0, Context1, ?config(client, C)),
    ok = assert_values_with_invertable({1, 1, 10}, Request0, Context1, C).

-spec batch_with_invertable_commit_with_session_ok(config()) -> _.
batch_with_invertable_commit_with_session_ok(C) ->
    Context0 = ?payproc_ctx_payment(?string, ?string, ?cash(10), ?cash(10), undefined),
    ?LIMIT_REQUEST(_RequestID, _Changes) = Request0 = construct_request_with_invertable(C),
    ok = hold_and_assert_batch_with_invertable({1, 1, 10}, Request0, Context0, C),
    Context1 = ?payproc_ctx_payment(?string, ?string, ?cash(10), ?cash(10), ?payproc_ctx_session),
    ok = lim_client:commit_batch(Request0, Context1, ?config(client, C)),
    ok = assert_values_with_invertable({0, 1, 10}, Request0, Context1, C).

construct_request_with_invertable(C) ->
    ID = ?config(id, C),
    ?LIMIT_REQUEST(ID, [
        construct_for_limit_change(ID, 0, ?turnover_metric_number(), ?finalization_behaviour_invertable_by_session, C),
        construct_for_limit_change(ID, 1, ?turnover_metric_number(), ?finalization_behaviour_normal, C),
        construct_for_limit_change(ID, 2, ?turnover_metric_amount(<<"RUB">>), undefined, C)
    ]).

hold_and_assert_batch_with_invertable({Value0, Value1, Value2}, Request0, Context, C) ->
    {ok, LimitStats} = lim_client:hold_batch(Request0, Context, ?config(client, C)),
    %% NOTE Split operations for invertablity can break order of items in
    %% response and mismatch it for limit changes provided in request.
    [LimitState0, LimitState1, LimitState2] = lists:sort(LimitStats),
    ?assertEqual(Value0, LimitState0#limiter_Limit.amount),
    ?assertEqual(Value1, LimitState1#limiter_Limit.amount),
    ?assertEqual(Value2, LimitState2#limiter_Limit.amount),
    {ok, [LimitState0 | [LimitState1 | [LimitState2]]]} = lim_client:get_values(Request0, Context, ?config(client, C)),
    ok.

assert_values_with_invertable({Value0, Value1, Value2}, Request0, Context, C) ->
    {ok, LimitStats} = lim_client:get_values(Request0, Context, ?config(client, C)),
    [LimitState0, LimitState1, LimitState2] = lists:sort(LimitStats),
    ?assertEqual(Value0, LimitState0#limiter_Limit.amount),
    ?assertEqual(Value1, LimitState1#limiter_Limit.amount),
    ?assertEqual(Value2, LimitState2#limiter_Limit.amount),
    ok.

%%

construct_for_limit_change(BaseID, Num, Metric, FinalizationBehaviour, C) ->
    {ID, Version} = configure_limit(
        ?time_range_month(),
        ?scopes([?scope_provider(), ?scope_payment_tool()]),
        Metric,
        undefined,
        genlib:format("~s/~B", [BaseID, Num]),
        FinalizationBehaviour,
        C
    ),
    ?LIMIT_CHANGE(ID, Version).

hold_and_assert_batch(Value, Request0, Context, C) ->
    {ok, [LimitState0 | [LimitState1 | [LimitState2]]]} = lim_client:hold_batch(Request0, Context, ?config(client, C)),
    ?assertEqual(Value, LimitState0#limiter_Limit.amount),
    ?assertEqual(Value, LimitState1#limiter_Limit.amount),
    ?assertEqual(Value, LimitState2#limiter_Limit.amount),
    {ok, [LimitState0 | [LimitState1 | [LimitState2]]]} = lim_client:get_values(Request0, Context, ?config(client, C)),
    ok.

assert_batch(BatchValue, Request0, Context, C) ->
    {ok, [LimitState0 | [LimitState1 | [LimitState2]]]} = lim_client:get_batch(Request0, Context, ?config(client, C)),
    ?assertEqual(BatchValue, LimitState0#limiter_Limit.amount),
    ?assertEqual(BatchValue, LimitState1#limiter_Limit.amount),
    ?assertEqual(BatchValue, LimitState2#limiter_Limit.amount),
    ok.

assert_values(Value, Request0, Context, C) ->
    {ok, [LimitState0 | [LimitState1 | [LimitState2]]]} = lim_client:get_values(Request0, Context, ?config(client, C)),
    ?assertEqual(Value, LimitState0#limiter_Limit.amount),
    ?assertEqual(Value, LimitState1#limiter_Limit.amount),
    ?assertEqual(Value, LimitState2#limiter_Limit.amount),
    ok.

hold_and_commit(Change, Context, Client) ->
    hold_and_commit(Change, Context, Context, Client).

hold_and_commit(?LIMIT_CHANGE(ID, Version) = Change, Context, ContextCommit, Client) ->
    OperationID = lim_string:join($., [<<"operation">>, ID, integer_to_binary(Version), genlib:unique()]),
    {ok, _} = lim_client:hold_batch(?LIMIT_REQUEST(OperationID, [Change]), Context, Client),
    ok = lim_client:commit_batch(?LIMIT_REQUEST(OperationID, [Change]), ContextCommit, Client).

mock_exchange(Rational, C) ->
    lim_mock:mock_services([{xrates, fun('GetConvertedAmount', _) -> {ok, Rational} end}], C).

configure_limit(TimeRange, Scopes, C) ->
    configure_limit(TimeRange, Scopes, ?turnover_metric_amount(<<"RUB">>), C).

configure_limit(TimeRange, Scopes, Metric, C) ->
    configure_limit(TimeRange, Scopes, Metric, undefined, C).

configure_limit(TimeRange, Scopes, Metric, CurrencyConversion, C) ->
    configure_limit(TimeRange, Scopes, Metric, CurrencyConversion, ?config(id, C), C).

configure_limit(TimeRange, Scopes, Metric, CurrencyConversion, ID, C) ->
    configure_limit(TimeRange, Scopes, Metric, CurrencyConversion, ID, {normal, #limiter_config_Normal{}}, C).

configure_limit(TimeRange, Scopes, Metric, CurrencyConversion, ID, FinalizationBehaviour, C) when is_list(Scopes) ->
    ContextType =
        case get_group_name(C) of
            withdrawals -> ?ctx_type_wthdproc();
            _Default -> ?ctx_type_payproc()
        end,
    create_limit_config(ID, #limiter_config_LimitConfig{
        processor_type = <<"TurnoverProcessor">>,
        started_at = <<"2000-01-01T00:00:00Z">>,
        shard_size = 1,
        time_range_type = TimeRange,
        context_type = ContextType,
        type = ?lim_type_turnover(Metric),
        scopes = Scopes,
        description = <<"Description">>,
        op_behaviour = ?op_behaviour(?op_subtraction()),
        currency_conversion = CurrencyConversion,
        finalization_behaviour = FinalizationBehaviour
    }).

create_limit_config(ID, #limiter_config_LimitConfig{} = LimitConfig) ->
    LimitConfigObject = #domain_LimitConfigObject{
        ref = #domain_LimitConfigRef{id = ID},
        data = LimitConfig
    },
    Version = dmt_client:insert({limit_config, LimitConfigObject}, ensure_stub_author()),
    {ID, Version}.

gen_unique_id(Prefix) ->
    genlib:format("~s/~B", [Prefix, lim_time:now()]).

get_group_name(C) ->
    GroupProps = ?config(tc_group_properties, C),
    proplists:get_value(name, GroupProps).

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
