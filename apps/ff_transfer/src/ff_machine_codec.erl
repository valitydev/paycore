-module(ff_machine_codec).

-export([marshal_event/3]).
-export([unmarshal_event/2]).
-export([marshal_aux_state/1]).
-export([unmarshal_aux_state/1]).
-export([payload_to_binary/1]).

-export_type([domain/0]).

-type domain() :: deposit | source | destination | withdrawal | withdrawal_session.
-type format_version() :: pos_integer().
-type timestamped_event() :: {ev, term(), term()}.
-type event_payload() :: {bin, binary()}.

-spec marshal_event(domain(), format_version(), timestamped_event()) -> event_payload().
marshal_event(deposit, 1, Timestamped) ->
    marshal_thrift_event(
        Timestamped,
        fun(T) -> ff_deposit_codec:marshal(timestamped_change, T) end,
        fistful_deposit_thrift,
        'TimestampedChange'
    );
marshal_event(source, 1, Timestamped) ->
    marshal_thrift_event(
        Timestamped,
        fun(T) -> ff_source_codec:marshal(timestamped_change, T) end,
        fistful_source_thrift,
        'TimestampedChange'
    );
marshal_event(destination, 1, Timestamped) ->
    marshal_thrift_event(
        Timestamped,
        fun(T) -> ff_destination_codec:marshal(timestamped_change, T) end,
        fistful_destination_thrift,
        'TimestampedChange'
    );
marshal_event(withdrawal, 1, Timestamped) ->
    marshal_thrift_event(
        Timestamped,
        fun(T) -> ff_withdrawal_codec:marshal(timestamped_change, T) end,
        fistful_wthd_thrift,
        'TimestampedChange'
    );
marshal_event(withdrawal_session, 1, Timestamped) ->
    marshal_thrift_event(
        Timestamped,
        fun(T) -> ff_withdrawal_session_codec:marshal(timestamped_change, T) end,
        fistful_wthd_session_thrift,
        'TimestampedChange'
    );
marshal_event(Domain, Format, _Timestamped) ->
    erlang:error({unknown_event_format, Domain, Format}).

-spec unmarshal_event(domain(), binary()) -> timestamped_event().
unmarshal_event(deposit, Payload) ->
    unmarshal_thrift_event(
        Payload,
        fun(T) -> ff_deposit_codec:unmarshal(timestamped_change, T) end,
        fistful_deposit_thrift,
        'TimestampedChange'
    );
unmarshal_event(source, Payload) ->
    unmarshal_thrift_event(
        Payload,
        fun(T) -> ff_source_codec:unmarshal(timestamped_change, T) end,
        fistful_source_thrift,
        'TimestampedChange'
    );
unmarshal_event(destination, Payload) ->
    unmarshal_thrift_event(
        Payload,
        fun(T) -> ff_destination_codec:unmarshal(timestamped_change, T) end,
        fistful_destination_thrift,
        'TimestampedChange'
    );
unmarshal_event(withdrawal, Payload) ->
    unmarshal_thrift_event(
        Payload,
        fun(T) -> ff_withdrawal_codec:unmarshal(timestamped_change, T) end,
        fistful_wthd_thrift,
        'TimestampedChange'
    );
unmarshal_event(withdrawal_session, Payload) ->
    unmarshal_thrift_event(
        Payload,
        fun(T) -> ff_withdrawal_session_codec:unmarshal(timestamped_change, T) end,
        fistful_wthd_session_thrift,
        'TimestampedChange'
    ).

%% aux_state: legacy machinery_prg_backend wrote plain term_to_binary(AuxSt).
-spec marshal_aux_state(term()) -> binary().
marshal_aux_state(AuxSt) ->
    term_to_binary(AuxSt).

-spec unmarshal_aux_state(binary()) -> term().
unmarshal_aux_state(<<>>) ->
    #{};
unmarshal_aux_state(Payload) when is_binary(Payload) ->
    binary_to_term(Payload).

%% Event payload: write the legacy envelope term_to_binary({bin, ThriftBin})
%% (machinery_prg_backend used machinery_utils:encode(term, ...)).
-spec payload_to_binary(event_payload()) -> binary().
payload_to_binary(Payload) ->
    term_to_binary(Payload).

-spec marshal_thrift_event(
    timestamped_event(),
    fun((timestamped_event()) -> term()),
    atom(),
    atom()
) -> event_payload().
marshal_thrift_event(Timestamped, MarshalFun, ThriftModule, ThriftStruct) ->
    ThriftChange = MarshalFun(Timestamped),
    Type = {struct, struct, {ThriftModule, ThriftStruct}},
    {bin, ff_proto_utils:serialize(Type, ThriftChange)}.

%% Legacy machinery_prg_backend stored events as term_to_binary({bin, ThriftBin}).
legacy_thrift_payload(Payload) when is_binary(Payload) ->
    case binary_to_term(Payload) of
        {bin, Bin} when is_binary(Bin) ->
            Bin;
        Other ->
            erlang:error({legacy_msgpack_event, Other})
    end.

-spec unmarshal_thrift_event(
    binary(),
    fun((term()) -> timestamped_event()),
    atom(),
    atom()
) -> timestamped_event().
unmarshal_thrift_event(Payload, UnmarshalFun, ThriftModule, ThriftStruct) ->
    ThriftBin = legacy_thrift_payload(Payload),
    Type = {struct, struct, {ThriftModule, ThriftStruct}},
    ThriftChange = ff_proto_utils:deserialize(Type, ThriftBin),
    UnmarshalFun(ThriftChange).

%% --- Golden tests: legacy FF format compatibility (stage 1) ----------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec aux_state_roundtrip_test() -> _.
aux_state_roundtrip_test() ->
    AuxSt = #{ctx => #{<<"k">> => <<"v">>}, model => some_model},
    ?assertEqual(AuxSt, unmarshal_aux_state(marshal_aux_state(AuxSt))).

-spec aux_state_empty_test() -> _.
aux_state_empty_test() ->
    ?assertEqual(#{}, unmarshal_aux_state(<<>>)).

-spec aux_state_reads_legacy_term_to_binary_test() -> _.
aux_state_reads_legacy_term_to_binary_test() ->
    %% Legacy machinery wrote aux_state as plain term_to_binary(AuxSt).
    AuxSt = #{ctx => #{}, model => legacy},
    ?assertEqual(AuxSt, unmarshal_aux_state(term_to_binary(AuxSt))).

-spec legacy_thrift_payload_reads_legacy_envelope_test() -> _.
legacy_thrift_payload_reads_legacy_envelope_test() ->
    ThriftBin = <<0, 1, 2, 3, 4>>,
    %% Legacy machinery_prg_backend wrote events as term_to_binary({bin, ThriftBin}).
    ?assertEqual(ThriftBin, legacy_thrift_payload(term_to_binary({bin, ThriftBin}))).

-endif.
