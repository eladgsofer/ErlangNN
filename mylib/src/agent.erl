%%%-------------------------------------------------------------------
%%% @author elad.sofer
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(agent).

-behaviour(gen_server).

-export([start_link/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(agent_state, {ets, nnId, agentId, seedGene, collectorPid}).
-include("records.hrl").
%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link(CollectorPid, ETS, NNid, Gene, AgentId) ->
  gen_server:start_link({local, AgentId}, ?MODULE, [CollectorPid, ETS, NNid, Gene, AgentId], []).

init([CollectorPid, ETS, NNid, Gene, AgentId]) ->

  io:format("Hi I am agent:~p, Details: CollectorPid:~p|NNid:~p|Gene~p~n", [AgentId, CollectorPid, NNid, Gene]),
  {ok, #agent_state{ets=ETS, nnId=NNid, seedGene=Gene, collectorPid=CollectorPid, agentId = AgentId}}.

handle_call({run_simulation, Gene}, _From, State = #agent_state{agentId = AgentId}) ->
  % the AgentId is: <node>_nnX atom
  {_, _, SimulationVec} = exoself:map(AgentId,Gene),
  % {SrcPid, _} = _From,
  {reply, {ok, SimulationVec}, State}.

handle_cast({executeIteration, MutId, Gene}, State = #agent_state{ets=ETS, nnId=NNid, seedGene=SeedGene, collectorPid=CollectorPid, agentId = AgentId}) ->
  % NNid is the AgentId as well, each agent has it's own network to handle.
  ActualGene =
    if
      MutId==0 -> SeedGene;
      true-> Gene
    end,

  MutatedGene = mutate:mutate(ActualGene),
  {Score, ProcessesCount, _} = exoself:map(AgentId,Gene),
  io:format("NNid:~p|Score:~p|Processes Count:~p~n",[AgentId, Score, ProcessesCount]),

  ets:insert(ETS, #nn_rec{nn_id = NNid, mutId = MutId, processes_count = ProcessesCount, score=Score, gene=MutatedGene}),
  %gen_statem:cast(CollectorPid, {sync, AgentId}),
  CollectorPid ! {sync, AgentId},
  {noreply, State#agent_state{}}.


handle_info(_Info, State = #agent_state{}) ->
  {noreply, State}.

terminate(_Reason, _State = #agent_state{}) ->
  ok.

code_change(_OldVsn, State = #agent_state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================





%%handle_cast({computeNN, Gene}, State = #nn_agent_state{nnId = NNid, populationMgmt = MgmtProc, mutId=MutId, ets=ETS}) ->
%%  %TODO Mutate the gene
%%  spawn(fun(MgmtProc, ETS, NNid, MutId) -> simulateNN(Gene,MgmtProc, ETS, NNid, MutId) end),
%%  {noreply, State}.
%%
%%
%%simulateNN(Gene, MgmtProc, ETS, NNid, MutId) ->
%%  {NNId, {score, Score}, {processesInfo, ProcessesInfo}} = exoself:map(NNid, ETS, NNid, MutId),
%%  MgmtProc ! {NNId, {score, Score}, {processesInfo, ProcessesInfo}}.

% -record(genotype, {nn_id, scoring_list, processes_info}).

%	NN_Entry = case ets:member(ETS, NNid) of
%							true -> ets:lookup(ETS, NNid);
%							false-> E =  #nn_rec{nn_id = NNid, score=0, processes_info = []},
%								ets:insert(ETS,E) , E
%						 end,
%	ProcessesInfo = lists:append(NN_Entry#nn_rec.processes_info, {list_to_atom("MutId_" ++ integer_to_list(MutId)), Processes_Count}),
%