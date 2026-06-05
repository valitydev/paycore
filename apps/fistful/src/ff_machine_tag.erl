-module(ff_machine_tag).

-define(BENDER_NS, <<"machinegun-tag">>).

-export([get_binding/2]).
-export([create_binding/3]).

-type tag() :: binary().
-type ns() :: prg_machine:namespace().
-type entity_id() :: binary().

-spec get_binding(ns(), tag()) -> {ok, entity_id()} | {error, not_found}.
get_binding(NS, Tag) ->
    WoodyContext = operation_context:get_woody_context(operation_context:load_fistful()),
    case bender_client:get_internal_id(tag_to_external_id(NS, Tag), WoodyContext) of
        {ok, EntityID} ->
            {ok, EntityID};
        {error, internal_id_not_found} ->
            {error, not_found}
    end.

-spec create_binding(ns(), tag(), entity_id()) -> ok | no_return().
create_binding(NS, Tag, EntityID) ->
    create_binding_(NS, Tag, EntityID, undefined).

%%

create_binding_(NS, Tag, EntityID, Context) ->
    WoodyContext = operation_context:get_woody_context(operation_context:load_fistful()),
    {ok, EntityID} = bender_client:gen_constant(tag_to_external_id(NS, Tag), EntityID, WoodyContext, Context),
    ok.

tag_to_external_id(NS, Tag) ->
    BinNS = atom_to_binary(NS, utf8),
    <<?BENDER_NS/binary, "-", BinNS/binary, "-", Tag/binary>>.
