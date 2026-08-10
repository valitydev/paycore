-module(pm_woody_event_handler).

-behaviour(woody_event_handler).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

%% woody_event_handler behaviour callbacks
-export([handle_event/4]).

-spec handle_event(Event, RpcId, Meta, Opts) -> ok when
    Event :: woody_event_handler:event(),
    RpcId :: woody:rpc_id() | undefined,
    Meta :: woody_event_handler:event_meta(),
    Opts :: woody:options().
handle_event(Event, RpcID, RawMeta, Opts) ->
    FilteredMeta = filter_meta(RawMeta),
    scoper_woody_event_handler:handle_event(Event, RpcID, FilteredMeta, Opts).

%% Internals

filter_meta(RawMeta0) ->
    maps:map(fun do_filter_meta/2, RawMeta0).

do_filter_meta(args, Args) ->
    filter(Args);
do_filter_meta(_Key, Value) ->
    Value.

%% cut secrets
filter(#payproc_ProviderTerminal{proxy = Proxy} = ProviderTerminal) ->
    #domain_ProxyDefinition{options = Options} = Proxy,
    ProviderTerminal#payproc_ProviderTerminal{
        proxy = Proxy#domain_ProxyDefinition{options = maps:without([<<"api-key">>, <<"secret-key">>], Options)}
    };
%% common
filter(L) when is_list(L) ->
    [filter(E) || E <- L];
filter(T) when is_tuple(T) ->
    list_to_tuple(filter(tuple_to_list(T)));
%% default
filter(V) ->
    V.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(ARG_W_SECRET,
    {
        #payproc_ProviderTerminal{
            ref = #domain_TerminalRef{id = 128},
            name = <<"TestTerm">>,
            provider = #payproc_ProviderDetails{
                ref = #domain_ProviderRef{id = 1},
                name = <<"Provider1">>
            },
            proxy = #domain_ProxyDefinition{
                name = <<"Proxy">>,
                description = <<"Desc">>,
                url = <<"http://127.0.0.1">>,
                options = #{<<"api-key">> => <<"secret">>, <<"secret-key">> => <<"secret">>}
            }
        }
    }
).

-define(ARG_WO_SECRET,
    {
        #payproc_ProviderTerminal{
            ref = #domain_TerminalRef{id = 128},
            name = <<"TestTerm">>,
            provider = #payproc_ProviderDetails{
                ref = #domain_ProviderRef{id = 1},
                name = <<"Provider1">>
            },
            proxy = #domain_ProxyDefinition{
                name = <<"Proxy">>,
                description = <<"Desc">>,
                url = <<"http://127.0.0.1">>,
                options = #{}
            }
        }
    }
).

-spec test() -> _.

-spec format_event_w_secret_test_() -> _.
format_event_w_secret_test_() ->
    [
        ?_assertEqual(
            #{args => {some_data, ?ARG_WO_SECRET}, code => 200, function => 'ComputePaymentInstitution'},
            filter_meta(
                #{args => {some_data, ?ARG_W_SECRET}, code => 200, function => 'ComputePaymentInstitution'}
            )
        )
    ].

-endif.
