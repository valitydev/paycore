-module(lim_config_machine).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_limiter_config_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_conf_v2_thrift.hrl").

%% Accessors

-export([type/1]).
-export([context_type/1]).
-export([currency_conversion/1]).

%% API

-export([get_values/2]).
-export([get_batch/3]).
-export([hold_batch/3]).
-export([commit_batch/3]).
-export([rollback_batch/3]).

-export([calculate_shard_id/2]).
-export([mk_scope_prefix/2]).

-type lim_context() :: lim_context:t().
-type processor_type() :: lim_router:processor_type().
-type processor() :: lim_router:processor().
-type description() :: binary().

-type limit_type() :: {turnover, lim_turnover_metric:t()}.
-type limit_scope() :: ordsets:ordset(limit_scope_type()).
-type limit_scope_type() ::
    party
    | shop
    | wallet
    | payment_tool
    | provider
    | terminal
    | payer_contact_email
    | {destination_field, [Field :: binary()]}.
-type shard_size() :: pos_integer().
-type shard_id() :: binary().
-type prefix() :: binary().
-type time_range_type() :: {calendar, year | month | week | day} | {interval, pos_integer()}.
-type time_range() :: #{
    upper := timestamp(),
    lower := timestamp()
}.

-type context_type() :: lim_context:context_type().

-type config() :: #{
    id := lim_id(),
    processor_type := processor_type(),
    started_at := timestamp(),
    shard_size := shard_size(),
    time_range_type := time_range_type(),
    context_type := context_type(),
    type := limit_type(),
    scope => limit_scope(),
    description => description(),
    op_behaviour => op_behaviour(),
    currency_conversion => currency_conversion(),
    finalization_behaviour => finalization_behaviour()
}.

-type op_behaviour() :: #{operation_type() := addition | subtraction}.
-type operation_type() :: invoice_payment_refund.
-type currency_conversion() :: boolean().
-type finalization_behaviour() :: normal | {invertable, session_presence}.

-type lim_id() :: limproto_limiter_thrift:'LimitID'().
-type lim_version() :: dmsl_domain_thrift:'DataRevision'().
-type lim_change() :: limproto_limiter_thrift:'LimitChange'().
-type limit() :: limproto_limiter_thrift:'Limit'().
-type timestamp() :: dmsl_base_thrift:'Timestamp'().
-type operation_id() :: limproto_limiter_thrift:'OperationID'().
-type lim_changes() :: [lim_change()].
-type changes_group() :: {context_type(), finalization_behaviour()}.

-export_type([config/0]).
-export_type([limit_type/0]).
-export_type([limit_scope/0]).
-export_type([time_range_type/0]).
-export_type([time_range/0]).
-export_type([lim_id/0]).
-export_type([lim_change/0]).
-export_type([limit/0]).
-export_type([timestamp/0]).

%% Handler behaviour

-callback make_change(
    Stage :: lim_turnover_metric:stage(),
    LimitChange :: lim_change(),
    Config :: config(),
    LimitContext :: lim_context()
) -> {ok, lim_liminator:limit_change()} | {error, make_change_error()}.

-type make_change_error() :: lim_turnover_processor:make_change_error().
-type get_limit_error() :: lim_turnover_processor:get_limit_error().
-type hold_error() :: lim_turnover_processor:hold_error().
-type commit_error() :: lim_turnover_processor:commit_error().
-type rollback_error() :: lim_turnover_processor:rollback_error().

-type config_error() :: {config, notfound}.

-import(lim_pipeline, [do/1, unwrap/1, unwrap/2]).

%% Accessors

