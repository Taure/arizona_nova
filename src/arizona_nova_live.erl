-module(arizona_nova_live).

-moduledoc """
Arizona LiveView integration helpers for Nova routes.

Provides `live/1,2` to create Nova-compatible route callbacks that render
Arizona views on the initial HTTP request. The websocket connection uses
the existing `arizona_nova_websocket` module with `#{protocol => ws}`.

## Example

```erlang
-module(my_app_router).
-behaviour(nova_router).
-export([routes/1]).

routes(_Env) ->
    [#{prefix => "",
       security => false,
       routes => [
           {"/", arizona_nova_live:live(my_home_view), #{methods => [get]}},
           {"/counter", arizona_nova_live:live(my_counter_view, #{initial => 0}), #{methods => [get]}},
           {"/live", arizona_nova_websocket, #{protocol => ws}},
           {"/assets/[...]", "static/assets"}
       ]}].
```
""".

-export([
    live/1,
    live/2,
    resolve_view/1
]).

-ignore_xref([
    {arizona_cowboy_request, new, 1},
    {arizona_view, call_mount_callback, 3},
    {arizona_renderer, render_layout, 1},
    {cowboy_router, execute, 2},
    resolve_view/1
]).

-dialyzer({nowarn_function, [do_render/3, resolve_view/1, build_dispatch/1]}).

-define(VIEWS_KEY, arizona_nova_views).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

-doc """
Create a Nova route callback that renders an Arizona LiveView.

Returns a fun suitable for Nova's route format. On HTTP request, it
mounts the view, renders the full layout, and returns HTML.

```erlang
{"/", arizona_nova_live:live(my_home_view), #{methods => [get]}}
```
""".
-spec live(module()) -> fun((cowboy_req:req()) -> term()).
live(ViewModule) ->
    live(ViewModule, #{}).

-doc """
Create a Nova route callback with a custom mount argument.

```erlang
{"/counter", arizona_nova_live:live(my_counter_view, #{initial => 0}), #{methods => [get]}}
```
""".
-spec live(module(), term()) -> fun((cowboy_req:req()) -> term()).
live(ViewModule, MountArg) ->
    register_view(ViewModule, MountArg),
    fun(Req) -> do_render(ViewModule, MountArg, Req) end.

-doc """
Resolve a view module from the Arizona dispatch table.
Used by `arizona_nova_websocket` to determine which view to mount
from the WebSocket connection's path query parameter.
""".
-spec resolve_view(cowboy_req:req()) -> {view, module(), term(), list()}.
resolve_view(Req) ->
    {ok, _Req, Env} = cowboy_router:execute(
        Req,
        #{dispatch => {persistent_term, arizona_dispatch}}
    ),
    maps:get(handler_opts, Env).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

do_render(ViewModule, MountArg, Req) ->
    ArizonaReq = arizona_cowboy_request:new(Req),
    View = arizona_view:call_mount_callback(ViewModule, MountArg, ArizonaReq),
    {Html, _RenderView} = arizona_renderer:render_layout(View),
    {status, 200, #{<<"content-type">> => <<"text/html; charset=utf-8">>}, Html}.

register_view(ViewModule, MountArg) ->
    Views = persistent_term:get(?VIEWS_KEY, #{}),
    Updated = Views#{ViewModule => MountArg},
    persistent_term:put(?VIEWS_KEY, Updated),
    build_dispatch(Updated).

build_dispatch(Views) ->
    CowboyRoutes = [
        {<<"/">>, arizona_view_handler, {view, Mod, MountArg, []}}
        || {Mod, MountArg} <- maps:to_list(Views)
    ],
    ArizonaDispatch = cowboy_router:compile([{'_', CowboyRoutes}]),
    persistent_term:put(arizona_dispatch, ArizonaDispatch),
    ok.
