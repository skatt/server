-module(lucky_sup).
-behaviour(supervisor).
-include_lib("nsm_db/include/config.hrl").
-export([start_link/0]).
-export([init/1]).
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    RestartStrategy = one_for_one,
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 1,
    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},
    Restart = permanent,
    Shutdown = 2000,

    OkeyLucky =
        {okey_lucky, %% Id
         {lucky, start_link, [okey, [{game_type, game_okey},
                                               {mode, normal}]]},
         permanent, %% Restart
         2000,      %% Shutdown timeout
         worker,    %% Process type
         [lucky]
        },
    TavlaLucky =
        {tavla_lucky, %% Id
         {lucky, start_link, [tavla, [{game_type, game_tavla},
                                                {mode, exclusive}]]},
         permanent, %% Restart
         2000,      %% Shutdown timeout
         worker,    %% Process type
         [lucky]
        },

    {ok, { SupFlags, [OkeyLucky, TavlaLucky]} }.

