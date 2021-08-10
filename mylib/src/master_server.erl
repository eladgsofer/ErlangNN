%%%-------------------------------------------------------------------
%%% @author tom
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 04. Aug 2021 3:44 PM
%%%-------------------------------------------------------------------
-module(master_server).
-author("tom").
-include("records.hrl").

-behaviour(gen_server).

%% API
-export([start_link/5, generateSeeds/2, start_slave/4, start_king/4]).
%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).
-compile(export_all).


-define(SERVER, ?MODULE).

-define(TOM, 'king@Tom-VirtualBox').

-define(ELAD, 'king@pds-MacBook-Pro').

-define(MASTER_NODE, 'king@132.72.104.105').

-define(NODE1, 'node1@132.72.104.125').
-define(NODE2, 'node2@Tom-VirtualBox').
-define(NODE3, 'node3@Tom-VirtualBox').
-define(TIMER_INTERVAL, 1000).

-record(state, {nn_amount,nnPerNode,mutate_iteration,max_mutate_iteration,rabbit_pos, track,prev_nodes, timer_ref, parentGenes}).
-record(track,{?MASTER_NODE,?NODE1,?NODE2,?NODE3}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%-----------------
%% ---------------------------------------------------

start_king(Layers,Max_Mutation_iterations,Simulation_steps,NN_amount)->
  start_link(Layers,Max_Mutation_iterations,Simulation_steps,NN_amount,true).

start_slave(Layers,Max_Mutation_iterations,Simulation_steps,NN_amount)->
  start_link(Layers,Max_Mutation_iterations,Simulation_steps,NN_amount,false).

start_link(Layers,Max_Mutation_iterations,Simulation_steps,NN_amount,IsMaster) ->
  ServerId =
    case IsMaster of
      true  -> king;
      false-> utills:generateServerId(?MODULE)
    end,

  gen_server:start_link({global, ServerId}, ?MODULE, [Layers,Max_Mutation_iterations,Simulation_steps,NN_amount,IsMaster, ServerId], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([Layers,Max_Mutation_iterations,Simulation_steps,NN_amount, IsMaster, ServerId]) ->
  register(ServerId, self()), %TODO check if register global and how?

  %TODO Write configuration to DB SIM_STEPS...
  Rabbit_pos= exoself:generateRabbitPatrol(),
  Track = #track{?MASTER_NODE = {?MASTER_NODE,maps:new()}, ?NODE1 = {?NODE1,maps:new()},?NODE2 = {?NODE2,maps:new()},?NODE3 = {?NODE3,maps:new()}},

  State = #state{nn_amount = NN_amount, mutate_iteration=1, max_mutate_iteration = Max_Mutation_iterations,
    rabbit_pos = Rabbit_pos, track=Track, prev_nodes = findActiveNodes(), parentGenes = []},
  %io:format("Registered P:~p~n", [registered()]),
  NewState =
    case IsMaster of
    true->
      ActiveNodes = findActiveNodes(),
      ActiveSlaves = findSlaves(),
      io:format("ActiveNodes:~p~n", [ActiveNodes]),
      mnesia:create_schema(ActiveNodes),
      mnesia:start(),

      % Trigger Slaves - They start the Mnesia
      lists:foreach(fun(Sl_Node)-> Dest = {utills:generateServerId(Sl_Node, ?MODULE), Sl_Node}, io:format("Dest~p", [Dest]) , Dest ! {king, startSlave} end, ActiveSlaves),
      collectMnesiaStartMsgs(ActiveSlaves),
      database:init(ActiveNodes),
      NNPerNode = round(math:floor(NN_amount/length(findActiveNodes()))),

      startPopulationFSM(self(), NNPerNode, Layers, ?SIM_ITERATIONS),
      graphic:start(),

      {ok, TimerRef} = timer:send_interval(?TIMER_INTERVAL, self(), check_genotyps),
      {ok, State#state{timer_ref=TimerRef, nnPerNode = NNPerNode}};

    false ->
      io:format("Waiting for master...~n"),
      receive
        {king, startSlave} -> mnesia:start(), {king, ?MASTER_NODE} ! {node(), mnesiaStarted}
      end,

      NNPerNode = round(math:floor(NN_amount/length(findActiveNodes()))),
      MasterId = {king, ?MASTER_NODE},
      io:format("STARTING POPULATION~n"),
      startPopulationFSM(MasterId, NNPerNode, Layers, ?SIM_ITERATIONS),
      {ok, State#state{nnPerNode = NNPerNode}}
  end, NewState.


startPopulationFSM(MasterId, NNPerNode,Layers, Simulation_steps)->
  {NNids, AgentsIds} = generateSeeds(NNPerNode,Layers),
  population_fsm:start_link(NNPerNode,Simulation_steps, MasterId,{NNids, AgentsIds}).

handle_call(_Request, _From, State) ->
  {reply, ok, State}.


handle_cast({ok, Node, NNids},State)->
  io:format("Population IS UP ~p~n", [Node]),
  Servername = utills:generateServerId(Node,population_fsm),
  Seeds = [{NNid,0}||NNid<-NNids],
  gen_statem:cast({global, Servername}, {runNetwork, Seeds, 1}),
  {noreply, State};

handle_cast({Node, done, Mutation_iterations}, State) ->
  io:format("Done from:~p~n", [Node]),
  Old = State#state.track,
  NewTrack = case Node of
               ?MASTER_NODE->
                 {_,TrackNode} = Old#track.?MASTER_NODE,
                 Old#track{?MASTER_NODE = {?MASTER_NODE,maps:put(Mutation_iterations, finish, TrackNode)}};
               ?NODE1->
                 {_,TrackNode} = Old#track.?NODE1,
                 Old#track{?NODE1 = {?NODE1,maps:put(Mutation_iterations, finish, TrackNode)}};
               ?NODE2->
                 {_,TrackNode} = Old#track.?NODE2,
                 Old#track{?NODE2 = {?NODE2,maps:put(Mutation_iterations, finish, TrackNode)}};
               ?NODE3->
                 {_,TrackNode} = Old#track.?NODE3,
                 Old#track{?NODE3 = {?NODE3,maps:put(Mutation_iterations, finish, TrackNode)}};
               _-> ok
             end,
  {noreply, State#state{track = NewTrack}}.

handle_info(_Info, State) ->
  Mutate_iteration = State#state.mutate_iteration,
  NN_Amount = State#state.nn_amount,
  Active_Nodes= findActiveNodes(),
  %CHANGE NUMBER OF NN_AMOUNT FOR EACH NODE
  NewState = case Active_Nodes==State#state.prev_nodes of
               true->
                 handleIteration(State, Active_Nodes, Mutate_iteration);
               false ->
                 io:format("#### NODES CHANGED ACTIVE:~p PREV:~p~n", [Active_Nodes, State#state.prev_nodes]),
                 % Update the work per node equally
                 Updated_State_1 = State#state{prev_nodes = Active_Nodes, nnPerNode = round(math:floor(NN_Amount/length(Active_Nodes)))},
                 io:format("NEW ACTIVE NODES:~p~n", [Active_Nodes]),
                 io:format("NEW nnPerNode:~p~n", [Updated_State_1#state.nnPerNode]),
                 Updated_State_2 = restartIteration(Updated_State_1,Mutate_iteration, Active_Nodes),
                 handleIteration(Updated_State_2, Active_Nodes, Mutate_iteration-1)

             end,

  {noreply, NewState}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

turnOffTimer(TRef) -> RES = timer:cancel(TRef), io:format(RES).

filterNodesMaps([],_, Acc)-> lists:reverse(Acc);

filterNodesMaps([Node|ActiveNodes],Maps, Acc)->
  {_, Map} = lists:keyfind(Node, 1, Maps),
  filterNodesMaps(ActiveNodes, Maps, [Map|Acc]).


handleIteration(State,Active_Nodes,Mutate_iteration) ->
  Track = State#state.track, Maps_list = tl(tuple_to_list(Track)),
  Maps = filterNodesMaps(Active_Nodes, Maps_list, []),
  Readys = [ready || M <-Maps, maps:find(Mutate_iteration,M)=/=error],

  case length(Readys)==length(Active_Nodes) of % Double check that we're fine
    true-> io:format("handleIteration:~p~n", [Mutate_iteration]),
      case Mutate_iteration==State#state.max_mutate_iteration of
        false->
          Updated_State = State#state{mutate_iteration = Mutate_iteration + 1},
          U_S = triggerCalcState(Mutate_iteration, Active_Nodes, Updated_State), U_S;
        true->
          io:format("Final Iteration:~n"),
          {Best_score,Best_Genotype,Processes_cnt} = chooseBest(Mutate_iteration,State),
          io:format("Best_score:~p~n", [Best_score]),
          %io:format("Best_Genotype:~p~n", [Best_Genotype]),
          %io:format("Processes_cnt:~p~n", [Processes_cnt]),
          Cx = hd(Best_Genotype),
          Nurons_num = length(Cx#cortex.nids),
          %io:format("Nurons_num:~p~n", [Nurons_num]),
          Statistics = [{process, Processes_cnt},{neurons, Nurons_num},{fitness, Best_score}],
          Agent = utills:generateServerId(?MASTER_NODE, nn1),
          %io:format("Sending simulation to agent:~p~n", [Agent]),

          {ok,Path} = gen_server:call(Agent,{run_simulation,Best_Genotype}),
          io:format("hunter path:~p~n", [Path]),
          display(Path,Statistics),

          %io:format("TIMER_REF~p~n", [State#state.timer_ref]),
          %turnOffTimer(State#state.timer_ref),
          %io:format("whoooo~p~n", [State#state.timer_ref]),

          State
      end;
    false-> State
  end.


triggerCalcState(Mutation_iterations,Active_Nodes,Updated_State)-> %%mnesia:force_load_table(db),
  {atomic,List} = database:read_all_mutateIter(Mutation_iterations),
  OffspringGenes = [{Score,{NNid,MutatIter}} || {db,NNid,MutatIter,_,_,Score} <-List],
  Sortd_by_score = lists:keysort(1, OffspringGenes ++ Updated_State#state.parentGenes),
  %io:format("Sortd_by_score:~p~n", [Sortd_by_score]),
  BestGenotypes = lists:sublist(Sortd_by_score, Updated_State#state.nnPerNode),
  %io:format("Best_Genotypes_to_brodcast:~p~n", [BestGenotypes]),
  U_S = Updated_State#state{parentGenes = BestGenotypes},
  %io:format("Updated prev_best_gene:~p~n", [U_S#state.prev_best_gene]),
  %io:format("Bests_genotyps:~p~n", [Bests_genotyps]),
  broadcastGenes(BestGenotypes,Active_Nodes,U_S), U_S.

broadcastGenes(BestGenotypes,Active_Nodes,Updated_State)->
  ChosenGenes = [{NNid,MutatIter}||{_,{NNid,MutatIter}} <-BestGenotypes],
  %io:format("ChosenGenes:~p~n", [ChosenGenes]),

  % PopAddresses = [{Node, utills:generateServerId(Node, population_fsm)}||Node<-Active_Nodes],
  PopAddresses = [utills:generateServerId(Node, population_fsm)||Node<-Active_Nodes],   %TODO VIEW HOW TO CAST TO A REMOTE NODE
  %io:format("Population Addresses~p~n", [PopAddresses]),
  TriggerCalc = fun(PopAddr)-> gen_server:cast({global, PopAddr}, {runNetwork, ChosenGenes, Updated_State#state.mutate_iteration}) end,
  lists:foreach(TriggerCalc, PopAddresses).

chooseBest(Mutation_iterations,State)->%%mnesia:force_load_table(db),
  {atomic,List} = database:read_all_mutateIter(Mutation_iterations),
  Filtered = [{Score,{NNid,MutatIter}}||{db,NNid,MutatIter,_,_,Score} <-List],
  Sortd_by_score = lists:keysort(1,Filtered++State#state.parentGenes),
  {_,{NNid,MutatIter}}=hd(Sortd_by_score),
  {atomic,Best_Net} = database:get({NNid,MutatIter}),
  {db,_,_,Genotype,Processes_cnt,Score_db}=hd(Best_Net),
  {Score_db,Genotype,Processes_cnt}.

display([],_)-> turnOffTimer;
display([[R_X,R_Y,H_X,H_Y]|Path],Statistics)->
  graphic:update_location({R_X*20,R_Y*20},{H_X*20,H_Y*20},Statistics),
  timer:sleep(500),
  io:format("CurrentPath~p~n", [Path]),
  display(Path,Statistics).

generateSeeds(NN_amount,Layers)-> % Initialize State
  % Each node create it's own seed
  {NNids, AgentsIds} = Env_Params = utills:generateNNIds(1,NN_amount),
  AgentIdsZipped = lists:zip(NNids, AgentsIds),
  Seeds=[#db{nn_id = NNid,mutId =0,
    gene=constructor:construct_Genotype(AgentId,rng,pts,Layers),
    processes_count = 0,score = 0}||{NNid, AgentId}<-AgentIdsZipped],
  database:write_records(Seeds), Env_Params.


findActiveNodes()->
  NodeList = [?MASTER_NODE, ?NODE1, ?NODE2, ?NODE3],
  [Node || Node<- NodeList, net_kernel:connect_node(Node)==true].

findSlaves()->
  NodeList = [?NODE1, ?NODE2, ?NODE3],
  [Node || Node<- NodeList, net_kernel:connect_node(Node)==true].

restartIteration(State, MutIter, ActiveNodes)->
  database:delete_all_mutateIter(MutIter),
  io:format("BEFORE:~n~p~n", [State#state.track#track.?MASTER_NODE]),
  Updated_State = removeMutIter(ActiveNodes,MutIter,State),
  io:format("AFTER:~n~p~n", [Updated_State#state.track#track.?MASTER_NODE]),
  Updated_State.

removeMutIter([],_, State) -> State;
removeMutIter([Node|ActiveNodes],Mutation_iterations, State) ->
  Old = State#state.track,
  NewTrack = case Node of
               ?MASTER_NODE->
                 {_,TrackNode} = Old#track.?MASTER_NODE,
                 Old#track{?MASTER_NODE = {?MASTER_NODE,maps:remove(Mutation_iterations,TrackNode)}};
               ?NODE1->
                 {_,TrackNode} = Old#track.?NODE1,
                 Old#track{?NODE1 = {?NODE1,maps:remove(Mutation_iterations,TrackNode)}};
               ?NODE2->
                 {_,TrackNode} = Old#track.?NODE2,
                 Old#track{?NODE2 = {?NODE2,maps:remove(Mutation_iterations,TrackNode)}};
               ?NODE3->
                 {_,TrackNode} = Old#track.?NODE3,
                 Old#track{?NODE3 = {?NODE3,maps:remove(Mutation_iterations,TrackNode)}};
               _-> ok
             end,
  removeMutIter(ActiveNodes,Mutation_iterations, State#state{track = NewTrack}).

collectMnesiaStartMsgs([])-> ok;
collectMnesiaStartMsgs([S|Slaves])->
  receive
    {S, mnesiaStarted} -> collectMnesiaStartMsgs(Slaves)
  end.
