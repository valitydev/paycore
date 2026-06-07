-module(prg_machine_registry).

%%% Namespace -> handler module registry (ETS owner).

-behaviour(gen_server).

-define(TABLE, prg_machine_dispatch).
-define(SERVER, ?MODULE).

-export([get_child_spec/1]).
-export([start_link/1]).
-export([lookup/1]).
-export([ensure_table/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

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
    gen_server:start_link({local, ?SERVER}, ?MODULE, Handlers, []).

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

-spec init([module()]) -> {ok, #{handlers := [module()]}}.
init(Handlers) ->
    ok = ensure_table(),
    true = ets:insert(?TABLE, [{H:namespace(), H} || H <- Handlers]),
    {ok, #{handlers => Handlers}}.

-spec handle_call(term(), {pid(), term()}, map()) -> {reply, term(), map()}.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(_Info, State) ->
    {noreply, State}.
