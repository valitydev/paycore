-module(pm_ct_domain).

-include_lib("damsel/include/dmsl_domain_conf_v2_thrift.hrl").

-export([upsert/2]).
-export([commit/2]).

-export([with/2]).

%%

-type revision() :: pm_domain:revision().
-type object() :: pm_domain:object().

-spec upsert(revision(), object() | [object()]) -> {revision(), [pm_domain:ref()]} | no_return().
upsert(Revision, NewObject) when not is_list(NewObject) ->
    upsert(Revision, [NewObject]);
upsert(Revision, NewObjects) ->
    Commit = lists:foldl(
        fun(NewObject = {Tag, {_ObjectName, Ref, NewData}}, Ops) ->
            case pm_domain:find(Revision, {Tag, Ref}) of
                NewData ->
                    Ops;
                notfound ->
                    [
                        {insert, #domain_conf_v2_InsertOp{
                            object = {Tag, NewData},
                            force_ref = {Tag, Ref}
                        }}
                        | Ops
                    ];
                _OldData ->
                    [
                        {update, #domain_conf_v2_UpdateOp{object = NewObject}}
                        | Ops
                    ]
            end
        end,
        [],
        NewObjects
    ),
    commit(Revision, Commit).

-spec commit(revision(), [dmt_client:operation()]) -> {revision(), [pm_domain:ref()]} | no_return().
commit(Revision, Operations) ->
    #domain_conf_v2_CommitResponse{version = Version, new_objects = NewObjects} =
        dmt_client:commit(Revision, Operations, generate_author()),
    NewObjectsIDs = [
        {Tag, Ref}
     || {Tag, {_ON, Ref, _Obj}} <- ordsets:to_list(NewObjects)
    ],
    {Version, NewObjectsIDs}.

-spec with(object() | [object()], fun((revision()) -> _)) ->
    {revision(), [pm_domain:ref()]} | no_return().
with(NewObjects, Fun) ->
    WasRevision = pm_domain:head(),
    {Version, NewObjectsIDs} = upsert(WasRevision, NewObjects),
    _ = Fun(Version),
    {Version, NewObjectsIDs}.

generate_author() ->
    dmt_client:create_author(genlib:unique(), genlib:unique()).
