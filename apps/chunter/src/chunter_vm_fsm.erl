%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 30 Oct 2012 by Heinz Nikolaus Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(chunter_vm_fsm).

-behaviour(gen_fsm).

%% API
-export([start_link/1]).
-ignore_xref([start_link/1,
              initialized/2,
              creating/2,
              loading/2,
              stopped/2,
              booting/2,
              running/2,
              shutting_down/2]).

-export([create/4,
         load/1,
         delete/1,
         remove/1,
         transition/2,
         update/3,
         snapshot/2,
         delete_snapshot/2,
         rollback_snapshot/2,
         force_state/2]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         console_send/2,
         console_link/2,
         code_change/4]).

%% This functions have to be exported but are only used internally.
-export([initialized/2,
         creating/2,
         loading/2,
         stopped/2,
         booting/2,
         running/2,
         shutting_down/2]).

-define(SERVER, ?MODULE).

-record(state, {hypervisor, type, uuid, console, listeners = []}).

%%%===================================================================
%%% API
%%%===================================================================

-spec create(UUID::fifo:uuid(), PackageSpec::fifo:package(),
             DatasetSpec::fifo:dataset(), VMSpec::fifo:config()) ->
                    ok.

create(UUID, PackageSpec, DatasetSpec, VMSpec) ->
    start_link(UUID),
    gen_fsm:send_event({global, {vm, UUID}}, {create, PackageSpec, DatasetSpec, VMSpec}).

update(UUID, Package, Config) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, {update, Package, Config}).

-spec load(UUID::fifo:uuid()) -> ok.

load(UUID) ->
    case global:whereis_name({vm, UUID}) of
        undefined ->
            start_link(UUID),
            gen_fsm:send_event({global, {vm, UUID}}, load);
        _ ->
            register(UUID)
    end.

-spec transition(UUID::fifo:uuid(), State::fifo:vm_state()) -> ok.

transition(UUID, State) ->
    gen_fsm:send_event({global, {vm, UUID}}, {transition, State}).

-spec delete(UUID::fifo:uuid()) -> ok.

delete(UUID) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, delete).

-spec remove(UUID::fifo:uuid()) -> ok.

remove(UUID) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, remove).

-spec force_state(UUID::fifo:uuid(), State::fifo:vm_state()) -> ok.

force_state(UUID, State) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, {force_state, State}).

-spec register(UUID::fifo:uuid()) -> ok.

register(UUID) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, register).

snapshot(UUID, SnapID) ->
    gen_fsm:sync_send_all_state_event({global, {vm, UUID}}, {snapshot, SnapID}).

delete_snapshot(UUID, SnapID) ->
    gen_fsm:sync_send_all_state_event({global, {vm, UUID}}, {snapshot, delete, SnapID}).

rollback_snapshot(UUID, SnapID) ->
    gen_fsm:sync_send_all_state_event({global, {vm, UUID}}, {snapshot, rollback, SnapID}).

console_send(UUID, Data) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, {console, send, Data}).

