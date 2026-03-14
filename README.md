# arizona_nova

Arizona LiveView integration for the Nova web framework.

Bridges [Arizona](https://github.com/novaframework/arizona_core) live views into
[Nova](https://github.com/novaframework/nova) via a WebSocket controller that
plugs into Nova's routing and plugin pipeline. Handles the full bidirectional
protocol: events from the browser, diffs/dispatches/redirects/reloads back.

## Installation

Add `arizona_nova` to your deps in `rebar.config`:

```erlang
{deps, [
    {arizona_nova, "~> 0.1"}
]}.
```

## Setup

### Route configuration

Register the WebSocket controller in your Nova routes. The `view_resolver`
function receives the Cowboy request and returns the view module to mount:

```erlang
#{prefix => "/live",
  type => ws,
  controller => arizona_nova_websocket,
  controller_data => #{
      view_resolver => fun my_app_router:resolve_view/1
  }}
```

The view resolver must return `{view, ViewModule, MountArg, Middlewares}`.

### Application environment

| Key              | Default       | Description                                      |
|------------------|---------------|--------------------------------------------------|
| `pubsub_scope`   | `nova_scope`  | PubSub pg scope (share with Nova's pg scope)     |
| `live_reload`    | `false`       | Subscribe to `arizona:reload` topic for dev reload |

Set in `sys.config` or application env:

```erlang
{arizona_nova, [
    {pubsub_scope, nova_scope},
    {live_reload, true}
]}.
```

## Documentation

Full documentation is available on [HexDocs](https://hexdocs.pm/arizona_nova).

## License

[MIT](LICENSE)
