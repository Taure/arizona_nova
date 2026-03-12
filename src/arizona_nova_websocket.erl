-module(arizona_nova_websocket).
-moduledoc ~"""
Cowboy WebSocket handler for Arizona LiveView within Nova applications.

Adapted from `arizona_websocket` for use with the Nova web framework.
Uses Nova's routing and PubSub infrastructure instead of Arizona's
standalone server and configuration.

## View Resolution

The `view_resolver` option in `WebSocketOpts` determines how the WebSocket
maps incoming path parameters to view modules. Nova provides this via
`nova_arizona:resolve_view/1`.

## Live Reload

Controlled by the `arizona_nova` application env `live_reload` (default: false).
When enabled, subscribes to the `arizona:reload` PubSub topic.
""".
-behaviour(cowboy_websocket).

%% --------------------------------------------------------------------
%% API function exports
%% --------------------------------------------------------------------

-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).

%% --------------------------------------------------------------------
%% Types exports
%% --------------------------------------------------------------------

-export_type([state/0]).
-export_type([call_result/0]).
-export_type([terminate_reason/0]).
-export_type([websocket_close_code/0]).
-export_type([options/0]).

%% --------------------------------------------------------------------
%% Types definitions
%% --------------------------------------------------------------------

-record(state, {
    live_pid :: pid(),
    live_shutdown_timeout :: timeout()
}).

-opaque state() :: #state{}.

-nominal call_result() :: {Commands :: cowboy_websocket:commands(), State :: state()}.

-nominal terminate_reason() ::
    normal
    | shutdown
    | {shutdown, term()}
    | {remote, websocket_close_code(), Reason :: binary()}
    | term().

-nominal websocket_close_code() ::
    % Normal Closure
    1000
    % Going Away
    | 1001
    % Protocol Error
    | 1002
    % Unsupported Data
    | 1003
    % No Status Rcvd
    | 1005
    % Abnormal Closure
    | 1006
    % Invalid frame payload data
    | 1007
    % Policy Violation
    | 1008
    % Message Too Big
    | 1009
    % Mandatory Extension
    | 1010
    % Internal Server Error
    | 1011
    % TLS handshake
    | 1015
    % Other codes
    | pos_integer().

-nominal options() :: #{
    idle_timeout => timeout(),
    view_resolver := fun((cowboy_req:req()) -> term())
}.

%% --------------------------------------------------------------------
%% API function definitions
%% --------------------------------------------------------------------

-spec init(Req, WebSocketOpts) -> Result when
    Req :: cowboy_req:req(),
    Result ::
        {cowboy_websocket, Req1,
            {ViewModule, MountArg, ArizonaRequest, LiveShutdownTimeout, WebSocketOpts}},
    ViewModule :: module(),
    MountArg :: arizona_view:mount_arg(),
    ArizonaRequest :: arizona_request:request(),
    LiveShutdownTimeout :: timeout(),
    WebSocketOpts :: options(),
    Req1 :: cowboy_req:req().
init(CowboyRequest, WebSocketOpts) ->
    PathParams = cowboy_req:parse_qs(CowboyRequest),
    {~"path", LivePath} = proplists:lookup(~"path", PathParams),
    {~"qs", Qs} = proplists:lookup(~"qs", PathParams),
    LiveRequest = CowboyRequest#{path => LivePath, qs => Qs},
    ViewResolver = maps:get(view_resolver, WebSocketOpts),
    {view, ViewModule, MountArg, _Middlewares} = ViewResolver(LiveRequest),
    ArizonaRequest = arizona_cowboy_request:new(LiveRequest),
    LiveShutdownTimeout = 5_000,
    {cowboy_websocket, CowboyRequest,
        {ViewModule, MountArg, ArizonaRequest, LiveShutdownTimeout, WebSocketOpts}}.

-spec websocket_init(InitData) -> Result when
    InitData :: {ViewModule, MountArg, ArizonaRequest, LiveShutdownTimeout, WebSocketOpts},
    ViewModule :: module(),
    MountArg :: arizona_view:mount_arg(),
    ArizonaRequest :: arizona_request:request(),
    LiveShutdownTimeout :: timeout(),
    WebSocketOpts :: options(),
    Result :: call_result().
