%%%-------------------------------------------------------------------
%%% @author elad.sofer
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Aug 2021 2:23 PM
%%%-------------------------------------------------------------------
-module(db).
-author("elad.sofer").
-include("records.hrl").
%% API
-export([init/1,init/0,write/5,read_all_mutateIter/1,select_best_genes/1,write_records/1]).

init()->init([]).
init(Node_List) ->
  mnesia:create_schema([node()|Node_List]), mnesia:start(),
  mnesia:create_table(db,[{ram_copies, [node()|Node_List]},{type, bag},{attributes, record_info(fields,db)}]).

write_records([])->ok;
write_records([Record|Records])->Fun = fun() ->mnesia:write(Record) end, mnesia:transaction(Fun),write_records(Records).


write(NN_id, MutId, Gene, Processes_count, Score) ->
  Tmp = #db{nn_id = NN_id,mutId = MutId,gene = Gene,processes_count = Processes_count,score = Score},
  Fun = fun() ->mnesia:write(Tmp) end, mnesia:transaction(Fun).

read_all_mutateIter(Iter) ->
  F = fun() ->
    Elem = #db{mutId = Iter,nn_id = '_',gene = '_',processes_count = '_',score = '_'},
    mnesia:select(db, [{Elem, [], ['$_']}])
      end,
  mnesia:transaction(F).

select_best_genes([{NnId,Iter}|Tail]) ->select_best_genes([{NnId,Iter}|Tail],[]).
select_best_genes([{NnId,Iter}|Tail],Acc)->
  F = fun() ->
    Elem = #db{mutId = Iter,nn_id =NnId,gene = '$1',_= '_'},
    mnesia:select(db, [{Elem, [], ['$1']}])
      end,
  {atomic,Tmp}= mnesia:transaction(F),
  select_best_genes(Tail,Acc++Tmp);
select_best_genes([],Acc)-> Acc.
