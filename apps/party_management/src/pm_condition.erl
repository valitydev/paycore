-module(pm_condition).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("party_management/include/domain.hrl").

%%

-export([test/3]).
-export([some_defined/1]).
-export([ternary_and/1]).
-export([ternary_or/1]).
-export([ternary_while/1]).

%%
-export_type([ternary_term/0]).
-export_type([ternary_value/0]).

-type condition() :: dmsl_domain_thrift:'Condition'().
-type varset() :: pm_selector:varset().
-type ternary_term() :: ternary_lazy_term() | ternary_simple_term().
-type ternary_lazy_term() :: fun(() -> ternary_simple_term()).
%% Any (any()) other value is evaluated as true
-type ternary_simple_term() :: ternary_value() | any().
-type ternary_value() :: true | undefined | false.

-spec test(condition(), varset(), pm_domain:revision()) -> true | false | undefined.
test({category_is, V1}, #{category := V2}, _) ->
    V1 =:= V2;
test({currency_is, V1}, #{currency := V2}, _) ->
    V1 =:= V2;
test({cost_in, V}, #{cost := C}, _) ->
    pm_cash_range:is_inside(C, V) =:= within;
test({cost_is_multiple_of, V}, #{cost := C}, _) ->
    test_cash_is_multiple_of(C, V);
test({payment_tool, C}, #{payment_tool := V}, Rev) ->
    pm_payment_tool:test_condition(C, V, Rev);
test({shop_location_is, V}, #{shop := S}, _) ->
    V =:= S#domain_ShopConfig.location;
test({party, V}, #{party_ref := PartyRef} = VS, _) ->
    test_party(V, PartyRef, VS);
test({identification_level_is, V1}, #{identification_level := V2}, _) ->
    V1 =:= V2;
test({bin_data, #domain_BinDataCondition{} = C}, #{bin_data := #domain_BinData{} = V}, Rev) ->
    test_bindata_tool(C, V, Rev);
test({trust_level_is, V1}, #{trust_level := V2}, _) ->
    V1 =:= V2;
test(_, #{}, _) ->
    undefined.

test_party(#domain_PartyCondition{party_ref = PartyRef, definition = Def}, PartyRef, VS) ->
    test_party_definition(Def, VS);
test_party(_, _, _) ->
    false.

test_party_definition(undefined, _) ->
    true;
test_party_definition({shop_is, ID1}, #{shop_id := ID2}) ->
    ID1 =:= ID2;
test_party_definition({wallet_is, ID1}, #{wallet_id := ID2}) ->
    ID1 =:= ID2;
test_party_definition(_, _) ->
    undefined.

test_bindata_tool(
    #domain_BinDataCondition{
        payment_system = PaymentSystemCondition,
        bank_name = BankNameCondition
    },
    #domain_BinData{
        payment_system = PaymentSystem,
        bank_name = BankName
    },
    _Rev
) ->
    ternary_and([
        ternary_or([
            PaymentSystemCondition == undefined,
            fun() -> test_string_condition(PaymentSystemCondition, PaymentSystem) end
        ]),
        ternary_or([
            BankNameCondition == undefined,
            fun() -> test_string_condition(BankNameCondition, BankName) end
        ])
    ]).

test_string_condition({matches, Substring}, String) ->
    string:find(String, Substring) /= nomatch;
test_string_condition({equals, String1}, String2) ->
    String1 =:= String2.

-spec some_defined(list()) -> boolean().
some_defined(List) ->
    genlib_list:compact(List) /= [].

%% Ternary AND
%% Truth-table
%%   T U F
%% T T U F
%% U U U F
%% F F F F
%% Empty list is undefined
%% Lazily-evaluated if applicable
-spec ternary_and([ternary_term()]) -> ternary_value().
ternary_and([]) ->
    undefined;
ternary_and(List) ->
    genlib_list:foldl_while(
        fun(Elem, Acc) ->
            case ternary_and(compute_term(Elem), Acc) of
                false -> {halt, false};
                Result -> {cont, Result}
            end
        end,
        true,
        List
    ).

%% Ternary OR
%% Truth-table
%%   T U F
%% T T T T
%% U T U U
%% F T U F
%% Empty list is undefined
%% Lazily-evaluated if applicable
-spec ternary_or([ternary_term()]) -> ternary_value().
ternary_or([]) ->
    undefined;
ternary_or(List) ->
    genlib_list:foldl_while(
        fun(Elem, Acc) ->
            case ternary_or(compute_term(Elem), Acc) of
                true -> {halt, true};
                Result -> {cont, Result}
            end
        end,
        false,
        List
    ).

%% Similar to Ternary AND, but stops on any non-true value
%% Useful for calculating applications with possibly-defined dependencies, like:
%% ternary_while([Arg1, Arg2, fun () -> fn(Arg1, Arg2) end])
%% Truth-table
%%   T U F
%% T T U F
%% U U U U
%% F F F F
%% (T if all arguments are T, first non-T arg otherwise)
%% Empty list is undefined
%% Lazily-evaluated if applicable
-spec ternary_while([ternary_term()]) -> ternary_value().
ternary_while(Terms) ->
    genlib_list:foldl_while(
        fun(Term, _) ->
            case compute_term(Term) of
                true -> {cont, true};
                Result -> {halt, Result}
            end
        end,
        undefined,
        Terms
    ).

ternary_and(true, true) ->
    true;
ternary_and(MaybeLeftFalse, MaybeRightFalse) when MaybeLeftFalse == false; MaybeRightFalse == false ->
    false;
ternary_and(MaybeLeftUndef, MaybeRightUndef) when MaybeLeftUndef == undefined; MaybeRightUndef == undefined ->
    undefined.

ternary_or(false, false) ->
    false;
ternary_or(MaybeLeftTrue, MaybeRightTrue) when MaybeLeftTrue == true; MaybeRightTrue == true ->
    true;
ternary_or(MaybeLeftUndef, MaybeRightUndef) when MaybeLeftUndef == undefined; MaybeRightUndef == undefined ->
    undefined.

compute_term(Fun) when is_function(Fun, 0) -> to_ternary_bool(Fun());
compute_term(Term) -> to_ternary_bool(Term).

to_ternary_bool(Bool) when is_boolean(Bool) -> Bool;
to_ternary_bool(undefined) -> undefined;
to_ternary_bool(_) -> true.

test_cash_is_multiple_of(
    #domain_Cash{amount = A1, currency = C},
    #domain_Cash{amount = A2, currency = C}
) ->
    A1 rem A2 =:= 0;
test_cash_is_multiple_of(_, _) ->
    false.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec some_defined_empty_test() -> _.
some_defined_empty_test() ->
    ?assertEqual(false, some_defined([])).

-spec some_defined_undefined_test() -> _.
some_defined_undefined_test() ->
    ?assertEqual(false, some_defined([undefined, undefined, undefined])).

-spec some_defined_defined_test() -> _.
some_defined_defined_test() ->
    ?assertEqual(true, some_defined([undefined, undefined, true])).

-spec ternary_and_empty_args_test() -> _.
ternary_and_empty_args_test() ->
    ?assertEqual(undefined, ternary_and([])).

-spec ternary_and_truth_table_test() -> _.
ternary_and_truth_table_test() ->
    Table = [
        {true, true, true},
        {true, undefined, undefined},
        {true, false, false},
        {undefined, true, undefined},
        {undefined, undefined, undefined},
        {undefined, false, false},
        {false, true, false},
        {false, undefined, false},
        {false, false, false}
    ],
    lists:foreach(
        fun({L, R, Result}) ->
            ?assertEqual(Result, ternary_and([L, R]))
        end,
        Table
    ).

-spec ternary_or_empty_args_test() -> _.
ternary_or_empty_args_test() ->
    ?assertEqual(undefined, ternary_or([])).

-spec ternary_or_truth_table_test() -> _.
ternary_or_truth_table_test() ->
    Table = [
        {true, true, true},
        {true, undefined, true},
        {true, false, true},
        {undefined, true, true},
        {undefined, undefined, undefined},
        {undefined, false, undefined},
        {false, true, true},
        {false, undefined, undefined},
        {false, false, false}
    ],
    lists:foreach(
        fun({L, R, Result}) ->
            ?assertEqual(Result, ternary_or([L, R]))
        end,
        Table
    ).

-spec ternary_while_truth_table_test() -> _.
ternary_while_truth_table_test() ->
    Table = [
        {true, true, true},
        {true, undefined, undefined},
        {true, false, false},
        {undefined, true, undefined},
        {undefined, undefined, undefined},
        {undefined, false, undefined},
        {false, true, false},
        {false, undefined, false},
        {false, false, false}
    ],
    lists:foreach(
        fun({L, R, Result}) ->
            ?assertEqual(Result, ternary_while([L, R]))
        end,
        Table
    ).

-spec cash_is_multiple_of_condition_test() -> _.
cash_is_multiple_of_condition_test() ->
    Currency1 = <<"RUB">>,
    Currency2 = <<"USD">>,
    _ = [
        ?assertEqual(test_cash_is_multiple_of(?cash(10, Currency1), ?cash(5, Currency1)), true),
        ?assertEqual(test_cash_is_multiple_of(?cash(10, Currency1), ?cash(7, Currency1)), false),
        ?assertEqual(test_cash_is_multiple_of(?cash(10, Currency1), ?cash(5, Currency2)), false)
    ].

-endif.
