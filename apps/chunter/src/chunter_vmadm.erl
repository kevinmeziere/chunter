%%%-------------------------------------------------------------------
%%% @author Heinz N. Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz N. Gies
%%% @doc
%%%
%%% @end
%%% Created : 10 May 2012 by Heinz N. Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(chunter_vmadm).

%% API
-export([start/1,
         start/2,
         stop/1,
         info/1,
         reboot/1,
         delete/2,
         create/1,
         update/2
        ]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

-spec start(UUID::fifo:uuid()) -> list().
start(UUID) ->
    lager:info([{fifi_component, chunter}],
               "vmadm:start - UUID: ~s.", [UUID]),
    Cmd = <<"/usr/sbin/vmadm start ", UUID/binary>>,
    lager:debug([{fifi_component, chunter}],
                "vmadm:cmd - ~s.", [Cmd]),
    os:cmd(binary_to_list(Cmd)).

-spec start(UUID::fifo:uuid(), Image::binary()) -> list().

start(UUID, Image) ->
    lager:info([{fifi_component, chunter}],
               "vmadm:start - UUID: ~s, Image: ~s.", [UUID, Image]),
    Cmd = <<"/usr/sbin/vmadm start ", UUID/binary>>,
    lager:debug([{fifi_component, chunter}],
                "vmadm:cmd - ~s.", [Cmd]),
    os:cmd(binary_to_list(Cmd)).

-spec delete(UUID::fifo:uuid(), Mem::binary()) -> ok.

delete(UUID, Mem) ->
    lager:info([{fifi_component, chunter}],
               "vmadm:delete - UUID: ~s.", [UUID]),
    Cmd = <<"/usr/sbin/vmadm delete ", UUID/binary>>,
    lager:debug([{fifi_component, chunter}],
                "vmadm:cmd - ~s.", [Cmd]),
    os:cmd(binary_to_list(Cmd)),
    chunter_server:unprovision_memory(Mem),
    chunter_vm_fsm:remove(UUID).

-spec info(UUID::fifo:uuid()) -> fifo:config_list().

info(UUID) ->
    lager:info([{fifi_component, chunter}],
               "vmadm:info - UUID: ~s.", [UUID]),
    Cmd = <<"/usr/sbin/vmadm info ", UUID/binary>>,
    lager:debug([{fifi_component, chunter}],
                "vmadm:cmd - ~s.", [Cmd]),
    case os:cmd(binary_to_list(Cmd)) of
        "Unable" ++ _ ->
            [];
        JSON ->
            jsx:to_term(list_to_binary(JSON))
    end.

-spec stop(UUID::fifo:uuid()) -> list().

stop(UUID) ->
    lager:info([{fifi_component, chunter}],
               "vmadm:stop - UUID: ~s.", [UUID]),
    Cmd = <<"/usr/sbin/vmadm stop ", UUID/binary>>,
    lager:debug([{fifi_component, chunter}],
                "vmadm:cmd - ~s.", [Cmd]),
    os:cmd(binary_to_list(Cmd)).

-spec reboot(UUID::fifo:uuid()) -> list().

reboot(UUID) ->
    lager:info([{fifi_component, chunter}],
               "vmadm:reboot - UUID: ~s.", [UUID]),
    Cmd = <<"/usr/sbin/vmadm reboot ", UUID/binary>>,
    lager:debug([{fifi_component, chunter}],
                "vmadm:cmd - ~s.", [Cmd]),
    os:cmd(binary_to_list(Cmd)).

-spec create(UUID::fifo:vm_config()) -> ok |
                                        {error, binary() |
                                         timeout |
                                         unknown}.

create(Data) ->
    {<<"uuid">>, UUID} = lists:keyfind(<<"uuid">>, 1, Data),
    lager:info("~p", [<<"Creation of VM '", UUID/binary, "' started.">>]),
    %%    libsnarl:msg(Owner, info, <<"Creation of VM '", Alias/binary, "' started.">>),
    lager:info([{fifi_component, chunter}],
               "vmadm:create", []),
    Cmd =  code:priv_dir(chunter) ++ "/vmadm_wrap.sh create",
    lager:debug([{fifi_component, chunter}],
                "vmadm:cmd - ~s.", [Cmd]),
    Port = open_port({spawn, Cmd}, [use_stdio, binary, {line, 1000}, stderr_to_stdout, exit_status]),
    port_command(Port, jsx:to_json(Data)),
    port_command(Port, "\nEOF\n"),
    {<<"max_physical_memory">>, Mem} = lists:keyfind(<<"max_physical_memory">>, 1, Data),
    Res = case wait_for_tex(Port) of
              ok ->
                  chunter_server:provision_memory(Mem*1024*1024),
                  chunter_vm_fsm:load(UUID);
              {error, 1 = E} ->
                  lager:error([{fifi_component, chunter}],
                              "vmad:create - Failed: ~p.", [E]),
                  chunter_server:provision_memory(Mem*1024*1024),
                  chunter_vm_fsm:load(UUID);
              {error, E} ->
                  lager:error([{fifi_component, chunter}],
                              "vmad:create - Failed: ~p.", [E]),
                  E
          end,
    Res.

update(UUID, Data) ->
    lager:info("~p", [<<"Updaring of VM '", UUID/binary, "' started.">>]),
    %%    libsnarl:msg(Owner, info, <<"Creation of VM '", Alias/binary, "' started.">>),
    lager:info([{fifi_component, chunter}],
               "vmadm:create", []),
    Cmd =  code:priv_dir(chunter) ++ "/vmadm_wrap.sh update " ++ binary_to_list(UUID),
    lager:debug([{fifi_component, chunter}],
                "vmadm:cmd - ~s.", [Cmd]),
    Port = open_port({spawn, Cmd}, [use_stdio, binary, {line, 1000}, stderr_to_stdout, exit_status]),
    port_command(Port, jsx:to_json(Data)),
    port_command(Port, "\nEOF\n"),
    receive
        {Port, {exit_status, _}} ->
            chunter_vm_fsm:load(UUID)
    after
        60000 ->
            chunter_vm_fsm:load(UUID)
    end.


%% This function reads the process's input untill it knows that the vm was created or failed.
-spec wait_for_tex(Port::any()) ->
                          {ok, UUID::fifo:uuid()} |
                          {error, Text::binary() |
                                        timeout |
                                        unknown}.
wait_for_tex(Port) ->
    receive
        {Port,{exit_status, 0}} ->
            ok;
        {Port,{exit_status, S}} ->
            {error, S}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
