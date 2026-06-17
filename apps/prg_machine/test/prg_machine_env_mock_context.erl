-module(prg_machine_env_mock_context).

-export([reset/0, events/0, record/1]).

-spec reset() -> ok.
reset() ->
    persistent_term:put({?MODULE, events}, []),
    ok.

-spec events() -> [context_bound].
events() ->
    persistent_term:get({?MODULE, events}, []).

-spec record(context_bound) -> ok.
record(Event) ->
    Events = persistent_term:get({?MODULE, events}, []),
    persistent_term:put({?MODULE, events}, Events ++ [Event]).
