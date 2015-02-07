%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 30 Oct 2012 by Heinz Nikolaus Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(chunter_vm_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_fsm).
-behaviour(ezdoor_behaviour).

%% API
-export([start_link/1, door_event/3]).
-ignore_xref([start_link/1,
              initialized/2,
              creating/2,
              loading/2,
              stopped/2,
              booting/2,
              running/2,
              restoring_backup/2,
              creating_backup/2,
              rolling_back_snapshot/2,
              creating_snapshot/2,
              deleting_snapshot/2,
              shutting_down/2]).

-export([create/4,
         load/1,
         delete/1,
         transition/2,
         update/3,
         backup/3,
         restore_backup/3,
         snapshot/2,
         delete_snapshot/2,
         delete_backup/2,
         rollback_snapshot/2,
         service_action/3,
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
         shutting_down/2,
         restoring_backup/2,
         creating_backup/2,
         rolling_back_snapshot/2,
         creating_snapshot/2,
         deleting_snapshot/2
        ]).

-record(state, {hypervisor,
                type = unknown,
                uuid,
                console,
                orig_state,
                args,
                services = [],
                listeners = [],
                nsq = false,
                public_state,
                auth_ref,
                api_ref}).

-define(AUTH_DOOR, "_joyent_sshd_key_is_authorized").
-define(API_DOOR, "_fifo").


%%%===================================================================
%%% API
%%%===================================================================

-spec create(UUID::fifo:uuid(), PackageSpec::fifo:package(),
             DatasetSpec::fifo:dataset(), VMSpec::fifo:config()) ->
                    ok.

create(UUID, PackageSpec, DatasetSpec, VMSpec) ->
    chunter_vm_sup:start_child(UUID),
    gen_fsm:send_event({global, {vm, UUID}}, {create, PackageSpec, DatasetSpec, VMSpec}).

update(UUID, Package, Config) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, {update, Package, Config}).

-spec load(UUID::fifo:uuid()) -> ok.

load(UUID) ->
    case global:whereis_name({vm, UUID}) of
        undefined ->
            chunter_vm_sup:start_child(UUID),
            gen_fsm:send_event({global, {vm, UUID}}, load);
        _ ->
            ok
    end,
    register(UUID).

-spec transition(UUID::fifo:uuid(), State::fifo:vm_state()) -> ok.

transition(UUID, State) ->
    gen_fsm:send_event({global, {vm, UUID}}, {transition, State}).

-spec delete(UUID::fifo:uuid()) -> ok.

delete(UUID) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, delete).

-spec force_state(UUID::fifo:uuid(), State::fifo:vm_state()) -> ok.

force_state(UUID, State) ->
    case global:whereis_name({vm, UUID}) of
        undefined ->
            chunter_vm_sup:start_child(UUID),
            gen_fsm:send_event({global, {vm, UUID}}, load),
            register(UUID);
        _ ->
            gen_fsm:send_all_state_event({global, {vm, UUID}}, {force_state, State})
    end.


-spec register(UUID::fifo:uuid()) -> ok.

register(UUID) ->
    gen_fsm:send_all_state_event({global, {vm, UUID}}, register).

restore_backup(UUID, SnapID, Options) ->
    case global:whereis_name({vm, UUID}) of
        undefined ->
            chunter_vm_sup:start_child(UUID),
            gen_fsm:send_event({global, {vm, UUID}},
                               {restore, SnapID, Options});
        _ ->
            gen_fsm:sync_send_all_state_event(
              {global, {vm, UUID}}, {backup, restore, SnapID, Options})
    end.

door_event(Pid, Ref, down) ->
    gen_fsm:send_all_state_event(Pid, {door, Ref, down});

door_event(Pid, Ref, Data) ->
    gen_fsm:sync_send_all_state_event(Pid, {door, Ref, Data}).


service_action(UUID, Action, Service)
  when Action =:= enable;
       Action =:= disable;
       Action =:= clear ->
    gen_fsm:sync_send_all_state_event({global, {vm, UUID}},
                                      {service, Action, Service}).

backup(UUID, SnapID, Options) ->
    gen_fsm:sync_send_all_state_event({global, {vm, UUID}}, {backup, SnapID, Options}).

delete_backup(UUID, SnapID) ->
    gen_fsm:sync_send_all_state_event({global, {vm, UUID}}, {backup, delete, SnapID}).

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

