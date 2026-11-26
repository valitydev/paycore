-module(prg_machine_registry).

%%% Namespace -> handler and operation context binding (ETS owner).

-behaviour(gen_server).

-define(TABLE, prg_machine_dispatch).
-define(SERVER, ?MODULE).

-export([get_child_spec/1]).
-export([start_link/1]).
-export([lookup/1]).
-export([lookup_registration/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-type registration() :: #{handler := module(), binding := op_context:binding()}.
-type entry() :: {prg_machine:namespace(), registration()}.

-record(state, {}).

-type state() :: #state{}.

-spec get_child_spec([registration()]) -> supervisor:child_spec().
get_child_spec(Registrations) ->
    #{
        id => prg_machine_registry,
        start => {?MODULE, start_link, [Registrations]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec start_link([registration()]) -> {ok, pid()} | {error, term()}.
start_link(Registrations) ->
    case prepare_entries(Registrations, #{}) of
        {ok, Entries} -> gen_server:start_link({local, ?SERVER}, ?MODULE, Entries, []);
        {error, _} = Error -> Error
    end.

-spec lookup(prg_machine:namespace()) -> {ok, module()} | {error, {unknown_namespace, prg_machine:namespace()}}.
lookup(NS) ->
    case lookup_registration(NS) of
        {ok, #{handler := Handler}} -> {ok, Handler};
        {error, _} = Error -> Error
    end.

-spec lookup_registration(prg_machine:namespace()) ->
    {ok, registration()} | {error, {unknown_namespace, prg_machine:namespace()}}.
lookup_registration(NS) ->
    case ets:lookup(?TABLE, NS) of
        [{NS, Registration}] -> {ok, Registration};
        [] -> {error, {unknown_namespace, NS}}
    end.

%% Resolve and validate all namespaces before starting the owner or publishing entries.
prepare_entries([], Entries) ->
    {ok, maps:to_list(Entries)};
prepare_entries([#{handler := Handler, binding := _Binding} = Registration | Rest], Entries) ->
    NS = prg_machine:handler_namespace(Handler),
    case maps:is_key(NS, Entries) of
        true -> {error, {duplicate_namespace, NS}};
        false -> prepare_entries(Rest, Entries#{NS => Registration})
    end.

-spec init([entry()]) -> {ok, state()}.
init(Entries) ->
    _ = ets:new(?TABLE, [named_table, set, protected, {read_concurrency, true}]),
    true = ets:insert(?TABLE, Entries),
    {ok, #state{}}.

-spec handle_call(term(), {pid(), term()}, state()) -> {reply, term(), state()}.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(_Info, State) ->
    {noreply, State}.
