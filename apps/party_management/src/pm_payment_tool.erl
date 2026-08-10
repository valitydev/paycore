%%% Payment tools

-module(pm_payment_tool).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").

%%

-export([create_from_method/1]).
-export([test_condition/3]).

%%

-type t() :: dmsl_domain_thrift:'PaymentTool'().
-type method() :: dmsl_domain_thrift:'PaymentMethodRef'().
-type condition() :: dmsl_domain_thrift:'PaymentToolCondition'().

-import(pm_condition, [some_defined/1, ternary_and/1, ternary_while/1]).

-spec create_from_method(method()) -> t().
%% TODO empty strings - ugly hack for dialyzar
create_from_method(#domain_PaymentMethodRef{
    id =
        {bank_card, #domain_BankCardPaymentMethod{
            payment_system = PaymentSystem,
            is_cvv_empty = IsCVVEmpty,
            payment_token = PaymentToken,
            tokenization_method = TokenizationMethod
        }}
}) ->
    {bank_card, #domain_BankCard{
        token = <<"">>,
        payment_system = PaymentSystem,
        bin = <<"">>,
        last_digits = <<"">>,
        payment_token = PaymentToken,
        tokenization_method = TokenizationMethod,
        is_cvv_empty = IsCVVEmpty
    }};
create_from_method(#domain_PaymentMethodRef{id = {payment_terminal, Ref}}) ->
    {payment_terminal, #domain_PaymentTerminal{payment_service = Ref}};
create_from_method(#domain_PaymentMethodRef{id = {digital_wallet, Ref}}) ->
    {digital_wallet, #domain_DigitalWallet{
        payment_service = Ref,
        id = <<"">>
    }};
create_from_method(#domain_PaymentMethodRef{id = {mobile, Ref}}) ->
    {mobile_commerce, #domain_MobileCommerce{
        operator = Ref,
        phone = #domain_MobilePhone{
            cc = <<"">>,
            ctn = <<"">>
        }
    }};
create_from_method(#domain_PaymentMethodRef{id = {crypto_currency, Ref}}) ->
    {crypto_currency, Ref};
create_from_method(#domain_PaymentMethodRef{id = {generic, Generic}}) ->
    {generic, #domain_GenericPaymentTool{
        payment_service = Generic#domain_GenericPaymentMethod.payment_service
    }}.

%%

-spec test_condition(condition(), t(), pm_domain:revision()) -> boolean() | undefined.
test_condition({bank_card, C}, {bank_card, V = #domain_BankCard{}}, Rev) ->
    test_bank_card_condition(C, V, Rev);
test_condition({payment_terminal, C}, {payment_terminal, V = #domain_PaymentTerminal{}}, _Rev) ->
    test_payment_terminal_condition(C, V);
test_condition({digital_wallet, C}, {digital_wallet, V = #domain_DigitalWallet{}}, _Rev) ->
    test_digital_wallet_condition(C, V);
test_condition({crypto_currency, C}, {crypto_currency, V}, _Rev) ->
    test_crypto_currency_condition(C, {ref, V});
test_condition({mobile_commerce, C}, {mobile_commerce, V}, _Rev) ->
    test_mobile_commerce_condition(C, V);
test_condition({generic, C}, {generic, V}, _Rev) ->
    test_generic_condition(C, V);
test_condition(_PaymentTool, _Condition, _Rev) ->
    false.

test_bank_card_condition(#domain_BankCardCondition{definition = Def}, V, Rev) when Def /= undefined ->
    test_bank_card_condition_def(Def, V, Rev);
test_bank_card_condition(#domain_BankCardCondition{}, _, _Rev) ->
    true.

test_bank_card_condition_def({payment_system, PaymentSystem}, V, _Rev) ->
    test_payment_system_condition(PaymentSystem, V);
test_bank_card_condition_def({issuer_country_is, IssuerCountry}, V, _Rev) ->
    test_issuer_country_condition(IssuerCountry, V);
test_bank_card_condition_def({issuer_bank_is, BankRef}, V, Rev) ->
    test_issuer_bank_condition(BankRef, V, Rev);
test_bank_card_condition_def({category_is, CategoryRef}, V, Rev) ->
    test_bank_card_category_condition(CategoryRef, V, Rev);
test_bank_card_condition_def(
    {empty_cvv_is, Val},
    #domain_BankCard{is_cvv_empty = Val},
    _Rev
) ->
    true;
%% Для обратной совместимости с картами, у которых нет is_cvv_empty
test_bank_card_condition_def(
    {empty_cvv_is, false},
    #domain_BankCard{is_cvv_empty = undefined},
    _Rev
) ->
    true;
test_bank_card_condition_def({empty_cvv_is, _Val}, #domain_BankCard{}, _Rev) ->
    false.

test_payment_system_condition(
    #domain_PaymentSystemCondition{
        payment_system_is = PsIs,
        token_service_is = TpIs,
        tokenization_method_is = TmIs
    },
    #domain_BankCard{
        payment_system = Ps,
        payment_token = Tp,
        tokenization_method = Tm
    }
) ->
    ternary_and([
        some_defined([PsIs, TpIs, TmIs]),
        PsIs == undefined orelse PsIs == Ps,
        TpIs == undefined orelse TpIs == Tp,
        TmIs == undefined orelse ternary_while([Tm, TmIs == Tm])
    ]).

test_issuer_country_condition(Country, #domain_BankCard{issuer_country = TargetCountry}) ->
    ternary_while([TargetCountry, Country == TargetCountry]).

test_issuer_bank_condition(BankRef, #domain_BankCard{bank_name = BankName, bin = BIN}, Rev) ->
    #domain_Bank{binbase_id_patterns = Patterns, bins = BINs} = pm_domain:get(Rev, {bank, BankRef}),
    case {Patterns, BankName} of
        {P, B} when is_list(P) and is_binary(B) ->
            test_bank_card_patterns(Patterns, BankName);
        % TODO т.к. BinBase не обладает полным объемом данных, при их отсутствии мы возвращаемся к проверкам по бинам.
        %      B будущем стоит избавиться от этого.
        {_, _} ->
            test_bank_card_bins(BIN, BINs)
    end.

test_bank_card_category_condition(CategoryRef, #domain_BankCard{category = Category}, Rev) ->
    #domain_BankCardCategory{
        category_patterns = Patterns
    } = pm_domain:get(Rev, {bank_card_category, CategoryRef}),
    test_bank_card_patterns(Patterns, Category).

test_bank_card_bins(BIN, BINs) ->
    ordsets:is_element(BIN, BINs).

test_bank_card_patterns(Patterns, BankName) ->
    Matches = ordsets:filter(fun(E) -> genlib_wildcard:match(BankName, E) end, Patterns),
    ordsets:size(Matches) > 0.

test_payment_terminal_condition(#domain_PaymentTerminalCondition{definition = Def}, V) ->
    Def =:= undefined orelse test_payment_terminal_condition_def(Def, V).

test_payment_terminal_condition_def(
    {payment_service_is, Ps1},
    #domain_PaymentTerminal{payment_service = Ps2}
) ->
    Ps1 =:= Ps2;
test_payment_terminal_condition_def(_Cond, _Data) ->
    false.

test_digital_wallet_condition(#domain_DigitalWalletCondition{definition = Def}, V) ->
    Def =:= undefined orelse test_digital_wallet_condition_def(Def, V).

test_digital_wallet_condition_def(
    {payment_service_is, Ps1},
    #domain_DigitalWallet{payment_service = Ps2}
) ->
    Ps1 =:= Ps2;
test_digital_wallet_condition_def(_Cond, _Data) ->
    false.

test_crypto_currency_condition(#domain_CryptoCurrencyCondition{definition = Def}, V) ->
    Def =:= undefined orelse test_crypto_currency_condition_def(Def, V).

test_crypto_currency_condition_def({crypto_currency_is, C1}, {ref, C2}) ->
    C1 =:= C2;
test_crypto_currency_condition_def(_Cond, _Data) ->
    false.

test_mobile_commerce_condition(#domain_MobileCommerceCondition{definition = Def}, V) ->
    Def =:= undefined orelse test_mobile_commerce_condition_def(Def, V).

test_mobile_commerce_condition_def(
    {operator_is, C1},
    #domain_MobileCommerce{operator = C2}
) ->
    C1 =:= C2;
test_mobile_commerce_condition_def(_Cond, _Data) ->
    false.

test_generic_condition({resource_field_matches, _}, #domain_GenericPaymentTool{data = undefined}) ->
    false;
test_generic_condition(
    {resource_field_matches, #domain_GenericResourceCondition{field_path = Path, value = Value}},
    #domain_GenericPaymentTool{data = #base_Content{type = Type, data = Data}}
) ->
    case decode_content(Type, Data) of
        {ok, Result} ->
            case get_field_by_path(Path, Result) of
                {ok, Value} -> true;
                _ -> false
            end;
        _ ->
            false
    end;
test_generic_condition({payment_service_is, Ref1}, #domain_GenericPaymentTool{payment_service = Ref2}) ->
    Ref1 =:= Ref2;
test_generic_condition(_Cond, _Data) ->
    false.

decode_content(<<"application/schema-instance+json; schema=", _/binary>>, Data) ->
    {ok, jsx:decode(Data)};
decode_content(<<"application/json">>, Data) ->
    {ok, jsx:decode(Data)};
decode_content(Type, _Data) ->
    {error, {unsupported, Type}}.

get_field_by_path([], Data) ->
    {ok, Data};
get_field_by_path([Key | Path], Data) ->
    case maps:get(Key, Data, undefined) of
        undefined -> {error, notfound};
        Value -> get_field_by_path(Path, Value)
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

%% In order to test nonsense condition
-dialyzer({nowarn_function, test_condition_test/0}).
-spec test_condition_test() -> _.
test_condition_test() ->
    RevisionUnused = 1,
    PaymentSystemRef = #domain_PaymentSystemRef{id = <<"id">>},
    BankCardTokenServiceRef = #domain_BankCardTokenServiceRef{id = <<"id">>},

    %% BankCard
    ?assertEqual(
        true,
        test_condition(
            {bank_card, #domain_BankCardCondition{}},
            {bank_card, #domain_BankCard{}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        true,
        test_condition(
            {bank_card, #domain_BankCardCondition{
                definition =
                    {payment_system, #domain_PaymentSystemCondition{
                        payment_system_is = PaymentSystemRef
                    }}
            }},
            {bank_card, #domain_BankCard{payment_system = PaymentSystemRef}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        true,
        test_condition(
            {bank_card, #domain_BankCardCondition{
                definition =
                    {payment_system, #domain_PaymentSystemCondition{
                        token_service_is = BankCardTokenServiceRef
                    }}
            }},
            {bank_card, #domain_BankCard{payment_token = BankCardTokenServiceRef}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        true,
        test_condition(
            {bank_card, #domain_BankCardCondition{
                definition =
                    {payment_system, #domain_PaymentSystemCondition{
                        tokenization_method_is = dpan
                    }}
            }},
            {bank_card, #domain_BankCard{tokenization_method = dpan}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        true,
        test_condition(
            {bank_card, #domain_BankCardCondition{definition = {issuer_country_is, 'RUS'}}},
            {bank_card, #domain_BankCard{issuer_country = 'RUS'}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        true,
        test_condition(
            {bank_card, #domain_BankCardCondition{definition = {empty_cvv_is, true}}},
            {bank_card, #domain_BankCard{is_cvv_empty = true}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        false,
        test_condition(
            {bank_card, #domain_BankCardCondition{definition = {empty_cvv_is, true}}},
            {bank_card, #domain_BankCard{}},
            RevisionUnused
        )
    ),

    PaymentServiceRef = #domain_PaymentServiceRef{id = <<"id">>},
    %% PaymentTerminal
    ?assertEqual(
        true,
        test_condition(
            {payment_terminal, #domain_PaymentTerminalCondition{definition = {payment_service_is, PaymentServiceRef}}},
            {payment_terminal, #domain_PaymentTerminal{payment_service = PaymentServiceRef}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        false,
        test_condition(
            {payment_terminal, #domain_PaymentTerminalCondition{definition = nonsense}},
            {payment_terminal, #domain_PaymentTerminal{}},
            RevisionUnused
        )
    ),

    %% DigitalWallet
    ?assertEqual(
        true,
        test_condition(
            {digital_wallet, #domain_DigitalWalletCondition{definition = {payment_service_is, PaymentServiceRef}}},
            {digital_wallet, #domain_DigitalWallet{payment_service = PaymentServiceRef}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        false,
        test_condition(
            {digital_wallet, #domain_DigitalWalletCondition{definition = nonsense}},
            {digital_wallet, #domain_DigitalWallet{}},
            RevisionUnused
        )
    ),

    %% MobileCommerce
    MobileOperatorRef = #domain_MobileOperatorRef{id = <<"id">>},
    ?assertEqual(
        true,
        test_condition(
            {mobile_commerce, #domain_MobileCommerceCondition{definition = {operator_is, MobileOperatorRef}}},
            {mobile_commerce, #domain_MobileCommerce{operator = MobileOperatorRef}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        false,
        test_condition(
            {mobile_commerce, #domain_MobileCommerceCondition{definition = nonsense}},
            {mobile_commerce, #domain_MobileCommerce{}},
            RevisionUnused
        )
    ),

    %% Generic
    ?assertEqual(
        true,
        test_condition(
            {generic, {payment_service_is, PaymentServiceRef}},
            {generic, #domain_GenericPaymentTool{payment_service = PaymentServiceRef}},
            RevisionUnused
        )
    ),
    ?assertEqual(
        false,
        test_condition(
            {generic, nonsense},
            {generic, #domain_GenericPaymentTool{}},
            RevisionUnused
        )
    ).

-endif.
