-module(routing_domain).

-callback compute_ruleset(
    dmsl_domain_thrift:'RoutingRulesetRef'(), map(), hg_route:revision()
) -> {ok, dmsl_domain_thrift:'RoutingRuleset'()}.

-callback resolve_terminal(hg_route:terminal_ref(), hg_route:revision()) ->
    {ok, hg_route:provider_ref()}.

-callback validate_candidate(dmsl_domain_thrift:'RoutingCandidate'()) -> ok | no_return().
