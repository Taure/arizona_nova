-module(arizona_nova).
-moduledoc """
Public API for Arizona Nova integration.

Provides view resolver registration and configuration helpers.
Apps register their view resolvers at startup so the shared
WebSocket endpoint can route to the correct view module.

## Usage

```erlang
%% In your app's start/2:
arizona_nova:register_views(my_app, fun my_controller:resolve_view/1).
```
""".

-export([prefix/0, register_views/2, resolve_view/1]).

-define(RESOLVER_TABLE, arizona_nova_resolvers).

-doc "Get the configured URL prefix. Default: `/arizona`.".
-spec prefix() -> binary().
prefix() ->
    case application:get_env(arizona_nova, prefix, ~"/arizona") of
        Prefix when is_binary(Prefix) -> Prefix;
        Prefix when is_list(Prefix) -> list_to_binary(Prefix)
    end.

-doc "Register a view resolver for an application.".
-spec register_views(atom(), fun((map()) -> {view, module(), term(), list()})) -> ok.
register_views(App, ResolverFun) when is_atom(App), is_function(ResolverFun, 1) ->
    ets:insert(?RESOLVER_TABLE, {App, ResolverFun}),
    ok.

-doc false.
-spec resolve_view(map()) -> {view, module(), term(), list()}.
resolve_view(Req) ->
    Resolvers = ets:tab2list(?RESOLVER_TABLE),
    try_resolvers(Resolvers, Req).

try_resolvers([], Req) ->
    logger:warning(#{msg => ~"No view resolver matched", path => maps:get(path, Req, undefined)}),
    error({no_view_resolver, Req});
try_resolvers([{App, Resolver} | Rest], Req) ->
    try
        case Resolver(Req) of
            {view, _, _, _} = Result ->
                Result;
            Other ->
                logger:warning(#{
                    msg => ~"View resolver returned unexpected format", app => App, result => Other
                }),
                try_resolvers(Rest, Req)
        end
    catch
        Class:Reason ->
            logger:warning(#{
                msg => ~"View resolver failed", app => App, class => Class, reason => Reason
            }),
            try_resolvers(Rest, Req)
    end.