%% start_debug_link(UUID) ->
%%     F = <<"/var/db/chunter/trace.", UUID/binary, ".log">>,
%%     FileName = binary_to_list(F),
%%     gen_fsm:start_link({global, {vm, UUID}}, ?MODULE, [UUID],
%%                        [{debug,[trace, log, {log_to_file, FileName}]}]).

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
    process_flag(trap_exit, true),
    {Hypervisor, _, _} = chunter_server:host_info(),
    ls_vm:register(UUID, Hypervisor),
    SnapshotIVal = application:get_env(chunter, snapshot_update_interval, 900000),
    ServiceIVal = application:get_env(chunter, update_services_interval, 10000),
    timer:send_interval(SnapshotIVal, update_snapshots), % This is every 15 minutes
    timer:send_interval(ServiceIVal, update_services),  % This is every 10 seconds
    %% timer:send_interval(1000, {init, zonedoor}),  % Check Zonedoor status every second don't need this any longer?
    snapshot_sizes(UUID),
    NSQ = case application:get_env(nsq_producer) of
              {ok, _} ->
                  true;
              _ ->
                  false
          end,
    {ok, initialized, #state{uuid = UUID, hypervisor = Hypervisor, nsq = NSQ}}.

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

initialized({create, Package, Dataset, VMSpec},
            State=#state{hypervisor = Hypervisor, uuid=UUID}) ->
    PackageSpec = ft_package:to_json(Package),
    DatasetSpec = ft_dataset:to_json(Dataset),
    {ok, DatasetUUID} = jsxd:get(<<"uuid">>, DatasetSpec),
    VMData = chunter_spec:to_vmadm(PackageSpec, DatasetSpec, jsxd:set(<<"uuid">>, UUID, VMSpec)),
    VMData1 = eplugin:fold('vm:create_json', VMData),
    lager:debug("Creating with spec: ~p", [VMData1]),
    eplugin:call('vm:create', UUID, VMData1),
    SniffleData  = chunter_spec:to_sniffle(VMData1),
    {ok, Ram} = jsxd:get(<<"ram">>, PackageSpec),
    chunter_server:reserve_mem(Ram),
    SniffleData1 = jsxd:set(<<"ram">>, Ram, SniffleData),
    change_state(UUID, <<"installing_dataset">>),
    libhowl:send(UUID, [{<<"event">>, <<"update">>},
                        {<<"data">>,
                         [{<<"hypervisor">>, Hypervisor},
                          {<<"config">>, SniffleData1},
                          {<<"package">>, jsxd:get(<<"uuid">>, <<>>, PackageSpec)}]}]),
    Type = case jsxd:get(<<"type">>, SniffleData1) of
               {ok, <<"kvm">>} -> kvm;
               _ -> zone
           end,
    ls_vm:set_config(UUID, SniffleData1),
    lager:debug("[create:~s] Done generating config, handing to img install.",
                [UUID]),
    case chunter_dataset_srv:install(DatasetUUID, UUID) of
        ok ->
            lager:debug("[create:~s] Done installing image going to create now.",
                        [UUID]),
            case chunter_vmadm:create(VMData1) of
                ok ->
                    lager:debug("[create:~s] Done creating continuing on.", [UUID]),
                    case jsxd:get(<<"owner">>, VMSpec) of
                        {ok, Org} when Org =/= <<>> ->
                            ls_org:resource_action(Org, UUID, timestamp(),
                                                   confirm_create, []);
                        _ ->
                            ok
                    end,
                    {next_state, creating,
                     State#state{type = Type,
                                 public_state = change_state(UUID, <<"creating">>)}};
                {error, E} ->
                    lager:error("[create:~s] Failed to create with error: ~p",
                                [UUID, E]),
                    change_state(UUID, <<"failed">>),
                    {stop, normal, State}
            end;
        E ->
			lager:error("[create:~s] Dataset import failed with: ~p",
						[UUID, E]),
			change_state(UUID, <<"failed">>),
            {stop, normal, State}
    end;

initialized({restore, SnapID, Options},
            State=#state{uuid=VM}) ->
    {ok, VMObj} = ls_vm:get(VM),
    Remote = ft_vm:backups(VMObj),
    case jsxd:get([SnapID, <<"xml">>], false, Remote) of
        true ->
            UUIDL = binary_to_list(VM),
            Conf = chunter_snap:mk_s3_conf(Options),
            Bucket = proplists:get_value(s3_bucket, Options),
            {ok, XML} = fifo_s3:download(Bucket, <<VM/binary, "/", SnapID/binary, ".xml">>, Conf),
            ok = file:write_file(<<"/etc/zones/", VM/binary, ".xml">>, XML),
            os:cmd("echo '" ++ UUIDL ++ ":installed:/zones/" ++ UUIDL ++ ":" ++ UUIDL ++ "' >> /etc/zones/index");
        false ->
            ok
    end,
    Local = chunter_snap:get(VM),
    case chunter_snap:restore_path(SnapID, Remote, Local) of
        {ok, Path} ->
            chunter_snap:describe_restore(Path),
            Toss0 =
                [S || {_, S, _} <- Path,
                      jsxd:get([S, <<"local">>], false, Remote)
                          =:= false],
            Toss = [T || T <- Toss0, T =/= SnapID],
            backup_update(VM, SnapID, <<"local">>, true),
            Type = case jsxd:get(<<"type">>, ft_vm:config(VMObj)) of
                       {ok, <<"kvm">>} -> kvm;
                       _ -> zone
                   end,
            State1 = State#state{orig_state=loading,
                                 type = Type,
                                 args={SnapID, Options, Path, Toss}},
            libhowl:send(<<"command">>,
                         [{<<"event">>, <<"vm-restored">>},
                          {<<"uuid">>, uuid:uuid4s()},
                          {<<"data">>,
                           [{<<"uuid">>, VM}]}]),

            {next_state, restoring_backup, State1, 0};
        E ->
            {next_state, E, initialized, State}
    end;

initialized(_, State) ->
    {next_state, initialized, State}.

-spec creating({transition, NextState::fifo:vm_state()}, State::term()) ->
                      {next_state, atom(), State::term()}.

creating({transition, NextState}, State = #state{uuid=UUID}) ->
    lager:debug("[creating:~s] Transitioning to state ~s.",
                [UUID, NextState]),
    R = chunter_lock:release(UUID),
    lager:debug("[creating:~s] Log released with: ~p.",
                [UUID, R]),
    {next_state, binary_to_atom(NextState),
     State#state{public_state = change_state(State#state.uuid, NextState)}}.

-spec loading({transition, NextState::fifo:vm_state()}, State::term()) ->
                     {next_state, atom(), State::term()}.

loading({transition, NextState}, State) ->
    {next_state, binary_to_atom(NextState), State#state{public_state = change_state(State#state.uuid, NextState, false)}}.

-spec stopped({transition, NextState::fifo:vm_state()}, State::term()) ->
                     {next_state, atom(), State::term()}.

stopped({transition, NextState = <<"booting">>}, State) ->
    {next_state, binary_to_atom(NextState), State#state{public_state = change_state(State#state.uuid, NextState)}};

stopped(start, State) ->
    chunter_vmadm:start(State#state.uuid),
    {next_state, stopped, State};

stopped(_, State) ->
    {next_state, stopped, State}.

-spec booting({transition, NextState::fifo:vm_state()}, State::term()) ->
                     {next_state, atom(), State::term()}.

booting({transition, NextState = <<"shutting_down">>}, State) ->
    {next_state, binary_to_atom(NextState),
     State#state{public_state = change_state(State#state.uuid, NextState)}};

booting({transition, NextState = <<"running">>}, State) ->
    timer:send_after(500, get_info),
    {next_state, binary_to_atom(NextState),
     State#state{public_state = change_state(State#state.uuid, NextState)}};

booting(_, State) ->
    {next_state, booting, State}.

-spec running({transition, NextState::fifo:vm_state()}, State::term()) ->
                     {next_state, atom(), State::term()}.

running({transition, NextState = <<"shutting_down">>}, State) ->
    {next_state, binary_to_atom(NextState),
     State#state{public_state = change_state(State#state.uuid, NextState)}};

running(_, State) ->
    {next_state, running, State}.

-spec shutting_down({transition, NextState::fifo:vm_state()}, State::term()) ->
                           {next_state, atom(), State::term()}.

shutting_down({transition, NextState = <<"stopped">>}, State) ->
    {next_state, binary_to_atom(NextState),
     State#state{public_state = change_state(State#state.uuid, NextState)}};

shutting_down(_, State) ->
    {next_state, shutting_down, State}.

restoring_backup(timeout, State =
                     #state{orig_state = NextState,
                            args = {SnapID, Options, Path, Toss},
                            uuid = VM}) ->
    [snapshot_action(VM, Snap, fun do_restore/4, Options)
     || Snap <- Path],
    [snapshot_action(VM, Snap, fun do_delete_snapshot/4,
                     fun finish_delete_snapshot/4, Options)
     || Snap <- Toss],
    libhowl:send(VM,
                 [{<<"event">>, <<"backup">>},
                  {<<"data">>,
                   [{<<"action">>, <<"restored">>},
                    {<<"uuid">>, SnapID}]}]),
    timer:send_after(500, get_info),
    %% The restored dataset does not have the correct quota,
    %% we reapply the package to make sure it is applied.
    {ok, V} = ls_vm:get(VM),
    Package = ft_vm:package(V),
    ls_vm:update(VM, Package, []),
    {next_state, NextState, State#state{orig_state=undefined, args={}}}.

creating_backup(timeout, State = #state{orig_state = NextState, uuid=VM,
                                        args={SnapID, Options}}) ->
    lager:debug("Creating Backup with options: ~p", [Options]),
    case proplists:is_defined(create, Options) of
        true ->
            lager:debug("New Snapshot: ~p", [SnapID]),
            snapshot_action(
              VM, SnapID, fun do_snapshot/4,
              fun finish_snapshot/4, [backup]);
        _ ->
            ok
    end,
    spawn(fun () ->
                  snapshot_action(VM, SnapID, fun do_backup/4,
                                  fun finish_backup/4, Options),
                  case proplists:get_value(delete, Options) of
                      true ->
                          lager:debug("Deleint snapshot: ~p", [SnapID]),
                          snapshot_action(VM, SnapID, fun do_delete_snapshot/4,
                                          fun finish_delete_snapshot/4, Options),
                          backup_update(VM, SnapID, <<"local">>, false);
                      parent ->
                          backup_update(VM, SnapID, <<"local">>, true),
                          case proplists:get_value(parent, Options) of
                              undefined ->
                                  lager:debug("Deleting parent but not defined."),
                                  ok;
                              Parent ->
                                  lager:debug("Deleting parent: ~p", [Parent]),
                                  snapshot_action(VM, Parent,
                                                  fun do_delete_snapshot/4,
                                                  fun finish_delete_snapshot/4,
                                                  Options),
                                  backup_update(VM, Parent, <<"local">>, false)
                          end;
                      undefined ->
                          backup_update(VM, SnapID, <<"local">>, true)
                  end
          end),
    {next_state, NextState, State#state{orig_state=undefined, args={}}}.


creating_snapshot(timeout, State = #state{orig_state = NextState,
                                          args={SnapID}}) ->
    snapshot_action(State#state.uuid, SnapID, fun do_snapshot/4,
                    fun finish_snapshot/4, []),
    {next_state, NextState, State#state{orig_state=undefined, args={}}}.

deleting_snapshot(timeout, State = #state{orig_state = NextState,
                                          args={SnapID}}) ->
    snapshot_action(State#state.uuid, SnapID, fun do_delete_snapshot/4,
                    fun finish_delete_snapshot/4, []),
    {next_state, NextState, State#state{orig_state=undefined, args={}}}.

rolling_back_snapshot(timeout, State = #state{orig_state = NextState,
                                              args={SnapID}}) ->
    snapshot_action(State#state.uuid, SnapID, fun do_rollback_snapshot/4,
                    fun finish_rollback_snapshot/4, []),
    {next_state, NextState, State#state{orig_state=undefined, args={}}}.

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
                          {next_state, NextStateName::fifo:vm_state_atom(),
                           NextState::term()} |
                          {stop, Reason::term(), NewState::term()}.

handle_event({force_state, NextState}, StateName, State) ->
    case binary_to_atom(NextState) of
        StateName
          when NextState =:= State#state.public_state ->
            {next_state, StateName, State};
        StateName ->
            {next_state, StateName, State#state{public_state = change_state(State#state.uuid, NextState, false)}};
        running = N ->
            {next_state, running,State#state{public_state = change_state(State#state.uuid, NextState, StateName =:= N)}};
        Other ->
            {next_state, Other, State#state{public_state = change_state(State#state.uuid, NextState, StateName =:= Other)}}
    end;

handle_event(register, StateName, State = #state{uuid = UUID}) ->
    ls_vm:register(UUID, State#state.hypervisor),
    %%    change_state(State#state.uuid, atom_to_binary(StateName)),
    case load_vm(UUID) of
        {error, not_found} ->
            lager:debug("[~s] Stopping in load, notfound.", [State#state.uuid]),
            {stop, not_found, State};
        VMData ->
            snapshot_sizes(UUID),
            timer:send_after(500, get_info),
            SniffleData = chunter_spec:to_sniffle(VMData),
            Type = case jsxd:get(<<"type">>, SniffleData) of
                       {ok, <<"kvm">>} -> kvm;
                       _ -> zone
                   end,
            lager:info("[~s] Has type: ~p.", [UUID, Type]),
            libhowl:send(UUID, [{<<"event">>, <<"update">>},
                                {<<"data">>,
                                 [{<<"config">>, SniffleData}]}]),
            ls_vm:set_config(UUID, SniffleData),
            State1 = State#state{type = Type},
            change_state(State1#state.uuid, atom_to_binary(StateName), false),
            {next_state, StateName, State1#state{services = []}}
    end;

handle_event({update, Package, Config}, StateName,
             State = #state{uuid = UUID}) ->
    case load_vm(UUID) of
        {error, not_found} ->
            lager:debug("[~s] Stopping in update, notfound.",
                        [State#state.uuid]),
            {stop, not_found, State};
        VMData ->
            P = case Package of
                    undefined ->
                        undefined;
                    _ ->
                        ft_package:to_json(Package)
                end,
            Update = chunter_spec:create_update(VMData, P, Config),
            case chunter_vmadm:update(UUID, Update) of
                ok ->
                    case load_vm(UUID) of
                        {error, not_found} ->
                            lager:debug("[~s] Stopping in load, notfound.",
                                        [State#state.uuid]),
                            {stop, not_found, State};
                        VMData1 ->
                            chunter_server:update_mem(),
                            SniffleData = chunter_spec:to_sniffle(VMData1),
                            ls_vm:set_config(UUID, SniffleData),
                            ls_vm:log(UUID, <<"Update complete.">>),
                            UodateData = case Package of
                                             undefined ->
                                                 [{<<"config">>, SniffleData}];
                                             _ ->
                                                 [{<<"package">>, ft_package:uuid(Package)},
                                                  {<<"config">>, SniffleData}]
                                         end,
                            libhowl:send(UUID, [{<<"event">>, <<"update">>},
                                                {<<"data">>, UodateData}]),
                            {next_state, StateName, State}
                    end;
                {error, E} ->
                    lager:error("[~s] updated failed with ~p", [UUID, E]),
                    ls_vm:log(UUID, <<"Update failed.">>),
                    {next_state, StateName, State}
            end
    end;

handle_event(remove, _StateName, State) ->
    lager:debug("[~s] Calling remove.", [State#state.uuid]),
    ls_vm:unregister(State#state.uuid),
    {stop, normal, State};

handle_event(delete, _StateName, State = #state{uuid = UUID}) ->
    lager:debug("[~s] Calling delete.", [State#state.uuid]),
    case load_vm(UUID) of
        {error, not_found} ->
            ok;
        _VM ->
            chunter_vmadm:delete(UUID),
            lager:info("Deleting ~s successfull, letting sniffle know.", [UUID]),
            ls_vm:delete(UUID)
    end,
    wait_for_delete(UUID),
    {stop, normal, State};

handle_event({console, send, Data}, StateName, State = #state{console = C}) when is_port(C) ->
    port_command(C, Data),
    {next_state, StateName, State};

handle_event({console, link, Pid}, StateName, State = #state{console = C, listeners = Ls}) when is_port(C) ->
    {next_state, StateName, State#state{listeners = [Pid | Ls]}};

handle_event({console, send, _Data}, StateName, State) ->
    {next_state, StateName, State};

handle_event({console, link, _Pid}, StateName, State) ->
    {next_state, StateName, State};

handle_event({door, _Ref, down}, StateName,
             State = #state{auth_ref=_Ref, uuid=UUID}) ->
    lager:warning("[vm:~s] auth door down!", [UUID]),
    timer:send_after(1000, {init, zonedoor}),
    {next_state, StateName, State#state{auth_ref = undefined}};

handle_event({door, _Ref, down}, StateName,
             State = #state{api_ref=_Ref, uuid=UUID}) ->
    lager:warning("[vm:~s] api door down!", [UUID]),
    timer:send_after(1000, {init, zonedoor}),
    {next_state, StateName, State#state{api_ref = undefined}};

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


handle_sync_event({door, Ref, Data}, _From, StateName,
             State = #state{auth_ref=Ref, uuid=UUID}) ->
    R = case auth_credintials(UUID, Data) of
            true ->
                <<"1">>;
            false ->
                <<"0">>
        end,
    {reply, {ok, R}, StateName, State};

handle_sync_event({door, Ref, Data}, _From, StateName,
             State = #state{api_ref=Ref, uuid=UUID}) ->
    lager:info("[zone:~s] API: ~s", [UUID, Data]),
    try jsx:decode(Data) of
        JSON ->
            JSON1 = jsxd:from_list(JSON),
            Reply = case chunter_api:call(UUID, JSON1) of
                        {ok, D} ->
                            Bin = jsx:encode(D),
                            {ok, <<$1, Bin/binary>>};
                        {error, E} ->
                            lager:warning("[zdoor] error: ~p", [E]),
                            RJSON = jsx:encode([{error, list_to_binary(E)}]),
                            {ok, <<$0, RJSON/binary>>}
                    end,
            {reply, Reply, StateName, State}
    catch
        _:_ ->
            lager:warning("[zdoor] error: ~p", [Data]),
            RJSON = jsx:encode([{error,  <<"format error: ", Data/binary>>}]),
            Reply = {ok, <<$0, RJSON/binary>>},
            {reply, Reply, StateName, State}
    end;

handle_sync_event({backup, restore, SnapID, Options}, _F, StateName, State) ->
    VM = State#state.uuid,
    {ok, VMObj} = ls_vm:get(VM),
    Remote = ft_vm:backups(VMObj),
    Local = chunter_snap:get(VM),
    case chunter_snap:restore_path(SnapID, Remote, Local) of
        {ok, Path} ->
            chunter_snap:describe_restore(Path),
            Toss0 =
                [S || {_, S, _} <- Path,
                      jsxd:get([S, <<"local">>], false, Remote)
                          =:= false],
            Toss = [T || T <- Toss0, T =/= SnapID],
            backup_update(VM, SnapID, <<"local">>, true),
            State1 = State#state{orig_state=StateName,
                                 args={SnapID, Options, Path, Toss}},
            {reply, ok, restoring_backup, State1, 0};
        E ->
            {reply, E, StateName, State}
    end;

handle_sync_event({backup, delete, SnapID}, _From, StateName, State) ->
    State1 = State#state{orig_state=StateName, args={SnapID}},
    backup_update(State#state.uuid, SnapID, <<"local">>, false),
    backup_update(State#state.uuid, SnapID, <<"local_size">>, 0),
    {reply, ok, deleting_snapshot, State1, 0};

handle_sync_event({service, enable, Service}, _From, StateName, State) ->
    {reply, smurf:enable(Service, [{zone, State#state.uuid}]), StateName, State, 0};

handle_sync_event({service, disable, Service}, _From, StateName, State) ->
    {reply, smurf:disable(Service, [{zone, State#state.uuid}]), StateName, State, 0};

handle_sync_event({service, clear, Service}, _From, StateName, State) ->
    {reply, smurf:clear(Service, [{zone, State#state.uuid}]), StateName, State, 0};

handle_sync_event({backup, SnapID, Options}, _From, StateName, State) ->
    State1 = State#state{orig_state=StateName, args={SnapID, Options}},
    {reply, ok, creating_backup, State1, 0};

handle_sync_event({snapshot, SnapID}, _From, StateName, State) ->
    State1 = State#state{orig_state=StateName,
                         args={SnapID}},
    {reply, ok, creating_snapshot, State1, 0};

handle_sync_event({snapshot, delete, SnapID}, _From, StateName, State) ->
    State1 = State#state{orig_state=StateName,
                         args={SnapID}},
    {reply, ok, deleting_snapshot, State1, 0};


handle_sync_event({snapshot, rollback, SnapID}, _From, StateName, State) ->
    State1 = State#state{orig_state=StateName,
                         args={SnapID}},
    {reply, ok, rolling_back_snapshot, State1, 0};

handle_sync_event(delete, _From, StateName, State) ->
    case load_vm(State#state.uuid) of
        {error, not_found} ->
            lager:debug("[~s] Delete sync event.", [State#state.uuid]),
            {stop, not_found, State};
        _VM ->
            spawn(chunter_vmadm, delete, [State#state.uuid]),
            libhowl:send(State#state.uuid, [{<<"event">>, <<"delete">>}]),
            {reply, ok, StateName, State}
    end;

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


handle_info(update_snapshots, StateName, State = #state{uuid = UUID}) ->
    snapshot_sizes(UUID),
    {next_state, StateName, State};

handle_info({C, {data, Data}}, StateName, State = #state{console = C,
                                                         listeners = Ls}) ->
    Ls1 = [ L || L <- Ls, is_process_alive(L)],
    [ L ! {data, Data} || L <- Ls1],
    {next_state, StateName, State#state{listeners = Ls1}};

handle_info({_C,{exit_status, _}}, stopped,
            State = #state{console = _C, type=zone}) ->
    lager:warning("[console:~s] Exited but vm in stopped", [State#state.uuid]),
    {next_state, stopped, State};

handle_info({_C,{exit_status, Status}}, StateName,
            State = #state{console = _C, type=zone}) ->
    lager:warning("[console:~s] Exited with status: ~p",
                  [State#state.uuid, Status]),
    timer:send_after(1000, {init, console}),
    {next_state, StateName, State};

handle_info({'EXIT', _C, PosixCode}, stopped,
            State = #state{console = _C, type=zone}) ->
    lager:warning("[console:~s] Exited with status ~p but vm in stopped.",
                  [State#state.uuid, PosixCode]),
    {next_state, stopped, State};

handle_info({'EXIT', _C, PosixCode}, StateName,
            State = #state{console = _C, type=zone}) ->
    lager:warning("[console:~s] Exited with code: ~p",
                  [State#state.uuid, PosixCode]),
    timer:send_after(1000, {init, console}),
    {next_state, StateName, State};

handle_info({'EXIT', _D, _PosixCode}, StateName, State) ->
    {next_state, StateName, State};

handle_info(update_services, running, State=#state{
                                               uuid=UUID,
                                               nsq=NSQ,
                                               services = OldServices,
                                               type = zone
                                              }) ->
    case {chunter_smf:update(UUID, OldServices), OldServices} of
        {{ok, ServiceSet, Changed}, []} ->
            lager:debug("[~s] Initializing ~p Services.",
                        [UUID, length(Changed)]),
            ls_vm:set_service(UUID,
                              [{Srv, St}
                               || {Srv, _, St} <- Changed]),
            {next_state, running, State#state{services = ServiceSet}};
        {{ok, ServiceSet, Changed}, _} ->
            lager:debug("[~s] Updating ~p Services.",
                        [UUID, length(Changed)]),
            %% Update changes which are not removes
            ls_vm:set_service(UUID,
                              [{Srv, SrvState}
                               || {Srv, _, SrvState} <- Changed,
                                  SrvState =/= <<"removed">>]),
            %% Delete services that were changed.
            ls_vm:set_service(UUID,
                              [{Srv, delete}
                               || {Srv, _, <<"removed">>} <- Changed]),
            update_services(UUID, Changed, NSQ),
            {next_state, running, State#state{services = ServiceSet}};
        _ ->
            {next_state, running, State}
    end;

handle_info(update_services, StateName, State) ->
    {next_state, StateName, State};

handle_info(get_info, stopped, State) ->
    timer:send_after(1000, get_info),
    {next_state, stopped, State};

handle_info(get_info, StateName, State=#state{type=zone}) ->
    State1 = init_console(State),
    State2 = ensure_zonedoor(State1),
    {next_state, StateName, State2};

handle_info(get_info, StateName, State=#state{type=kvm}) ->
    case chunter_vmadm:info(State#state.uuid) of
        {error, no_info} ->
            timer:send_after(1000, get_info),
            {next_state, StateName, State};
        {ok, Info} ->
            ls_vm:set_info(State#state.uuid, Info),
            {next_state, StateName, State}
    end;

handle_info({init, _}, stopped, State) ->
    {next_state, stopped, State};

handle_info({init, console}, StateName, State=#state{type=zone}) ->
    {next_state, StateName, init_console(State)};

handle_info({init, zonedoor}, StateName, State=#state{type=zone}) ->
    {next_state, StateName, ensure_zonedoor(State)};

handle_info({init, _}, StateName, State) ->
    {next_state, StateName, State};

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

terminate(Reason, StateName,
          State = #state{uuid = UUID, auth_ref=AuthRef, api_ref=APIRef}) ->
    lager:warning("[terminate:~s] Terminating from ~p with reason ~p.",
                  [UUID, StateName, Reason]),
    lager:warning("[terminate:~s] The state: ~p .", [UUID, State]),
    case erlang:port_info(State#state.console) of
        undefined ->
            lager:debug("[terminate:~s] console not running.", [UUID]),
            ok;
        _ ->
            incinerate(State#state.console)
    end,
    ezdoor_server:remove(AuthRef),
    ezdoor_server:remove(APIRef),
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

incinerate(Port) ->
    {os_pid, OsPid} = erlang:port_info(Port, os_pid),
    port_close(Port),
    lager:warning("Killing ~p with -9", [OsPid]),
    os:cmd(io_lib:format("/usr/bin/kill -9 ~p", [OsPid])).

init_console(State) ->
    case erlang:port_info(State#state.console) of
        undefined ->
            [{_, Name, _, _, _, _}] = zoneadm(State#state.uuid),
            Console = code:priv_dir(chunter) ++ "/runpty /usr/sbin/zlogin -C " ++ binary_to_list(Name),
            ConsolePort = open_port({spawn, Console}, [binary]),
            State#state{console = ConsolePort};
        _ ->
            State
    end.

ensure_zonedoor(State) ->
    State1 = case ezdoor_server:add(?MODULE, State#state.uuid, ?AUTH_DOOR) of
                 {ok, AuthRef} ->
                     State#state{auth_ref = AuthRef};
                 {error, doublicate} ->
                     State
             end,
    case ezdoor_server:add(?MODULE, State1#state.uuid, ?API_DOOR) of
        {ok, APIRef} ->
            State1#state{api_ref = APIRef};
        {error, doublicate} ->
            State1
    end.



do_snapshot(<<_:1/binary, P/binary>>, _VM, SnapID, _) ->
    chunter_zfs:snapshot(P, SnapID).

finish_snapshot(_VM, _SnapID, [backup], ok) ->
    ok;
finish_snapshot(VM, SnapID, _, ok) ->
    ls_vm:set_snapshot(
      VM, [{[SnapID, <<"state">>],
            <<"completed">>}]),
    libhowl:send(VM,
                 [{<<"event">>, <<"snapshot">>},
                  {<<"data">>,
                   [{<<"action">>, <<"completed">>},
                    {<<"uuid">>, SnapID}]}]),
    ok;

finish_snapshot(_VM, _SnapID, _, error) ->
    error.

do_delete_snapshot(<<_:1/binary, P/binary>>, _VM, SnapID, _) ->
    chunter_zfs:destroy_snapshot(P, SnapID, [f, r]).

finish_delete_snapshot(VM, SnapID, _, ok) ->
    lager:debug("Deleting ~p", [SnapID]),
    ls_vm:set_snapshot(VM, [{[SnapID], delete}]),
    libhowl:send(VM,
                 [{<<"event">>, <<"snapshot">>},
                  {<<"data">>,
                   [{<<"action">>, <<"deleted">>},
                    {<<"uuid">>, SnapID}]}]),
    ok;

finish_delete_snapshot(_VM, _SnapID, _, error) ->
    error.

do_rollback_snapshot(<<_:1/binary, P/binary>>, _VM, SnapID, _) ->
    chunter_zfs:rollback(P, SnapID, [r]).

finish_rollback_snapshot(VM, SnapID, _, ok) ->
    libhowl:send(VM,
                 [{<<"event">>, <<"snapshot">>},
                  {<<"data">>,
                   [{<<"action">>, <<"rollback">>},
                    {<<"uuid">>, SnapID}]}]),
    lager:debug("[Snapshot] committing rollback fo snapshot ~s on VM ~s.", [VM, SnapID]),
    ls_vm:commit_snapshot_rollback(VM, SnapID);

finish_rollback_snapshot(_VM, _SnapID, _, error) ->
    lager:error("Snapshot rollback failed!"),
    error.

do_backup(Path, VM, SnapID, Options) ->
    chunter_snap:upload(Path, VM, SnapID, Options).

finish_backup(VM, UUID, Opts, ok) ->
    case proplists:is_defined(xml, Opts) of
        true ->
            Conf = chunter_snap:mk_s3_conf(Opts),
            Bucket = proplists:get_value(s3_bucket, Opts),
            {ok, XML} = file:read_file(
                          binary_to_list(<<"/etc/zones/", VM/binary, ".xml">>)),
            fifo_s3:upload(Bucket, <<VM/binary, "/", UUID/binary, ".xml">>, XML, Conf),
            backup_update(VM, UUID, <<"xml">>, true),
            ok;
        false ->
            ok
    end,
    backup_update(VM, UUID, <<"state">>, <<"completed">>);

finish_backup(_VM, _UUID, _, error) ->
    error.

snapshot_action_on_disks(VM, UUID, Fun, LastReply, Disks, Opts) ->
    lists:foldl(
      fun (_, {error, E}) ->
              {error, E};
          (Disk, {S, Reply0}) ->
              case jsxd:get(<<"path">>, Disk) of
                  {ok, <<_:14/binary, P1/binary>>} ->
                      case Fun(P1, VM, UUID, Opts) of
                          {ok, Res} ->
                              {S, <<Reply0/binary, "\n", Res/binary>>};
                          {ok, Res, _} ->
                              {S, <<Reply0/binary, "\n", Res/binary>>};
                          {error, Code, Res} ->
                              lager:error("Failed snapshot disk ~s from VM ~s ~p:~s.", [P1, VM, Code, Res]),
                              ls_vm:log(
                                VM,
                                <<"Failed snapshot disk ", P1/binary, ": ", Res/binary>>),
                              {error, <<Reply0/binary, "\n", Res/binary>>}
                      end;
                  _ ->
                      {error, <<"missing">>}
              end
      end, LastReply, Disks).

snapshot_action(VM, UUID, Fun, Opts) ->
    snapshot_action(VM, UUID, Fun, fun(_,_,_,_) -> ok end, Opts).

snapshot_action(VM, UUID, Fun, CompleteFun, Opts) ->
    case load_vm(VM) of
        {error, not_found} ->
            ok;
        VMData ->
            Spec = chunter_spec:to_sniffle(VMData),
            case jsxd:get(<<"zonepath">>, Spec) of
                {ok, P} ->
                    R = case Fun(P, VM, UUID, Opts) of
                            {ok, Rx, _} ->
                                {ok, Rx};
                            O ->
                                O
                        end,
                    case R of
                        {ok, _} = R0 ->
                            Disks = jsxd:get(<<"disks">>, [], Spec),
                            case snapshot_action_on_disks(VM, UUID, Fun, R0, Disks, Opts) of
                                {ok, Res} ->
                                    M = io_lib:format("Snapshot done: ~p",
                                                      [Res]),
                                    ls_vm:log(VM, iolist_to_binary(M)),
                                    CompleteFun(VM, UUID, Opts, ok);
                                {error, E} ->
                                    libhowl:send(VM,
                                                 [{<<"event">>, <<"snapshot">>},
                                                  {<<"data">>,
                                                   [{<<"action">>, <<"error">>},
                                                    {<<"message">>, list_to_binary(E)},
                                                    {<<"uuid">>, UUID}]}]),
                                    lager:error("Snapshot failed with: ~p", E),
                                    CompleteFun(VM, UUID, Opts, error)
                            end;
                        {error, Code, Reply} ->
                            lager:error("Failed snapshot VM ~s ~p: ~s.",
                                        [VM, Code, Reply]),
                            ls_vm:log(VM, <<"Failed to snapshot: ",
                                            Reply/binary>>),
                            CompleteFun(VM, UUID, Opts, error)
                    end;
                _ ->
                    lager:error("Failed to snapshot VM ~s.", [VM]),
                    ls_vm:log(VM, <<"Failed snapshot: can't find zonepath.">>),
                    error
            end
    end.

snapshot_sizes(VM) ->
    lager:info("[~s] Updating Snapshots.", [VM]),
    case {libsniffle:servers(), ls_vm:get(VM)} of
        {[], _} ->
            lager:warning("[~s] No Servers to update snapshots.", [VM]),
            ok;
        {_, {ok, V}} ->
            Snaps = case load_vm(VM) of
                        {error, not_found} ->
                            [];
                        VMData ->
                            Spec = chunter_spec:to_sniffle(VMData),
                            chunter_snap:get_all(VM, Spec)
                    end,
            %% First we look at backups
            Bs = ft_vm:backups(V),
            KnownB = [ ID || {ID, _} <- Bs],
            Backups1 = lists:filter(fun ({Name, _}) ->
                                            lists:member(Name, KnownB)
                                    end, Snaps),
            Local = [N || {N, _ } <- Backups1],
            NonLocal = lists:subtract(KnownB, Local),
            Bs1 = [{[Name, <<"local_size">>], Size}
                   || {Name, Size} <- Backups1] ++
                [{[Name, <<"local_size">>], 0}
                 || Name <- NonLocal],
            ls_vm:set_backup(VM, Bs1),

            %% And then at sanpshots
            Ss = ft_vm:snapshots(V),
            KnownS = [ ID || {ID, _} <- Ss],
            Snaps1 =lists:filter(fun ({Name, _}) ->
                                         lists:member(Name, KnownS)
                                 end, Snaps),
            FlatSnaps = [Name || {Name, _Size} <- Snaps],
            SnapsGone = lists:filter(fun (Name) ->
                                             not lists:member(Name, FlatSnaps)
                                      end, KnownS),
            Ss1 = [{[Name, <<"size">>], Size}
                   || {Name, Size} <- Snaps1],
            Ss2 = [{[Name], delete} || Name <- SnapsGone],
            ls_vm:set_snapshot(VM, Ss1 ++ Ss2);
        _ ->
            lager:warning("[~s] Could not read VM data.", [VM]),
            ok
    end.

do_restore(Path, VM, {local, SnapId}, Opts) ->
    do_rollback_snapshot(Path, VM, SnapId, Opts);
do_restore(Path, VM, {full, SnapId, SHA1}, Opts) ->
    do_destroy(Path, VM, SnapId, Opts),
    chunter_snap:download(Path, VM, SnapId, SHA1, Opts),
    wait_import(Path),
    do_rollback_snapshot(Path, VM, SnapId, Opts);
do_restore(Path, VM, {incr, SnapId, SHA1}, Opts) ->
    chunter_snap:download(Path, VM, SnapId, SHA1, Opts),
    wait_import(Path),
    do_rollback_snapshot(Path, VM, SnapId, Opts).

do_destroy(<<_:1/binary, P/binary>>, _VM, _SnapID, _) ->
    chunter_zfs:destroy(P, [f,r]).

%%%===================================================================
%%% Utility
%%%===================================================================

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

-spec change_state(UUID::binary(), State::fifo:vm_state()) -> fifo:vm_state().

change_state(UUID, State) ->
    change_state(UUID, State, true).

-spec change_state(UUID::binary(), State::fifo:vm_state(), boolean()) -> fifo:vm_state().

change_state(UUID, State, true) ->
    %% State1 = case filelib:is_file(<<"/zones/", UUID/binary, "/root/var/svc/provisioning">>) of
    %%              true ->
    %%                  <<"provisioning (", State/binary, ")">>;
    %%              false ->
    %%                  State
    %%          end,
    %% This will stay out untill someone provides a propper solution
    State1 = State,
    ls_vm:log(UUID, <<"Transitioning ", State1/binary>>),
    ls_vm:state(UUID, State1),
    libhowl:send(UUID, [{<<"event">>, <<"state">>}, {<<"data">>, State1}]),
    State1;

change_state(UUID, State, false) ->
    %% State1 = case filelib:is_file(<<"/zones/", UUID/binary, "/root/var/svc/provisioning">>) of
    %%              true ->
    %%                  <<"provisioning (", State/binary, ")">>;
    %%              false ->
    %%                  State
    %%          end,
    %% This will stay out untill someone provides a propper solution
    State1 = State,
    ls_vm:state(UUID, State1),
    libhowl:send(UUID, [{<<"event">>, <<"state">>}, {<<"data">>, State1}]),
    State1.

-spec binary_to_atom(B::binary()) -> A::atom().
binary_to_atom(B) ->
    list_to_atom(binary_to_list(B)).

-spec atom_to_binary(I::binary()|atom()) -> A::binary().
atom_to_binary(B) when is_binary(B) ->
    B;
atom_to_binary(A) ->
    list_to_binary(atom_to_list(A)).

backup_update(VM, SnapID, K, V) ->
    ls_vm:set_backup(VM, [{[SnapID, K], V}]),
    libhowl:send(VM,
                 [{<<"event">>, <<"backup">>},
                  {<<"data">>,
                   [{<<"action">>, <<"update">>},
                    {<<"data">>, [{K, V}]},
                    {<<"uuid">>, SnapID}]}]).
update_services(_, [], _) ->
    ok;

update_services(UUID, Changed, true) ->
    Changed1 = [{Srv, [{<<"old">>, Old},
                       {<<"new">>, New}]} || {Srv, Old, New} <- Changed],
    JSON = jsx:encode([{vm, UUID}, {data, Changed1}]),
    ensq:send(services, JSON),
    update_services(UUID, Changed, false);

update_services(UUID, Changed, false) ->
    case [{Srv, New} || {Srv, _Old, New} <- Changed, _Old =/= New] of
        [] ->
            ok;
        Changed1 ->
            libhowl:send(UUID, [{<<"event">>, <<"services">>}, {<<"data">>, Changed1}])
    end.

wait_import(<<_:1/binary, P/binary>>) ->
    Cmd = "zfs list -Hp -t all -r " ++ binary_to_list(P),
    wait_image(0, Cmd).

wait_image(N, Cmd) when N < 3 ->
    timer:sleep(5000),
    wait_image(length(re:split(os:cmd(Cmd), "\n")), Cmd);

wait_image(_, _) ->
    lager:debug("<IMG> done waiting.", []),
    ok.

timestamp() ->
    {Mega,Sec,Micro} = erlang:now(),
    (Mega*1000000+Sec)*1000000+Micro.

auth_credintials(UUID, Data) ->
    case re:split(Data, " ") of
        [User, _UserID, KeyID] ->
            chk_key(UUID, User, KeyID);
        _ ->
            lager:warning("[zonedoor] recived unknown data: ~p.", [Data]),
            false
    end.

chk_key(UUID, User, KeyID) ->
    KeyBin = libsnarl:keystr_to_id(KeyID),
    case ls_user:key_find(KeyBin) of
        {ok, UID} ->
            Res = libsnarl:allowed(UID, [<<"vms">>, UUID, <<"console">>])
                orelse libsnarl:allowed(UID, [<<"vms">>, UUID, <<"ssh">>])
                orelse libsnarl:allowed(UID, [<<"vms">>, UUID, <<"ssh">>, User]),
            lager:warning("[zonedoor:~s] User ~s trying to connect with key ~s -> ~s",
                          [UUID, User, KeyID, Res]),
            Res;
        _ ->
            lager:warning("[zonedoor:~s] denied.", [UUID]),
            false
    end.

wait_for_delete(UUID) when is_binary(UUID) ->
    wait_for_delete(binary_to_list(UUID));

wait_for_delete(UUID) ->
    UUIDn = UUID ++ "\n",
    case os:cmd(["/usr/sbin/zoneadm -z ", UUID, " list"]) of
        UUIDn ->
            ok;
        _ ->
            timer:sleep(1000),
            wait_for_delete(UUID)
    end.
