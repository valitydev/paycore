%%% Invoice template machine

-module(hg_invoice_template).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("mg_proto/include/mg_proto_state_processing_thrift.hrl").

-define(NS, invoice_template).
-define(EVENT_FORMAT_VERSION, 1).

%% Woody handler called by hg_woody_service_wrapper
-behaviour(hg_woody_service_wrapper).

-export([handle_function/3]).

%% Machine callbacks
-behaviour(prg_machine).

-export([namespace/0]).

-export([init/2]).
-export([process_signal/2]).
-export([process_call/2]).
-export([process_repair/2]).
-export([marshal_event_body/1]).
-export([unmarshal_event_body/2]).
-export([marshal_aux_state/1]).
-export([unmarshal_aux_state/1]).
-export([apply_event/4]).

%% API

-export([get/1]).
-export([unmarshal_invoice_template_params/1]).

-type tpl_id() :: dmsl_domain_thrift:'InvoiceTemplateID'().
-type tpl() :: dmsl_domain_thrift:'InvoiceTemplate'().

%% Internal types

-type invoice_template_change() :: dmsl_payproc_thrift:'InvoiceTemplateChange'().
-type machine() :: prg_machine:machine().
-type prg_result() :: prg_machine:result().

%% API

-spec get(tpl_id()) -> tpl().
get(TplID) ->
    get_invoice_template(TplID).

