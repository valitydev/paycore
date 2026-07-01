-module(prg_machine_env_mock_handler).

-behaviour(prg_machine).

-export([
    namespace/0,
    init/2,
    process_signal/2,
    process_call/2,
    process_repair/2,
    process_notification/2,
    marshal_event_body/2,
    unmarshal_event_body/1,
    marshal_aux_state/1,
    unmarshal_aux_state/1,
    apply_event/4
]).

-spec namespace() -> prg_machine:namespace().
namespace() ->
    env_test_ns.

-spec init(prg_machine:args(), prg_machine:machine()) -> prg_machine:result().
init(_Args, #{namespace := NS}) ->
    Scope = op_context:scope_for_namespace(NS),
    try
        _ = op_context:load(op_context:key(Scope)),
        prg_machine_env_mock_context:record({context_bound, Scope})
    catch
        _:_ ->
            ok
    end,
    #{events => [], action => idle}.

-spec process_signal(prg_machine:signal(), prg_machine:machine()) -> prg_machine:result().
process_signal(_Signal, _Machine) ->
    #{events => [], action => idle}.

-spec process_call(prg_machine:call(), prg_machine:machine()) -> {prg_machine:response(), prg_machine:result()}.
process_call(_Call, _Machine) ->
    {ok, #{events => [], action => idle}}.

-spec process_repair(prg_machine:args(), prg_machine:machine()) -> prg_machine:result() | {error, term()}.
process_repair(_Args, _Machine) ->
    #{events => [], action => idle}.

-spec process_notification(prg_machine:args(), prg_machine:machine()) -> prg_machine:result().
process_notification(_Args, _Machine) ->
    #{}.

-spec marshal_event_body(prg_machine:timestamp(), prg_machine:event_body()) -> {undefined, binary()}.
marshal_event_body(_Timestamp, Body) ->
    {undefined, term_to_binary(Body)}.

-spec unmarshal_event_body(binary()) -> prg_machine:event_body().
unmarshal_event_body(Payload) ->
    binary_to_term(Payload, [safe]).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    term_to_binary(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(<<>>) ->
    #{};
unmarshal_aux_state(Bin) when is_binary(Bin) ->
    binary_to_term(Bin, [safe]).

-spec apply_event(
    prg_machine:event_id(),
    prg_machine:timestamp(),
    prg_machine:event_body(),
    term()
) -> term().
apply_event(_EventID, _Ts, _Body, Model) ->
    Model.
