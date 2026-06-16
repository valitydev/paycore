-module(prg_machine_registry).

%%% Namespace -> handler module registry (ETS owner).

-define(TABLE, prg_machine_dispatch).
-define(SERVER, ?MODULE).

-export([get_child_spec/1]).
-export([start_link/1]).
-export([lookup/1]).
-export([ensure_table/0]).
-export([init/1]).

-spec get_child_spec([module()]) -> supervisor:child_spec().
get_child_spec(Handlers) ->
    #{
        id => prg_machine_registry,
        start => {?MODULE, start_link, [Handlers]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec start_link([module()]) -> {ok, pid()} | {error, term()}.
start_link(Handlers) ->
    proc_lib:start_link(?MODULE, init, [Handlers]).

-spec lookup(prg_machine:namespace()) -> {ok, module()} | {error, {unknown_namespace, prg_machine:namespace()}}.
lookup(NS) ->
    case ets:info(?TABLE) of
        undefined ->
            {error, {unknown_namespace, NS}};
        _ ->
            case ets:lookup(?TABLE, NS) of
                [{NS, Handler}] ->
                    {ok, Handler};
                [] ->
                    {error, {unknown_namespace, NS}}
            end
    end.

-spec ensure_table() -> ok.
ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            _ = ets:new(?TABLE, [named_table, set, protected, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

-spec init([module()]) -> ok.
init(Handlers) ->
    true = register(?SERVER, self()),
    ok = ensure_table(),
    true = ets:insert(?TABLE, [{prg_machine:handler_namespace(H), H} || H <- Handlers]),
    proc_lib:init_ack({ok, self()}),
    loop().

loop() ->
    receive
        stop ->
            ok;
        _Msg ->
            loop()
    end.
