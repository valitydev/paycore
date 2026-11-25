-module(prg_machine_registry_tests).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec lookup_contract_test() -> _.
lookup_contract_test() ->
    Registration = registration(),
    OtherRegistration = #{handler => prg_machine_aux_state_test_handler, binding => op_context:binding(hellgate)},
    with_registry([Registration, OtherRegistration], fun() ->
        ?assertEqual({ok, prg_machine_env_mock_handler}, prg_machine_registry:lookup(env_test_ns)),
        ?assertEqual({ok, Registration}, prg_machine_registry:lookup_registration(env_test_ns)),
        ?assertEqual({ok, OtherRegistration}, prg_machine_registry:lookup_registration(aux_state_test_ns)),
        lists:foreach(
            fun(NS) ->
                Error = {error, {unknown_namespace, NS}},
                ?assertEqual(Error, prg_machine_registry:lookup(NS)),
                ?assertEqual(Error, prg_machine_registry:lookup_registration(NS))
            end,
            [unknown_registry_namespace, 'ff/unknown_registry_namespace']
        )
    end).

-spec duplicate_namespace_test() -> _.
duplicate_namespace_test() ->
    Registration = registration(),
    Alias = Registration#{handler => prg_machine_registry_namespace_alias, binding => op_context:binding(hellgate)},
    with_registry([Registration], fun() ->
        Owner = whereis(prg_machine_registry),
        ?assertEqual(
            {error, {duplicate_namespace, env_test_ns}},
            prg_machine_registry:start_link([Registration, Alias])
        ),
        ?assertEqual(Owner, whereis(prg_machine_registry)),
        ?assertEqual({ok, Registration}, prg_machine_registry:lookup_registration(env_test_ns))
    end).

-spec registry_restart_test() -> _.
registry_restart_test() ->
    Registration = registration(),
    FirstOwner = with_registry([Registration], fun() -> whereis(prg_machine_registry) end),
    Updated = Registration#{binding => op_context:binding(hellgate)},
    SecondOwner = with_registry([Updated], fun() ->
        ?assertEqual({ok, Updated}, prg_machine_registry:lookup_registration(env_test_ns)),
        whereis(prg_machine_registry)
    end),
    ?assertNotEqual(FirstOwner, SecondOwner).

registration() ->
    #{handler => prg_machine_env_mock_handler, binding => op_context:binding(fistful)}.

with_registry(Registrations, Run) ->
    {ok, Pid} = prg_machine_registry:start_link(Registrations),
    true = unlink(Pid),
    try
        Run()
    after
        ok = gen_server:stop(Pid)
    end.
