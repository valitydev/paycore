-module(operation_context).

-export([create/0]).
-export([create/1]).
-export([save/2]).
-export([load/1]).
-export([cleanup/2]).

-export([save_hellgate/1]).
-export([load_hellgate/0]).
-export([cleanup_hellgate/0]).

-export([save_fistful/1]).
-export([load_fistful/0]).
-export([cleanup_fistful/0]).

-export([get_woody_context/1]).
-export([set_woody_context/2]).
-export([get_party_client_context/1]).
-export([set_party_client_context/2]).
-export([get_party_client/1]).
-export([set_party_client/2]).

-export([hellgate_binding/0]).
-export([fistful_binding/0]).
-export([env_enter/2]).
-export([env_leave/1]).

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

-define(HG_REGISTRY_KEY, {p, l, stored_hg_context}).
-define(FF_REGISTRY_KEY, {p, l, {ff_context, stored_context}}).

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

-spec save_hellgate(context()) -> ok.
save_hellgate(Context) ->
    save(?HG_REGISTRY_KEY, Context).

-spec load_hellgate() -> context() | no_return().
load_hellgate() ->
    load(?HG_REGISTRY_KEY).

-spec cleanup_hellgate() -> ok.
cleanup_hellgate() ->
    cleanup(?HG_REGISTRY_KEY, strict).

-spec save_fistful(context()) -> ok.
save_fistful(Context) ->
    save(?FF_REGISTRY_KEY, Context).

-spec load_fistful() -> context() | no_return().
load_fistful() ->
    load(?FF_REGISTRY_KEY).

-spec cleanup_fistful() -> ok.
cleanup_fistful() ->
    cleanup(?FF_REGISTRY_KEY, lenient).

-spec hellgate_binding() -> binding().
hellgate_binding() ->
    #{
        registry_key => ?HG_REGISTRY_KEY,
        cleanup_mode => strict
    }.

-spec fistful_binding() -> binding().
fistful_binding() ->
    #{
        registry_key => ?FF_REGISTRY_KEY,
        cleanup_mode => lenient
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

-spec get_woody_context(context()) -> woody_context().
get_woody_context(#{woody_context := WoodyContext}) ->
    WoodyContext.

-spec set_woody_context(woody_context(), context()) -> context().
set_woody_context(WoodyContext, Context) ->
    Context#{woody_context => WoodyContext}.

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

-define(HG_TEST_KEY, {p, l, stored_hg_context}).
-define(FF_TEST_KEY, {p, l, {ff_context, stored_context}}).

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
        ok = save(?HG_TEST_KEY, CtxHg),
        ok = save(?FF_TEST_KEY, CtxFf),
        CtxHgLoaded = load(?HG_TEST_KEY),
        CtxFfLoaded = load(?FF_TEST_KEY),
        ?assertEqual(WoodyHg, get_woody_context(CtxHgLoaded)),
        ?assertEqual(WoodyFf, get_woody_context(CtxFfLoaded)),
        ?assertNotEqual(
            get_party_client_context(CtxHgLoaded),
            get_party_client_context(CtxFfLoaded)
        ),
        ok = cleanup(?HG_TEST_KEY, strict),
        CtxFfAfterHgCleanup = load(?FF_TEST_KEY),
        ?assertEqual(WoodyFf, get_woody_context(CtxFfAfterHgCleanup)),
        ok = cleanup(?FF_TEST_KEY, lenient)
    after
        cleanup(?HG_TEST_KEY, lenient),
        cleanup(?FF_TEST_KEY, lenient)
    end.

-spec scoped_helpers_test() -> _.
scoped_helpers_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(woody),
    WoodyCtx = woody_context:new(),
    try
        ok = save_fistful(create(#{woody_context => WoodyCtx})),
        ?assertEqual(WoodyCtx, get_woody_context(load_fistful())),
        ok = cleanup_fistful(),
        ok = cleanup_fistful()
    after
        cleanup_fistful()
    end.

-endif.
