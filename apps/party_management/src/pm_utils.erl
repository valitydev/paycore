-module(pm_utils).

-export([unique_id/0]).
-export([unwrap_result/1]).
-export([select_defined/2]).
-export([binary_ends_with/2]).

%%

-spec unique_id() -> dmsl_base_thrift:'ID'().
unique_id() ->
    <<ID:64>> = snowflake:new(),
    genlib_format:format_int_base(ID, 62).

-spec select_defined(T | undefined, T | undefined) -> T | undefined.
select_defined(V1, V2) ->
    select_defined([V1, V2]).

-spec select_defined([T | undefined]) -> T | undefined.
select_defined([V | _]) when V /= undefined ->
    V;
select_defined([undefined | Vs]) ->
    select_defined(Vs);
select_defined([]) ->
    undefined.

-spec binary_ends_with(binary(), binary()) -> boolean().
binary_ends_with(Binary, Suffix) when byte_size(Binary) < byte_size(Suffix) ->
    false;
binary_ends_with(Binary, Suffix) when is_binary(Binary), is_binary(Suffix) ->
    Suffix =:= binary:part(Binary, byte_size(Binary) - byte_size(Suffix), byte_size(Suffix)).

%%

-spec unwrap_result
    ({ok, T}) -> T;
    ({error, _}) -> no_return().
unwrap_result({ok, V}) ->
    V;
unwrap_result({error, E}) ->
    error(E).
