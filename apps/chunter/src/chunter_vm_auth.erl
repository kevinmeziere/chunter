%%%-------------------------------------------------------------------
%%% @author Kevin Meziere <kevin@meziere.com>
%%% @copyright (C) 2014, Kevin Meziere
%%% @doc
%%%
%%% @end
%%% Created : 01 Aug 2014 by Kevin Meziere <kevin@meziere.com>
%%%-------------------------------------------------------------------
-module(chunter_vm_auth).

-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(state, {port, doors=[]}).

-define(HEATRBEAT_INTERVAL, 1000). % 2 seconds - zonedoor terminates after 7 sec of no HB. Allow 2 misses

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
   

init(_) ->
  Cmd = code:priv_dir(chunter) ++ "/zonedoor",
	DoorPort = open_port({spawn_executable, Cmd},
	                     [{args, []}, use_stdio, {line, 1024}, exit_status]),
  erlang:send_after(?HEATRBEAT_INTERVAL, self(), heartbeat),
	{ok, #state{port = DoorPort}}.



handle_call({verify_zonedoor, UUID}, _, State) ->
    case lists:member(UUID, State#state.doors) of
      false ->
        io:format("Request to add zone door: ~s~n", [UUID]),
        Data = io_lib:format("a~s~n", [UUID]),
        port_command(State#state.port, Data),
        State1 = State#state{doors = lists:flatten([UUID, State#state.doors])},
        {reply, ok, State1};
      _ ->
       {reply, ok, State}
    end;
handle_call({remove_zonedoor, UUID}, _, State) ->
    case lists:member(UUID, State#state.doors) of
      true ->
        io:format("Request to delete zone door: ~s~n", [UUID]),
        Data = io_lib:format("d~s~n", [UUID]),
        port_command(State#state.port, Data),
        State1 = State#state{doors = lists:delete(UUID, State#state.doors)},
        {reply, ok, State1};
      _ ->
        {reply, ok, State}
      end.



handle_info(heartbeat, State) ->
  port_command(State#state.port, "h\n"),
  erlang:send_after(?HEATRBEAT_INTERVAL, self(), heartbeat),
  {noreply, State};
handle_info({Port,{data,{eol,Data}}} , State) ->
	io:format("Received data: ~s~n", [Data]),
	auth_credintials(Port, Data),
	{noreply, State}.




auth_credintials(Port, [UUID,KeyID]) ->
    KeyBin = libsnarl:keystr_to_id(KeyID),
    case ls_user:key_find(KeyBin) of
        {ok, UserID} ->
            lager:warning("[zonedoor:~s] User ~s trying to connect with key ~s",
                          [UUID, UserID, KeyID]),
            case libsnarl:allowed(UserID, [<<"vms">>, UUID, <<"console">>]) orelse
                libsnarl:allowed(UserID, [<<"vms">>, UUID, <<"ssh">>]) of
                true ->
                    lager:warning("[zonedoor:~s] granted.", [UUID]),
                    port_command(Port, "r1\n");
                _ ->
                    lager:warning("[zonedoor:~s] denied.", [UUID]),
                    port_command(Port, "r0\n")
            end;
        _ ->
            lager:warning("[zonedoor:~s] denied.", [UUID]),
            port_command(Port, "r0\n")
    end;
auth_credintials(Port, Data) -> 
	case re:split(Data, " ") of
        [UUID,_,_,KeyID] ->
        	auth_credintials(Port, [UUID,KeyID]),
        	ok;
    	 _ ->
          lager:warning("[zonedoor] recived unknown data: ~p.", [Data]),
          ok
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%% @end
%%--------------------------------------------------------------------

terminate(_, State) -> 
  incinerate(State#state.port),
  ok.



%%%===================================================================
%%% Internal functions
%%%===================================================================

incinerate(Port) ->
    {os_pid, OsPid} = erlang:port_info(Port, os_pid),
    port_close(Port),
    lager:warning("Killing ~p with -9", [OsPid]),
    os:cmd(io_lib:format("/usr/bin/kill -9 ~p", [OsPid])).




%%%===================================================================
%%% Unused gen_server functions
%%%===================================================================

handle_cast(_, State) -> {noreply, State}.
code_change(_, State, _) -> {ok, State}.
