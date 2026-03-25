-module(arizona_nova_app).
-moduledoc false.
-behaviour(application).

%% --------------------------------------------------------------------
%% Behaviour (application) exports
%% --------------------------------------------------------------------

-export([start/2]).
-export([stop/1]).

%% --------------------------------------------------------------------
%% Behaviour (application) callbacks
%% --------------------------------------------------------------------

-spec start(StartType, StartArgs) -> {ok, Pid} | {error, term()} when
    StartType :: application:start_type(),
    StartArgs :: term(),
    Pid :: pid().
start(_StartType, _StartArgs) ->
    init_resolver_table(),
    PubsubScope = application:get_env(arizona_nova, pubsub_scope, nova_scope),
    arizona_nova_sup:start_link(#{pubsub_scope => PubsubScope}).

init_resolver_table() ->
    case ets:whereis(arizona_nova_resolvers) of
        undefined ->
            ets:new(arizona_nova_resolvers, [
                named_table, public, set, {read_concurrency, true}
            ]);
        _ ->
            ok
    end.

-spec stop(State) -> ok when
    State :: term().
stop(_State) ->
    ok.
