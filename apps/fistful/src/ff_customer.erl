-module(ff_customer).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_customer_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-type id() :: dmsl_customer_thrift:'CustomerID'().
-type withdrawal_id() :: dmsl_customer_thrift:'WithdrawalID'().

-export_type([id/0]).

-export([check/2]).
-export([add_withdrawal/3]).

%% A withdrawal is made for a Customer linked to its party. One that is unknown, or linked to
%% other parties only, is not found
-spec check(id(), ff_party:id()) -> ok | {error, notfound}.
check(CustomerID, PartyID) ->
    case call('Get', {CustomerID, #domain_PartyConfigRef{id = PartyID}}) of
        {ok, #customer_CustomerState{}} ->
            ok;
        {exception, #customer_CustomerNotFound{}} ->
            {error, notfound}
    end.

%% cubasty is part of the core: a failure is not swallowed but fails the caller, so that the
%% machine step is retried. The call is idempotent, so a retried step records the withdrawal once.
%% Only answers a retry would not change are handled
-spec add_withdrawal(id(), withdrawal_id(), ff_party:id()) -> ok.
add_withdrawal(CustomerID, WithdrawalID, PartyID) ->
    PartyRef = #domain_PartyConfigRef{id = PartyID},
    case call('AddWithdrawal', {CustomerID, WithdrawalID, PartyRef}) of
        {ok, ok} ->
            ok;
        %% A Customer deleted mid-withdrawal has no history to record the withdrawal in
        {exception, #customer_CustomerNotFound{}} ->
            ok;
        %% The withdrawal is already recorded for another Customer: it points at a bug worth seeing
        {exception, #base_InvalidRequest{errors = Errors}} ->
            _ = logger:error("Customer withdrawal record rejected: ~p", [Errors]),
            ok
    end.

call(Function, Args) ->
    Service = {dmsl_customer_thrift, 'CustomerManagement'},
    ff_woody_client:call(customer_management, {Service, Function, Args}).
