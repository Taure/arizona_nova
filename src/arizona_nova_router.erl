-module(arizona_nova_router).
-moduledoc """
Nova router for Arizona. Registers the shared WebSocket endpoint
and serves arizona_core static assets (JS, CSS).

Add `arizona_nova` to your app's `nova_apps`:

```erlang
{my_app, [{nova_apps, [arizona_nova]}]}
```

Configure the prefix (default `/arizona`):

```erlang
{arizona_nova, [{prefix, "/arizona"}]}
```
""".

-behaviour(nova_router).

-export([routes/1]).

-spec routes(term()) -> [map()].
routes(_Env) ->
    Prefix = arizona_nova:prefix(),
    [
        #{
            prefix => Prefix,
            security => false,
            routes => [
                {~"/live", arizona_nova_ws, #{protocol => ws}},
                {~"/assets/[...]", {arizona_core, "static/assets"}}
            ]
        }
    ].
