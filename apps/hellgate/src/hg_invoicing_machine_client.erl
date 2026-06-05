-module(hg_invoicing_machine_client).

%%% Thrift RPC to invoicing machines via progressor.
%%% Encode/decode with hg_proto_utils; transport via prg_machine:call/6.
%%% hg_proto stays in apps/hellgate (not in prg_machine).

-export([thrift_call/5]).
-export([thrift_call/8]).

-type namespace() :: prg_machine:namespace().
-type id() :: prg_machine:id().
-type service_name() :: atom().
-type function_ref() :: hg_proto_utils:thrift_fun_ref().
-type args() :: woody:args().
-type event_id() :: prg_machine:event_id().
-type response() :: prg_machine:response().

-spec thrift_call(namespace(), id(), service_name(), function_ref(), args()) ->
    response() | {error, notfound | failed}.
thrift_call(NS, ID, Service, FunRef, Args) ->
    thrift_call(NS, ID, Service, FunRef, Args, undefined, undefined, forward).

-spec thrift_call(
    namespace(),
    id(),
    service_name(),
    function_ref(),
    args(),
    event_id() | undefined,
    non_neg_integer() | undefined,
    forward | backward
) -> response() | {error, notfound | failed}.
thrift_call(NS, ID, ServiceName, FunRef, Args, After, Limit, Direction) ->
    EncodedArgs = marshal_thrift_args(ServiceName, FunRef, Args),
    MachineCall = {FunRef, unmarshal_thrift_args(ServiceName, FunRef, EncodedArgs)},
    case prg_machine:call(NS, ID, MachineCall, After, Limit, Direction) of
        {ok, Response} ->
            unmarshal_thrift_response(ServiceName, FunRef, Response);
        {error, notfound} ->
            {error, notfound};
        {error, failed} ->
            {error, failed};
        {error, _} = Error ->
            Error
    end.

marshal_thrift_args(ServiceName, FunctionRef, Args) ->
    {Service, _Function} = FunctionRef,
    {Module, Service} = hg_proto:get_service(ServiceName),
    FullFunctionRef = {Module, FunctionRef},
    hg_proto_utils:serialize_function_args(FullFunctionRef, Args).

unmarshal_thrift_args(ServiceName, FunctionRef, EncodedArgs) ->
    {Service, _Function} = FunctionRef,
    {Module, Service} = hg_proto:get_service(ServiceName),
    FullFunctionRef = {Module, FunctionRef},
    hg_proto_utils:deserialize_function_args(FullFunctionRef, EncodedArgs).

unmarshal_thrift_response(ServiceName, FunctionRef, Response) ->
    {Service, _Function} = FunctionRef,
    {Module, Service} = hg_proto:get_service(ServiceName),
    FullFunctionRef = {Module, FunctionRef},
    case Response of
        ok ->
            ok;
        {ok, EncodedReply} when is_binary(EncodedReply) ->
            Reply = hg_proto_utils:deserialize_function_reply(FullFunctionRef, EncodedReply),
            {ok, Reply};
        {ok, Reply} ->
            {ok, Reply};
        {exception, EncodedException} when is_binary(EncodedException) ->
            Exception = hg_proto_utils:deserialize_function_exception(FullFunctionRef, EncodedException),
            {exception, Exception};
        {exception, Exception} ->
            {exception, Exception}
    end.
