-module(prg_machine_action).

-export([new/0]).
-export([instant/0]).
-export([set_timeout/1]).
-export([set_timeout/2]).
-export([set_deadline/1]).
-export([set_deadline/2]).
-export([set_timer/1]).
-export([set_timer/2]).
-export([unset_timer/0]).
-export([unset_timer/1]).
-export([mark_removal/1]).
-export([to_progressor/1]).

-type seconds() :: non_neg_integer().
-type datetime() :: calendar:datetime() | binary().
-type timer() :: {timeout, seconds()} | {deadline, datetime()}.
-type t() ::
    undefined
    | unset_timer
    | remove
    | #{set_timer := timer(), remove => boolean()}.

-export_type([t/0, timer/0, seconds/0]).

-spec new() -> t().
new() ->
    #{}.

-spec instant() -> t().
instant() ->
    set_timeout(0, new()).

-spec set_timeout(seconds()) -> t().
set_timeout(Seconds) ->
    set_timeout(Seconds, new()).

-spec set_timeout(seconds(), t()) -> t().
set_timeout(Seconds, Action) when is_integer(Seconds), Seconds >= 0 ->
    set_timer({timeout, Seconds}, Action).

-spec set_deadline(datetime()) -> t().
set_deadline(Deadline) ->
    set_deadline(Deadline, new()).

-spec set_deadline(datetime(), t()) -> t().
set_deadline(Deadline, Action) ->
    set_timer({deadline, Deadline}, Action).

-spec set_timer(timer()) -> t().
set_timer(Timer) ->
    set_timer(Timer, new()).

-spec set_timer(timer(), t()) -> t().
set_timer(Timer, Action) ->
    Action#{set_timer => Timer}.

-spec unset_timer() -> t().
unset_timer() ->
    unset_timer(new()).

-spec unset_timer(t()) -> t().
unset_timer(Action) when is_map(Action) ->
    maps:without([set_timer], Action);
unset_timer(unset_timer) ->
    unset_timer.

-spec mark_removal(t()) -> t().
mark_removal(Action) ->
    Action#{remove => true}.

-spec to_progressor(t()) -> progressor_action() | undefined.
to_progressor(undefined) ->
    undefined;
to_progressor(unset_timer) ->
    unset_timer;
to_progressor(remove) ->
    #{remove => true};
to_progressor(#{set_timer := Timer, remove := true}) ->
    #{set_timer => marshal_timer(Timer), remove => true};
to_progressor(#{set_timer := Timer}) ->
    #{set_timer => marshal_timer(Timer)};
to_progressor(#{remove := true}) ->
    #{remove => true};
to_progressor(#{}) ->
    undefined.

%%

-type progressor_action() :: #{set_timer := non_neg_integer(), remove => true} | unset_timer.

marshal_timer({timeout, Seconds}) when is_integer(Seconds) ->
    erlang:system_time(microsecond) div 1000000 + Seconds;
marshal_timer({deadline, {_, _} = Dt}) ->
    genlib_time:daytime_to_unixtime(Dt);
marshal_timer({deadline, Bin}) when is_binary(Bin) ->
    calendar:rfc3339_to_system_time(unicode:characters_to_list(Bin), [{unit, second}]).
