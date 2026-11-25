-module(prg_machine_registry_namespace_alias).

-export([namespace/0]).

-spec namespace() -> prg_machine:namespace().
namespace() ->
    prg_machine_env_mock_handler:namespace().