websocket_init({ViewModule, MountArg, ArizonaRequest, LiveShutdownTimeout, WebSocketOpts}) ->
    {ok, LivePid} = arizona_live:start_link(ViewModule, MountArg, ArizonaRequest, self()),
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
    Cmds = [{set_options, WebSocketOpts}, {text, InitialPayload}],
    State = #state{
        live_pid = LivePid,
        live_shutdown_timeout = LiveShutdownTimeout
    },
    handle_diff_response(ViewId, Diff, #{}, Cmds, State).

-spec websocket_handle(Message, State) -> Result when
    Message :: {text, binary()},
    State :: state(),
    Result :: call_result().
websocket_handle({text, JSONBinary}, State) ->
    try
        Message = json:decode(JSONBinary),
        MessageType = maps:get(~"type", Message, undefined),
        handle_message_type(MessageType, Message, State)
    catch
        Error:Reason:Stacktrace ->
            handle_websocket_error(Error, Reason, Stacktrace, State)
    end.

-spec websocket_info(Info, State) -> Result when
    Info :: term(),
    State :: state(),
    Result :: call_result().
websocket_info({actions_response, StatefulId, Diff, HierarchicalStructure, Actions}, State) ->
    handle_actions_response(StatefulId, Diff, HierarchicalStructure, Actions, State);
websocket_info({pubsub_message, ~"arizona:reload", FileType}, State) ->
    Message = #{type => ~"reload", file_type => FileType},
    ReloadPayload = json_encode(Message),
    {[{text, ReloadPayload}], State}.

-spec terminate(Reason, Req, State) -> ok when
    Reason :: arizona_live:terminate_reason(),
    Req :: cowboy_req:req(),
    State :: state().
terminate(Reason, _Req, #state{} = State) ->
    gen_server:stop(State#state.live_pid, {shutdown, Reason}, State#state.live_shutdown_timeout);
terminate(_Reason, _Req, _State) ->
    ok.

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

-spec handle_message_type(MessageType, Message, State) -> Result when
    MessageType :: binary() | undefined,
    Message :: map(),
    State :: state(),
    Result :: call_result().
handle_message_type(~"event", Message, State) ->
    handle_event_message(Message, State);
handle_message_type(~"ping", _Message, State) ->
    handle_ping_message(State);
handle_message_type(_UnknownType, _Message, State) ->
    handle_unknown_message(State).

-spec handle_event_message(Message, State) -> Result when
    Message :: map(),
    State :: state(),
    Result :: call_result().
handle_event_message(Message, #state{} = State) ->
    LivePid = State#state.live_pid,
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
    {[], State}.

-spec handle_actions_response(StatefulId, Diff, HierarchicalStructure, Actions, State) ->
    Result
when
    StatefulId :: arizona_stateful:id(),
    Diff :: arizona_differ:diff(),
    HierarchicalStructure :: arizona_hierarchical_dict:hierarchical_structure(),
    Actions :: arizona_action:actions(),
    State :: state(),
    Result :: call_result().
handle_actions_response(StatefulId, Diff, HierarchicalStructure, Actions, #state{} = State) ->
    ActionCmds = [action_to_command(Action) || Action <- Actions],
    handle_diff_response(StatefulId, Diff, HierarchicalStructure, ActionCmds, State).

-spec action_to_command(Action) -> Command when
    Action :: arizona_action:action(),
    Command :: {text, JSON},
    JSON :: json:encode_value().
action_to_command({dispatch, Event, Data}) ->
    Payload = json_encode(#{
        type => ~"dispatch",
        event => Event,
        data => Data
    }),
    {text, Payload};
action_to_command({reply, Ref, Data}) ->
    Payload = json_encode(#{
        type => ~"reply",
        ref_id => Ref,
        data => Data
    }),
    {text, Payload};
action_to_command({redirect, Url, Options}) ->
    Payload = json_encode(#{
        type => ~"redirect",
        url => Url,
        options => Options
    }),
    {text, Payload};
action_to_command(reload) ->
    Payload = json_encode(#{
        type => ~"reload"
    }),
    {text, Payload}.

-spec handle_diff_response(StatefulId, Diff, HierarchicalStructure, Cmds, State) -> Result when
    StatefulId :: arizona_stateful:id(),
    Diff :: arizona_differ:diff(),
    HierarchicalStructure :: arizona_hierarchical_dict:hierarchical_structure(),
    Cmds :: cowboy_websocket:commands(),
    State :: state(),
    Result :: call_result().
handle_diff_response(StatefulId, Diff, HierarchicalStructure, Cmds, #state{} = State) ->
    case Diff of
        [] ->
            {Cmds, State};
        _ ->
            DiffPayload = json_encode(#{
                type => ~"diff",
                stateful_id => StatefulId,
                changes => Diff,
                structure => HierarchicalStructure
            }),
            {Cmds ++ [{text, DiffPayload}], State}
    end.

-spec handle_ping_message(State) -> Result when
    State :: state(),
    Result :: call_result().
handle_ping_message(State) ->
    PongPayload = json_encode(#{type => ~"pong"}),
    {[{text, PongPayload}], State}.

-spec handle_unknown_message(State) -> Result when
    State :: state(),
    Result :: call_result().
handle_unknown_message(State) ->
    ErrorPayload = json_encode(#{
        type => ~"error",
        message => ~"Unknown message type"
    }),
    {[{text, ErrorPayload}], State}.

-spec handle_websocket_error(Error, Reason, Stacktrace, State) -> Result when
    Error :: term(),
    Reason :: term(),
    Stacktrace :: list(),
    State :: state(),
    Result :: call_result().
handle_websocket_error(Error, Reason, Stacktrace, State) ->
    logger:error("WebSocket message handling error: ~p:~p~nStacktrace: ~p", [
        Error, Reason, Stacktrace
    ]),
    ErrorPayload = json_encode(#{
        type => ~"error",
        message => ~"Internal server error"
    }),
    {[{text, ErrorPayload}], State}.

-spec json_encode(Term) -> JSONData when
    Term :: term(),
    JSONData :: iodata().
json_encode(Term) ->
    json:encode(Term, fun json_encoder/2).

-spec json_encoder(Term, Encoder) -> JSONData when
    Term :: term(),
    Encoder :: json:encoder(),
    JSONData :: iodata().
json_encoder(Tuple, Encoder) when is_tuple(Tuple) ->
    json:encode_list(tuple_to_list(Tuple), Encoder);
json_encoder(Other, Encoder) ->
    json:encode_value(Other, Encoder).
