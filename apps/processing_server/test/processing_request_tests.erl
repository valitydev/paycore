-module(processing_request_tests).

-include_lib("eunit/include/eunit.hrl").

-export([handle_function/3]).

-spec test() -> _.

-spec handle_function(woody:func(), {fun((term()) -> term())}, term()) -> term().
handle_function(_Function, {Handle}, Options) ->
    Handle(Options).

-spec request_contract_test_() -> _.
request_contract_test_() ->
    {setup, fun setup/0, [fun hg_reply/0, fun ff_reply/0, fun hg_exception_clears_context/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(processing_server),
    processing_server:setup_metrics().

hg_reply() ->
    Options = #{handler => ?MODULE, ns => <<"test">>},
    Deadline = woody_deadline:from_timeout(60000),
    Context = woody_context:set_deadline(Deadline, woody_context:new()),
    Handle = fun(HandlerOptions) ->
        ?assertEqual(Options, HandlerOptions),
        BoundContext = op_context:load(op_context:key(hellgate)),
        ?assertEqual(Context, op_context:get_woody_context(BoundContext)),
        response
    end,
    ?assertEqual({ok, response}, hg_woody_service_wrapper:handle_function(hg_reply, {Handle}, Context, Options)).

ff_reply() ->
    PartyClient = party_client:create_client(),
    HandlerOptions = #{setting => value},
    Options = #{handler => {?MODULE, HandlerOptions}, party_client => PartyClient},
    Handle = fun(ActualOptions) ->
        ?assertEqual(HandlerOptions, ActualOptions),
        Context = op_context:load(op_context:key(fistful)),
        ?assertEqual(PartyClient, op_context:get_party_client(Context)),
        {ok, response}
    end,
    ?assertEqual(
        {ok, response},
        ff_woody_wrapper:handle_function(ff_reply, {Handle}, woody_context:new(), Options)
    ).

hg_exception_clears_context() ->
    Handle = fun throw_business_failure/1,
    Options = #{handler => ?MODULE},
    ?assertThrow(
        business_failure,
        hg_woody_service_wrapper:handle_function(hg_failure, {Handle}, woody_context:new(), Options)
    ),
    ?assertError(badarg, op_context:load(op_context:key(hellgate))).

-spec throw_business_failure(term()) -> no_return().
throw_business_failure(_Options) ->
    throw(business_failure).
