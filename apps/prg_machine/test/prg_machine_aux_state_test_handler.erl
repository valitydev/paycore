-module(prg_machine_aux_state_test_handler).

%%% Test handler: aux_state corruption scenarios (H1/H2/M1).

-behaviour(prg_machine).

-export([
    namespace/0,
    init/2,
    process_signal/2,
    process_call/2,
    process_repair/2,
    marshal_aux_state/1,
    unmarshal_aux_state/1
]).

-define(NS, aux_state_test_ns).

-spec namespace() -> prg_machine:namespace().
namespace() ->
    ?NS.

-spec init(prg_machine:args(), prg_machine:machine()) -> prg_machine:result().
init(_Args, _Machine) ->
    #{
        events => [],
        action => idle,
        auxst => #{model => initialized}
    }.

-spec process_signal(prg_machine:signal(), prg_machine:machine()) -> prg_machine:result().
process_signal(timeout, Machine) ->
    _ = prg_machine:collapse(?MODULE, Machine),
    #{events => [], action => idle}.

-spec process_call(prg_machine:call(), prg_machine:machine()) ->
    {prg_machine:response(), prg_machine:result()}.
process_call(business_exception, _Machine) ->
    {{exception, {business, rejected}}, #{}};
process_call(crash, _Machine) ->
    erlang:error(deliberate_crash);
process_call(recheck, Machine) ->
    Model = prg_machine:collapse(?MODULE, Machine),
    {ok, #{events => [], action => idle, auxst => #{model => Model}}}.

-spec process_repair(prg_machine:args(), prg_machine:machine()) -> prg_machine:result() | {error, term()}.
process_repair(_Args, _Machine) ->
    #{events => [], action => idle}.

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(undefined) ->
    %% Mimics hg_invoice: marshaling undefined yields a non-empty corrupting binary.
    term_to_binary({corrupt, undefined});
marshal_aux_state(AuxSt) ->
    term_to_binary(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(<<>>) ->
    #{};
unmarshal_aux_state(Bin) when is_binary(Bin) ->
    binary_to_term(Bin, [safe]).