-spec started_at(config()) -> timestamp().
started_at(#{started_at := Value}) ->
    Value.

-spec shard_size(config()) -> shard_size().
shard_size(#{shard_size := Value}) ->
    Value.

-spec time_range_type(config()) -> time_range_type().
time_range_type(#{time_range_type := Value}) ->
    Value.

-spec type(config()) -> limit_type().
type(#{type := Value}) ->
    Value;
type(_) ->
    {turnover, number}.

-spec scope(config()) -> limit_scope().
scope(#{scope := Value}) ->
    Value;
scope(_) ->
    ordsets:new().

-spec context_type(config()) -> context_type().
context_type(#{context_type := Value}) ->
    Value.

-spec finalization_behaviour(config()) -> finalization_behaviour().
finalization_behaviour(#{finalization_behaviour := Value}) ->
    Value;
finalization_behaviour(_) ->
    normal.

-spec currency_conversion(config()) -> currency_conversion().
currency_conversion(#{currency_conversion := Value}) ->
    Value;
currency_conversion(_) ->
    false.

%%

-spec get_values(lim_changes(), lim_context()) ->
    {ok, [lim_liminator:limit_response()]} | {error, config_error() | {processor(), get_limit_error()}}.
get_values(LimitChanges, LimitContext) ->
    do(fun() ->
        Changes = unwrap(collect_changes(hold, LimitChanges, LimitContext)),
        Names = lists:map(fun lim_liminator:get_name/1, Changes),
        unwrap(lim_liminator:get_values(Names, LimitContext))
    end).

-spec get_batch(operation_id(), lim_changes(), lim_context()) ->
    {ok, [lim_liminator:limit_response()]} | {error, config_error() | {processor(), get_limit_error()}}.
get_batch(OperationID, LimitChanges, LimitContext) ->
    do(fun() ->
        GroupedChanges = unwrap(collect_grouped_changes(hold, LimitChanges, LimitContext)),
        F = fun(Group, Changes) ->
            OperationIDForGroup = operation_id_for_group(OperationID, Group),
            unwrap(OperationID, lim_liminator:get(OperationIDForGroup, Changes, LimitContext))
        end,
        lists:flatten(maps:values(maps:map(F, GroupedChanges)))
    end).

-spec hold_batch(operation_id(), lim_changes(), lim_context()) ->
    {ok, [lim_liminator:limit_response()]}
    | {error, config_error() | {processor(), hold_error()} | {operation_id(), lim_liminator:invalid_request_error()}}.
hold_batch(OperationID, LimitChanges, LimitContext) ->
    do(fun() ->
        GroupedChanges = unwrap(collect_grouped_changes(hold, LimitChanges, LimitContext)),
        F = fun(Group, Changes) ->
            OperationIDForGroup = operation_id_for_group(OperationID, Group),
            unwrap(OperationID, lim_liminator:hold(OperationIDForGroup, Changes, LimitContext))
        end,
        lists:flatten(maps:values(maps:map(F, GroupedChanges)))
    end).

-spec commit_batch(operation_id(), lim_changes(), lim_context()) ->
    ok
    | {error, config_error() | {processor(), commit_error()} | {operation_id(), lim_liminator:invalid_request_error()}}.
commit_batch(OperationID, LimitChanges, LimitContext) ->
    do(fun() ->
        GroupedChanges = unwrap(collect_grouped_changes(commit, LimitChanges, LimitContext)),
        F = fun(Group, Changes) ->
            OperationIDForGroup = operation_id_for_group(OperationID, Group),
            Behaviour = resolve_group_finalization_behaviour(Group, LimitContext),
            unwrap(OperationID, finalize(OperationIDForGroup, Changes, LimitContext, commit, Behaviour))
        end,
        maps:foreach(F, GroupedChanges)
    end).

-spec rollback_batch(operation_id(), lim_changes(), lim_context()) ->
    ok
    | {error,
        config_error() | {processor(), rollback_error()} | {operation_id(), lim_liminator:invalid_request_error()}}.
rollback_batch(OperationID, LimitChanges, LimitContext) ->
    do(fun() ->
        GroupedChanges = unwrap(collect_grouped_changes(hold, LimitChanges, LimitContext)),
        F = fun(Group, Changes) ->
            OperationIDForGroup = operation_id_for_group(OperationID, Group),
            Behaviour = resolve_group_finalization_behaviour(Group, LimitContext),
            unwrap(OperationID, finalize(OperationIDForGroup, Changes, LimitContext, rollback, Behaviour))
        end,
        maps:foreach(F, GroupedChanges)
    end).

finalize(OperationIDForGroup, Changes, LimitContext, commit, normal) ->
    lim_liminator:commit(OperationIDForGroup, Changes, LimitContext);
finalize(OperationIDForGroup, Changes, LimitContext, commit, inverted) ->
    lim_liminator:rollback(OperationIDForGroup, Changes, LimitContext);
finalize(OperationIDForGroup, Changes, LimitContext, rollback, normal) ->
    lim_liminator:rollback(OperationIDForGroup, Changes, LimitContext);
finalize(OperationIDForGroup, Changes, LimitContext, rollback, inverted) ->
    lim_liminator:commit(OperationIDForGroup, Changes, LimitContext).

-spec resolve_group_finalization_behaviour(changes_group(), lim_context()) -> normal | inverted.
resolve_group_finalization_behaviour({_, normal}, _) ->
    normal;
resolve_group_finalization_behaviour({ContextType, {invertable, session_presence}}, LimitContext) ->
    case lim_context:get_value(ContextType, session, LimitContext) of
        {ok, undefined} ->
            normal;
        {ok, _Some} ->
            inverted;
        {error, {unsupported, _}} ->
            %% If context doesn't support session value then we treat it as
            %% normal finalization.
            normal;
        {error, notfound} ->
            normal
    end.

operation_id_for_group(OperationID, {_, normal}) ->
    OperationID;
operation_id_for_group(OperationID, {_, {invertable, session_presence}}) ->
    <<OperationID/binary, "/inverted/session-presence">>.

-spec collect_grouped_changes(hold | commit, lim_changes(), lim_context()) ->
    {ok, #{changes_group() => lim_changes()}} | {error, config_error() | {processor(), get_limit_error()}}.
collect_grouped_changes(Stage, LimitChanges, LimitContext) ->
    collect_grouped_changes(Stage, LimitChanges, LimitContext, #{}).

collect_grouped_changes(_, [], _, Acc) ->
    {ok, Acc};
collect_grouped_changes(Stage, [LimitChange | Other], LimitContext, Acc0) ->
    do(fun() ->
        #limiter_LimitChange{id = ID, version = Version} = LimitChange,
        %% NOTE We use only "woody_context" of given limit context to get
        %% handler.
        {Handler, Config} = unwrap(get_handler(ID, Version, LimitContext)),
        Change = unwrap(Handler, Handler:make_change(Stage, LimitChange, Config, LimitContext)),
        %% NOTE Because rules to resolve change's finalization behaviour can be
        %% dependent on operation's context ("context" key of given limit
        %% context map), each group is discriminated by bothe context type and
        %% finalization behaviour values.
        %% Thus, we must ensure changes are in appropriate group before we
        %% evalute groups behaviour against operation's limit context.
        ContextType = context_type(Config),
        FinalizationBehaviour = finalization_behaviour(Config),
        Group = {ContextType, FinalizationBehaviour},
        Acc1 = maps:update_with(Group, fun(Changes) -> [Change | Changes] end, [Change], Acc0),
        unwrap(collect_grouped_changes(Stage, Other, LimitContext, Acc1))
    end).

%% NOTE Used only for `get_values/2' function that doesn't care about groups of
%% changes, nor resulting list's order.
collect_changes(_Stage, [], _LimitContext) ->
    {ok, []};
collect_changes(Stage, [LimitChange = #limiter_LimitChange{id = ID, version = Version} | Other], LimitContext) ->
    do(fun() ->
        {Handler, Config} = unwrap(get_handler(ID, Version, LimitContext)),
        Change = unwrap(Handler, Handler:make_change(Stage, LimitChange, Config, LimitContext)),
        [Change | unwrap(collect_changes(Stage, Other, LimitContext))]
    end).

get_handler(ID, Version, LimitContext) ->
    do(fun() ->
        Config = #{processor_type := ProcessorType} = unwrap(config, get_config(ID, Version, LimitContext)),
        {ok, Handler} = lim_router:get_handler(ProcessorType),
        {Handler, Config}
    end).

-spec get_config(lim_id(), lim_version(), lim_context()) -> {ok, config()} | {error, notfound}.
get_config(ID, Version, #{woody_context := WoodyContext}) ->
    LimitConfigRef = {limit_config, #domain_LimitConfigRef{id = ID}},
    try
        #domain_conf_v2_VersionedObject{object = {limit_config, ConfigObject}} =
            dmt_client:checkout_object(Version, LimitConfigRef, #{woody_context => WoodyContext}),
        {ok, unmarshal_limit_config(ConfigObject)}
    catch
        throw:#domain_conf_v2_ObjectNotFound{} ->
            {error, notfound}
    end.

-spec calculate_shard_id(timestamp(), config()) -> shard_id().
calculate_shard_id(Timestamp, Config) ->
    StartedAt = started_at(Config),
    ShardSize = shard_size(Config),
    case time_range_type(Config) of
        {calendar, Range} ->
            calculate_calendar_shard_id(Range, Timestamp, StartedAt, ShardSize);
        {interval, _Interval} ->
            erlang:error({interval_time_range_not_implemented, Config})
    end.

calculate_calendar_shard_id(Range, Timestamp, StartedAt, ShardSize) ->
    StartDatetime = parse_timestamp(StartedAt),
    CurrentDatetime = parse_timestamp(Timestamp),
    Units = calculate_time_units(Range, CurrentDatetime, StartDatetime),
    SignPrefix = mk_sign_prefix(Units),
    RangePrefix = mk_unit_prefix(Range),
    mk_shard_id(<<SignPrefix/binary, "/", RangePrefix/binary>>, Units, ShardSize).

calculate_time_units(year, CurrentDatetime, StartDatetime) ->
    StartSecBase = calculate_start_of_year_seconds(StartDatetime),
    StartSec = calendar:datetime_to_gregorian_seconds(StartDatetime),
    CurrentSecBase = calculate_start_of_year_seconds(CurrentDatetime),
    CurrentSec = calendar:datetime_to_gregorian_seconds(CurrentDatetime),

    StartDelta = StartSec - StartSecBase,
    CurrentDelta = CurrentSec - (CurrentSecBase + StartDelta),
    maybe_previous_unit(CurrentDelta, year(CurrentDatetime) - year(StartDatetime));
calculate_time_units(month, CurrentDatetime, StartDatetime) ->
    StartSecBase = calculate_start_of_month_seconds(StartDatetime),
    StartSec = calendar:datetime_to_gregorian_seconds(StartDatetime),
    CurrentSecBase = calculate_start_of_month_seconds(CurrentDatetime),
    CurrentSec = calendar:datetime_to_gregorian_seconds(CurrentDatetime),

    StartDelta = StartSec - StartSecBase,
    CurrentDelta = CurrentSec - (CurrentSecBase + StartDelta),

    YearDiff = year(CurrentDatetime) - year(StartDatetime),
    MonthDiff = month(CurrentDatetime) - month(StartDatetime),

    maybe_previous_unit(CurrentDelta, YearDiff * 12 + MonthDiff);
calculate_time_units(week, {CurrentDate, CurrentTime}, {StartDate, StartTime}) ->
    StartWeekRem = calendar:date_to_gregorian_days(StartDate) rem 7,
    StartWeekBase = (calendar:date_to_gregorian_days(StartDate) div 7) * 7,
    CurrentWeekBase = (calendar:date_to_gregorian_days(CurrentDate) div 7) * 7,

    StartSecBase = calendar:datetime_to_gregorian_seconds(
        {calendar:gregorian_days_to_date(StartWeekBase), {0, 0, 0}}
    ),
    StartSec = calendar:datetime_to_gregorian_seconds(
        {calendar:gregorian_days_to_date(StartWeekBase + StartWeekRem), StartTime}
    ),
    CurrentSecBase = calendar:datetime_to_gregorian_seconds(
        {calendar:gregorian_days_to_date(CurrentWeekBase), {0, 0, 0}}
    ),
    CurrentSec = calendar:datetime_to_gregorian_seconds(
        {calendar:gregorian_days_to_date(CurrentWeekBase + StartWeekRem), CurrentTime}
    ),

    StartDelta = StartSec - StartSecBase,
    CurrentDelta = CurrentSec - (CurrentSecBase + StartDelta),

    StartWeeks = calendar:date_to_gregorian_days(StartDate) div 7,
    CurrentWeeks = calendar:date_to_gregorian_days(CurrentDate) div 7,
    maybe_previous_unit(CurrentDelta, CurrentWeeks - StartWeeks);
calculate_time_units(day, {CurrentDate, CurrentTime}, {StartDate, StartTime}) ->
    StartSecBase = calendar:datetime_to_gregorian_seconds({StartDate, {0, 0, 0}}),
    StartSec = calendar:datetime_to_gregorian_seconds({StartDate, StartTime}),
    CurrentSecBase = calendar:datetime_to_gregorian_seconds({CurrentDate, {0, 0, 0}}),
    CurrentSec = calendar:datetime_to_gregorian_seconds({CurrentDate, CurrentTime}),
    StartDelta = StartSec - StartSecBase,
    CurrentDelta = CurrentSec - (CurrentSecBase + StartDelta),
    StartDays = calendar:date_to_gregorian_days(StartDate),
    CurrentDays = calendar:date_to_gregorian_days(CurrentDate),
    maybe_previous_unit(CurrentDelta, CurrentDays - StartDays).

maybe_previous_unit(Delta, Unit) when Delta < 0 ->
    Unit - 1;
maybe_previous_unit(_Delta, Unit) ->
    Unit.

calculate_start_of_year_seconds({{Year, _, _}, _Time}) ->
    calendar:datetime_to_gregorian_seconds({{Year, 1, 1}, {0, 0, 0}}).

calculate_start_of_month_seconds({{Year, Month, _}, _Time}) ->
    calendar:datetime_to_gregorian_seconds({{Year, Month, 1}, {0, 0, 0}}).

year({{Year, _, _}, _Time}) ->
    Year.

month({{_Year, Month, _}, _Time}) ->
    Month.

mk_unit_prefix(day) -> <<"day">>;
mk_unit_prefix(week) -> <<"week">>;
mk_unit_prefix(month) -> <<"month">>;
mk_unit_prefix(year) -> <<"year">>.

mk_sign_prefix(Units) when Units >= 0 -> <<"future">>;
mk_sign_prefix(_) -> <<"past">>.

mk_shard_id(Prefix, Units, ShardSize) ->
    ID = integer_to_binary(abs(Units) div ShardSize),
    <<Prefix/binary, "/", ID/binary>>.

-spec mk_scope_prefix(config(), lim_context()) ->
    {ok, {prefix(), lim_context:change_context()}} | {error, lim_context:context_error()}.
mk_scope_prefix(Config, LimitContext) ->
    mk_scope_prefix_impl(scope(Config), context_type(Config), LimitContext).

-spec mk_scope_prefix_impl(limit_scope(), context_type(), lim_context()) ->
    {ok, {prefix(), lim_context:change_context()}} | {error, lim_context:context_error()}.
mk_scope_prefix_impl(Scope, ContextType, LimitContext) ->
    do(fun() ->
        Bits = enumerate_context_bits(Scope),
        lists:foldl(
            fun(Bit, {AccPrefix, Map}) ->
                BinaryBit = encode_bit(Bit),
                Value = unwrap(extract_context_bit(Bit, ContextType, LimitContext)),
                {append_prefix(Value, AccPrefix), Map#{<<"Scope.", BinaryBit/binary>> => Value}}
            end,
            {<<>>, #{}},
            Bits
        )
    end).

encode_bit({prefix, _Prefix}) ->
    genlib:to_binary(prefix);
encode_bit({from, {destination_field, FieldPath}}) ->
    lim_string:join($., [<<"destination_field">>] ++ FieldPath);
encode_bit({from, BitType}) ->
    genlib:to_binary(BitType).

-spec append_prefix(binary(), prefix()) -> prefix().
append_prefix(Fragment, Acc) ->
    <<Acc/binary, "/", Fragment/binary>>.

-type context_bit() ::
    {from, _ValueName :: atom()}
    | {prefix, prefix()}.

-spec enumerate_context_bits(limit_scope()) -> [context_bit()].
enumerate_context_bits(Types) ->
    TypesOrder =
        [
            party,
            shop,
            wallet,
            payment_tool,
            provider,
            terminal,
            payer_contact_email,
            %% Scope 'destination_field' differs from other scope
            %% types by having an attribute and being represented as a
            %% tuple '{destination_field, [Field :: binary()]}'.
            destination_field,
            sender,
            receiver
        ],
    SortedTypes = lists:filtermap(
        fun
            (destination_field) ->
                case lists:keyfind(destination_field, 1, Types) of
                    {destination_field, _} = Found -> {true, Found};
                    _ -> false
                end;
            (T) ->
                ordsets:is_element(T, Types)
        end,
        TypesOrder
    ),
    SquashedTypes = squash_scope_types(SortedTypes),
    lists:flatmap(fun get_context_bits/1, SquashedTypes).

squash_scope_types([party, shop | Rest]) ->
    % NOTE
    % Shop scope implies party scope.
    [shop | squash_scope_types(Rest)];
squash_scope_types([party, wallet | Rest]) ->
    % NOTE
    % Wallet scope implies party scope.
    [wallet | squash_scope_types(Rest)];
squash_scope_types([provider, terminal | Rest]) ->
    % NOTE
    % Provider scope implies provider scope.
    [terminal | squash_scope_types(Rest)];
squash_scope_types([Type | Rest]) ->
    [Type | squash_scope_types(Rest)];
squash_scope_types([]) ->
    [].

-spec get_context_bits(limit_scope_type()) -> [context_bit()].
get_context_bits(party) ->
    [{from, owner_id}];
get_context_bits(shop) ->
    % NOTE
    % We need to preserve order between party / shop to ensure backwards compatibility.
    [{from, owner_id}, {from, shop_id}];
get_context_bits(payment_tool) ->
    [{from, payment_tool}];
get_context_bits(wallet) ->
    [{prefix, <<"wallet">>}, {from, owner_id}, {from, wallet_id}];
get_context_bits(provider) ->
    [{prefix, <<"provider">>}, {from, provider_id}];
get_context_bits(terminal) ->
    [{prefix, <<"terminal">>}, {from, provider_id}, {from, terminal_id}];
get_context_bits(payer_contact_email) ->
    [{prefix, <<"payer_contact_email">>}, {from, payer_contact_email}];
get_context_bits({destination_field, FieldPath}) ->
    [{prefix, <<"destination">>}, {from, {destination_field, FieldPath}}];
get_context_bits(sender) ->
    [{prefix, <<"sender">>}, {from, sender}];
get_context_bits(receiver) ->
    [{prefix, <<"receiver">>}, {from, receiver}].

-spec extract_context_bit(context_bit(), context_type(), lim_context()) ->
    {ok, binary()} | {error, lim_context:context_error()}.
extract_context_bit({prefix, Prefix}, _ContextType, _LimitContext) ->
    {ok, Prefix};
extract_context_bit({from, {destination_field, FieldPath}}, ContextType, LimitContext) ->
    do(fun() ->
        #{type := Type, data := Data} = unwrap(get_generic_payment_tool_resource(ContextType, LimitContext)),
        DecodedData = unwrap(lim_context_utils:decode_content(Type, Data)),
        FieldValue = unwrap(lim_context_utils:get_field_by_path(FieldPath, DecodedData)),
        PrefixedValue = lim_string:join($., FieldPath ++ [FieldValue]),
        HashedValue = lim_context_utils:base61_hash(PrefixedValue),
        mk_scope_component([HashedValue])
    end);
extract_context_bit({from, payment_tool}, ContextType, LimitContext) ->
    case lim_context:get_value(ContextType, payment_tool, LimitContext) of
        {ok, {bank_card, #{token := Token, exp_date := {Month, Year}}}} ->
            {ok, mk_scope_component([Token, Month, Year])};
        {ok, {bank_card, #{token := Token, exp_date := undefined}}} ->
            {ok, mk_scope_component([Token, <<"undefined">>])};
        {ok, {digital_wallet, #{id := ID, service := Service}}} ->
            {ok, mk_scope_component([<<"DW">>, Service, ID])};
        %% Generic payment tool is supposed to be not supported
        {ok, {generic = Type, _}} ->
            {error, {unsupported, {payment_tool, Type}}};
        {error, _} = Error ->
            Error
    end;
extract_context_bit({from, ValueName}, ContextType, LimitContext) ->
    lim_context:get_value(ContextType, ValueName, LimitContext).

mk_scope_component(Fragments) ->
    lim_string:join($/, Fragments).

get_generic_payment_tool_resource(ContextType, LimitContext) ->
    case lim_context:get_value(ContextType, payment_tool, LimitContext) of
        {ok, {generic, #{data := ResourceData}}} ->
            {ok, ResourceData};
        {ok, {ToolType, _}} ->
            {error, {unsupported, ToolType}};
        {error, _} = Error ->
            Error
    end.

parse_timestamp(Bin) ->
    try
        MicroSeconds = genlib_rfc3339:parse(Bin, microsecond),
        case genlib_rfc3339:is_utc(Bin) of
            false ->
                erlang:error({bad_timestamp, not_utc}, [Bin]);
            true ->
                calendar:system_time_to_universal_time(MicroSeconds, microsecond)
        end
    catch
        error:Error:St ->
            erlang:raise(error, {bad_timestamp, Bin, Error}, St)
    end.

unmarshal_limit_config(#domain_LimitConfigObject{
    ref = #domain_LimitConfigRef{id = ID},
    data = #limiter_config_LimitConfig{
        processor_type = ProcessorType,
        started_at = StartedAt,
        shard_size = ShardSize,
        time_range_type = TimeRangeType,
        context_type = ContextType,
        type = Type,
        scopes = Scopes,
        description = Description,
        op_behaviour = OpBehaviour,
        currency_conversion = CurrencyConversion,
        finalization_behaviour = FinalizationBehaviour
    }
}) ->
    genlib_map:compact(#{
        id => ID,
        processor_type => ProcessorType,
        started_at => StartedAt,
        shard_size => ShardSize,
        time_range_type => unmarshal_time_range_type(TimeRangeType),
        context_type => unmarshal_context_type(ContextType),
        type => maybe_apply(Type, fun unmarshal_type/1),
        scope => maybe_apply(Scopes, fun unmarshal_scope/1),
        description => Description,
        op_behaviour => maybe_apply(OpBehaviour, fun unmarshal_op_behaviour/1),
        currency_conversion => CurrencyConversion =/= undefined,
        finalization_behaviour => unmarshal_finalization_behaviour(FinalizationBehaviour)
    }).

unmarshal_finalization_behaviour(undefined) ->
    normal;
unmarshal_finalization_behaviour({normal, #limiter_config_Normal{}}) ->
    normal;
unmarshal_finalization_behaviour({invertable, {session_presence, #limiter_config_Inversed{}}}) ->
    {invertable, session_presence}.

unmarshal_time_range_type({calendar, CalendarType}) ->
    {calendar, unmarshal_calendar_time_range_type(CalendarType)};
unmarshal_time_range_type({interval, #limiter_config_TimeRangeTypeInterval{amount = Amount}}) ->
    {interval, Amount}.

unmarshal_calendar_time_range_type({day, _}) ->
    day;
unmarshal_calendar_time_range_type({week, _}) ->
    week;
unmarshal_calendar_time_range_type({month, _}) ->
    month;
unmarshal_calendar_time_range_type({year, _}) ->
    year.

unmarshal_context_type({payment_processing, #limiter_config_LimitContextTypePaymentProcessing{}}) ->
    payment_processing;
unmarshal_context_type({withdrawal_processing, #limiter_config_LimitContextTypeWithdrawalProcessing{}}) ->
    withdrawal_processing.

unmarshal_type({turnover, #limiter_config_LimitTypeTurnover{metric = Metric}}) ->
    {turnover, maybe_apply(Metric, fun unmarshal_turnover_metric/1, number)}.

unmarshal_turnover_metric({number, _}) ->
    number;
unmarshal_turnover_metric({amount, #limiter_config_LimitTurnoverAmount{currency = Currency}}) ->
    {amount, Currency}.

unmarshal_scope({single, Type}) ->
    ordsets:from_list([unmarshal_scope_type(Type)]);
unmarshal_scope({multi, Types}) ->
    ordsets:from_list(lists:map(fun unmarshal_scope_type/1, ordsets:to_list(Types)));
unmarshal_scope(Types) when is_list(Types) ->
    ordsets:from_list(lists:map(fun unmarshal_scope_type/1, ordsets:to_list(Types))).

unmarshal_scope_type({party, _}) ->
    party;
unmarshal_scope_type({shop, _}) ->
    shop;
unmarshal_scope_type({wallet, _}) ->
    wallet;
unmarshal_scope_type({payment_tool, _}) ->
    payment_tool;
unmarshal_scope_type({provider, _}) ->
    provider;
unmarshal_scope_type({terminal, _}) ->
    terminal;
unmarshal_scope_type({payer_contact_email, _}) ->
    payer_contact_email;
unmarshal_scope_type({destination_field, #limiter_config_LimitScopeDestinationFieldDetails{field_path = FieldPath}}) ->
    %% Domain config variant clause
    {destination_field, FieldPath};
unmarshal_scope_type({sender, _}) ->
    sender;
unmarshal_scope_type({receiver, _}) ->
    receiver.

unmarshal_op_behaviour(#limiter_config_OperationLimitBehaviour{invoice_payment_refund = Refund}) ->
    genlib_map:compact(#{
        invoice_payment_refund => maybe_apply(Refund, fun unmarshal_behaviour/1)
    }).

unmarshal_behaviour({subtraction, #limiter_config_Subtraction{}}) ->
    subtraction;
unmarshal_behaviour({addition, #limiter_config_Addition{}}) ->
    addition.

maybe_apply(undefined, _) ->
    undefined;
maybe_apply(Value, Fun) ->
    Fun(Value).

maybe_apply(undefined, _, Default) ->
    Default;
maybe_apply(Value, Fun, _Default) ->
    Fun(Value).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-include_lib("limiter_proto/include/limproto_context_payproc_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_withdrawal_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").

-spec test() -> _.

-spec unmarshal_config_object_test() -> _.
unmarshal_config_object_test() ->
    Config = #{
        id => <<"id">>,
        processor_type => <<"type">>,
        started_at => <<"2000-01-01T00:00:00Z">>,
        shard_size => 7,
        time_range_type => {calendar, day},
        context_type => payment_processing,
        type => {turnover, number},
        scope => ordsets:from_list([party, shop, {destination_field, [<<"path">>, <<"to">>, <<"field">>]}]),
        description => <<"description">>,
        currency_conversion => true,
        finalization_behaviour => {invertable, session_presence}
    },
    Object = #domain_LimitConfigObject{
        ref = #domain_LimitConfigRef{id = <<"id">>},
        data = #limiter_config_LimitConfig{
            processor_type = <<"type">>,
            started_at = <<"2000-01-01T00:00:00Z">>,
            shard_size = 7,
            time_range_type = {calendar, {day, #limiter_config_TimeRangeTypeCalendarDay{}}},
            context_type = {payment_processing, #limiter_config_LimitContextTypePaymentProcessing{}},
            type =
                {turnover, #limiter_config_LimitTypeTurnover{metric = {number, #limiter_config_LimitTurnoverNumber{}}}},
            scopes = ordsets:from_list([
                {'party', #limiter_config_LimitScopeEmptyDetails{}},
                {'shop', #limiter_config_LimitScopeEmptyDetails{}},
                {'destination_field', #limiter_config_LimitScopeDestinationFieldDetails{
                    field_path = [<<"path">>, <<"to">>, <<"field">>]
                }}
            ]),
            description = <<"description">>,
            currency_conversion = #limiter_config_CurrencyConversion{},
            finalization_behaviour = {invertable, {session_presence, #limiter_config_Inversed{}}}
        }
    },
    ?assertEqual(Config, unmarshal_limit_config(Object)).

-spec check_sign_prefix_test() -> _.
check_sign_prefix_test() ->
    ?assertEqual(<<"past">>, mk_sign_prefix(-10)),
    ?assertEqual(<<"future">>, mk_sign_prefix(0)),
    ?assertEqual(<<"future">>, mk_sign_prefix(10)).

-spec check_calculate_day_shard_id_test() -> _.
check_calculate_day_shard_id_test() ->
    StartedAt1 = <<"2000-01-01T00:00:00Z">>,
    ?assertEqual(<<"future/day/0">>, calculate_calendar_shard_id(day, <<"2000-01-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/day/2">>, calculate_calendar_shard_id(day, <<"2000-01-03T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"past/day/1">>, calculate_calendar_shard_id(day, <<"1999-12-31T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/day/1">>, calculate_calendar_shard_id(day, <<"2000-01-02T23:59:59Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/day/1">>, calculate_calendar_shard_id(day, <<"2000-01-04T00:00:00Z">>, StartedAt1, 2)),
    ?assertEqual(<<"future/day/366">>, calculate_calendar_shard_id(day, <<"2001-01-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/day/12">>, calculate_calendar_shard_id(day, <<"2001-01-01T00:00:00Z">>, StartedAt1, 30)),
    StartedAt2 = <<"2000-01-01T03:00:00Z">>,
    ?assertEqual(<<"past/day/1">>, calculate_calendar_shard_id(day, <<"2000-01-01T00:00:00Z">>, StartedAt2, 1)),
    ?assertEqual(<<"future/day/1">>, calculate_calendar_shard_id(day, <<"2000-01-03T00:00:00Z">>, StartedAt2, 1)).

-spec check_calculate_week_shard_id_test() -> _.
check_calculate_week_shard_id_test() ->
    StartedAt1 = <<"2000-01-01T00:00:00Z">>,
    ?assertEqual(<<"future/week/0">>, calculate_calendar_shard_id(week, <<"2000-01-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"past/week/1">>, calculate_calendar_shard_id(week, <<"1999-12-31T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/week/1">>, calculate_calendar_shard_id(week, <<"2000-01-08T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/week/1">>, calculate_calendar_shard_id(week, <<"2000-01-15T00:00:00Z">>, StartedAt1, 2)),
    ?assertEqual(<<"future/week/52">>, calculate_calendar_shard_id(week, <<"2001-01-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/week/13">>, calculate_calendar_shard_id(week, <<"2001-01-01T00:00:00Z">>, StartedAt1, 4)),
    StartedAt2 = <<"2000-01-02T03:00:00Z">>,
    ?assertEqual(<<"past/week/1">>, calculate_calendar_shard_id(week, <<"2000-01-02T00:00:00Z">>, StartedAt2, 1)),
    ?assertEqual(<<"future/week/0">>, calculate_calendar_shard_id(week, <<"2000-01-09T00:00:00Z">>, StartedAt2, 1)).

-spec check_calculate_month_shard_id_test() -> _.
check_calculate_month_shard_id_test() ->
    StartedAt1 = <<"2000-01-01T00:00:00Z">>,
    ?assertEqual(<<"future/month/0">>, calculate_calendar_shard_id(month, <<"2000-01-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"past/month/1">>, calculate_calendar_shard_id(month, <<"1999-12-31T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/month/1">>, calculate_calendar_shard_id(month, <<"2000-02-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/month/1">>, calculate_calendar_shard_id(month, <<"2000-03-01T00:00:00Z">>, StartedAt1, 2)),
    ?assertEqual(<<"future/month/12">>, calculate_calendar_shard_id(month, <<"2001-01-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/month/1">>, calculate_calendar_shard_id(month, <<"2001-01-01T00:00:00Z">>, StartedAt1, 12)),
    StartedAt2 = <<"2000-01-02T03:00:00Z">>,
    ?assertEqual(<<"past/month/1">>, calculate_calendar_shard_id(month, <<"2000-01-02T00:00:00Z">>, StartedAt2, 1)),
    ?assertEqual(<<"future/month/0">>, calculate_calendar_shard_id(month, <<"2000-02-02T00:00:00Z">>, StartedAt2, 1)).

-spec check_calculate_year_shard_id_test() -> _.
check_calculate_year_shard_id_test() ->
    StartedAt1 = <<"2000-01-01T00:00:00Z">>,
    ?assertEqual(<<"future/year/0">>, calculate_calendar_shard_id(year, <<"2000-01-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"past/year/1">>, calculate_calendar_shard_id(year, <<"1999-12-31T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/year/1">>, calculate_calendar_shard_id(year, <<"2001-01-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/year/1">>, calculate_calendar_shard_id(year, <<"2003-01-01T00:00:00Z">>, StartedAt1, 2)),
    ?assertEqual(<<"future/year/10">>, calculate_calendar_shard_id(year, <<"2010-01-01T00:00:00Z">>, StartedAt1, 1)),
    ?assertEqual(<<"future/year/2">>, calculate_calendar_shard_id(year, <<"2020-01-01T00:00:00Z">>, StartedAt1, 10)),
    StartedAt2 = <<"2000-01-02T03:00:00Z">>,
    ?assertEqual(<<"past/year/1">>, calculate_calendar_shard_id(year, <<"2000-01-01T00:00:00Z">>, StartedAt2, 1)),
    ?assertEqual(<<"future/year/0">>, calculate_calendar_shard_id(year, <<"2001-01-01T00:00:00Z">>, StartedAt2, 1)).

-define(PAYPROC_CTX_INVOICE(Invoice, Payment, Route), #limiter_LimitContext{
    payment_processing = #context_payproc_Context{
        op = {invoice_payment, #context_payproc_OperationInvoicePayment{}},
        invoice = #context_payproc_Invoice{
            invoice = Invoice,
            payment = #context_payproc_InvoicePayment{
                payment = Payment,
                route = Route
            }
        }
    }
}).

-define(PAYPROC_CTX_INVOICE(Invoice),
    ?PAYPROC_CTX_INVOICE(
        Invoice,
        ?PAYMENT(?PAYER(?PAYMENT_TOOL)),
        ?ROUTE(22, 2)
    )
).

-define(INVOICE(OwnerID, ShopID), #domain_Invoice{
    id = <<"ID">>,
    party_ref = #domain_PartyConfigRef{id = OwnerID},
    shop_ref = #domain_ShopConfigRef{id = ShopID},
    domain_revision = 1,
    created_at = <<"2000-02-02T12:12:12Z">>,
    status = {unpaid, #domain_InvoiceUnpaid{}},
    details = #domain_InvoiceDetails{product = <<>>},
    due = <<"2222-02-02T12:12:12Z">>,
    cost = #domain_Cash{amount = 42, currency = #domain_CurrencyRef{symbolic_code = <<"CNY">>}}
}).

-define(PAYMENT(Payer), #domain_InvoicePayment{
    id = <<"ID">>,
    created_at = <<"2000-02-02T12:12:12Z">>,
    status = {pending, #domain_InvoicePaymentPending{}},
    cost = #domain_Cash{amount = 42, currency = #domain_CurrencyRef{symbolic_code = <<"CNY">>}},
    domain_revision = 1,
    flow = {instant, #domain_InvoicePaymentFlowInstant{}},
    payer = Payer
}).

-define(PAYER(PaymentTool),
    {payment_resource, #domain_PaymentResourcePayer{
        resource = #domain_DisposablePaymentResource{payment_tool = PaymentTool},
        contact_info = #domain_ContactInfo{email = <<"email">>}
    }}
).

-define(PAYMENT_TOOL,
    {bank_card, #domain_BankCard{
        token = <<"token">>,
        bin = <<"****">>,
        last_digits = <<"last_digits">>,
        exp_date = #domain_BankCardExpDate{month = 2, year = 2022}
    }}
).

-define(WITHDRAWAL_CTX(Withdrawal, WalletID, Route), #limiter_LimitContext{
    withdrawal_processing = #context_withdrawal_Context{
        op = {withdrawal, #context_withdrawal_OperationWithdrawal{}},
        withdrawal = #context_withdrawal_Withdrawal{
            withdrawal = Withdrawal,
            wallet_id = WalletID,
            route = Route
        }
    }
}).

-define(WITHDRAWAL(OwnerID, PaymentTool), #wthd_domain_Withdrawal{
    destination = PaymentTool,
    sender = #domain_PartyConfigRef{id = OwnerID},
    created_at = <<"2000-02-02T12:12:12Z">>,
    body = #domain_Cash{amount = 42, currency = #domain_CurrencyRef{symbolic_code = <<"CNY">>}}
}).

-define(ROUTE(ProviderID, TerminalID), #base_Route{
    provider = #domain_ProviderRef{id = ProviderID},
    terminal = #domain_TerminalRef{id = TerminalID}
}).

-spec global_scope_empty_prefix_test() -> _.
global_scope_empty_prefix_test() ->
    Context = #{context => ?PAYPROC_CTX_INVOICE(?INVOICE(<<"OWNER">>, <<"SHOP">>))},
    ?assertEqual({ok, {<<>>, #{}}}, mk_scope_prefix_impl(ordsets:new(), payment_processing, Context)).

-spec preserve_scope_prefix_order_test_() -> [_TestGen].
preserve_scope_prefix_order_test_() ->
    Context = #{context => ?PAYPROC_CTX_INVOICE(?INVOICE(<<"OWNER">>, <<"SHOP">>))},
    [
        ?_assertEqual(
            {ok, {<<"/OWNER/SHOP">>, #{<<"Scope.owner_id">> => <<"OWNER">>, <<"Scope.shop_id">> => <<"SHOP">>}}},
            mk_scope_prefix_impl(ordsets:from_list([shop, party]), payment_processing, Context)
        ),
        ?_assertEqual(
            {ok, {<<"/OWNER/SHOP">>, #{<<"Scope.owner_id">> => <<"OWNER">>, <<"Scope.shop_id">> => <<"SHOP">>}}},
            mk_scope_prefix_impl(ordsets:from_list([party, shop]), payment_processing, Context)
        ),
        ?_assertEqual(
            {ok, {<<"/OWNER/SHOP">>, #{<<"Scope.owner_id">> => <<"OWNER">>, <<"Scope.shop_id">> => <<"SHOP">>}}},
            mk_scope_prefix_impl(ordsets:from_list([shop]), payment_processing, Context)
        )
    ].

-spec prefix_content_test_() -> [_TestGen].
prefix_content_test_() ->
    Context = #{
        context => ?PAYPROC_CTX_INVOICE(
            ?INVOICE(<<"OWNER">>, <<"SHOP">>),
            ?PAYMENT(?PAYER(?PAYMENT_TOOL)),
            ?ROUTE(22, 2)
        )
    },
    WithdrawalContext = #{
        context => ?WITHDRAWAL_CTX(
            ?WITHDRAWAL(<<"OWNER">>, ?PAYMENT_TOOL),
            <<"WALLET">>,
            ?ROUTE(22, 2)
        )
    },
    [
        ?_assertEqual(
            {ok,
                {<<"/terminal/22/2">>, #{
                    <<"Scope.prefix">> => <<"terminal">>,
                    <<"Scope.provider_id">> => <<"22">>,
                    <<"Scope.terminal_id">> => <<"2">>
                }}},
            mk_scope_prefix_impl(ordsets:from_list([terminal, provider]), payment_processing, Context)
        ),
        ?_assertEqual(
            {ok,
                {<<"/terminal/22/2">>, #{
                    <<"Scope.prefix">> => <<"terminal">>,
                    <<"Scope.provider_id">> => <<"22">>,
                    <<"Scope.terminal_id">> => <<"2">>
                }}},
            mk_scope_prefix_impl(ordsets:from_list([provider, terminal]), payment_processing, Context)
        ),
        ?_assertEqual(
            {ok,
                {<<"/wallet/OWNER/WALLET">>, #{
                    <<"Scope.owner_id">> => <<"OWNER">>,
                    <<"Scope.prefix">> => <<"wallet">>,
                    <<"Scope.wallet_id">> => <<"WALLET">>
                }}},
            mk_scope_prefix_impl(ordsets:from_list([wallet, party]), withdrawal_processing, WithdrawalContext)
        ),
        ?_assertEqual(
            {ok,
                {<<"/token/2/2022/payer_contact_email/email">>, #{
                    <<"Scope.payer_contact_email">> => <<"email">>,
                    <<"Scope.payment_tool">> => <<"token/2/2022">>,
                    <<"Scope.prefix">> => <<"payer_contact_email">>
                }}},
            mk_scope_prefix_impl(ordsets:from_list([payer_contact_email, payment_tool]), payment_processing, Context)
        )
    ].

-endif.
