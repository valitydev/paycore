-module(lim_mock_service).

-behaviour(woody_server_thrift_handler).

-export([handle_function/4]).

-type opts() :: #{
    function := fun((woody:func(), woody:args()) -> woody:result())
}.

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), opts()) -> {ok, term()}.
handle_function(FunName, Args, _, #{function := Fun}) ->
    Fun(FunName, Args).
