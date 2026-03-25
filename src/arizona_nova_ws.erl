-module(arizona_nova_ws).
-moduledoc """
Nova-compatible WebSocket handler for Arizona LiveView connections.

Wraps `arizona_nova_websocket` and flattens multi-frame replies
to match Nova's single-frame WebSocket interface. Uses registered
view resolvers from `arizona_nova:register_views/2`.
""".

-export([init/1, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-spec init(map()) -> {ok, map()}.
init(ControllerData) ->
    arizona_nova_websocket:init(ControllerData#{view_resolver => fun arizona_nova:resolve_view/1}).

-spec websocket_init(map()) -> {reply, term(), map()} | {ok, map()}.
websocket_init(ControllerData) ->
    try
        flatten_reply(arizona_nova_websocket:websocket_init(ControllerData))
    catch
        Class:Reason:Stack ->
            logger:error(#{
                msg => ~"Arizona WS init failed",
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            {ok, ControllerData}
    end.

-spec websocket_handle(term(), map()) -> {reply, term(), map()} | {ok, map()}.
websocket_handle({ping, _}, ControllerData) ->
    {ok, ControllerData};
websocket_handle({pong, _}, ControllerData) ->
    {ok, ControllerData};
websocket_handle(Frame, ControllerData) ->
    logger:info(#{
        msg => ~"WS handle frame",
        frame => Frame,
        has_live_pid => maps:is_key(live_pid, ControllerData)
    }),
    try
        Result = arizona_nova_websocket:websocket_handle(Frame, ControllerData),
        logger:info(#{msg => ~"WS handle result", result_type => element(1, Result)}),
        flatten_reply(Result)
    catch
        Class:Reason:Stack ->
            logger:error(#{
                msg => ~"WS handle crashed", class => Class, reason => Reason, stacktrace => Stack
            }),
            {ok, ControllerData}
    end.

-spec websocket_info(term(), map()) -> {reply, term(), map()} | {ok, map()}.
websocket_info({pending_frame, Frame}, ControllerData) ->
    {reply, Frame, ControllerData};
websocket_info({actions_response, _, _, _, _} = Msg, ControllerData) ->
    flatten_reply(arizona_nova_websocket:websocket_info(Msg, ControllerData));
websocket_info({pubsub_message, _, _} = Msg, ControllerData) ->
    flatten_reply(arizona_nova_websocket:websocket_info(Msg, ControllerData));
websocket_info(_Msg, ControllerData) ->
    {ok, ControllerData}.

-spec terminate(term(), cowboy_req:req(), map()) -> ok.
terminate(Reason, Req, ControllerData) ->
    arizona_nova_websocket:terminate(Reason, Req, ControllerData).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% Nova's handle_ws expects {reply, SingleFrame, CD}, not {reply, [Frame], CD}.
flatten_reply({ok, CD}) ->
    {ok, CD};
flatten_reply({reply, [Frame], CD}) ->
    {reply, Frame, CD};
flatten_reply({reply, [Frame | Rest], CD}) ->
    _ = [self() ! {pending_frame, F} || F <- Rest],
    {reply, Frame, CD}.
