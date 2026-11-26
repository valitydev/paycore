-module(op_context).

-export([create/0]).
-export([create/1]).
-export([save/2]).
-export([load/1]).
-export([cleanup/1]).
-export([cleanup/2]).

-export([key/1]).
-export([binding/1]).

-export([get_woody_context/1]).
-export([get_party_client_context/1]).
-export([set_party_client_context/2]).
-export([get_party_client/1]).
-export([set_party_client/2]).

-export([env_enter/2]).
-export([env_leave/1]).
-export([current_woody_context/0]).

-type scope() :: hellgate | fistful.
-type registry_key() :: {p, l, term()}.
-type cleanup_mode() :: strict | lenient.

-type binding() :: #{
    registry_key := registry_key(),
    cleanup_mode := cleanup_mode()
}.

-type context() :: #{
    woody_context := woody_context(),
    party_client_context := party_client_context(),
    party_client => party_client()
}.

-type options() :: #{
    woody_context => woody_context(),
    party_client_context => party_client_context(),
    party_client => party_client()
}.

-export_type([
    scope/0,
    registry_key/0,
    cleanup_mode/0,
    binding/0,
    context/0,
    options/0
]).

%% Internal types

-type woody_context() :: woody_context:ctx().
-type party_client() :: party_client:client().
-type party_client_context() :: party_client:context().

%% API

-spec create() -> context().
create() ->
    create(#{}).

-spec create(options()) -> context().
create(Options0) ->
    Options1 = ensure_woody_context_exists(Options0),
    ensure_party_context_exists(Options1).

-spec save(registry_key(), context()) -> ok.
save(RegistryKey, Context) ->
    true =
        try
            gproc:reg(RegistryKey, Context)
        catch
            error:badarg ->
                gproc:set_value(RegistryKey, Context)
        end,
    ok.

-spec load(registry_key()) -> context() | no_return().
load(RegistryKey) ->
    gproc:get_value(RegistryKey).

-spec cleanup(scope()) -> ok.
cleanup(Scope) when Scope =:= hellgate; Scope =:= fistful ->
    cleanup(key(Scope), cleanup_mode(Scope)).

-spec cleanup(registry_key(), cleanup_mode()) -> ok.
cleanup(RegistryKey, strict) ->
    true = gproc:unreg(RegistryKey),
    ok;
cleanup(RegistryKey, lenient) ->
    try
        true = gproc:unreg(RegistryKey)
    catch
        _:_ -> ok
    end,
    ok.

-spec key(scope()) -> registry_key().
key(hellgate) ->
    {p, l, stored_hg_context};
key(fistful) ->
    {p, l, {ff_context, stored_context}}.

-spec binding(scope()) -> binding().
binding(Scope) ->
    #{
        registry_key => key(Scope),
        cleanup_mode => cleanup_mode(Scope)
    }.

-spec env_enter(woody_context(), binding()) -> ok.
env_enter(WoodyCtx, #{registry_key := RegistryKey}) ->
    ok = save(
        RegistryKey,
        create(#{
            woody_context => WoodyCtx,
            party_client => party_client:create_client()
        })
    ).

-spec env_leave(binding()) -> ok.
env_leave(#{registry_key := RegistryKey, cleanup_mode := CleanupMode}) ->
    cleanup(RegistryKey, CleanupMode).

%% Resolve the woody context bound to the current process: try the hellgate
%% binding first, then the fistful one (their gproc keys differ, so there is no
%% collision), falling back to a fresh context with a warning. Replaces the old
%% global prg_machine woody_context_loader app-env hook.
-spec current_woody_context() -> woody_context().
current_woody_context() ->
    case try_load_woody_context([key(hellgate), key(fistful)]) of
        {ok, WoodyContext} ->
            WoodyContext;
        error ->
            _ = logger:warning(
                "op_context: no woody context bound to the current process, using a fresh one"
            ),
            woody_context:new()
    end.

-spec try_load_woody_context([registry_key()]) -> {ok, woody_context()} | error.
try_load_woody_context([]) ->
    error;
try_load_woody_context([Key | Rest]) ->
    try get_woody_context(load(Key)) of
        WoodyContext -> {ok, WoodyContext}
    catch
        _:_ -> try_load_woody_context(Rest)
    end.

-spec get_woody_context(context()) -> woody_context().
get_woody_context(#{woody_context := WoodyContext}) ->
    WoodyContext.

-spec get_party_client(context()) -> party_client().
get_party_client(#{party_client := PartyClient}) ->
    PartyClient;
get_party_client(Context) ->
    error(no_party_client, [Context]).

-spec set_party_client(party_client(), context()) -> context().
set_party_client(PartyClient, Context) ->
    Context#{party_client => PartyClient}.

-spec get_party_client_context(context()) -> party_client_context().
get_party_client_context(#{party_client_context := PartyContext}) ->
    PartyContext.

-spec set_party_client_context(party_client_context(), context() | options()) -> context().
set_party_client_context(PartyContext, Context) ->
    Context#{party_client_context => PartyContext}.

%% Internal functions

-spec cleanup_mode(scope()) -> cleanup_mode().
cleanup_mode(hellgate) ->
    strict;
cleanup_mode(fistful) ->
    lenient.

-spec ensure_woody_context_exists(options()) -> options().
ensure_woody_context_exists(#{woody_context := _WoodyContext} = Options) ->
    Options;
ensure_woody_context_exists(Options) ->
    Options#{woody_context => woody_context:new()}.

-spec ensure_party_context_exists(options()) -> context().
ensure_party_context_exists(#{party_client_context := _PartyContext} = Options) ->
    Options;
ensure_party_context_exists(#{woody_context := WoodyContext} = Options) ->
    set_party_client_context(party_client:create_context(#{woody_context => WoodyContext}), Options).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec colocated_keys_isolated_test() -> _.
colocated_keys_isolated_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(woody),
    WoodyHg = woody_context:add_meta(woody_context:new(), #{<<"app">> => <<"hg">>}),
    WoodyFf = woody_context:add_meta(woody_context:new(), #{<<"app">> => <<"ff">>}),
    try
        CtxHg = create(#{woody_context => WoodyHg}),
        CtxFf = create(#{woody_context => WoodyFf}),
        ok = save(key(hellgate), CtxHg),
        ok = save(key(fistful), CtxFf),
        CtxHgLoaded = load(key(hellgate)),
        CtxFfLoaded = load(key(fistful)),
        ?assertEqual(WoodyHg, get_woody_context(CtxHgLoaded)),
        ?assertEqual(WoodyFf, get_woody_context(CtxFfLoaded)),
        ?assertNotEqual(
            get_party_client_context(CtxHgLoaded),
            get_party_client_context(CtxFfLoaded)
        ),
        ok = cleanup(hellgate),
        CtxFfAfterHgCleanup = load(key(fistful)),
        ?assertEqual(WoodyFf, get_woody_context(CtxFfAfterHgCleanup)),
        ok = cleanup(fistful)
    after
        cleanup(key(hellgate), lenient),
        cleanup(fistful)
    end.

-spec scoped_helpers_test() -> _.
scoped_helpers_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(woody),
    WoodyCtx = woody_context:new(),
    try
        ok = save(key(fistful), create(#{woody_context => WoodyCtx})),
        ?assertEqual(WoodyCtx, get_woody_context(load(key(fistful)))),
        ok = cleanup(fistful),
        ok = cleanup(fistful)
    after
        cleanup(fistful)
    end.

-endif.
