-module(pm_accounting).

-export([get_account/1]).
-export([get_balance/1]).
-export([create_account/1]).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_accounter_thrift.hrl").

-type amount() :: dmsl_domain_thrift:'Amount'().
-type currency_code() :: dmsl_domain_thrift:'CurrencySymbolicCode'().
-type account_id() :: dmsl_accounter_thrift:'AccountID'().
-type thrift_account() :: dmsl_accounter_thrift:'Account'().

-type account() :: #{
    account_id => account_id(),
    currency_code => currency_code()
}.

-type balance() :: #{
    account_id => account_id(),
    own_amount => amount(),
    min_available_amount => amount(),
    max_available_amount => amount()
}.

-spec get_account(account_id()) -> account().
get_account(AccountID) ->
    Account = do_get_account(AccountID),
    construct_account(Account).

-spec get_balance(account_id()) -> balance().
get_balance(AccountID) ->
    Account = do_get_account(AccountID),
    construct_balance(Account).

-spec create_account(currency_code()) -> account_id().
create_account(CurrencyCode) ->
    create_account(CurrencyCode, undefined).

-spec create_account(currency_code(), binary() | undefined) -> account_id().
create_account(CurrencyCode, Description) ->
    case call_accounter('CreateAccount', {construct_prototype(CurrencyCode, Description)}) of
        {ok, Result} ->
            Result
    end.

-spec do_get_account(account_id()) -> thrift_account().
do_get_account(AccountID) ->
    case call_accounter('GetAccountByID', {AccountID}) of
        {ok, Result} ->
            Result;
        {exception, #accounter_AccountNotFound{}} ->
            pm_woody_wrapper:raise(#payproc_AccountNotFound{})
    end.

construct_prototype(CurrencyCode, Description) ->
    #accounter_AccountPrototype{
        currency_sym_code = CurrencyCode,
        description = Description,
        creation_time = pm_datetime:format_now()
    }.

%%

construct_account(
    #accounter_Account{
        id = AccountID,
        currency_sym_code = CurrencyCode
    }
) ->
    #{
        account_id => AccountID,
        currency_code => CurrencyCode
    }.

construct_balance(
    #accounter_Account{
        id = AccountID,
        own_amount = OwnAmount,
        min_available_amount = MinAvailableAmount,
        max_available_amount = MaxAvailableAmount
    }
) ->
    #{
        account_id => AccountID,
        own_amount => OwnAmount,
        min_available_amount => MinAvailableAmount,
        max_available_amount => MaxAvailableAmount
    }.

%%

call_accounter(Function, Args) ->
    pm_woody_wrapper:call(accounter, Function, Args).
