-module(arizona_nova_websocket).
-moduledoc ~"""
Nova WebSocket controller for Arizona LiveView connections.

Implements the Nova WS controller interface so that Arizona LiveView
connections go through Nova's plugin pipeline. Uses multi-frame replies
to send initial renders, diffs, and action responses.

## Controller Data

The `controller_data` map carries:
- `view_resolver` — function to resolve view modules from request paths
- `live_pid` — the `arizona_live` GenServer process (set after init)
- `live_shutdown_timeout` — timeout for stopping the live process

## Live Reload

Controlled by the `arizona_nova` application env `live_reload` (default: false).
When enabled, subscribes to the `arizona:reload` PubSub topic.
""".

%% --------------------------------------------------------------------
%% Nova WS controller exports
%% --------------------------------------------------------------------

-export([init/1]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).

%% --------------------------------------------------------------------
%% Nova WS controller callbacks
%% --------------------------------------------------------------------

-spec init(ControllerData) -> {ok, ControllerData} when
    ControllerData :: map().
init(ControllerData) ->
    Req = maps:get(req, ControllerData),
    ViewResolver = maps:get(view_resolver, ControllerData),
    PathParams = cowboy_req:parse_qs(Req),
    {~"path", LivePath} = proplists:lookup(~"path", PathParams),
    {~"qs", Qs} = proplists:lookup(~"qs", PathParams),
    LiveRequest = Req#{path => LivePath, qs => Qs},
    {view, ViewModule, MountArg, _Middlewares} = ViewResolver(LiveRequest),
    ArizonaReq = arizona_cowboy_request:new(LiveRequest),
    {ok, ControllerData#{
        view_module => ViewModule,
        mount_arg => MountArg,
        arizona_req => ArizonaReq,
        live_shutdown_timeout => 5_000
    }}.

-spec websocket_init(ControllerData) -> {reply, list(), ControllerData} when
    ControllerData :: map().
