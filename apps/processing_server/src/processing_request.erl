-module(processing_request).

-export([run/3]).
-export([create_context/2]).
-export([ensure_deadline/2]).

-export_type([options/0]).

-type options() :: #{
    binding := op_context:binding(),
    handler := module(),
    function := woody:func(),
    party_client => party_client:client(),
    default_handling_timeout => timeout()
}.

-define(DEFAULT_HANDLING_TIMEOUT, 30000).

%% Wrappers keep their handler arguments, return values and business exceptions.
%% This module owns only the lifetime and measurement of a single RPC request.
-spec run(woody_context:ctx(), options(), fun(() -> Result)) -> Result.
run(WoodyContext0, #{binding := Binding, handler := Handler, function := Function} = Options, Handle) ->
    #{registry_key := Key, cleanup_mode := CleanupMode} = Binding,
    WoodyContext = ensure_deadline(WoodyContext0, Options),
    Context = create_context(WoodyContext, Options),
    ok = op_context:save(Key, Context),
    try
        measure(Handler, Function, Handle)
    after
        op_context:cleanup(Key, CleanupMode)
    end.

-spec create_context(woody_context:ctx(), map()) -> op_context:context().
create_context(WoodyContext, Options) ->
    ContextOptions = maps:with([party_client], Options),
    op_context:create(ContextOptions#{woody_context => WoodyContext}).

-spec ensure_deadline(woody_context:ctx(), map()) -> woody_context:ctx().
ensure_deadline(WoodyContext, Options) ->
    case woody_context:get_deadline(WoodyContext) of
        undefined ->
            Timeout = maps:get(default_handling_timeout, Options, ?DEFAULT_HANDLING_TIMEOUT),
            woody_context:set_deadline(woody_deadline:from_timeout(Timeout), WoodyContext);
        _Deadline ->
            WoodyContext
    end.

measure(Handler, Function, Handle) ->
    {DurationMicro, Result} = timer:tc(Handle),
    Labels = [atom_to_binary(Handler), atom_to_binary(Function)],
    ok = prometheus_histogram:observe(
        woody_wrapper_processing_duration_ms,
        Labels,
        DurationMicro div 1000
    ),
    Result.
