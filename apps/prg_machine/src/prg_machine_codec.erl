-module(prg_machine_codec).

-export([encode_term/1]).
-export([decode_term/1]).

-spec encode_term(term()) -> binary().
encode_term(Term) ->
    term_to_binary(Term).

-spec decode_term(term()) -> term().
decode_term(Term) when is_binary(Term) ->
    case binary_to_term(Term) of
        %% Legacy double envelope: old hg_machine wrote
        %% term_to_binary({bin, term_to_binary(Args)}) for call/init args.
        {bin, Bin} when is_binary(Bin) ->
            binary_to_term(Bin);
        Decoded ->
            Decoded
    end;
decode_term(Term) ->
    Term.