console_link(UUID, Pid) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, {console, link, Pid}).

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(UUID) ->
    gen_fsm:start_link({global, {vm, UUID}}, ?MODULE, [UUID], []).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init([UUID]) ->
    {Hypervisor, _} = chunter_server:host_info(),
    libsniffle:vm_register(UUID, Hypervisor),
    timer:send_interval(900000, update_snapshots), % This is every 15 minutes
    snapshot_sizes(UUID),
    zdoor:open(UUID, "_joyent_sshd_key_is_authorized"),
    {ok, initialized, #state{uuid = UUID, hypervisor = Hypervisor}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same
%% name as the current state name StateName is called to handle
%% the event. It is also called if a timeout occurs.
%%
%% @spec state_name(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------

-spec initialized(Action::load |
                          {create,  PackageSpec::fifo:package(),
                           DatasetSpec::fifo:dataset(), VMSpec::fifo:config()}, State::term()) ->
                         {next_state, loading, State::term()} |
                         {next_state, creating, State::term()} |
                         {next_state, initialized, State::term()}.

initialized(load, State) ->
    {next_state, loading, State};

initialized({create, PackageSpec, DatasetSpec, VMSpec},
            State=#state{hypervisor = Hypervisor, uuid=UUID}) ->
    {ok, DatasetUUID} = jsxd:get(<<"dataset">>, DatasetSpec),
    VMData = chunter_spec:to_vmadm(PackageSpec, DatasetSpec, jsxd:set(<<"uuid">>, UUID, VMSpec)),
    eplugin:call('vm:create', UUID, VMData),
    SniffleData  = chunter_spec:to_sniffle(VMData),
    {ok, Ram} = jsxd:get(<<"ram">>, PackageSpec),
    chunter_server:reserve_mem(Ram),
    SniffleData1 = jsxd:set(<<"ram">>, Ram, SniffleData),
    change_state(UUID, <<"installing_dataset">>),
    libhowl:send(UUID, [{<<"event">>, <<"update">>},
                        {<<"data">>,
                         [{<<"hypervisor">>, Hypervisor},
                          {<<"config">>, SniffleData1}]}]),
    libsniffle:vm_set(UUID, [{<<"config">>, SniffleData1}]),
    install_image(DatasetUUID),
    spawn(chunter_vmadm, create, [VMData]),
    change_state(UUID, <<"creating">>),
    {next_state, creating, State};

initialized(_, State) ->
    {next_state, initialized, State}.

-spec creating({transition, NextState::fifo:vm_state()}, State::term()) ->
                      {next_state, atom(), State::term()}.

creating({transition, NextState}, State) ->
    change_state(State#state.uuid, NextState),
    {next_state, binary_to_atom(NextState), State}.

-spec loading({transition, NextState::fifo:vm_state()}, State::term()) ->
                     {next_state, atom(), State::term()}.

loading({transition, NextState}, State) ->
    libsniffle:vm_set(State#state.uuid, <<"state">>, NextState),
    {next_state, binary_to_atom(NextState), State}.

-spec stopped({transition, NextState::fifo:vm_state()}, State::term()) ->
                     {next_state, atom(), State::term()}.

stopped({transition, NextState = <<"booting">>}, State) ->
    change_state(State#state.uuid, NextState),
    {next_state, binary_to_atom(NextState), State};

stopped(start, State) ->
    chunter_vmadm:start(State#state.uuid),
    {next_state, stopped, State};

stopped(_, State) ->
    {next_state, stopped, State}.

-spec booting({transition, NextState::fifo:vm_state()}, State::term()) ->
                     {next_state, atom(), State::term()}.

booting({transition, NextState = <<"shutting_down">>}, State) ->
    change_state(State#state.uuid, NextState),
    {next_state, binary_to_atom(NextState), State};

booting({transition, NextState = <<"running">>}, State) ->
    change_state(State#state.uuid, NextState),
    timer:send_after(500, get_info),
    {next_state, binary_to_atom(NextState), State};

booting(_, State) ->
    {next_state, booting, State}.

-spec running({transition, NextState::fifo:vm_state()}, State::term()) ->
                     {next_state, atom(), State::term()}.

running({transition, NextState = <<"shutting_down">>}, State) ->
    change_state(State#state.uuid, NextState),
    {next_state, binary_to_atom(NextState), State};

running(_, State) ->
    {next_state, running, State}.

-spec shutting_down({transition, NextState::fifo:vm_state()}, State::term()) ->
                           {next_state, atom(), State::term()}.

shutting_down({transition, NextState = <<"stopped">>}, State) ->
    change_state(State#state.uuid, NextState),
    {next_state, binary_to_atom(NextState), State};

shutting_down(_, State) ->
    {next_state, shutting_down, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/[2,3], the instance of this function with
%% the same name as the current state name StateName is called to
%% handle the event.
%%
%% @spec state_name(Event, From, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------

-spec handle_event({force_state, NextState::fifo:vm_state()},
                   StateName::atom(),
                   State::term()) ->
                          {next_state, NextStateName::fifo:vm_state_atom(), NextState::term()} |
                          {stop, Reason::term(), NewState::term()}.

handle_event({force_state, NextState}, StateName, State) ->
    case binary_to_atom(NextState) of
        StateName ->
            {next_state, StateName, State};
        running = N ->
            timer:send_after(500, get_info),
            change_state(State#state.uuid, NextState, StateName =:= N),
            {next_state, running, State};
        Other ->
            change_state(State#state.uuid, NextState, StateName =:= Other),
            {next_state, Other, State}
    end;

handle_event(register, StateName, State = #state{uuid = UUID}) ->
    libsniffle:vm_register(UUID, State#state.hypervisor),
    %%    change_state(State#state.uuid, atom_to_binary(StateName)),
    case load_vm(UUID) of
        {error, not_found} ->
            {stop, not_found, State};
        VMData ->
            snapshot_sizes(UUID),
            timer:send_after(500, get_info),
            SniffleData = chunter_spec:to_sniffle(VMData),
            libhowl:send(UUID, [{<<"event">>, <<"update">>},
                                {<<"data">>,
                                 [{<<"config">>, SniffleData}]}]),
            libsniffle:vm_set(UUID, [{<<"state">>, atom_to_binary(StateName)},
                                     {<<"config">>, SniffleData}]),
            {next_state, StateName, State}
    end;

handle_event({update, Package, Config}, StateName,
             State = #state{uuid = UUID}) ->
    case load_vm(UUID) of
        {error, not_found} ->
            {stop, not_found, State};
        VMData ->
            Update = chunter_spec:create_update(VMData, Package, Config),
            chunter_vmadm:update(UUID, Update),
            case load_vm(UUID) of
                {error, not_found} ->
                    {stop, not_found, State};
                VMData1 ->
                    chunter_server:update_mem(),
                    SniffleData = chunter_spec:to_sniffle(VMData1),
                    libsniffle:vm_set(UUID, [{<<"config">>, SniffleData}]),
                    libsniffle:vm_log(UUID, <<"Update complete.">>),
                    libhowl:send(UUID, [{<<"event">>, <<"update">>},
                                        {<<"data">>,
                                         [{<<"package">>, jsxd:get(<<"uuid">>, <<"-">>, Package)},
                                          {<<"config">>, SniffleData}]}]),
                    {next_state, StateName, State}
            end
    end;

handle_event(remove, _StateName, State) ->
    libsniffle:vm_unregister(State#state.uuid),
    {stop, normal, State};

handle_event(delete, StateName, State) ->
    case load_vm(State#state.uuid) of
        {error, not_found} ->
            {stop, not_found, State};
        _VM ->
            spawn(chunter_vmadm, delete, [State#state.uuid]),
            libhowl:send(State#state.uuid, [{<<"event">>, <<"delete">>}]),
            {next_state, StateName, State}
    end;

handle_event({console, send, Data}, StateName, State = #state{console = C}) when is_port(C) ->
    port_command(C, Data),
    {next_state, StateName, State};

handle_event({console, link, Pid}, StateName, State = #state{console = C, listeners = Ls}) when is_port(C) ->
    {next_state, StateName, State#state{listeners = [Pid | Ls]}};

handle_event({console, send, _Data}, StateName, State) ->
    {next_state, StateName, State};

handle_event({console, link, _Pid}, StateName, State) ->
    {next_state, StateName, State};

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_sync_event({snapshot, UUID}, _From, StateName, State) ->
    {reply, snapshot_action(State#state.uuid, UUID, fun do_snapshot/2), StateName, State};

handle_sync_event({snapshot, delete, UUID}, _From, StateName, State) ->
    {reply, snapshot_action(State#state.uuid, UUID, fun do_delete_snapshot/2), StateName, State};

handle_sync_event({snapshot, rollback, UUID}, _From, StateName, State) ->
    {reply, snapshot_action(State#state.uuid, UUID, fun do_rollback_snapshot/2), StateName, State};

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------


handle_info({C, {data, Data}}, StateName, State = #state{console = C,
                                                         listeners = Ls}) ->
    Ls1 = [ L || L <- Ls, is_process_alive(L)],
    [ L ! {data, Data} || L <- Ls1],
    {next_state, StateName, State#state{listeners = Ls1}};

handle_info({zdoor, Req, Data}, StateName,
            State = #state{
                       uuid = UUID
                      }) ->
    io:format("~s~n", [Data]),
    case re:split(Data, " ") of
        [User, _, KeyID] ->
            lager:warning("[zonedoor:~s] User ~s trying to connect with key ~s",
                          [UUID, User, KeyID]),
            KeyBin = libsnarl:keystr_to_id(KeyID),
            case libsnarl:user_key_find(KeyBin) of
                {ok, UserID} ->
                    case libsnarl:allowed(UserID, [<<"vms">>, UUID, <<"console">>]) orelse
                        libsnarl:allowed(UserID, [<<"vms">>, UUID, <<"ssh">>, User]) of
                        true ->
                            lager:warning("[zonedoor:~s] granted.", [UUID]),
                            zdoor:reply(Req, <<"1\n">>);
                        _ ->
                            lager:warning("[zonedoor:~s] denied.", [UUID]),
                            zdoor:reply(Req, <<"0\n">>)
                    end;
                _ ->
                    lager:warning("[zonedoor:~s] denied.", [UUID]),
                    zdoor:reply(Req, <<"0\n">>)
            end;
        _ ->
            lager:warning("[zonedoor:~s] can't parse auth request: ~s.", [UUID, Data]),
            ok
    end,
    {next_state, StateName, State};

handle_info({_C,{exit_status,1}}, StateName,
            State = #state{
                       console = _C,
                       type = zone
                      }) ->
    timer:send_after(1000, init_console),
    {next_state, StateName, State};

handle_info(update_snapshots, StateName, State) ->
    snapshot_sizes(State#state.uuid),
    {next_state, StateName, State};

handle_info(get_info, StateName, State) ->
    Info = chunter_vmadm:info(State#state.uuid),
    State1 = init_console(State),
    libsniffle:vm_set(State#state.uuid, <<"info">>, Info),
    {next_state, StateName, State1};

handle_info(init_console, StateName, State) ->
    {next_state, StateName, init_console(State)};

handle_info(Info, StateName, State) ->
    lager:warning("unknown data: ~p", [Info]),
    {next_state, StateName, State}.

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
terminate(_Reason, _StateName, State) ->
    lager:warning("Terminating vm fsm."),
    case erlang:port_info(State#state.console) of
        undefined ->
            lager:warning("console not running"),
            ok;
        _ ->
            port_close(State#state.console)
    end,
    zdoor:cose(State#state.uuid, "_joyent_sshd_key_is_authorized"),
    ok.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

init_console(State = #state{console = _C}) when is_port(_C) ->
    State;

init_console(State) ->
    [{_, Name, _, _, _, _}] = zoneadm(State#state.uuid),
    Console = code:priv_dir(chunter) ++ "/runpty /usr/sbin/zlogin -C " ++ binary_to_list(Name),
    ConsolePort = open_port({spawn, Console}, [binary]),
    State#state{console = ConsolePort}.

-spec install_image(DatasetUUID::fifo:uuid()) -> ok | string().

install_image(DatasetUUID) ->
    lager:debug("Installing dataset ~s.", [DatasetUUID]),
    Path = filename:join(<<"/zones">>, DatasetUUID),
    lager:debug("Checking path ~s.", [Path]),
    case os:cmd("zfs list zones/" ++ binary_to_list(DatasetUUID) ++">/dev/null; echo $?") of
        "0\n" ->
            lager:debug("found.", []),
            ok;
        _ ->
            {ok, Parts} = libsniffle:img_list(DatasetUUID),
            [Idx | Parts1] = lists:sort(Parts),
            {Cmd, B} = case libsniffle:img_get(DatasetUUID, Idx) of
                           {ok, <<31:8, 139:8, _/binary>> = AB} ->
                               {code:priv_dir(chunter) ++ "/zfs_receive.gzip.sh", AB};
                           {ok, <<"BZh", _/binary>> = AB} ->
                               {code:priv_dir(chunter) ++ "/zfs_receive.bzip2.sh", AB}
                       end,
            lager:debug("not found going to run: ~s ~s.", [Cmd, DatasetUUID]),
            Port = open_port({spawn_executable, Cmd},
                             [{args, [DatasetUUID]}, use_stdio, binary,
                              stderr_to_stdout, exit_status]),
            port_command(Port, B),
            lager:debug("We have the following parts: ~p.", [Parts1]),
            write_image(Port, DatasetUUID, Parts1, 0)
    end.

write_image(Port, UUID, [Idx|_], 2) ->
    lager:debug("<IMG> ~p import failed at chunk ~p.", [UUID, Idx]),
    port_close(Port),
    {error, retries_exceeded};

write_image(Port, UUID, [Idx|R], Retry) ->
    lager:debug("<IMG> ~s[~p]", [UUID, Idx]),
    case libsniffle:img_get(UUID, Idx) of
        {ok, B} ->
            port_command(Port, B),
            write_image(Port, UUID, R, 0);
        _ ->
            lager:warning("<IMG> ~p[~p]: retry!", [UUID, Idx]),
            timer:sleep(1000),
            write_image(Port, UUID, [Idx|R], Retry+1)
    end;

write_image(Port, UUID, [], _) ->
    lager:debug("<IMG> done, going to wait for zfs to finish now.", []),
    port_close(Port),
    UUIDL = binary_to_list(UUID),
    %% We need to satisfy imgadm *shakes fist* this seems to be a minimal
    %% manifest that is enough to not make it throw up.

    {ok, DS} = libsniffle:dataset_get(UUID),
    Manifest = jsxd:from_list([{<<"manifest">>,
                                [{<<"v">>, 2},
                                 {<<"uuid">>, UUID},
                                 {<<"disabled">>, false},
                                 {<<"type">>, <<"zvol">>},
                                 {<<"state">>, <<"active">>}]},
                               {<<"zpool">>, <<"zones">>}]),
    %% Need to set the correct type
    Manifest1 = case jsxd:get([<<"type">>], DS) of
                    {ok, <<"zone">>} ->
                        jsxd:set([<<"manifest">>, <<"type">>],
                                 <<"zone-dataset">>, Manifest);
                    _ ->
                        Manifest
                end,
    %% and write it to zoneamd's new destination folder ...
    file:write_file("/var/imgadm/images/zones-" ++ UUIDL ++ ".json",
                    jsx:encode(Manifest1)),
    Cmd = "zfs list -Hp -t all -r  zones/" ++ UUIDL,

    wait_image(0, Cmd).


wait_image(N, Cmd) when N < 3 ->
    timer:sleep(5000),
    wait_image(length(re:split(os:cmd(Cmd), "\n")), Cmd);

wait_image(_, _) ->
    lager:debug("<IMG> done waiting.", []).

-spec zoneadm(ZUUID::fifo:uuid()) -> [{ID::binary(),
                                       Name::binary(),
                                       VMState::binary(),
                                       Path::binary(),
                                       UUID::binary(),
                                       Type::binary()}].

zoneadm(ZUUID) ->
    Zones = [ re:split(Line, ":")
              || Line <- re:split(os:cmd("/usr/sbin/zoneadm -u" ++
                                             binary_to_list(ZUUID) ++
                                             " list -p"), "\n")],
    [{ID, Name, VMState, Path, UUID, Type} ||
        [ID, Name, VMState, Path, UUID, Type, _IP, _SomeNumber] <- Zones].

-spec load_vm(ZUUID::fifo:uuid()) -> fifo:vm_config() | {error, not_found}.

load_vm(ZUUID) ->
    case [chunter_zoneparser:load([{<<"name">>,Name},
                                   {<<"state">>, VMState},
                                   {<<"zonepath">>, Path},
                                   {<<"type">>, Type}]) ||
             {_ID, Name, VMState, Path, _UUID, Type} <- zoneadm(ZUUID)] of
        [VM | _] ->
            VM;
        [] ->
            {error, not_found}
    end.

-spec change_state(UUID::binary(), State::fifo:vm_state()) -> ok.

change_state(UUID, State) ->
    change_state(UUID, State, true).

-spec change_state(UUID::binary(), State::fifo:vm_state(), true | false) -> ok.

change_state(UUID, State, true) ->
    libsniffle:vm_log(UUID, <<"Transitioning ", State/binary>>),
    libsniffle:vm_set(UUID, <<"state">>, State),
    libhowl:send(UUID, [{<<"event">>, <<"state">>}, {<<"data">>, State}]);

change_state(UUID, State, false) ->
    libsniffle:vm_set(UUID, <<"state">>, State),
    libhowl:send(UUID, [{<<"event">>, <<"state">>}, {<<"data">>, State}]).


-spec binary_to_atom(B::binary()) -> A::atom().
binary_to_atom(B) ->
    list_to_atom(binary_to_list(B)).

-spec atom_to_binary(I::binary()|atom()) -> A::binary().
atom_to_binary(B) when is_binary(B) ->
    B;
atom_to_binary(A) ->
    list_to_binary(atom_to_list(A)).

do_snapshot(Path, SnapID) ->
    <<_:1/binary, P/binary>> = Path,
    CmdB = <<"/usr/sbin/zfs snapshot ",
             P/binary, "@", SnapID/binary>>,
    Cmd = binary_to_list(CmdB),
    lager:info("Creating snapshot: ~s", [Cmd]),
    Port = open_port({spawn, Cmd}, [use_stdio, binary, {line, 1000},
                                    stderr_to_stdout, exit_status]),
    wait_for_port(Port, <<>>).

do_delete_snapshot(Path, SnapID) ->
    <<_:1/binary, P/binary>> = Path,
    CmdB = <<"/usr/sbin/zfs destroy ",
             P/binary, "@", SnapID/binary>>,
    Cmd = binary_to_list(CmdB),
    lager:info("Deleting snapshot: ~s", [Cmd]),
    Port = open_port({spawn, Cmd}, [use_stdio, binary, {line, 1000},
                                    stderr_to_stdout, exit_status]),
    wait_for_port(Port, <<>>).

do_rollback_snapshot(Path, SnapID) ->
    <<_:1/binary, P/binary>> = Path,
    CmdB = <<"/usr/sbin/zfs rollback -r ",
             P/binary, "@", SnapID/binary>>,
    Cmd = binary_to_list(CmdB),
    lager:info("Rolling back snapshot: ~s", [Cmd]),
    Port = open_port({spawn, Cmd}, [use_stdio, binary, {line, 1000},
                                    stderr_to_stdout, exit_status]),
    wait_for_port(Port, <<>>).

wait_for_port(Port, Reply) ->
    receive
        {Port, {data, {eol, Data}}} ->
            wait_for_port(Port, <<Reply/binary, Data/binary>>);
        {Port, {data, Data}} ->
            wait_for_port(Port, <<Reply/binary, Data/binary>>);
        {Port,{exit_status, 0}} ->
            {ok, Reply};
        {Port,{exit_status, S}} ->
            {error, S, Reply}
    end.


snapshot_action(VM, UUID, Action) ->
    case load_vm(VM) of
        {error, not_found} ->
            ok;
        VMData ->
            Spec = chunter_spec:to_sniffle(VMData),
            case jsxd:get(<<"zonepath">>, Spec) of
                {ok, P} ->
                    case Action(P, UUID) of
                        {ok, Reply} ->
                            R = lists:foldl(
                                  fun (Disk, {S, Reply0}) ->
                                          case jsxd:get(<<"path">>, Disk) of
                                              {ok, <<_:14/binary, P1/binary>>} ->
                                                  case Action(P1, UUID) of
                                                      {ok, Res} ->
                                                          {S, <<Reply0/binary, "\n", Res/binary>>};
                                                      {error, Code, Res} ->
                                                          lager:error("Failed snapshot disk ~s from VM ~s ~p:~s.", [P1, VM, Code, Res]),
                                                          libsniffle:vm_log(
                                                            VM,
                                                            <<"Failed snapshot disk ", P1/binary, ": ", Reply/binary>>),
                                                          {error, <<Reply0/binary, "\n", Res/binary>>}
                                                  end;
                                              _ ->
                                                  {error, missing}
                                          end
                                  end, {ok, Reply},
                                  jsxd:get(<<"disks">>, [], Spec)),
                            case R of
                                {ok, Res} ->
                                    libsniffle:vm_log(VM,<<"Snapshot done ", Res/binary>>),
                                    ok;
                                {error, _} ->
                                    error
                            end;
                        {error, Code, Reply} ->
                            lager:error("Failed snapshot VM ~s ~p: ~s.",
                                        [VM, Code, Reply]),
                            libsniffle:vm_log(VM, <<"Failed to snapshot: ",
                                                    Reply/binary>>),
                            error
                    end;
                _ ->
                    lager:error("Failed to snapshot VM ~s.", [VM]),
                    libsniffle:vm_log(VM, <<"Failed snapshot: can't find zonepath.">>),
                    error
            end
    end.


snapshot_sizes(VM) ->
    case libsniffle:servers() of
        [] ->
            ok;
        _ ->
            {ok, V} = libsniffle:vm_get(VM),
            case jsxd:get([<<"snapshots">>], V) of
                {ok, S} ->
                    Data = os:cmd("/usr/sbin/zfs list -r -t snapshot -pH zones/"
                                  ++ binary_to_list(VM)),
                    Lines = [re:split(L, "\t") || L <-re:split(Data, "\n"),
                                                  L =/= <<>>],
                    Known = [ ID || {ID, _} <- S],
                    Snaps = [{lists:last(re:split(Name, "@")),
                              list_to_integer(binary_to_list(Size))}
                             || [Name, Size, _, _, _] <- Lines],
                    Snaps1 =lists:filter(fun ({Name, _}) ->
                                                 lists:member(Name, Known)
                                         end, Snaps),
                    [libsniffle:vm_set(
                       VM,
                       [<<"snapshots">>, Name, <<"size">>],
                       Size) || {Name, Size} <- Snaps1];
                _ ->
                    ok
            end
    end.
