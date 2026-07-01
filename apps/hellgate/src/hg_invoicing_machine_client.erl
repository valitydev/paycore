-module(hg_invoicing_machine_client).

%%% Thrift RPC to invoicing machines via progressor.
%%% Call args are Erlang thrift terms; prg_machine encodes them with term_to_binary.
%%% hg_proto stays in apps/hellgate (not in prg_machine).

-export([thrift_call/5]).

-type namespace() :: prg_machine:namespace().
-type id() :: prg_machine:id().
-type service_name() :: atom().
-type function_ref() :: hg_proto_utils:thrift_fun_ref().
-type args() :: woody:args().
-type response() :: prg_machine:response().

-spec thrift_call(namespace(), id(), service_name(), function_ref(), args()) ->
    response() | {error, notfound | failed}.
thrift_call(NS, ID, _ServiceName, FunRef, Args) ->
    case prg_machine:call(NS, ID, {FunRef, Args}) of
        {ok, Response} ->
            normalize_response(Response);
        {error, notfound} ->
            {error, notfound};
        {error, failed} ->
            {error, failed};
        {error, _} = Error ->
            Error
    end.

-spec normalize_response(prg_machine:response()) -> response().
normalize_response(ok) ->
    ok;
normalize_response({ok, Reply}) ->
    {ok, Reply};
normalize_response({exception, Exception}) ->
    {exception, Exception}.