get_invoice_template(ID) ->
    case prg_machine:get(?NS, ID) of
        {ok, Machine = #{history := History}} ->
            _ = assert_invoice_template_not_deleted(lists:last(History)),
            prg_machine:collapse(?MODULE, Machine);
        {error, notfound} ->
            throw(#payproc_InvoiceTemplateNotFound{})
    end.

%% Woody handler

-spec handle_function(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function(Func, Args, Opts) ->
    scoper:scope(
        invoice_templating,
        fun() ->
            handle_function_(Func, Args, Opts)
        end
    ).

-spec handle_function_(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function_('Create', {Params}, _Opts) ->
    TplID = Params#payproc_InvoiceTemplateCreateParams.template_id,
    _ = set_meta(TplID),
    _Party = get_party(Params#payproc_InvoiceTemplateCreateParams.party_id),
    Shop = get_shop(
        Params#payproc_InvoiceTemplateCreateParams.shop_id,
        Params#payproc_InvoiceTemplateCreateParams.party_id
    ),
    ok = validate_create_params(Params, Shop),
    ok = start(TplID, Params),
    get_invoice_template(TplID);
handle_function_('Get', {TplID}, _Opts) ->
    _ = set_meta(TplID),
    get_invoice_template(TplID);
handle_function_('Update' = Fun, {TplID, Params} = Args, _Opts) ->
    _ = set_meta(TplID),
    Tpl = get_invoice_template(TplID),
    _ = get_party(Tpl#domain_InvoiceTemplate.party_ref),
    Shop = get_shop(Tpl#domain_InvoiceTemplate.shop_ref, Tpl#domain_InvoiceTemplate.party_ref),
    ok = validate_update_params(Params, Shop),
    call(TplID, Fun, Args);
handle_function_('Delete' = Fun, {TplID} = Args, _Opts) ->
    Tpl = get_invoice_template(TplID),
    _ = get_party(Tpl#domain_InvoiceTemplate.party_ref),
    _ = get_shop(Tpl#domain_InvoiceTemplate.shop_ref, Tpl#domain_InvoiceTemplate.party_ref),
    _ = set_meta(TplID),
    call(TplID, Fun, Args);
handle_function_('ComputeTerms', {TplID}, _Opts) ->
    _ = set_meta(TplID),
    Tpl = get_invoice_template(TplID),
    Cost =
        case Tpl#domain_InvoiceTemplate.details of
            {product, #domain_InvoiceTemplateProduct{price = {fixed, Cash}}} ->
                Cash;
            _ ->
                undefined
        end,
    Revision = hg_party:get_party_revision(),
    {PartyConfigRef, Party} = hg_party:checkout(Tpl#domain_InvoiceTemplate.party_ref, Revision),
    {#domain_ShopConfigRef{id = ShopConfigID}, Shop} = hg_party:get_shop(
        Tpl#domain_InvoiceTemplate.shop_ref,
        Tpl#domain_InvoiceTemplate.party_ref,
        Revision
    ),
    _ = assert_party_shop_operable(Shop, Party),
    VS = #{
        cost => Cost,
        shop_id => ShopConfigID,
        party_config_ref => PartyConfigRef,
        category => Shop#domain_ShopConfig.category,
        currency => hg_invoice_utils:get_shop_currency(Shop)
    },
    hg_invoice_utils:compute_shop_terms(
        Revision,
        Shop,
        VS
    ).

assert_party_shop_operable(Shop, Party) ->
    _ = hg_invoice_utils:assert_party_operable(Party),
    _ = hg_invoice_utils:assert_shop_operable(Shop),
    ok.

get_party(PartyConfigRef) ->
    {PartyConfigRef, Party} = hg_party:get_party(PartyConfigRef),
    _ = hg_invoice_utils:assert_party_operable(Party),
    Party.

get_shop(ShopConfigRef, PartyConfigRef) ->
    {ShopConfigRef, Shop} = hg_invoice_utils:assert_shop_exists(
        hg_party:get_shop(ShopConfigRef, PartyConfigRef, hg_party:get_party_revision())
    ),
    _ = hg_invoice_utils:assert_shop_operable(Shop),
    Shop.

set_meta(ID) ->
    scoper:add_meta(#{invoice_template_id => ID}).

validate_create_params(#payproc_InvoiceTemplateCreateParams{details = Details, mutations = Mutations}, Shop) ->
    ok = validate_details(Details, Mutations, Shop).

validate_update_params(#payproc_InvoiceTemplateUpdateParams{details = undefined}, _) ->
    ok;
validate_update_params(#payproc_InvoiceTemplateUpdateParams{details = Details, mutations = Mutations}, Shop) ->
    ok = validate_details(Details, Mutations, Shop).

validate_details({cart, #domain_InvoiceCart{}} = Details, Mutations, _) ->
    hg_invoice_mutation:validate_mutations(Mutations, Details);
validate_details({product, #domain_InvoiceTemplateProduct{price = Price}}, _, Shop) ->
    validate_price(Price, Shop).

validate_price({fixed, Cash}, Shop) ->
    hg_invoice_utils:validate_cost(Cash, Shop);
validate_price(
    {range,
        Range = #domain_CashRange{
            lower = {_, LowerCost},
            upper = {_, UpperCost}
        }},
    Shop
) ->
    ok = hg_invoice_utils:validate_cash_range(Range),
    ok = hg_invoice_utils:validate_cost(LowerCost, Shop),
    ok = hg_invoice_utils:validate_cost(UpperCost, Shop);
validate_price({unlim, _}, _Shop) ->
    ok.

start(ID, Params) ->
    EncodedParams = marshal_invoice_template_params(Params),
    map_start_error(prg_machine:start(?NS, ID, EncodedParams)).

call(ID, Function, Args) ->
    case
        hg_invoicing_machine_client:thrift_call(
            ?NS, ID, invoice_templating, {'InvoiceTemplating', Function}, Args
        )
    of
        ok ->
            ok;
        {ok, Reply} ->
            Reply;
        {exception, Exception} ->
            erlang:throw(Exception);
        {error, Error} ->
            map_error(Error)
    end.

-spec map_error(notfound | any()) -> no_return().
map_error(notfound) ->
    throw(#payproc_InvoiceTemplateNotFound{});
map_error(Reason) ->
    error(Reason).

map_start_error({ok, _}) ->
    ok;
map_start_error({error, Reason}) ->
    error(Reason).

%% Machine

-type create_params() :: dmsl_payproc_thrift:'InvoiceTemplateCreateParams'().
-type call() :: {{atom(), atom()}, woody:args()}.

-define(tpl_created(InvoiceTpl),
    {invoice_template_created, #payproc_InvoiceTemplateCreated{invoice_template = InvoiceTpl}}
).

-define(tpl_updated(Diff),
    {invoice_template_updated, #payproc_InvoiceTemplateUpdated{diff = Diff}}
).

-define(tpl_deleted(),
    {invoice_template_deleted, #payproc_InvoiceTemplateDeleted{}}
).

assert_invoice_template_not_deleted({_, _, [?tpl_deleted()]}) ->
    throw(#payproc_InvoiceTemplateRemoved{});
assert_invoice_template_not_deleted(_) ->
    ok.

-spec namespace() -> prg_machine:namespace().
namespace() ->
    ?NS.

-spec init(binary(), machine()) -> prg_result().
init(EncodedParams, #{id := ID}) ->
    Params = unmarshal_invoice_template_params(EncodedParams),
    Tpl = create_invoice_template(ID, Params),
    #{events => [[?tpl_created(Tpl)]]}.

create_invoice_template(ID, P) ->
    #domain_InvoiceTemplate{
        id = ID,
        party_ref = P#payproc_InvoiceTemplateCreateParams.party_id,
        shop_ref = P#payproc_InvoiceTemplateCreateParams.shop_id,
        invoice_lifetime = P#payproc_InvoiceTemplateCreateParams.invoice_lifetime,
        product = P#payproc_InvoiceTemplateCreateParams.product,
        name = P#payproc_InvoiceTemplateCreateParams.name,
        description = P#payproc_InvoiceTemplateCreateParams.description,
        created_at = hg_datetime:format_now(),
        details = P#payproc_InvoiceTemplateCreateParams.details,
        context = P#payproc_InvoiceTemplateCreateParams.context,
        mutations = P#payproc_InvoiceTemplateCreateParams.mutations
    }.

-spec process_repair(prg_machine:args(), machine()) -> no_return().
process_repair(_Args, _Machine) ->
    erlang:error({not_implemented, repair}).

-spec process_signal(prg_machine:signal(), machine()) -> prg_result().
process_signal(timeout, _Machine) ->
    #{};
process_signal({repair, _}, _Machine) ->
    #{}.

-spec process_call(call(), machine()) -> {prg_machine:response(), prg_result()}.
process_call(Call, Machine) ->
    St = prg_machine:collapse(?MODULE, Machine),
    try handle_call(Call, St) of
        {ok, Changes} ->
            {ok, #{events => [Changes]}};
        {Reply, Changes} ->
            {{ok, Reply}, #{events => [Changes]}}
    catch
        throw:Exception ->
            {{exception, Exception}, #{}}
    end.

handle_call({{'InvoiceTemplating', 'Update'}, {_TplID, Params}}, Tpl) ->
    Changes = [?tpl_updated(Params)],
    {merge_changes(Changes, Tpl), Changes};
handle_call({{'InvoiceTemplating', 'Delete'}, {_TplID}}, _Tpl) ->
    {ok, [?tpl_deleted()]}.

-spec apply_event(
    prg_machine:event_id(),
    prg_machine:timestamp(),
    [invoice_template_change()],
    tpl() | undefined
) -> tpl().
apply_event(_EventID, _Ts, Changes, Tpl) ->
    merge_changes(Changes, Tpl).

merge_changes([?tpl_created(Tpl)], _) ->
    Tpl;
merge_changes(
    [
        ?tpl_updated(#payproc_InvoiceTemplateUpdateParams{
            name = Name,
            invoice_lifetime = InvoiceLifetime,
            product = Product,
            description = Description,
            details = Details,
            context = Context,
            mutations = Mutations
        })
    ],
    Tpl
) ->
    Diff = [
        {name, Name},
        {invoice_lifetime, InvoiceLifetime},
        {product, Product},
        {description, Description},
        {details, Details},
        {context, Context},
        {mutations, Mutations}
    ],
    lists:foldl(fun update_field/2, Tpl, Diff).

update_field({_, undefined}, Tpl) ->
    Tpl;
update_field({invoice_lifetime, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{invoice_lifetime = V};
update_field({product, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{product = V};
update_field({name, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{name = V};
update_field({description, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{description = V};
update_field({details, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{details = V};
update_field({context, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{context = V};
update_field({mutations, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{mutations = V}.

%% Marshaling

-spec marshal_invoice_template_params(create_params()) -> binary().
marshal_invoice_template_params(Params) ->
    Type = {struct, struct, {dmsl_payproc_thrift, 'InvoiceTemplateCreateParams'}},
    hg_proto_utils:serialize(Type, Params).

-spec marshal_event_body(prg_machine:event_body()) -> {pos_integer(), binary()}.
marshal_event_body(Changes) when is_list(Changes) ->
    #{data := Data} = wrap_event_payload({invoice_template_changes, Changes}),
    Msgp = mg_msgpack_marshalling:marshal(Data),
    {?EVENT_FORMAT_VERSION, msgpack_payload_to_binary(Msgp)}.

-spec unmarshal_event_body(pos_integer(), binary()) -> prg_machine:event_body().
unmarshal_event_body(?EVENT_FORMAT_VERSION, Payload) ->
    decode_event_body(Payload);
unmarshal_event_body(Format, _Payload) ->
    erlang:error({unknown_event_format, Format}).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    msgpack_payload_to_binary(mg_msgpack_marshalling:marshal(AuxSt)).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(<<>>) ->
    #{};
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    %% Same compat as hg_invoice: legacy #mg_stateproc_Content{} or current msgpack blob.
    case binary_to_term(Payload) of
        #mg_stateproc_Content{data = {bin, <<>>}} ->
            #{};
        #mg_stateproc_Content{data = Data} ->
            mg_msgpack_marshalling:unmarshal(Data);
        Msgp ->
            mg_msgpack_marshalling:unmarshal(Msgp)
    end.

msgpack_payload_to_binary(Msgp) ->
    term_to_binary(Msgp).

decode_event_body(Payload) ->
    case try_unmarshal_msgpack_payload(Payload) of
        {ok, Data} ->
            changes_from_msgpack_data(Data);
        {error, _} ->
            unmarshal_event_payload(#{format_version => ?EVENT_FORMAT_VERSION, data => {bin, Payload}})
    end.

try_unmarshal_msgpack_payload(Payload) ->
    try
        {ok, mg_msgpack_marshalling:unmarshal(binary_to_term(Payload))}
    catch
        _:_ ->
            {error, invalid_msgpack_payload}
    end.

changes_from_msgpack_data({bin, Bin}) when is_binary(Bin) ->
    unmarshal_event_payload(#{format_version => ?EVENT_FORMAT_VERSION, data => {bin, Bin}});
changes_from_msgpack_data(#{format_version := V, data := Data}) ->
    unmarshal_event_payload(#{format_version => V, data => Data});
changes_from_msgpack_data(Changes) when is_list(Changes) ->
    Changes.

wrap_event_payload(Payload) ->
    Type = {struct, union, {dmsl_payproc_thrift, 'EventPayload'}},
    Bin = hg_proto_utils:serialize(Type, Payload),
    #{
        format_version => 1,
        data => {bin, Bin}
    }.

%% Unmashaling

-spec unmarshal_invoice_template_params(binary()) -> create_params().
unmarshal_invoice_template_params(EncodedParams) ->
    Type = {struct, struct, {dmsl_payproc_thrift, 'InvoiceTemplateCreateParams'}},
    hg_proto_utils:deserialize(Type, EncodedParams).

-spec unmarshal_event_payload(map()) -> [invoice_template_change()].
unmarshal_event_payload(#{format_version := 1, data := {bin, Changes}}) ->
    Type = {struct, union, {dmsl_payproc_thrift, 'EventPayload'}},
    {invoice_template_changes, Buf} = hg_proto_utils:deserialize(Type, Changes),
    Buf.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec aux_state_reads_legacy_mg_content_test() -> _.
aux_state_reads_legacy_mg_content_test() ->
    AuxSt = #{<<"legacy">> => 1},
    Msgp = mg_msgpack_marshalling:marshal(AuxSt),
    Legacy = term_to_binary(#mg_stateproc_Content{format_version = 1, data = Msgp}),
    ?assertEqual(AuxSt, unmarshal_aux_state(Legacy)).

-endif.
