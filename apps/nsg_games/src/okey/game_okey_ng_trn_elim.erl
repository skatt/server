%%% -------------------------------------------------------------------
%%% Author  : Sergii Polkovnikov <serge.polkovnikov@gmail.com>
%%% Description : The "Eliminate tournament" logic
%%%
%%% Created : Nov 02, 2012
%%% -------------------------------------------------------------------

%%% Terms explanation:
%%% GameId   - uniq identifier of the tournament. Type: integer().
%%% PlayerId - registration number of a player in the tournament. Type: integer()
%%% UserId   - cross system identifier of a physical user. Type: binary() (or string()?).
%%% TableId  - uniq identifier of a table in the tournament. Used by the
%%%          tournament logic. Type: integer().
%%% TableGlobalId - uniq identifier of a table in the system. Can be used
%%%          to refer to a table directly - without pointing to a tournament.
%%%          Type: integer()

-module(game_okey_ng_trn_elim).

-behaviour(gen_fsm).
%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include_lib("nsx_config/include/log.hrl").
-include_lib("nsg_srv/include/basic_types.hrl").
-include_lib("nsm_db/include/table.hrl").

%% --------------------------------------------------------------------
%% External exports
-export([start/2, start_link/2, reg/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-export([table_message/3, client_message/2, client_request/2, client_request/3]).

-export([get_prize_fund/3]).  % just passing info, not a gen_server part

-record(state,
        {%% Static values
         game_id           :: pos_integer(),
         trn_id            :: term(),
         params            :: proplists:proplist(),
         bots_params       :: proplists:proplist(),
         turns_plan        :: list(integer()), %% Defines how many players will be passed to a next turn
         kakush_per_round  :: integer(),
         demo_mode         :: boolean(), %% If true then results of turns will be generated randomly
         %% Dinamic values
         players,          %% The register of tournament players
         tables,           %% The register of tournament tables
         seats,            %% Stores relation between players and tables seats
         tournament_table  :: list(), %% [{TurnNum, TurnRes}], TurnRes = [{PlayerId, Points, Status}]
         table_id_counter  :: pos_integer(),
         turn              :: pos_integer(),
         cr_tab_requests   :: dict(),  %% {TableId, PlayersIds}
         reg_requests      :: dict(),  %% {PlayerId, From}
         tab_requests      :: dict(),  %% {RequestId, RequestContext}
         timer             :: undefined | reference(),
         timer_magic       :: undefined | reference(),
         tables_wl         :: list(), %% Tables waiting list
         tables_results    :: list()  %% [{TableId, TableResult}]
        }).

-record(player,
        {
         id              :: pos_integer(),
         user_id,
         user_info       :: #'PlayerInfo'{},
         is_bot          :: boolean(),
         status          :: active | eliminated
        }).

-record(table,
        {
         id              :: pos_integer(),
         global_id       :: pos_integer(),
         pid             :: pid(),
         relay           :: {atom(), pid()}, %% {RelayMod, RelayPid}
         mon_ref         :: reference(),
         state           :: initializing | ready | in_process | finished,
         context         :: term(), %% Context term of a table. For failover proposes.
         timer           :: reference()
        }).

-record(seat,
        {
         table           :: pos_integer(),
         seat_num        :: integer(),
         player_id       :: undefined | pos_integer(),
         registered_by_table :: undefined | boolean(),
         connected       :: undefined | boolean()
        }).


-define(STATE_INIT, state_init).
-define(STATE_WAITING_FOR_TABLES, state_waiting_for_tables).
-define(STATE_WAITING_FOR_PLAYERS, state_waiting_for_players).
-define(STATE_TURN_PROCESSING, state_turn_processing).
-define(STATE_SHOW_TURN_RESULT, state_show_turn_result).
-define(STATE_FINISHED, state_finished).

-define(TAB_MOD, game_okey_ng_table_trn).

-define(TABLE_STATE_INITIALIZING, initializing).
-define(TABLE_STATE_READY, ready).
-define(TABLE_STATE_IN_PROGRESS, in_progress).
-define(TABLE_STATE_FINISHED, finished).

-define(WAITING_PLAYERS_TIMEOUT, 3000) . %% Time between all table was created and starting a turn
-define(REST_TIMEOUT, 5000).             %% Time between a round finish and start of a new one
-define(SHOW_TURN_RESULT_TIMEOUT, 15000).%% Time between a turn finish and start of a new one
-define(SHOW_TOURNAMENT_RESULT_TIMEOUT, 15000). %% Time between last tour result showing and the tournament finish

-define(SEATS_NUM, 4). %% TODO: Define this by a parameter. Number of seats per table

%% ====================================================================
%% External functions
%% ====================================================================

start(GameId, Params) ->
    gen_fsm:start(?MODULE, [GameId, Params, self()], []).

start_link(GameId, Params) ->
    gen_fsm:start_link(?MODULE, [GameId, Params, self()], []).

reg(Pid, User) ->
    client_request(Pid, {join, User}, 10000).

table_message(Pid, TableId, Message) ->
    gen_fsm:send_all_state_event(Pid, {table_message, TableId, Message}).

client_message(Pid, Message) ->
    gen_fsm:send_all_state_event(Pid, {client_message, Message}).

client_request(Pid, Message) ->
    client_request(Pid, Message, 5000).

client_request(Pid, Message, Timeout) ->
    gen_fsm:sync_send_all_state_event(Pid, {client_request, Message}, Timeout).


%% ====================================================================
%% Server functions
%% ====================================================================

init([GameId, Params, _Manager]) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Init started",[GameId]),
    Registrants = get_param(registrants, Params),
    KakushPerRound = get_param(kakush_per_round, Params),
    Tours = get_param(tours, Params),
    DemoMode = get_option(demo_mode, Params, false),
    TrnId = get_option(trn_id, Params, undefined),

    RegistrantsNum = length(Registrants),
    {ok, TurnsPlan} = get_plan(KakushPerRound, RegistrantsNum, Tours),
    TableParams = table_parameters(?MODULE, self()),
    BotsParams = bots_parameters(),

    Players = setup_players(Registrants),
    PlayersIds = get_players_ids(Players),
    TTable = ttable_init(PlayersIds),
    ?INFO("OKEY_NG_TRN_ELIM <~p> started.  Pid:~p",[GameId, self()]),

    gen_fsm:send_all_state_event(self(), go),
    {ok, ?STATE_INIT, #state{game_id = GameId,
                             trn_id = TrnId,
                             params = TableParams,
                             bots_params = BotsParams,
                             kakush_per_round = KakushPerRound,
                             turns_plan = TurnsPlan,
                             demo_mode = DemoMode,
                             players = Players,
                             tournament_table = TTable,
                             table_id_counter = 1
                            }}.

%%===================================================================
handle_event(go, ?STATE_INIT, #state{game_id = GameId, trn_id = TrnId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Received a directive to starting the tournament.", [GameId]),
    GProcVal = #game_table{game_type = game_okey,
                           game_process = self(),
                           game_module = ?MODULE,
                           id = GameId,
                           trn_id = TrnId,
                           age_limit = 100,
                           game_mode = undefined,
                           game_speed = undefined,
                           feel_lucky = false,
                           owner = undefined,
                           creator = undefined,
                           rounds = undefined,
                           pointing_rules   = [],
                           pointing_rules_ex = [],
                           users = [],
                           name = "Okey Elimination Tournament - " ++ erlang:integer_to_list(GameId) ++ " "
                          },
    gproc:reg({p,g,self()}, GProcVal),
    init_turn(1, StateData);

handle_event({client_message, Message}, StateName, #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Received the message from a client: ~p.", [GameId, Message]),
    handle_client_message(Message, StateName, StateData);

handle_event({table_message, TableId, Message}, StateName, #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Received the message from table <~p>: ~p.", [GameId, TableId, Message]),
    handle_table_message(TableId, Message, StateName, StateData);

handle_event(Message, StateName, #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Unhandled message(event) received in state <~p>: ~p.",
          [GameId, StateName, Message]),
    {next_state, StateName, StateData}.

handle_sync_event({client_request, Request}, From, StateName, #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Received the request from a client: ~p.", [GameId, Request]),
    handle_client_request(Request, From, StateName, StateData);

handle_sync_event(Request, From, StateName, #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Unhandled request(event) received in state <~p> from ~p: ~p.",
          [GameId, StateName, From, Request]),
    {reply, {error, unknown_request}, StateName, StateData}.

%%===================================================================

handle_info({'DOWN', MonRef, process, _Pid, _}, StateName,
            #state{game_id = GameId, tables = Tables} = StateData) ->
    case get_table_by_mon_ref(MonRef, Tables) of
        #table{id = TableId} ->
            ?INFO("OKEY_NG_TRN_ELIM <~p> Table <~p> is down. Stopping", [GameId, TableId]),
            %% TODO: More smart handling (failover) needed
            {stop, {one_of_tables_down, TableId}, StateData};
        not_found ->
            {next_state, StateName, StateData}
    end;


handle_info({rest_timeout, TableId}, StateName,
            #state{game_id = GameId, tables = Tables} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Time to start new round for table <~p>.", [GameId, TableId]),
    #table{pid = TablePid} = Table = fetch_table(TableId, Tables),
    NewTable = Table#table{state = in_process},
    NewTables = store_table(NewTable, Tables),
    send_to_table(TablePid, start_round),
    {next_state, StateName, StateData#state{tables = NewTables}};


handle_info({timeout, Magic}, ?STATE_WAITING_FOR_PLAYERS,
            #state{timer_magic = Magic, game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Time to start new turn.", [GameId]),
    start_turn(StateData);


handle_info({timeout, Magic}, ?STATE_SHOW_TURN_RESULT,
            #state{timer_magic = Magic, turn = Turn,
                   turns_plan = Plan, game_id = GameId} = StateData) ->
    if Turn == length(Plan) ->
           ?INFO("OKEY_NG_TRN_ELIM <~p> Time to finalize the tournament.", [GameId]),
           finalize_tournament(StateData);
       true ->
           NewTurn = Turn + 1,
           ?INFO("OKEY_NG_TRN_ELIM <~p> Time to initialize turn <~p>.", [GameId, NewTurn]),
           init_turn(NewTurn, StateData)
    end;


handle_info({timeout, Magic}, ?STATE_FINISHED,
            #state{timer_magic = Magic, tables = Tables, game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Time to stopping the tournament.", [GameId]),
    finalize_tables_with_rejoin(Tables),
    {stop, normal, StateData#state{tables = [], seats = []}};


handle_info(Message, StateName, #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Unhandled message(info) received in state <~p>: ~p.",
          [GameId, StateName, Message]),
    {next_state, StateName, StateData}.

%%===================================================================

terminate(_Reason, _StateName, #state{game_id=GameId}=_StatData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Shutting down at state: <~p>. Reason: ~p",
          [GameId, _StateName, _Reason]),
    ok.

%%===================================================================

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

%% --------------------------------------------------------------------
%%% Internal functions
%% --------------------------------------------------------------------


handle_client_message(Message, StateName, #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Unhandled client message received in "
          "state <~p>: ~p.", [GameId, StateName, Message]),
    {next_state, StateName, StateData}.

%%===================================================================

handle_table_message(TableId, {player_connected, PlayerId},
                     StateName,
                     #state{seats = Seats} = StateData) ->
    case find_seats_by_player_id(PlayerId, Seats) of
        [#seat{seat_num = SeatNum}] ->
            NewSeats = update_seat_connect_status(TableId, SeatNum, true, Seats),
            {next_state, StateName, StateData#state{seats = NewSeats}};
        [] -> %% Ignoring the message
            {next_state, StateName, StateData}
    end;


handle_table_message(TableId, {player_disconnected, PlayerId},
                     StateName, #state{seats = Seats} = StateData) ->
    case find_seats_by_player_id(PlayerId, Seats) of
        [#seat{seat_num = SeatNum}] ->
            NewSeats = update_seat_connect_status(TableId, SeatNum, false, Seats),
            {next_state, StateName, StateData#state{seats = NewSeats}};
        [] -> %% Ignoring the message
            {next_state, StateName, StateData}
    end;


handle_table_message(TableId, {table_created, Relay},
                     ?STATE_WAITING_FOR_TABLES,
                     #state{tables = Tables, seats = Seats,
                            cr_tab_requests = TCrRequests,
                            reg_requests = RegRequests} = StateData) ->
    TabInitPlayers = dict:fetch(TableId, TCrRequests),
    NewTCrRequests = dict:erase(TableId, TCrRequests),
    %% Update status of players
    TabSeats = find_seats_by_table_id(TableId, Seats),
    F = fun(#seat{player_id = PlayerId} = S, Acc) ->
                case lists:member(PlayerId, TabInitPlayers) of
                    true -> store_seat(S#seat{registered_by_table = true}, Acc);
                    false -> Acc
                end
        end,
    NewSeats = lists:foldl(F, Seats, TabSeats),

    %% Process delayed registration requests
    TablePid = get_table_pid(TableId, Tables),
    F2 = fun(PlayerId, Acc) ->
                 case dict:find(PlayerId, Acc) of
                     {ok, From} ->
                         gen_fsm:reply(From, {ok, {PlayerId, Relay, {?TAB_MOD, TablePid}}}),
                         dict:erase(PlayerId, Acc);
                     error -> Acc
                 end
         end,
    NewRegRequests = lists:foldl(F2, RegRequests, TabInitPlayers),
    NewTables = update_created_table(TableId, Relay, Tables),
    case dict:size(NewTCrRequests) of
        0 -> 
            {TRef, Magic} = start_timer(?WAITING_PLAYERS_TIMEOUT),
            {next_state, ?STATE_WAITING_FOR_PLAYERS,
              StateData#state{tables = NewTables, seats = NewSeats, cr_tab_requests = NewTCrRequests,
                              reg_requests = NewRegRequests, timer = TRef, timer_magic = Magic}};
        _ -> {next_state, ?STATE_WAITING_FOR_TABLES,
              StateData#state{tables = NewTables, seats = NewSeats,
                              cr_tab_requests = NewTCrRequests, reg_requests = NewRegRequests}}
    end;


handle_table_message(TableId, {round_finished, NewScoringState, _RoundScore, _TotalScore},
                     ?STATE_TURN_PROCESSING,
                     #state{tables = Tables} = StateData) ->
    #table{pid = TablePid} = Table = fetch_table(TableId, Tables),
    TRef = erlang:send_after(?REST_TIMEOUT, self(), {rest_timeout, TableId}),
    NewTable = Table#table{context = NewScoringState, state = ?TABLE_STATE_FINISHED, timer = TRef},
    NewTables = store_table(NewTable, Tables),
    send_to_table(TablePid, show_round_result),
    {next_state, ?STATE_TURN_PROCESSING, StateData#state{tables = NewTables}};


handle_table_message(TableId, {game_finished, TableContext, _RoundScore, TotalScore},
                     ?STATE_TURN_PROCESSING = StateName,
                     #state{tables = Tables, tables_wl = WL, demo_mode = DemoMode,
                            tables_results = TablesResults} = StateData) ->
    TableScore = if DemoMode -> [{PlayerId, crypto:rand_uniform(1, 30)} || {PlayerId, _} <- TotalScore];
                    true -> TotalScore
                 end,
    NewTablesResults = [{TableId, TableScore} | TablesResults],
    #table{pid = TablePid} = Table = fetch_table(TableId, Tables),
    NewTable = Table#table{context = TableContext, state = ?TABLE_STATE_FINISHED},
    NewTables = store_table(NewTable, Tables),
    send_to_table(TablePid, show_round_result),
    %% TODO: Send to table "Waiting for the end of the turn"
    NewWL = lists:delete(TableId, WL),
    if NewWL == [] ->
           process_turn_result(StateData#state{tables = NewTables,
                                               tables_results = NewTablesResults,
                                               tables_wl = []});
       true ->
           {next_state, StateName, StateData#state{tables = NewTables,
                                                   tables_results = NewTablesResults,
                                                   tables_wl = NewWL}}
    end;


handle_table_message(TableId, {response, RequestId, Response},
                     StateName,
                     #state{game_id = GameId, tab_requests = TabRequests} = StateData) ->
    NewTabRequests = dict:erase(RequestId, TabRequests),
    case dict:find(RequestId, TabRequests) of
        {ok, ReqContext} ->
            ?INFO("OKEY_NG_TRN_ELIM <~p> The a response received from table <~p>. "
                  "RequestId: ~p. Request context: ~p. Response: ~p",
                  [GameId, TableId, RequestId, ReqContext, Response]),
            handle_table_response(TableId, ReqContext, Response, StateName,
                                  StateData#state{tab_requests = NewTabRequests});
        error ->
            ?ERROR("OKEY_NG_TRN_ELIM <~p> Table <~p> sent a response for unknown request. "
                   "RequestId: ~p. Response", []),
            {next_state, StateName, StateData#state{tab_requests = NewTabRequests}}
    end;


handle_table_message(TableId, Message, StateName, #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Unhandled table message received from table <~p> in "
          "state <~p>: ~p.", [GameId, TableId, StateName, Message]),
    {next_state, StateName, StateData}.

%%===================================================================
%% handle_table_response(_TableId, {register_player, PlayerId, TableId, SeatNum}, ok = _Response,
%%                       StateName,
%%                       #state{reg_requests = RegRequests, seats = Seats,
%%                              tables = Tables} = StateData) ->
%%     Seat = fetch_seat(TableId, SeatNum, Seats),
%%     NewSeats = store_seat(Seat#seat{registered_by_table = true}, Seats),
%%     %% Send response to a client for a delayed request
%%     NewRegRequests =
%%         case dict:find(PlayerId, RegRequests) of
%%             {ok, From} ->
%%                 #table{relay = Relay, pid = TablePid} = fetch_table(TableId, Tables),
%%                 gen_fsm:reply(From, {ok, {PlayerId, Relay, {?TAB_MOD, TablePid}}}),
%%                 dict:erase(PlayerId, RegRequests);
%%             error -> RegRequests
%%         end,
%%     {next_state, StateName, StateData#state{seats = NewSeats,
%%                                             reg_requests = NewRegRequests}};

%% handle_table_response(_TableId, {replace_player, PlayerId, TableId, SeatNum}, ok = _Response,
%%                       StateName,
%%                       #state{reg_requests = RegRequests, seats = Seats,
%%                              tables = Tables} = StateData) ->
%%     Seat = fetch_seat(TableId, SeatNum, Seats),
%%     NewSeats = store_seat(Seat#seat{registered_by_table = true}, Seats),
%%     %% Send response to a client for a delayed request
%%     NewRegRequests =
%%         case dict:find(PlayerId, RegRequests) of
%%             {ok, From} ->
%%                 #table{relay = Relay, pid = TablePid} = fetch_table(TableId, Tables),
%%                 gen_fsm:reply(From, {ok, {PlayerId, Relay, {?TAB_MOD, TablePid}}}),
%%                 dict:erase(PlayerId, RegRequests);
%%             error -> RegRequests
%%         end,
%%     {next_state, StateName, StateData#state{seats = NewSeats,
%%                                             reg_requests = NewRegRequests}}.

handle_table_response(TableId, RequestContext, Response, StateName,
                      #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Unhandled 'table response' received from table <~p> "
          "in state <~p>. Request context: ~p. Response: ~p.",
          [GameId, TableId, StateName, RequestContext, Response]),
    {next_state, StateName, StateData}.

%%===================================================================

handle_client_request({join, User}, From, StateName,
                      #state{game_id = GameId, reg_requests = RegRequests,
                             seats = Seats, players=Players, tables = Tables} = StateData) ->
    #'PlayerInfo'{id = UserId, robot = _IsBot} = User,
    ?INFO("OKEY_NG_TRN_ELIM <~p> The 'Join' request received from user: ~p.", [GameId, UserId]),
    if StateName == ?STATE_FINISHED ->
           ?INFO("OKEY_NG_TRN_ELIM <~p> The tournament is finished. "
                 "Reject to join user ~p.", [GameId, UserId]),
           {reply, {error, finished}, StateName, StateData};
       true ->
           case get_player_by_user_id(UserId, Players) of
               {ok, #player{status = active, id = PlayerId}} -> %% The user is an active member of the tournament.
                   ?INFO("OKEY_NG_TRN_ELIM <~p> User ~p is an active member of the tournament. "
                         "Allow to join.", [GameId, UserId]),
                   [#seat{table = TableId, registered_by_table = RegByTable}] = find_seats_by_player_id(PlayerId, Seats),
                   case RegByTable of
                       false -> %% Store this request to the waiting pool
                           ?INFO("OKEY_NG_TRN_ELIM <~p> User ~p not yet regirested by the table. "
                                 "Add the request to the waiting pool.", [GameId, UserId]),
                           NewRegRequests = dict:store(PlayerId, From, RegRequests),
                           {next_state, StateName, StateData#state{reg_requests = NewRegRequests}};
                       _ ->
                           ?INFO("OKEY_NG_TRN_ELIM <~p> Return join response for player ~p immediately.",
                                 [GameId, UserId]),
                           #table{relay = Relay, pid = TPid} = fetch_table(TableId, Tables),
                           {reply, {ok, {PlayerId, Relay, {?TAB_MOD, TPid}}}, StateName, StateData}
                   end;
               {ok, #player{status = eliminated}} ->
                   ?INFO("OKEY_NG_TRN_ELIM <~p> User ~p is member of the tournament but he was eliminated. "
                         "Reject to join.", [GameId, UserId]),
                   {reply, {error, out}, StateName, StateData};
               error -> %% Not a member
                   ?INFO("OKEY_NG_TRN_ELIM <~p> User ~p is not a member of the tournament. "
                         "Reject to join.", [GameId, UserId]),
                   {reply, {error, not_allowed}, StateName, StateData}
           end
    end;

handle_client_request(Request, From, StateName, #state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Unhandled client request received from ~p in "
          "state <~p>: ~p.", [GameId, From, StateName, Request]),
   {reply, {error, unexpected_request}, StateName, StateData}.

%%===================================================================
init_turn(Turn, #state{game_id = GameId, turns_plan = Plan, tournament_table = TTable,
                       params = TableParams, players = Players,
                       table_id_counter = TableIdCounter, tables = OldTables} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Initializing turn <~p>...", [GameId, Turn]),
    PlayersList = prepare_players_for_new_turn(Turn, TTable, Plan, Players),
    {NewTables, Seats, NewTableIdCounter, CrRequests} =
        setup_tables(PlayersList, TableIdCounter, GameId, TableParams),
    if Turn > 1 -> finalize_tables_with_rejoin(OldTables);
       true -> do_nothing
    end,
    ?INFO("OKEY_NG_TRN_ELIM <~p> Initializing of turn <~p> is finished. "
          "Waiting creating confirmations from the turns' tables...",
          [GameId, Turn]),
    {next_state, ?STATE_WAITING_FOR_TABLES, StateData#state{tables = NewTables,
                                                            seats = Seats,
                                                            table_id_counter = NewTableIdCounter,
                                                            turn = Turn,
                                                            cr_tab_requests = CrRequests,
                                                            reg_requests = dict:new(),
                                                            tab_requests = dict:new(),
                                                            tables_results = []
                                                           }}.


start_turn(#state{game_id = GameId, turn = Turn, tables = Tables} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Starting turn <~p>...", [GameId, Turn]),
    TablesList = tables_to_list(Tables),
    [send_to_table(Pid, start_round) || #table{pid = Pid} <- TablesList],
    F = fun(Table, Acc) ->
                store_table(Table#table{state = ?TABLE_STATE_IN_PROGRESS}, Acc)
        end,
    NewTables = lists:foldl(F, Tables, TablesList),
    WL = [T#table.id || T <- TablesList],
    ?INFO("OKEY_NG_TRN_ELIM <~p> Turn <~p> is started. Processing...",
          [GameId, Turn]),
    {next_state, ?STATE_TURN_PROCESSING, StateData#state{tables = NewTables,
                                                         tables_wl = WL}}.


process_turn_result(#state{game_id = GameId, tournament_table = TTable,
                           turns_plan = Plan, turn = Turn, tables_results = TablesResults,
                           players = Players, tables = Tables} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Turn <~p> is completed. Starting results processing...", [GameId, Turn]),
    TurnType = lists:nth(Turn, Plan),
    TurnResult = case TurnType of
                     ne -> turn_result_all(TablesResults);
                     {te, Limit} -> turn_result_per_table(Limit, TablesResults);
                     {ce, Limit} -> turn_result_overall(Limit, TablesResults)
                 end,
    NewTTable = ttable_store_turn_result(Turn, TurnResult, TTable),
    F = fun({PlayerId, _, eliminated}, Acc) -> set_player_status(PlayerId, eliminated, Acc);
           (_, Acc) -> Acc
        end,
    NewPlayers = lists:foldl(F, Players, TurnResult),
    TurnResultWithPos = set_turn_results_position(TurnResult), %% [{PlayerId, Position, Points, Status}]
    TurnResultWithUserId = [{get_user_id(PlayerId, Players), Position, Points, Status}
                            || {PlayerId, Position, Points, Status} <- TurnResultWithPos],
    TablesResultsWithPos = set_tables_results_position(TablesResults, TurnResult),
    [send_to_table(TablePid, {turn_result, Turn, TurnResultWithUserId})
       || #table{pid = TablePid} <- tables_to_list(Tables)],
    [send_to_table(get_table_pid(TableId, Tables),
                   {show_series_result, subs_status(TableResultWithPos, Turn, Plan)})
       || {TableId, TableResultWithPos} <- TablesResultsWithPos],
    {TRef, Magic} = start_timer(?SHOW_TURN_RESULT_TIMEOUT),
    ?INFO("OKEY_NG_TRN_ELIM <~p> Results processing of turn <~p> is finished. "
          "Waiting some time (~p secs) before continue...",
          [GameId, Turn, ?SHOW_TURN_RESULT_TIMEOUT div 1000]),
    {next_state, ?STATE_SHOW_TURN_RESULT, StateData#state{timer = TRef, timer_magic = Magic,
                                                          tournament_table = NewTTable,
                                                          players = NewPlayers}}.

finalize_tournament(#state{game_id = GameId} = StateData) ->
    ?INFO("OKEY_NG_TRN_ELIM <~p> Finalizing the tournament...", [GameId]),
    %% TODO: Real finalization needed
    {TRef, Magic} = start_timer(?SHOW_TOURNAMENT_RESULT_TIMEOUT),
    ?INFO("OKEY_NG_TRN_ELIM <~p> The tournament is finalized. "
          "Waiting some time (~p secs) before continue...",
          [GameId, ?SHOW_TOURNAMENT_RESULT_TIMEOUT div 1000]),
    {next_state, ?STATE_FINISHED, StateData#state{timer = TRef, timer_magic = Magic}}.


turn_result_all(TablesResults) ->
    F = fun({_, TableRes}, Acc) ->
            [{Pl, Points, active} || {Pl, Points} <- TableRes] ++ Acc
        end,
    lists:foldl(F, [], TablesResults).


turn_result_per_table(NextTurnLimit, TablesResults) ->
    F = fun({_, TableResult}, Acc) ->
                SortedRes = sort_results(TableResult),
                {Winners, _} = lists:unzip(lists:sublist(SortedRes, NextTurnLimit)),
                [case lists:member(Pl, Winners) of
                     true -> {Pl, Points, active};
                     false -> {Pl, Points, eliminated}
                 end || {Pl, Points} <- TableResult] ++ Acc
        end,
    lists:foldl(F, [], TablesResults).


turn_result_overall(TurnLimit, TablesResults) ->
    F = fun({_, TableRes}, Acc) -> TableRes ++ Acc end,
    OverallResults = lists:foldl(F, [], TablesResults),
    SortedResults = sort_results(OverallResults),
    {Winners, _} = lists:unzip(lists:sublist(SortedResults, TurnLimit)),
    [case lists:member(Pl, Winners) of
         true -> {Pl, Points, active};
         false -> {Pl, Points, eliminated}
     end || {Pl, Points} <- OverallResults].

%% set_turn_results_position([{PlayerId, Points, Status}]) -> [{PlayerId, Pos, Points, Status}]
set_turn_results_position(TurnResult) ->
    F = fun({PlayerId, Points, Status}, Pos) ->
                {{PlayerId, Pos, Points, Status}, Pos + 1}
        end,
    {TurnResultsWithPos, _} = lists:mapfoldl(F, 1, sort_results2(TurnResult)),
    TurnResultsWithPos.

%% set_tables_results_position/2 -> [{TableId, [{PlayerId, Position, Points, Status}]}]
set_tables_results_position(TablesResults, TurnResult) ->
    [begin
         TabResWithStatus = [lists:keyfind(PlayerId, 1, TurnResult) || {PlayerId, _} <- TableResult],
         {TableId, set_table_results_position(TabResWithStatus)}
     end || {TableId, TableResult} <- TablesResults].

%% set_table_results_position([{PlayerId, Points, Status}]) -> [{PlayerId, Pos, Points, Status}]
set_table_results_position(TableResult) ->
    F = fun({PlayerId, Points, Status}, Pos) ->
                {{PlayerId, Pos, Points, Status}, Pos + 1}
        end,
    {TurnResultsWithPos, _} = lists:mapfoldl(F, 1, sort_results2(TableResult)),
    TurnResultsWithPos.

subs_status(TableResultWithPos, Turn, Plan) ->
    LastTurn = Turn == length(Plan),
    {ActSubst, ElimSubst} = if LastTurn -> {winner, eliminated};
                               true -> {none, eliminated}
                            end,
    [case Status of
         active -> {PlayerId, Pos, Points, ActSubst};
         eliminated -> {PlayerId, Pos, Points, ElimSubst}
     end || {PlayerId, Pos, Points, Status} <- TableResultWithPos].


%% sort_results(Results) -> SortedResults
%% Types: Results = SortedResults = [{PlayerId, Points}]
%% Description: Sort the list from a best result to a lower one.
sort_results(Results) ->
    SF = fun({PId1, Points}, {PId2, Points}) -> PId1 =< PId2;
            ({_, Points1}, {_, Points2}) -> Points2 =< Points1
         end,
    lists:sort(SF, Results).

%% sort_results2(Results) -> SortedResults
%% Types: Results = SortedResults = [{PlayerId, Points, Status}] Status = active | eliminated
sort_results2(Results) ->
    SF = fun({PId1, Points, Status}, {PId2, Points, Status}) -> PId1 =< PId2;
            ({_PId1, Points1, Status}, {_PId2, Points2, Status}) -> Points2 =< Points1;
            ({_PId1, _Points1, _Status1}, {_PId2, _Points2, Status2}) -> Status2 == eliminated
         end,
    lists:sort(SF, Results).

%% replace_player_by_bot(PlayerId, TableId, SeatNum,
%%                       #state{players = Players, seats = Seats,
%%                              game_id = GameId, bots_params = BotsParams,
%%                              player_id_counter = NewPlayerId, tables = Tables,
%%                              tab_requests = Requests} = StateData) ->
%%     NewPlayers = del_player(PlayerId, Players),
%%     [#'PlayerInfo'{id = UserId} = UserInfo] = spawn_bots(GameId, BotsParams, 1),
%%     NewPlayers2 = reg_player(#player{id = NewPlayerId, user_id = UserId, is_bot = true}, NewPlayers),
%%     NewSeats = assign_seat(TableId, SeatNum, NewPlayerId, true, false, false, Seats),
%%     TablePid = get_table_pid(TableId, Tables),
%%     NewRequests = table_req_replace_player(TablePid, NewPlayerId, UserInfo, TableId, SeatNum, Requests),
%%     {next_state, ?STATE_PROCESSING, StateData#state{players = NewPlayers2,
%%                                                     seats = NewSeats,
%%                                                     player_id_counter = NewPlayerId + 1,
%%                                                     tab_requests = NewRequests}}.
%% 

%% table_req_replace_player(TablePid, PlayerId, UserInfo, TableId, SeatNum, TabRequests) ->
%%     RequestId = make_ref(),
%%     NewRequests = dict:store(RequestId, {replace_player, PlayerId, TableId, SeatNum}, TabRequests),
%%     send_to_table(TablePid, {replace_player, RequestId, UserInfo, PlayerId, SeatNum}),
%%     NewRequests.



%% prepare_players_for_new_turn(Turn, TTable, TurnsPlan, Players) -> [{PlayerId, UserInfo, Points}]
prepare_players_for_new_turn(Turn, TTable, TurnsPlan, Players) ->
    PrevTurn = Turn - 1,
    TResult = ttable_get_turn_result(PrevTurn, TTable),
    if Turn == 1 ->
           [{PlayerId, get_user_info(PlayerId, Players), _Points = 0}
            || {PlayerId, _, active} <- TResult];
       true ->
           case lists:nth(PrevTurn, TurnsPlan) of
               ne -> %% No one was eliminated => using the prev turn points
                   [{PlayerId, get_user_info(PlayerId, Players), Points}
                    || {PlayerId, Points, active} <- TResult];
               _ ->
                   [{PlayerId, get_user_info(PlayerId, Players), _Points = 0}
                    || {PlayerId, _, active} <- TResult]
           end
    end.


%% setup_tables(Players, TableIdCounter, GameId, TableParams) ->
%%                              {Tables, Seats, NewTableIdCounter, CrRequests}
%% Types: Players = {PlayerId, UserInfo, Points}
setup_tables(Players, TableIdCounter, GameId, TableParams) ->
    SPlayers = shuffle(Players),
    Groups = split_by_num(?SEATS_NUM, SPlayers),
    F = fun(Group, {TAcc, SAcc, TableId, TCrRequestsAcc}) ->
                {TPlayers, _} = lists:mapfoldl(fun({PlayerId, UserInfo, Points}, SeatNum) ->
                                                       {{PlayerId, UserInfo, SeatNum, Points}, SeatNum+1}
                                               end, 1, Group),
                TableParams2 = [{players, TPlayers} | TableParams],
                {ok, TabPid} = spawn_table(GameId, TableId, TableParams2),
                MonRef = erlang:monitor(process, TabPid),
                NewTAcc = reg_table(TableId, TabPid, MonRef, _GlTableId = 0, _Context = undefined, TAcc),
                F2 = fun({PlId, _, SNum, _}, Acc) ->
                             assign_seat(TableId, SNum, PlId, _Reg = false, _Conn = false, Acc)
                     end,
                NewSAcc = lists:foldl(F2, SAcc, TPlayers),
                PlayersIds = [PlayerId || {PlayerId, _, _} <- Group],
                NewTCrRequestsAcc = dict:store(TableId, PlayersIds, TCrRequestsAcc),
                {NewTAcc, NewSAcc, TableId + 1, NewTCrRequestsAcc}
        end,
    lists:foldl(F, {tables_init(), seats_init(), TableIdCounter, dict:new()}, Groups).


%% setup_players(Registrants) -> Players
setup_players(Registrants) ->
    F = fun(UserId, {Acc, PlayerId}) ->
                {ok, UserInfo} = auth_server:get_user_info_by_user_id(UserId),
                NewAcc = store_player(#player{id = PlayerId, user_id = UserId,
                                              user_info = UserInfo, status = active}, Acc),
                {NewAcc, PlayerId + 1}
        end,
    {Players, _} = lists:foldl(F, {players_init(), 1}, Registrants),
    Players.


%% finalize_tables_with_rejoin(Tables) -> ok
finalize_tables_with_rejoin(Tables) ->
    F = fun(#table{mon_ref = MonRef, pid = TablePid}) ->
                erlang:demonitor(MonRef, [flush]),
                send_to_table(TablePid, rejoin_players),
                send_to_table(TablePid, stop)
        end,
    lists:foreach(F, tables_to_list(Tables)).

%% finalize_tables_with_rejoin(Tables) -> ok
finalize_tables_with_disconnect(Tables) ->
    F = fun(#table{mon_ref = MonRef, pid = TablePid}) ->
                erlang:demonitor(MonRef, [flush]),
                send_to_table(TablePid, disconnect_players),
                send_to_table(TablePid, stop)
        end,
    lists:foreach(F, tables_to_list(Tables)).


%% ttable_init(PlayersIds) -> TTable
%% Types: TTable = [{Turn, TurnResult}]
ttable_init(PlayersIds) -> [{0, [{Id, 0, active} || Id <- PlayersIds]}].

%% ttable_get_turn_result(Turn, TTable) -> undefined | TurnResult
%% Types: TurnResult = [{PlayerId, Points, PlayerState}]
%%          PlayerState = undefined | active | eliminated
ttable_get_turn_result(Turn, TTable) ->
    proplists:get_value(Turn, TTable).

%% ttable_store_turn_result(Turn, TurnResult, TTable) -> NewTTable
ttable_store_turn_result(Turn, TurnResult, TTable) ->
    lists:keystore(Turn, 1, TTable, {Turn, TurnResult}).


%% players_init() -> players()
players_init() -> midict:new().

%% store_player(#player{}, Players) -> NewPlayers
store_player(#player{id =Id, user_id = UserId} = Player, Players) ->
    midict:store(Id, Player, [{user_id, UserId}], Players).

get_players_ids(Players) ->
    [P#player.id || P <- players_to_list(Players)].

get_player_by_user_id(UserId, Players) ->
    case midict:geti(UserId, user_id, Players) of
        [Player] -> {ok, Player};
        [] -> error
    end.

%% players_to_list(Players) -> List
players_to_list(Players) -> midict:all_values(Players).

get_user_info(PlayerId, Players) ->
    #player{user_info = UserInfo} = midict:fetch(PlayerId, Players),
    UserInfo.

get_user_id(PlayerId, Players) ->
    #player{user_id = UserId} = midict:fetch(PlayerId, Players),
    UserId.

set_player_status(PlayerId, Status, Players) ->
    Player = midict:fetch(PlayerId, Players),
    store_player(Player#player{status = Status}, Players).

tables_init() -> midict:new().

reg_table(TableId, Pid, MonRef, GlobalId, TableContext, Tables) ->
    Table = #table{id = TableId, pid = Pid, mon_ref = MonRef, global_id = GlobalId,
                   state = initializing, context = TableContext},
    store_table(Table, Tables).

update_created_table(TableId, Relay, Tables) ->
    Table = midict:fetch(TableId, Tables),
    NewTable = Table#table{relay = Relay, state = ?TABLE_STATE_READY},
    store_table(NewTable, Tables).

store_table(#table{id = TableId, pid = Pid, mon_ref = MonRef, global_id = GlobalId} = Table, Tables) ->
    midict:store(TableId, Table, [{pid, Pid}, {global_id, GlobalId}, {mon_ref, MonRef}], Tables).

fetch_table(TableId, Tables) -> midict:fetch(TableId, Tables).

get_table_pid(TabId, Tables) ->
    #table{pid = TabPid} = midict:fetch(TabId, Tables),
    TabPid.

del_table(TabId, Tables) -> midict:erase(TabId, Tables).

get_table_by_mon_ref(MonRef, Tables) ->
    case midict:geti(MonRef, mon_ref, Tables) of
        [Table] -> Table;
        [] -> not_found
    end.

tables_to_list(Tables) -> midict:all_values(Tables).

seats_init() -> midict:new().

find_seats_by_player_id(PlayerId, Seats) ->
    midict:geti(PlayerId, player_id, Seats).

find_seats_by_table_id(TabId, Seats) ->
    midict:geti(TabId, table_id, Seats).

fetch_seat(TableId, SeatNum, Seats) -> midict:fetch({TableId, SeatNum}, Seats).

%% assign_seat(TabId, SeatNum, PlayerId, RegByTable, Connected, Seats) -> NewSeats
%% PlayerId = integer()
%% RegByTable = Connected = undefined | boolean()
assign_seat(TabId, SeatNum, PlayerId, RegByTable, Connected, Seats) ->
    Seat = #seat{table = TabId, seat_num = SeatNum, player_id = PlayerId,
                 registered_by_table = RegByTable, connected = Connected},
    store_seat(Seat, Seats).

update_seat_connect_status(TableId, SeatNum, ConnStatus, Seats) ->
    Seat = midict:fetch({TableId, SeatNum}, Seats),
    NewSeat = Seat#seat{connected = ConnStatus},
    store_seat(NewSeat, Seats).

store_seat(#seat{table = TabId, seat_num = SeatNum, player_id = PlayerId,
                 registered_by_table = _RegByTable,
                 connected = Connected} = Seat, Seats) ->
    Indices = if PlayerId == undefined ->
                     [{table_id, TabId}, {free, true}, {free_at_tab, TabId}];
                 true ->
                     [{table_id, TabId}, {free, false}, {non_free_at_tab, TabId},
                      {player_id, PlayerId}, {{connected, TabId}, Connected}]
              end,
    midict:store({TabId, SeatNum}, Seat, Indices, Seats).


shuffle(List) -> deck:to_list(deck:shuffle(deck:from_list(List))).

split_by_num(Num, List) -> split_by_num(Num, List, []).

split_by_num(_, [], Acc) -> lists:reverse(Acc);
split_by_num(Num, List, Acc) ->
    {Group, Rest} = lists:split(Num, List),
    split_by_num(Num, Rest, [Group | Acc]).

%% start_timer(Timeout) -> {TRef, Magic}
start_timer(Timeout) ->
    Magic = make_ref(),
    TRef = erlang:send_after(Timeout, self(), {timeout, Magic}),
    {TRef, Magic}.

spawn_bots(GameId, Params, BotsNum) ->
    spawn_bots(GameId, Params, BotsNum, []).

spawn_bots(_GameId, _Params, 0, Acc) -> Acc;
spawn_bots(GameId, Params, BotsNum, Acc) ->
    UserInfo = spawn_bot(bot_module(Params), GameId),
    spawn_bots(GameId, Params, BotsNum-1, [UserInfo | Acc]).

spawn_bot(BM, GameId) ->
    {NPid, _SPid, _NUId, User} = create_robot(BM, GameId),
    BM:join_game(NPid),
    User.

create_robot(BM, GameId) ->
    User = auth_server:robot_credentials(),
    NUId = User#'PlayerInfo'.id,
    {ok, NPid} = BM:start_link(self(), User, GameId),
    SPid = BM:get_session(NPid),
    {NPid, SPid, NUId, User}.

spawn_table(GameId, TableId, Params) -> ?TAB_MOD:start(GameId, TableId, Params).

send_to_table(TabPid, Message) -> ?TAB_MOD:parent_message(TabPid, Message).

%% table_parameters(ParentMod, ParentPid) -> Proplist
table_parameters(ParentMod, ParentPid) ->
    [
     {parent, {ParentMod, ParentPid}},
     {seats_num, 4},
%%     {players, []},
     {table_name, ""},
     {mult_factor, 1},
     {slang_allowed, false},
     {observers_allowed, false},
     {tournament_type, elimination},
%%     {round_timeout, 7*60*1000},
     {round_timeout, 20*1000},
     {speed, normal},
     {game_type, standard},
     {rounds, 10},
     {reveal_confirmation, true},
     {next_series_confirmation, false},
     {pause_mode, disabled},
     {social_actions_enabled, false}
    ].

%% bots_parameters() -> Proplist
bots_parameters() ->
    [
     {game, game_okey},
     {game_mode, standard},
     {lucky, true},
     {speed, normal},
     {rounds, 10}
    ].

seats_num(TableParams) -> proplists:get_value(seats_num, TableParams).

bot_module(TableParams) ->
    case proplists:get_value(game, TableParams) of
        game_okey -> game_okey_bot
    end.

get_param(ParamId, Params) ->
    {_, Value} = lists:keyfind(ParamId, 1, Params),
    Value.

get_option(OptionId, Params, DefValue) ->
    proplists:get_value(OptionId, Params, DefValue).

get_plan(KakushPerRound, RegistrantsNum,Tours) ->
    case lists:keyfind({KakushPerRound, RegistrantsNum,Tours}, 1, tournament_matrix()) of
        false -> {error, no_such_plan};
        {_NQ,_K, Plan} -> {ok, Plan}
    end.

get_prize_fund(KakushPerRound, RegistrantsNum,Tours) ->
    case lists:keyfind({KakushPerRound, RegistrantsNum,Tours}, 1, tournament_matrix()) of
        false -> {error, no_such_plan};
        {_NQ, K, _Plan} -> {ok, K}
    end.

tournament_matrix() ->
    [%% Kakush Pl.No         1          2         3         4         5         6         7         8
     { {  8,   16,3}, 54,   [ne      , {ce,  4}, {te,  1}                                                  ]},
     { { 10,   16,3}, 72,   [ne      , {ce,  4}, {te,  1}                                                  ]},
     { {  2,   64,4}, 80,   [ne      , {ce, 16}, {te,  1}, {te,  1}                                        ]},
     { {  4,   64,4}, 98,   [ne      , {ce, 16}, {te,  1}, {te,  1}                                        ]},
     { {  6,   64,4}, 158,  [ne      , {ce, 16}, {te,  1}, {te,  1}                                        ]},
     { {  8,   64,4}, 223,  [ne      , {ce, 16}, {te,  1}, {te,  1}                                        ]},
     { { 10,   64,4}, 295,  [ne      , {ce, 16}, {te,  1}, {te,  1}                                        ]},
     { {  2,  128,5}, 81,   [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}                              ]},
     { {  4,  128,5}, 162,  [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}                              ]},
     { {  6,  128,5}, 260,  [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}                              ]},
     { {  8,  128,5}, 368,  [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}                              ]},
     { { 10,  128,5}, 487,  [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}                              ]},
     { {  2,  256,5}, 198,  [ne      , {ce, 64}, {te,  1}, {te,  1}, {te,  1}                              ]},
     { {  4,  256,5}, 397,  [ne      , {ce, 64}, {te,  1}, {te,  1}, {te,  1}                              ]},
     { {  6,  256,5}, 635,  [ne      , {ce, 64}, {te,  1}, {te,  1}, {te,  1}                              ]},
     { {  8,  256,5}, 899,  [ne      , {ce, 64}, {te,  1}, {te,  1}, {te,  1}                              ]},
     { { 10,  256,5}, 1190, [ne      , {ce, 64}, {te,  1}, {te,  1}, {te,  1}                              ]},
     { {  2,  256,7}, 283,  [ne      , {ce,128}, ne      , {ce, 64}, {te,  1}, {te,  1}, {te,   1}         ]},
     { {  4,  256,7}, 566,  [ne      , {ce,128}, ne      , {ce, 64}, {te,  1}, {te,  1}, {te,   1}         ]},
     { {  6,  256,7}, 907,  [ne      , {ce,128}, ne      , {ce, 64}, {te,  1}, {te,  1}, {te,   1}         ]},
     { {  8,  256,7}, 1285, [ne      , {ce,128}, ne      , {ce, 64}, {te,  1}, {te,  1}, {te,   1}         ]},
     { { 10,  256,7}, 1701, [ne      , {ce,128}, ne      , {ce, 64}, {te,  1}, {te,  1}, {te,   1}         ]},
     { {  2,  512,6}, 326,  [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  4,  512,6}, 652,  [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  6,  512,6}, 1043, [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  8,  512,6}, 1478, [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { { 10,  512,6}, 1957, [{te,  2}, {te,  2}, {te,  2}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  2,  512,8}, 582,  [ne      , {ce,256}, ne      , {ce,128}, {te,  2}, {te,  1}, {te,  1}, {te,  1}]},
     { {  4,  512,8}, 1163, [ne      , {ce,256}, ne      , {ce,128}, {te,  2}, {te,  1}, {te,  1}, {te,  1}]},
     { {  6,  512,8}, 1861, [ne      , {ce,256}, ne      , {ce,128}, {te,  2}, {te,  1}, {te,  1}, {te,  1}]},
     { {  8,  512,8}, 2637, [ne      , {ce,256}, ne      , {ce,128}, {te,  2}, {te,  1}, {te,  1}, {te,  1}]},
     { { 10,  512,8}, 3490, [ne      , {ce,256}, ne      , {ce,128}, {te,  2}, {te,  1}, {te,  1}, {te,  1}]},
     { {  2, 1024,6}, 795,  [ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  4, 1024,6}, 1589, [ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  6, 1024,6}, 2543, [ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  8, 1024,6}, 3602, [ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { { 10, 1024,6}, 4767, [ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  2, 1024,8}, 1135, [ne      , {ce,512}, ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}]},
     { {  4, 1024,8}, 2271, [ne      , {ce,512}, ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}]},
     { {  6, 1024,8}, 3633, [ne      , {ce,512}, ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}]},
     { {  8, 1024,8}, 5147, [ne      , {ce,512}, ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}]},
     { { 10, 1024,8}, 6812, [ne      , {ce,512}, ne      , {ce,256}, {te,  1}, {te,  1}, {te,  1}, {te,  1}]},
     { {  2, 2048,6}, 1135, [{te,  2}, {te,  1}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  4, 2048,6}, 2271, [{te,  2}, {te,  1}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  6, 2048,6}, 3633, [{te,  2}, {te,  1}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  8, 2048,6}, 5147, [{te,  2}, {te,  1}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { { 10, 2048,6}, 6812, [{te,  2}, {te,  1}, {te,  1}, {te,  1}, {te,  1}, {te,  1}                    ]},
     { {  2, 2048,8}, 1987, [ne      , {ce,1024},{te,  2}, {te,  2}, {te,  1}, {te,  1}, {te,  1}, {te,  1}]},
     { {  4, 2048,8}, 3974, [ne      , {ce,1024},{te,  2}, {te,  2}, {te,  1}, {te,  1}, {te,  1}, {te,  1}]},
     { {  6, 2048,8}, 6359, [ne      , {ce,1024},{te,  2}, {te,  2}, {te,  1}, {te,  1}, {te,  1}, {te,  1}]}
  ].
