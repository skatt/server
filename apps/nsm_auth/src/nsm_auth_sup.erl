%%%-------------------------------------------------------------------
%%% @author Paul Peregud <pawel@saturn.lan>
%%% @copyright (C) 2011, Paul Peregud
%%% @doc
%%%
%%% @end
%%% Created : 10 Jan 2011 by Paul Peregud <pawel@saturn.lan>
%%%-------------------------------------------------------------------
-module(nsm_auth_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, stop/0]).

-include_lib("nsg_srv/include/conf.hrl").

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

stop() ->
    exit(?SERVER, shutdown).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    RestartStrategy = one_for_one,
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 3600,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    Restart = permanent,
    Shutdown = 2000,

    IdGen = {auth_server, {auth_server, start_link, []},
             Restart, Shutdown, worker, [auth_server]},

    {ok, {SupFlags, [IdGen]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
