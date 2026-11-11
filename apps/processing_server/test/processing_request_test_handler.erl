-module(processing_request_test_handler).

-export([handle_function/3]).

-spec handle_function(woody:func(), {fun((term()) -> term())}, term()) -> term().
handle_function(_Function, {Handle}, Options) ->
    Handle(Options).
