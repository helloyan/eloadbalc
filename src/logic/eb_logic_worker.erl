%%%-------------------------------------------------------------------
%%% @author tihon
%%% @copyright (C) 2014, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 16. Окт. 2014 1:29
%%%-------------------------------------------------------------------
-module(eb_logic_worker).
-author("tihon").

-behaviour(gen_server).

%% API
-export([start_link/1, get_all_data/0, add_node/1, restart_node/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(ETS, nodes_load).

-record(state,
{
  strategy :: atom(), %check strategy for logic
  timelist :: proplists:proplist()  %pairs of node-start time
}).

%%%===================================================================
%%% API
%%%===================================================================
%% get all data from table
-spec get_all_data() -> {Ready :: list(), Realtime :: list()}.
get_all_data() ->
  ets:foldl(fun check_data/2, {[], []}, ?ETS).

%% add node for checking. Will run update timer (if not realtime) and will update node's data
-spec add_node({Node :: atom(), Strgategy :: atom(), Max :: integer(), Time :: integer() | realtime}) -> ok.
add_node(Node) ->
  gen_server:call(?MODULE, {add, Node}).

%% switch realtime node monitoring and restart it later.
-spec restart_node(Node :: atom()) -> ok.
restart_node(Node) ->
  gen_server:cast(?MODULE, {reconnect, Node}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(Params :: list()) ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Params) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, Params, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%TODO dynamic nodes deleting, changing timers and strategy
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Params :: list()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init({Strategy, NodeList}) when Strategy == ram; Strategy == cpu; Strategy == counter ->
  ets:new(?ETS, [named_table, protected, {read_concurrency, true}]),
  StartTimeList = set_up_monitoring(NodeList, Strategy),  %set up monitoring - launch update timers for no rt nodes
  {ok, #state{strategy = Strategy, timelist = StartTimeList}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call({add, Node}, _From, State = #state{strategy = Strategy, timelist = Timelist}) ->  %add node dynamically
  Pair = set_up_node(Node, Strategy), % set monitoring, launch timer if not rt, cave conf
  {reply, ok, State#state{timelist = [Pair | Timelist]}}; %add to time restart list
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast({reconnect, Name}, State = #state{timelist = TimeList}) ->  %reconnect to node - realtime call
  case reconnect_later(Name, TimeList) of
    true -> turn_off_node(ets:lookup(?ETS, Name));  %set this node to off for realtime calls
    fase -> ok  %can't set reconnect timer - do not turn off the node
  end,
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info({update, Name, Time}, State = #state{timelist = TimeList}) -> %update node information
  [{Name, _, Max, Strategy}] = ets:lookup(?ETS, Name),
  try eb_logic:fetch_node_data(Name, Strategy) of  %got rpc error, node is down
    off -> reconnect_later(Name, TimeList); %reconnect to it later
    Data ->
      check_max(Name, Data, Max, Strategy), %check max logic  (off node or no)
      erlang:send_after(Time, self(), {update, Name, Time})  %update timer
  catch %in case of arithmetic expressions
    _:_ ->
      reconnect_later(Name, TimeList) %reconnect to it later
  end,
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%% @private
set_up_monitoring([], _) -> ok;
set_up_monitoring(NodeList, Strategy) when is_list(NodeList) ->
  lists:foldl(fun(Node, Acc) -> [set_up_node(Node, Strategy) | Acc] end, [], NodeList).

%% @private
set_up_node({Name, StartTime, realtime, Max}, Strategy) when is_atom(Name) -> %% Mark rt node as rt and save its conf
  ets:insert(?ETS, {Name, realtime, Max, Strategy}),
  {Name, StartTime};
set_up_node({Name, StartTime, Time, Max}, Strategy) when is_atom(Name) -> %% Run timer, get first launch data and save conf
  erlang:send_after(Time, self(), {update, Name, Time}),
  Data = eb_logic:fetch_node_data(Name, Strategy),
  ets:insert(?ETS, {Name, Data, Max, Strategy}),
  {Name, StartTime}.

%% @private
check_max(Node, Max, Current, Strategy) when Current > Max -> ets:insert(?ETS, {Node, off, Max, Strategy});
check_max(Node, Max, Current, Strategy) -> ets:insert(?ETS, {Node, Current, Max, Strategy}).

%% @private
check_data({Node, realtime, Max, Strategy}, {Ready, RT}) -> {Ready, [{Node, Max, Strategy} | RT]};
check_data({_, off, _, _}, Acc) -> Acc;
check_data({Node, Data, _, _}, {Ready, RT}) -> {[{Node, Data} | Ready], RT}.

%% @private
reconnect_later(Name, TimeList) ->
  case proplists:get_value(Name, TimeList) of %use connect time to update state
    undefined -> false; %no start time for this node
    Time ->
      erlang:send_after(Time, self(), {update, Name, Time}), %set connect timer
      true
  end.

%% @private
turn_off_node([{Name, realtime, Max, Strategy}]) -> %set this node to off for realtime calls
  ets:insert(?ETS, {Name, off, Max, Strategy});
turn_off_node(_) -> ok.
