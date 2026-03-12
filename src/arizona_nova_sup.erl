-module(arizona_nova_sup).
-moduledoc false.
-behaviour(supervisor).

%% --------------------------------------------------------------------
%% API function exports
%% --------------------------------------------------------------------

-export([start_link/1]).

%% --------------------------------------------------------------------
%% Behaviour (supervisor) exports
%% --------------------------------------------------------------------

-export([init/1]).

%% --------------------------------------------------------------------
%% API function definitions
%% --------------------------------------------------------------------

-spec start_link(Config) -> supervisor:startlink_ret() when
    Config :: #{pubsub_scope => atom()}.
start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

%% --------------------------------------------------------------------
%% Behaviour (supervisor) callbacks
%% --------------------------------------------------------------------

-spec init(Config) -> {ok, {SupFlags, [ChildSpec]}} when
    Config :: #{pubsub_scope => atom()},
    SupFlags :: supervisor:sup_flags(),
    ChildSpec :: supervisor:child_spec().
init(Config) ->
    Scope = maps:get(pubsub_scope, Config, nova_scope),
    ok = arizona_pubsub:set_scope(Scope),
    SupFlags = #{
        strategy => one_for_all,
        intensity => 0,
        period => 1
    },
    ChildSpecs = [
        #{
            id => arizona_live,
            start => {pg, start_link, [arizona_live]}
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
