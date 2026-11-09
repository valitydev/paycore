-module(lim_context_utils).

-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([route_provider_id/1]).
-export([route_terminal_id/1]).
-export([base61_hash/1]).
-export([decode_content/2]).
-export([get_field_by_path/2]).

-type provider_id() :: binary().
-type terminal_id() :: binary().

%%

-spec route_provider_id(limproto_base_thrift:'Route'()) ->
    {ok, provider_id()}.
route_provider_id(#base_Route{provider = #domain_ProviderRef{id = ID}}) ->
    {ok, genlib:to_binary(ID)}.

-spec route_terminal_id(limproto_base_thrift:'Route'()) ->
    {ok, terminal_id()}.
route_terminal_id(#base_Route{terminal = #domain_TerminalRef{id = ID}}) ->
    {ok, genlib:to_binary(ID)}.

-spec base61_hash(iolist() | binary()) -> binary().
base61_hash(IOList) ->
    <<I:160/integer>> = crypto:hash(sha, IOList),
    genlib_format:format_int_base(I, 61).

-spec decode_content(Type, binary()) ->
    {ok, map()} | {error, {unsupported, Type}}
when
    Type :: binary().
decode_content(<<"application/schema-instance+json; schema=", _/binary>>, Data) ->
    {ok, jsx:decode(Data)};
decode_content(<<"application/json">>, Data) ->
    {ok, jsx:decode(Data)};
decode_content(Type, _Data) ->
    {error, {unsupported, Type}}.

-spec get_field_by_path([binary()], map()) -> {ok, map() | binary() | number()} | {error, notfound}.
get_field_by_path([], Data) ->
    {ok, Data};
get_field_by_path([Key | Path], Data) ->
    case maps:get(Key, Data, undefined) of
        undefined -> {error, notfound};
        Value -> get_field_by_path(Path, Value)
    end.
