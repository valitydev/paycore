-module(legacy_fixture_lib).

-compile(nowarn_missing_spec).

%%% Load CT-captured legacy progressor bytes from test/fixtures/legacy/.

-export([root/0]).
-export([read_bin/2]).
-export([read_term/2]).
-export([read_event_payload/2]).
-export([read_event_metadata/2]).
-export([read_aux_state/1]).
-export([ff_fixtures/0]).
-export([hg_invoice_dir/0]).

-type fixture_dir() :: string().
-type domain() :: deposit | source | destination | withdrawal | withdrawal_session.

-spec root() -> file:filename().
root() ->
    filename:absname(
        filename:join([
            filename:dirname(?FILE),
            "..",
            "..",
            "..",
            "test",
            "fixtures",
            "legacy"
        ])
    ).

-spec ff_fixtures() -> [{domain(), fixture_dir()}].
ff_fixtures() ->
    [
        {deposit, "ff_deposit_v1"},
        {source, "ff_source_v1"},
        {destination, "ff_destination_v2"},
        {withdrawal, "ff_withdrawal_v2"},
        {withdrawal_session, "ff_withdrawal_session_v2"}
    ].

-spec hg_invoice_dir() -> fixture_dir().
hg_invoice_dir() ->
    "hg_invoice".

-spec read_bin(fixture_dir(), file:filename()) -> binary().
read_bin(Dir, Name) ->
    Path = filename:join([root(), Dir, "latest", Name]),
    {ok, Bin} = file:read_file(Path),
    Bin.

-spec read_term(fixture_dir(), file:filename()) -> term().
read_term(Dir, Name) ->
    Path = filename:join([root(), Dir, "latest", Name]),
    {ok, [Term]} = file:consult(Path),
    Term.

-spec read_event_payload(fixture_dir(), pos_integer()) -> binary().
read_event_payload(Dir, Index) ->
    read_bin(Dir, event_name(Index, "payload.bin")).

-spec read_event_metadata(fixture_dir(), pos_integer()) -> map().
read_event_metadata(Dir, Index) ->
    read_term(Dir, event_name(Index, "metadata.term")).

-spec read_aux_state(fixture_dir()) -> binary().
read_aux_state(Dir) ->
    read_bin(Dir, "aux_state.bin").

event_name(Index, Suffix) ->
    filename:join(["events", lists:flatten(io_lib:format("~4..0w.", [Index])) ++ Suffix]).
