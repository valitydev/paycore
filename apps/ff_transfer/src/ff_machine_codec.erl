-module(ff_machine_codec).

-export([marshal_event/3]).
-export([unmarshal_event/3]).
-export([marshal_aux_state/1]).
-export([unmarshal_aux_state/1]).
-export([payload_to_binary/1]).

-type domain() :: deposit | source | destination | withdrawal | withdrawal_session.
-type format_version() :: pos_integer().
-type timestamped_event() :: {ev, term(), term()}.

-spec marshal_event(domain(), format_version(), timestamped_event()) -> machinery_msgpack:t().
marshal_event(deposit, 1, Timestamped) ->
    marshal_thrift_event(
        Timestamped, ff_deposit_codec, timestamped_change, fistful_deposit_thrift, 'TimestampedChange'
    );
marshal_event(source, 1, Timestamped) ->
    marshal_thrift_event(Timestamped, ff_source_codec, timestamped_change, fistful_source_thrift, 'TimestampedChange');
marshal_event(destination, 1, Timestamped) ->
    marshal_thrift_event(
        Timestamped, ff_destination_codec, timestamped_change, fistful_destination_thrift, 'TimestampedChange'
    );
marshal_event(withdrawal, 1, Timestamped) ->
    marshal_thrift_event(
        Timestamped, ff_withdrawal_codec, timestamped_change, fistful_wthd_thrift, 'TimestampedChange'
    );
marshal_event(withdrawal_session, 1, Timestamped) ->
    marshal_thrift_event(
        Timestamped, ff_withdrawal_session_codec, timestamped_change, fistful_wthd_session_thrift, 'TimestampedChange'
    );
marshal_event(Domain, Format, _Timestamped) ->
    erlang:error({unknown_event_format, Domain, Format}).

-spec unmarshal_event(domain(), format_version(), binary()) -> timestamped_event().
unmarshal_event(deposit, 1, Payload) ->
    unmarshal_thrift_event(Payload, ff_deposit_codec, timestamped_change, fistful_deposit_thrift, 'TimestampedChange');
unmarshal_event(source, 1, Payload) ->
    unmarshal_thrift_event(Payload, ff_source_codec, timestamped_change, fistful_source_thrift, 'TimestampedChange');
unmarshal_event(destination, 1, Payload) ->
    unmarshal_thrift_event(
        Payload, ff_destination_codec, timestamped_change, fistful_destination_thrift, 'TimestampedChange'
    );
unmarshal_event(withdrawal, 1, Payload) ->
    unmarshal_thrift_event(Payload, ff_withdrawal_codec, timestamped_change, fistful_wthd_thrift, 'TimestampedChange');
unmarshal_event(withdrawal_session, 1, Payload) ->
    unmarshal_thrift_event(
        Payload, ff_withdrawal_session_codec, timestamped_change, fistful_wthd_session_thrift, 'TimestampedChange'
    );
unmarshal_event(Domain, Format, _Payload) ->
    erlang:error({unknown_event_format, Domain, Format}).

-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    payload_to_binary(machinery_mg_schema_generic:marshal(AuxSt)).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    machinery_mg_schema_generic:unmarshal({bin, Payload}).

-spec payload_to_binary(machinery_msgpack:t()) -> binary().
payload_to_binary({bin, Bin}) when is_binary(Bin) ->
    Bin;
payload_to_binary(Payload) ->
    {ok, Bin} = machinery_msgpack:pack(Payload),
    Bin.

-spec marshal_thrift_event(
    timestamped_event(),
    module(),
    atom(),
    atom(),
    atom()
) -> machinery_msgpack:t().
marshal_thrift_event(Timestamped, Codec, Tag, ThriftModule, ThriftStruct) ->
    ThriftChange = Codec:marshal(Tag, Timestamped),
    Type = {struct, struct, {ThriftModule, ThriftStruct}},
    {bin, ff_proto_utils:serialize(Type, ThriftChange)}.

-spec unmarshal_thrift_event(
    binary(),
    module(),
    atom(),
    atom(),
    atom()
) -> timestamped_event().
unmarshal_thrift_event(Payload, Codec, Tag, ThriftModule, ThriftStruct) ->
    Type = {struct, struct, {ThriftModule, ThriftStruct}},
    ThriftChange = ff_proto_utils:deserialize(Type, Payload),
    Codec:unmarshal(Tag, ThriftChange).
