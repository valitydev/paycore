-module(legacy_fixture_golden_test).

-compile(nowarn_unused_function).
-compile(nowarn_missing_spec).

-export([test/0]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("hellgate/include/domain.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-spec test() -> _.
test() ->
    eunit:test(?MODULE, [verbose]).

legacy_ff_event_test_() ->
    [
        {fixture_id(Dir, "_event"), fun() -> legacy_ff_event_test(Domain, Dir) end}
     || {Domain, Dir} <- legacy_fixture_lib:ff_fixtures()
    ].

legacy_ff_metadata_test_() ->
    [
        {fixture_id(Dir, "_metadata"), fun() -> legacy_ff_metadata_test(Dir) end}
     || {_Domain, Dir} <- legacy_fixture_lib:ff_fixtures()
    ].

legacy_ff_aux_state_test_() ->
    [
        {fixture_id(Dir, "_aux_state"), fun() -> legacy_ff_aux_state_test(Dir) end}
     || {_Domain, Dir} <- legacy_fixture_lib:ff_fixtures()
    ].

legacy_ff_rollback_test_() ->
    [
        {fixture_id(Dir, "_rollback"), fun() -> legacy_ff_rollback_roundtrip_test(Domain, Dir) end}
     || {Domain, Dir} <- legacy_fixture_lib:ff_fixtures()
    ].

legacy_hg_invoice_event_test_() ->
    {"hg_invoice_event", fun legacy_hg_invoice_event_test/0}.

legacy_hg_invoice_metadata_test_() ->
    {"hg_invoice_metadata", fun legacy_hg_invoice_metadata_test/0}.

legacy_hg_invoice_aux_state_test_() ->
    {"hg_invoice_aux_state", fun legacy_hg_invoice_aux_state_test/0}.

legacy_hg_aux_state_rollback_test_() ->
    {"hg_invoice_aux_state_rollback", fun legacy_hg_aux_state_rollback_test/0}.

legacy_hg_call_args_test_() ->
    {"hg_call_args", fun legacy_hg_call_args_test/0}.

legacy_hg_event_rollback_test_() ->
    {"hg_invoice_event_rollback", fun legacy_hg_event_rollback_test/0}.

%%

legacy_ff_event_test(Domain, Dir) ->
    Payload = legacy_fixture_lib:read_event_payload(Dir, 1),
    Meta = legacy_fixture_lib:read_event_metadata(Dir, 1),
    ?assertEqual(1, maps:get(<<"format">>, Meta)),
    ?assertNot(maps:is_key(<<"format_version">>, Meta)),
    ?assertMatch(<<131, _/binary>>, Payload),
    {bin, _} = binary_to_term(Payload),
    Timestamped = ff_machine_codec:unmarshal_event(Domain, 1, Payload),
    Change = ff_machine_lib:event_body_from_timestamped(Timestamped),
    ?assertMatch({created, _}, Change).

legacy_ff_metadata_test(Dir) ->
    Meta = legacy_fixture_lib:read_event_metadata(Dir, 1),
    ?assertEqual(#{<<"format">> => 1}, Meta).

legacy_ff_aux_state_test(Dir) ->
    Aux = legacy_fixture_lib:read_aux_state(Dir),
    ?assertMatch(#{ctx := _}, ff_machine_codec:unmarshal_aux_state(Aux)).

legacy_ff_rollback_roundtrip_test(Domain, Dir) ->
    LegacyPayload = legacy_fixture_lib:read_event_payload(Dir, 1),
    Timestamped = ff_machine_codec:unmarshal_event(Domain, 1, LegacyPayload),
    Encoded = ff_machine_codec:marshal_event(Domain, 1, Timestamped),
    NewPayload = ff_machine_codec:payload_to_binary(Encoded),
    ?assertEqual(LegacyPayload, NewPayload).

legacy_hg_invoice_event_test() ->
    Dir = legacy_fixture_lib:hg_invoice_dir(),
    Payload = legacy_fixture_lib:read_event_payload(Dir, 1),
    Meta = legacy_fixture_lib:read_event_metadata(Dir, 1),
    InvoiceID = trim_binary(legacy_fixture_lib:read_bin(Dir, "process_id.txt")),
    ?assertEqual(#{<<"format_version">> => 1}, Meta),
    ?assertNot(maps:is_key(<<"format">>, Meta)),
    Changes = hg_invoice:unmarshal_event_body(1, Payload),
    ?assertMatch([{invoice_created, _}], Changes),
    [{invoice_created, {payproc_InvoiceCreated, Invoice}}] = Changes,
    ?assertEqual(InvoiceID, Invoice#domain_Invoice.id).

legacy_hg_invoice_metadata_test() ->
    Meta = legacy_fixture_lib:read_event_metadata(legacy_fixture_lib:hg_invoice_dir(), 1),
    ?assertEqual(#{<<"format_version">> => 1}, Meta).

legacy_hg_invoice_aux_state_test() ->
    Dir = legacy_fixture_lib:hg_invoice_dir(),
    Aux = legacy_fixture_lib:read_aux_state(Dir),
    ?assertEqual(#{}, hg_invoice:unmarshal_aux_state(Aux)).

legacy_hg_aux_state_rollback_test() ->
    Dir = legacy_fixture_lib:hg_invoice_dir(),
    LegacyAux = legacy_fixture_lib:read_aux_state(Dir),
    ?assertEqual(LegacyAux, hg_invoice:marshal_aux_state(#{})).

legacy_hg_call_args_test() ->
    Dir = legacy_fixture_lib:hg_invoice_dir(),
    Bin = legacy_fixture_lib:read_bin(Dir, "call_args_thrift_get.bin"),
    Expected = legacy_fixture_lib:read_term(Dir, "call_args_thrift_get.expected.term"),
    Inner = decode_legacy_call_args(Bin),
    ?assertEqual(maps:get(inner_call, Expected), Inner),
    {thrift_call, invoicing, FunRef, EncodedArgs} = Inner,
    {Module, _Service} = hg_proto:get_service(invoicing),
    FullFunctionRef = {Module, FunRef},
    Args = hg_proto_utils:deserialize_function_args(FullFunctionRef, EncodedArgs),
    ?assertEqual(maps:get(normalized_call, Expected), {FunRef, Args}).

legacy_hg_event_rollback_test() ->
    Dir = legacy_fixture_lib:hg_invoice_dir(),
    LegacyPayload = legacy_fixture_lib:read_event_payload(Dir, 1),
    Changes = hg_invoice:unmarshal_event_body(1, LegacyPayload),
    {Format, NewPayload} = hg_invoice:marshal_event_body(Changes),
    ?assertEqual(1, Format),
    ?assertEqual(LegacyPayload, NewPayload).

fixture_id(Dir, Suffix) ->
    Dir ++ Suffix.

decode_legacy_call_args(Bin) when is_binary(Bin) ->
    case binary_to_term(Bin) of
        {bin, Inner} when is_binary(Inner) ->
            binary_to_term(Inner);
        Term ->
            Term
    end.

trim_binary(Bin) ->
    re:replace(Bin, "[\\s]+$", "", [{return, binary}, global]).
