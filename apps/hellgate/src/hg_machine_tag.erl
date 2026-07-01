-module(hg_machine_tag).

-define(BENDER_NS, <<"machinegun-tag">>).

-export([get_binding/2]).
-export([create_binding/3]).
-export([create_binding/4]).

-type tag() :: dmsl_base_thrift:'Tag'().
-type ns() :: prg_machine:namespace().
-type entity_id() :: dmsl_base_thrift:'ID'().
-type machine_id() :: prg_machine:id().

-spec get_binding(ns(), tag()) -> {ok, entity_id(), machine_id()} | {error, notfound}.
get_binding(NS, Tag) ->
    WoodyContext = op_context:get_woody_context(op_context:load(op_context:key(hellgate))),
    case bender_client:get_internal_id(tag_to_external_id(NS, Tag), WoodyContext) of
        {ok, EntityID} ->
            {ok, EntityID, EntityID};
        {ok, EntityID, #{<<"machine-id">> := MachineID}} ->
            {ok, EntityID, MachineID};
        {error, internal_id_not_found} ->
            {error, notfound}
    end.

-spec create_binding(ns(), tag(), entity_id()) -> ok | no_return().
create_binding(NS, Tag, EntityID) ->
    create_binding_(NS, Tag, EntityID, undefined).

-spec create_binding(ns(), tag(), entity_id(), machine_id()) -> ok | no_return().
create_binding(NS, Tag, EntityID, MachineID) ->
    create_binding_(NS, Tag, EntityID, #{<<"machine-id">> => MachineID}).

%%

create_binding_(NS, Tag, EntityID, Context) ->
    WoodyContext = op_context:get_woody_context(op_context:load(op_context:key(hellgate))),
    case bender_client:gen_constant(tag_to_external_id(NS, Tag), EntityID, WoodyContext, Context) of
        {ok, EntityID} ->
            ok;
        {ok, EntityID, Context} ->
            ok
    end.

tag_to_external_id(NS, Tag) ->
    BinNS = atom_to_binary(NS, utf8),
    <<?BENDER_NS/binary, "-", BinNS/binary, "-", Tag/binary>>.