websocket_init(ControllerData) ->
    #{view_module := ViewModule, mount_arg := MountArg, arizona_req := ArizonaReq} = ControllerData,
    {ok, LivePid} = arizona_live:start_link(ViewModule, MountArg, ArizonaReq, self()),
    ok = maybe_join_live_reload(),
    {HierarchicalStructure, Diff} = arizona_live:initial_render(LivePid),
    View = arizona_live:get_view(LivePid),
    ViewState = arizona_view:get_state(View),
    ViewId = arizona_stateful:get_binding(id, ViewState),
    InitialPayload = json_encode(#{
        type => ~"initial_render",
        stateful_id => ViewId,
        structure => HierarchicalStructure
    }),
    CD = ControllerData#{live_pid => LivePid},
    build_diff_reply(ViewId, Diff, #{}, [{text, InitialPayload}], CD).

-spec websocket_handle({text, binary()}, ControllerData) -> Result when
    ControllerData :: map(),
    Result :: {reply, list(), ControllerData} | {ok, ControllerData}.
websocket_handle({text, JSONBinary}, ControllerData) ->
    try
        Message = json:decode(JSONBinary),
        MessageType = maps:get(~"type", Message, undefined),
        handle_message_type(MessageType, Message, ControllerData)
    catch
        Error:Reason:Stacktrace ->
            handle_websocket_error(Error, Reason, Stacktrace, ControllerData)
    end.

-spec websocket_info(term(), ControllerData) -> Result when
    ControllerData :: map(),
    Result :: {reply, list(), ControllerData} | {ok, ControllerData}.
websocket_info(
    {actions_response, StatefulId, Diff, HierarchicalStructure, Actions}, ControllerData
) ->
    ActionCmds = [action_to_command(Action) || Action <- Actions],
    build_diff_reply(StatefulId, Diff, HierarchicalStructure, ActionCmds, ControllerData);
websocket_info({pubsub_message, ~"arizona:reload", FileType}, ControllerData) ->
    ReloadPayload = json_encode(#{type => ~"reload", file_type => FileType}),
    {reply, {text, ReloadPayload}, ControllerData}.

-spec terminate(Reason, Req, ControllerData) -> ok when
    Reason :: term(),
    Req :: cowboy_req:req(),
    ControllerData :: map().
terminate(Reason, _Req, ControllerData) ->
    case maps:get(live_pid, ControllerData, undefined) of
        undefined ->
            ok;
        LivePid ->
            Timeout = maps:get(live_shutdown_timeout, ControllerData, 5_000),
            gen_server:stop(LivePid, {shutdown, Reason}, Timeout)
    end.

%% --------------------------------------------------------------------
%% Internal functions
%% --------------------------------------------------------------------

maybe_join_live_reload() ->
    case application:get_env(arizona_nova, live_reload, false) of
        true ->
            ok = arizona_pubsub:join(~"arizona:reload", self()),
            logger:debug("Subscribed to arizona:reload topic");
        false ->
            ok
    end.

handle_message_type(~"event", Message, ControllerData) ->
    handle_event_message(Message, ControllerData);
handle_message_type(~"ping", _Message, ControllerData) ->
    PongPayload = json_encode(#{type => ~"pong"}),
    {reply, {text, PongPayload}, ControllerData};
handle_message_type(_UnknownType, _Message, ControllerData) ->
    ErrorPayload = json_encode(#{type => ~"error", message => ~"Unknown message type"}),
    {reply, {text, ErrorPayload}, ControllerData}.

handle_event_message(Message, ControllerData) ->
    #{live_pid := LivePid} = ControllerData,
    StatefulIdOrUndefined = maps:get(~"stateful_id", Message, undefined),
    Event = maps:get(~"event", Message),
    Params = maps:get(~"params", Message, #{}),
    RefId = maps:get(~"ref_id", Message, undefined),
    Payload =
        case RefId of
            undefined -> Params;
            _ -> {RefId, Params}
        end,
    ok = arizona_live:handle_event(LivePid, StatefulIdOrUndefined, Event, Payload),
    {ok, ControllerData}.

action_to_command({dispatch, Event, Data}) ->
    Payload = json_encode(#{type => ~"dispatch", event => Event, data => Data}),
    {text, Payload};
action_to_command({reply, Ref, Data}) ->
    Payload = json_encode(#{type => ~"reply", ref_id => Ref, data => Data}),
    {text, Payload};
action_to_command({redirect, Url, Options}) ->
    Payload = json_encode(#{type => ~"redirect", url => Url, options => Options}),
    {text, Payload};
action_to_command(reload) ->
    Payload = json_encode(#{type => ~"reload"}),
    {text, Payload}.

build_diff_reply(StatefulId, Diff, HierarchicalStructure, Cmds, ControllerData) ->
    case Diff of
        [] ->
            case Cmds of
                [] -> {ok, ControllerData};
                _ -> {reply, Cmds, ControllerData}
            end;
        _ ->
            DiffPayload = json_encode(#{
                type => ~"diff",
                stateful_id => StatefulId,
                changes => Diff,
                structure => HierarchicalStructure
            }),
            {reply, Cmds ++ [{text, DiffPayload}], ControllerData}
    end.

handle_websocket_error(Error, Reason, Stacktrace, ControllerData) ->
    logger:error("WebSocket message handling error: ~p:~p~nStacktrace: ~p", [
        Error, Reason, Stacktrace
    ]),
    ErrorPayload = json_encode(#{type => ~"error", message => ~"Internal server error"}),
    {reply, {text, ErrorPayload}, ControllerData}.

json_encode(Term) ->
    json:encode(Term, fun json_encoder/2).

json_encoder(Tuple, Encoder) when is_tuple(Tuple) ->
    json:encode_list(tuple_to_list(Tuple), Encoder);
json_encoder(Other, Encoder) ->
    json:encode_value(Other, Encoder).
