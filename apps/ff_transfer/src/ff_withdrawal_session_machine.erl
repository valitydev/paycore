%%%
%%% Withdrawal session machine — thin prg_machine client
%%%

-module(ff_withdrawal_session_machine).

-define(NS, 'ff/withdrawal/session_v2').

%% API

-export([session/1]).
-export([ctx/1]).

-export([create/3]).
-export([get/1]).
-export([get/2]).
-export([events/2]).
-export([repair/2]).
-export([process_callback/1]).

%%
%% Types
%%

-type repair_error() :: ff_repair:repair_error().
-type repair_response() :: ff_repair:repair_response().

-export_type([repair_error/0]).
-export_type([repair_response/0]).

-type id() :: prg_machine:id().
-type data() :: ff_withdrawal_session:data().
-type params() :: ff_withdrawal_session:params().

-type st() :: #{
    model := session(),
    ctx := ctx(),
    times => {prg_machine:timestamp() | undefined, prg_machine:timestamp() | undefined}
}.
-type session() :: ff_withdrawal_session:session_state().
-type event() :: ff_withdrawal_session:event().
-type event_range() :: {After :: non_neg_integer() | undefined, Limit :: non_neg_integer() | undefined}.
-type timestamp() :: prg_machine:timestamp().
-type timestamped_event(T) :: {ev, timestamp(), T}.

-type callback_params() :: ff_withdrawal_session:callback_params().
-type process_callback_response() :: ff_withdrawal_session:process_callback_response().
-type process_callback_error() ::
    {unknown_session, {tag, id()}}
    | ff_withdrawal_session:process_callback_error().

-type processor_error() ::
    {exception, atom(), term()}
    | {exception, atom(), term(), list()}.

-type ctx() :: ff_entity_context:context().

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%%
%% API
%%

-spec session(st()) -> session().
session(#{model := Model}) ->
    Model.

-spec ctx(st()) -> ctx().
ctx(#{ctx := Ctx}) ->
    Ctx.

-spec create(id(), data(), params()) -> ok | {error, exists}.
create(ID, Data, Params) ->
    do(fun() ->
        Events = unwrap(ff_withdrawal_session:create(ID, Data, Params)),
        unwrap(prg_machine:start(?NS, ID, Events))
    end).

-spec get(id()) ->
    {ok, st()}
    | {error, notfound}.
get(ID) ->
    get(ID, {undefined, undefined}).

-spec get(id(), event_range()) ->
    {ok, st()}
    | {error, notfound}.
get(ID, {After, Limit}) ->
    case prg_machine:get(?NS, ID, prg_machine:history_range(After, Limit, forward)) of
        {ok, Machine} ->
            {ok, machine_to_st(Machine)};
        {error, notfound} ->
            {error, notfound}
    end.

-spec events(id(), event_range()) ->
    {ok, [{integer(), timestamped_event(event())}]}
    | {error, notfound}.
events(ID, {After, Limit}) ->
    case prg_machine:get_history(?NS, ID, After, Limit, forward) of
        {ok, History} ->
            {ok, history_to_events(History)};
        {error, notfound} ->
            {error, notfound}
    end.

-spec repair(id(), ff_repair:scenario()) ->
    {ok, repair_response()} | {error, notfound | working | {failed, repair_error()}}.
repair(ID, Scenario) ->
    case prg_machine:repair(?NS, ID, Scenario) of
        {ok, Response} ->
            {ok, Response};
        {error, notfound} ->
            {error, notfound};
        {error, working} ->
            {error, working};
        {error, failed} ->
            {error, {failed, {invalid_result, unexpected_failure}}};
        {error, {repair, {failed, _Reason}}} = Error ->
            Error
    end.

-spec process_callback(callback_params()) ->
    {ok, process_callback_response()}
    | {error, process_callback_error() | processor_error() | failed}.
process_callback(#{tag := Tag} = Params) ->
    case ff_machine_tag:get_binding(?NS, Tag) of
        {ok, EntityID} ->
            call(EntityID, {process_callback, Params});
        {error, not_found} ->
            {error, {unknown_session, {tag, Tag}}}
    end.

%%
%% Internals
%%

-spec machine_to_st(prg_machine:machine()) -> st().
machine_to_st(#{history := History, aux_state := AuxState} = Machine) ->
    Model = prg_machine:collapse(ff_withdrawal_session, Machine),
    Ctx = maps:get(ctx, AuxState, #{}),
    #{
        model => Model,
        ctx => Ctx,
        times => history_times(History)
    }.

-spec history_to_events(prg_machine:history()) -> [{integer(), timestamped_event(event())}].
history_to_events(History) ->
    [{EventID, {ev, codec_timestamp(Timestamp), Body}} || {EventID, Timestamp, Body} <- History].

-spec history_times(prg_machine:history()) ->
    {prg_machine:timestamp() | undefined, prg_machine:timestamp() | undefined}.
history_times([]) ->
    {undefined, undefined};
history_times(History) ->
    lists:foldl(
        fun({_EventID, Timestamp, _Body}, {Created, _Updated}) ->
            case Created of
                undefined -> {Timestamp, Timestamp};
                _ -> {Created, Timestamp}
            end
        end,
        {undefined, undefined},
        History
    ).

call(Ref, Call) ->
    case prg_machine:call(?NS, Ref, Call) of
        {ok, Reply} ->
            Reply;
        {error, notfound} ->
            {error, {unknown_session, Ref}};
        {error, failed} ->
            {error, failed};
        {error, _} = Error ->
            Error
    end.

codec_timestamp({DateTime, USec} = Timestamp) when is_integer(USec) ->
    {DateTime, USec} = Timestamp;
codec_timestamp(DateTime) ->
    {DateTime, 0}.
