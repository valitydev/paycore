-module(prg_machine_registry_tests).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec duplicate_namespace_test() -> _.
duplicate_namespace_test() ->
    Registration = #{handler => prg_machine_aux_state_test_handler, binding => op_context:binding(hellgate)},
    Conflict = Registration#{binding => op_context:binding(fistful)},
    ?assertEqual(
        {error, {duplicate_namespace, aux_state_test_ns}},
        prg_machine_registry:start_link([Registration, Conflict])
    ).
