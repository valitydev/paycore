-module(hg_machine_action).

%%% Scheduling helpers for wire `action()` in processor intent.

-include_lib("progressor/include/progressor.hrl").

-export([marshal_timer/1, schedule_timer/1, schedule_after/1, schedule_deadline/1]).

-export_type([t/0, timer/0, seconds/0]).

-type seconds() :: timeout_sec().
-type datetime() :: calendar:datetime() | binary().
-type timer() :: {timeout, seconds()} | {deadline, datetime()}.
-type t() :: action().

-spec schedule_timer(timer()) -> t().
schedule_timer({timeout, 0}) ->
    timeout;
schedule_timer(Timer) ->
    {schedule, #{at => marshal_timer(Timer), action => timeout}}.

-spec schedule_after(seconds()) -> t().
schedule_after(0) ->
    timeout;
schedule_after(Seconds) when is_integer(Seconds), Seconds > 0 ->
    {schedule, #{at => erlang:system_time(second) + Seconds, action => timeout}}.

-spec schedule_deadline(datetime()) -> t().
schedule_deadline(Deadline) ->
    {schedule, #{at => marshal_timer({deadline, Deadline}), action => timeout}}.

-spec marshal_timer(timer()) -> timestamp_sec().
marshal_timer({timeout, 0}) ->
    erlang:system_time(second);
marshal_timer({timeout, Seconds}) when is_integer(Seconds), Seconds >= 0 ->
    erlang:system_time(second) + Seconds;
marshal_timer({deadline, {_, _} = Dt}) ->
    calendar:datetime_to_gregorian_seconds(Dt) - ?EPOCH_DIFF;
marshal_timer({deadline, Bin}) when is_binary(Bin) ->
    calendar:rfc3339_to_system_time(unicode:characters_to_list(Bin), [{unit, second}]);
marshal_timer(Other) ->
    error({invalid_timer, Other}).
