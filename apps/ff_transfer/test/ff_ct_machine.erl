%%%
%%% Test machine — hooks prg_machine timeout processing for CT
%%%

-module(ff_ct_machine).

-export([load_per_suite/0]).
-export([unload_per_suite/0]).

-export([set_hook/2]).
-export([clear_hook/1]).

-define(DISPATCH_TABLE, prg_machine_dispatch).

-spec load_per_suite() -> ok.
load_per_suite() ->
    meck:new(prg_machine, [no_link, passthrough]),
    meck:expect(prg_machine, process, fun process/3).

-spec unload_per_suite() -> ok.
unload_per_suite() ->
    meck:unload(prg_machine).

-type hook() :: fun((prg_machine:machine(), module(), _) -> _).

-spec set_hook(timeout, hook()) -> ok.
set_hook(timeout = On, Fun) when is_function(Fun, 3) ->
    persistent_term:put({?MODULE, hook, On}, Fun).

-spec clear_hook(timeout) -> ok.
clear_hook(timeout = On) ->
    _ = persistent_term:erase({?MODULE, hook, On}),
    ok.

process({timeout, _BinArgs, #{process_id := ID} = _Process} = Call, #{ns := NS} = Opts, BinCtx) ->
    case persistent_term:get({?MODULE, hook, timeout}, undefined) of
        Fun when is_function(Fun, 3) ->
            Handler = handler_module(NS),
            {ok, Machine} = prg_machine:get(NS, ID),
            _ = Fun(Machine, Handler, undefined),
            meck:passthrough([prg_machine, process, [Call, Opts, BinCtx]]);
        undefined ->
            meck:passthrough([prg_machine, process, [Call, Opts, BinCtx]])
    end;
process(Call, Opts, BinCtx) ->
    meck:passthrough([prg_machine, process, [Call, Opts, BinCtx]]).

handler_module(NS) ->
    case ets:lookup(?DISPATCH_TABLE, NS) of
        [{NS, Handler}] ->
            Handler;
        [] ->
            erlang:error({unknown_namespace, NS})
    end.
