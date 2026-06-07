-module(prg_machine_env_mock_handler).

-behaviour(prg_machine).

-export([namespace/0, init/2, process_signal/2, process_call/2, process_repair/2]).

-spec namespace() -> prg_machine:namespace().
namespace() ->
    env_test_ns.

-spec init(prg_machine:args(), prg_machine:machine()) -> prg_machine:result().
init(_Args, _Machine) ->
    #{events => [], action => progressor_action:new()}.

-spec process_signal(prg_machine:signal(), prg_machine:machine()) -> prg_machine:result().
process_signal(_Signal, _Machine) ->
    #{events => [], action => progressor_action:new()}.

-spec process_call(prg_machine:call(), prg_machine:machine()) -> {prg_machine:response(), prg_machine:result()}.
process_call(_Call, _Machine) ->
    {ok, #{events => [], action => progressor_action:new()}}.

-spec process_repair(prg_machine:args(), prg_machine:machine()) -> prg_machine:result() | {error, term()}.
process_repair(_Args, _Machine) ->
    #{events => [], action => progressor_action:new()}.
