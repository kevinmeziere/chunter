%%%-------------------------------------------------------------------
%%% @author Heinz N. Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz N. Gies
%%% @doc
%%%
%%% @end
%%% Created : 11 May 2012 by Heinz N. Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(chunter_zonemon).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ignore_xref([start_link/0]).

-define(SERVER, ?MODULE).

-define(INTERVAL, 1000).

-record(state, {name,
                port}).



%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

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
init([]) ->
    {Name, _, _} = chunter_server:host_info(),
    lager:info("chunter:zonemon - initializing: ~s", [Name]),
    Zonemon = code:priv_dir(chunter) ++ "/zonemon.sh",
    timer:send_interval(dflt_env(zonemon_interval, ?INTERVAL), zonecheck),
    PortOpts = [exit_status, use_stdio, binary, {line, 1000}],
    ZonePort = erlang:open_port({spawn, Zonemon}, PortOpts),
    lager:info("chunter:zonemon - stats watchdog started.", []),
    {ok, #state{
            name=Name,
            port=ZonePort
           }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_cast(_Msg, State) ->
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
handle_info(zonecheck, State) ->
    [chunter_vm_fsm:force_state(UUID, simplifie_state(VMState)) ||
        [ID,_Name,VMState,_Path,UUID,_Type,_IP,_SomeNumber] <-
            [ re:split(Line, ":")
              || Line <- re:split(os:cmd("/usr/sbin/zoneadm list -ip"), "\n")],
        ID =/= <<"0">>],
    {noreply, State};


handle_info({_Port, {data, {eol, Data}}}, #state{name=_Name, port=_Port} = State) ->
    case parse_data(Data) of
        {error, unknown} ->
            %%       statsderl:increment([Name, ".vm.zonewatchdog_error"], 1, 1),
            lager:error("watchdog:zone - unknwon message: ~p", [Data]);
        {_UUID, <<"crate">>} ->
            %%       statsderl:increment([Name, ".vm.create"], 1, 1),
            %%chunter_vm_fsm:load(UUID);
            ok;
        {UUID, Action} ->
            %%       statsderl:increment([Name, ".vm.", UUID, ".state_change"], 1, 1),
            chunter_vm_fsm:transition(UUID, simplifie_state(Action))
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
terminate(_Reason, #state{port=Zport}) ->
    erlang:port_close(Zport),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec simplifie_state(OriginalState::binary()) -> fifo:vm_state().

simplifie_state(<<"installed">>) ->
    <<"stopped">>;
simplifie_state(<<"uninitialized">>) ->
    <<"stopped">>;
simplifie_state(<<"initialized">>) ->
    <<"booting">>;
simplifie_state(<<"ready">>) ->
    <<"booting">>;
simplifie_state(<<"booting">>) ->
    <<"booting">>;
simplifie_state(<<"running">>) ->
    <<"running">>;
simplifie_state(<<"shutting_down">>) ->
    <<"shutting_down">>;
simplifie_state(<<"empty">>) ->
    <<"shutting_down">>;
simplifie_state(<<"down">>) ->
    <<"shutting_down">>;
simplifie_state(<<"dying">>) ->
    <<"shutting_down">>;
simplifie_state(<<"dead">>) ->
    <<"stopped">>.

-spec parse_data(binary()) -> {UUID::fifo:uuid(), State::binary()} | {error, unknown}.

parse_data(<<"S00: ", UUID/binary>>) ->
    {UUID, <<"uninitialized">>};
parse_data(<<"S01: ", UUID/binary>>) ->
    {UUID, <<"initialized">>};
parse_data(<<"S02: ", UUID/binary>>) ->
    {UUID, <<"ready">>};
parse_data(<<"S03: ", UUID/binary>>) ->
    {UUID, <<"booting">>};
parse_data(<<"S04: ", UUID/binary>>) ->
    {UUID, <<"running">>};
parse_data(<<"S05: ", UUID/binary>>) ->
    {UUID, <<"shutting_down">>};
parse_data(<<"S06: ", UUID/binary>>) ->
    {UUID, <<"empty">>};
parse_data(<<"S07: ", UUID/binary>>) ->
    {UUID, <<"down">>};
parse_data(<<"S08: ", UUID/binary>>) ->
    {UUID, <<"dying">>};
parse_data(<<"S09: ", UUID/binary>>) ->
    {UUID, <<"dead">>};
parse_data(<<"S10: ", UUID/binary>>) ->
    {UUID, <<"uninitialized">>};
parse_data(<<"S11: ", UUID/binary>>) ->
    {UUID, <<"creating">>};
parse_data(<<"S12: ", UUID/binary>>) ->
    {UUID, <<"destroying">>};
parse_data(_) ->
    {error, unknown}.

dflt_env(N, D) ->
    case application:get_env(N) of
        undefined ->
            D;
        {ok, V} ->
            V
    end.
