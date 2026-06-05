-module(prg_machine_env_mock_context).

-export([env_enter/1, env_leave/0]).
-export([reset/0, events/0, record/1]).

-spec env_enter(woody_context:ctx()) -> ok.
env_enter(WoodyCtx) ->
    record({enter, WoodyCtx}),
    ok.

-spec env_leave() -> ok.
env_leave() ->
    record(leave),
    ok.

-spec reset() -> ok.
reset() ->
    persistent_term:put({?MODULE, events}, []),
    ok.

-spec events() -> [enter | leave | {enter, woody_context:ctx()} | explicit_enter | explicit_leave].
events() ->
    persistent_term:get({?MODULE, events}, []).

-spec record(enter | leave | {enter, woody_context:ctx()} | explicit_enter | explicit_leave) -> ok.
record(Event) ->
    Events = persistent_term:get({?MODULE, events}, []),
    persistent_term:put({?MODULE, events}, Events ++ [Event]).
