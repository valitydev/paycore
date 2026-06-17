-module(prg_action).

%%% Wire `action()` helpers and damsel repair → wire conversion at HG API boundaries.

-include_lib("progressor/include/progressor.hrl").
-include_lib("damsel/include/dmsl_repair_thrift.hrl").

-export([marshal_timer/1, schedule_timer/1, schedule_deadline/1]).
-export([from_repair/1]).

-export_type([t/0, timer/0, seconds/0]).

-type seconds() :: timeout_sec().
-type datetime() :: calendar:datetime() | {calendar:datetime(), non_neg_integer()} | binary().
-type timer() :: {timeout, seconds()} | {deadline, datetime()}.
-type t() :: action().

-type timer_field() :: undefined | {set_timer, timer()} | unset_timer.
-type remove_field() :: undefined | remove.

-spec schedule_timer(timer()) -> t().
schedule_timer({timeout, 0}) ->
    timeout;
schedule_timer(Timer) ->
    {schedule, #{at => marshal_timer(Timer), action => timeout}}.

-spec schedule_deadline(datetime()) -> t().
schedule_deadline(Deadline) ->
    {schedule, #{at => marshal_timer({deadline, Deadline}), action => timeout}}.

-spec marshal_timer(timer()) -> timestamp_us().
marshal_timer({timeout, 0}) ->
    erlang:system_time(microsecond);
marshal_timer({timeout, Seconds}) when is_integer(Seconds), Seconds >= 0 ->
    erlang:system_time(microsecond) + Seconds * 1000000;
marshal_timer({deadline, {{{_, _, _}, {_, _, _}} = Dt, USec}}) when is_integer(USec) ->
    datetime_to_microseconds(Dt, USec);
marshal_timer({deadline, {{_, _, _}, {_, _, _}} = Dt}) ->
    datetime_to_microseconds(Dt, 0);
marshal_timer({deadline, Bin}) when is_binary(Bin) ->
    calendar:rfc3339_to_system_time(unicode:characters_to_list(Bin), [{unit, microsecond}]);
marshal_timer(Other) ->
    error({invalid_timer, Other}).

%% damsel repair → wire (remove beats timer)

-spec from_repair(undefined | dmsl_repair_thrift:'ComplexAction'() | t()) -> t().
from_repair(undefined) ->
    idle;
from_repair(#repair_ComplexAction{timer = Timer, remove = Remove}) ->
    from_timer_remove(repair_timer_field(Timer), repair_remove_field(Remove));
from_repair(Wire) when Wire =:= idle; Wire =:= suspend; Wire =:= timeout; Wire =:= remove ->
    Wire;
from_repair({schedule, _} = Wire) ->
    Wire.

-spec from_timer_remove(timer_field(), remove_field()) -> t().
from_timer_remove(_, remove) ->
    remove;
from_timer_remove(undefined, undefined) ->
    idle;
from_timer_remove({set_timer, Timer}, undefined) ->
    schedule_timer(Timer);
from_timer_remove(unset_timer, undefined) ->
    suspend.

repair_timer_field(undefined) ->
    undefined;
repair_timer_field({set_timer, #repair_SetTimerAction{timer = Timer}}) ->
    {set_timer, Timer};
repair_timer_field({unset_timer, _}) ->
    unset_timer.

repair_remove_field(undefined) ->
    undefined;
repair_remove_field(#repair_RemoveAction{}) ->
    remove.

%%

datetime_to_microseconds(Dt, USec) ->
    Sec = calendar:datetime_to_gregorian_seconds(Dt) - ?EPOCH_DIFF,
    Sec * 1000000 + USec.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec marshal_timer_machinery_deadline_test() -> _.
marshal_timer_machinery_deadline_test() ->
    Dt = {{2099, 6, 13}, {12, 34, 56}},
    USec = 789000,
    Sec = calendar:datetime_to_gregorian_seconds(Dt) - ?EPOCH_DIFF,
    Expected = Sec * 1000000 + USec,
    ?assertEqual(Expected, marshal_timer({deadline, {Dt, USec}})),
    ?assertEqual(marshal_timer({deadline, {Dt, 0}}), marshal_timer({deadline, Dt})).

-endif.
