%%%-------------------------------------------------------------------
%%% @author Heinz N. Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz N. Gies
%%% @doc
%%%
%%% @end
%%% Created : 10 May 2012 by Heinz N. Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(chunter_zoneparser).

%% API
-export([load/1]).

-type xml_element() :: {string(), [{string(), term()}], [xml_element()]}.

-define(REMOVE(Key),
        create_zone_data([{Key, _}|R], Disks, Nics, Datasets) ->
               create_zone_data(R, Disks, Nics, Datasets)).

-define(RENAME_INT(Old,New),
        create_zone_data([{Old, Value}|R], Disks, Nics, Datasets) ->
               {Num, []} = string:to_integer(binary_to_list(Value)),
               [{New, Num}
                |create_zone_data(R, Disks, Nics, Datasets)]).

-define(RENAME_B64(Old,New),
        create_zone_data([{Old, Value}|R], Disks, Nics, Datasets) ->
               [{New, base64:decode(Value)}
                |create_zone_data(R, Disks, Nics, Datasets)]).

-define(RENAME_BOOL(Old,New),
        create_zone_data([{Old, <<"true">>}|R], Disks, Nics, Datasets) ->
               [{New, true}|create_zone_data(R, Disks, Nics, Datasets)];
            create_zone_data([{Old, <<"false">>}|R], Disks, Nics, Datasets) ->
               [{New, false}|create_zone_data(R, Disks, Nics, Datasets)]).

-define(RENAME_SPLIT(Old,New),
        create_zone_data([{Old, Value}|R], Disks, Nics, Datasets) ->
               [{New, re:split(Value,",")}
                |create_zone_data(R, Disks, Nics, Datasets)]).

-define(RENAME(Old,New),
        create_zone_data([{Old, Value}|R], Disks, Nics, Datasets) ->
               [{New, Value}
                |create_zone_data(R, Disks, Nics, Datasets)]).

-define(NIC_RENAME(Old,New),
        create_nic([{Old, Value}|R]) ->
               [{New, Value}
                |create_nic(R)]).
-define(NIC_RENAME_INT(Old,New),
        create_nic([{Old, Value}|R]) ->
               {Num, []} = string:to_integer(binary_to_list(Value)),
               [{New, Num}
                |create_nic(R)]).
-define(NIC_RENAME_BOOL(Old,New),
        create_nic([{Old, <<"true">>}|R]) ->
               [{New, true}
                |create_nic(R)];
            create_nic([{Old, <<"false">>}|R]) ->
               [{New, false}
                |create_nic(R)]).

-define(DISK_RENAME(Old,New),
        create_disk([{Old, Value}|R]) ->
               [{New, Value}
                |create_disk(R)]).

-define(DISK_RENAME_INT(Old,New),
        create_disk([{Old, Value}|R]) ->
               {Num, []} = string:to_integer(binary_to_list(Value)),
               [{New, Num}
                |create_disk(R)]).
-define(DISK_RENAME_BOOL(Old,New),
        create_disk([{Old, <<"true">>}|R]) ->
               [{New, true}
                |create_disk(R)];
            create_disk([{Old, <<"false">>}|R]) ->
               [{New, false}
                |create_disk(R)]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec load(VM::fifo:vm_config()) -> fifo:vm_config().

load(VM) ->
    Name = proplists:get_value(<<"name">>, VM),
    Res = convert(<<"/etc/zones/", Name/binary, ".xml">>, VM),
    RouteFile = <<"/zones/", Name/binary, "/config/routes.json">>,
    case filelib:is_file(RouteFile) of
        false ->
            Res;
        true ->
            {ok, Routes} = file:read_file(RouteFile),
            RoutesJSON = jsx:decode(Routes),
            jsxd:set(<<"routes">>, RoutesJSON, Res)
    end.

-spec convert(Name::binary(), VM::fifo:vm_config()) -> fifo:vm_config().

convert(F, VM)->
    case file:read_file(F) of
        {ok, XML}  ->
            case erlsom:simple_form(XML) of
                {ok,{"zone",Attrs,Value},_}->
                    jsxd:from_list(create_zone_data(VM ++ map_attrs(Attrs)  ++ parse_xml(Value)));
                Err->
                    Err
            end;
        _ ->
            {error, not_found}
    end.

-spec parse_xml([xml_element()]) -> [xml_element() | {Key::binary()|atom(), Value::term()}].

parse_xml([{"zone",Attrib,Value}|T])->
    [{"zone", Attrib, lists:flatten(parse_xml(Value))}|parse_xml(T)];

parse_xml([{"dataset",Attrib,_Value}|T])->
    [{<<"dataset">>, list_to_binary(proplists:get_value("name", Attrib))}
     |parse_xml(T)];

parse_xml([{"attr",Attrib,_Value}|T])->
    [{list_to_binary(proplists:get_value("name", Attrib)),
      list_to_binary(proplists:get_value("value", Attrib))}
     |parse_xml(T)];

parse_xml([{"rctl",Attrib,[{"rctl-value",
                            Values,
                            _}]}|T])->
    [{list_to_binary(proplists:get_value("name", Attrib)),
      list_to_binary(proplists:get_value("limit", Values))}
     |parse_xml(T)];

parse_xml([{"net-attr",[{"name",Name},{"value",Value}],[]}|T])->
    [{list_to_binary(Name), list_to_binary(Value)}|parse_xml(T)];

parse_xml([{"net-attr",[{"value",Value},{"name",Name}],[]}|T])->
    [{list_to_binary(Name), list_to_binary(Value)}|parse_xml(T)];

parse_xml([{"device",
            [{"match",
              Path}],
            Content }|T]) ->
    [{<<"disk">>,
      [{<<"path">>, list_to_binary(Path)}|parse_xml(Content)]}
     |parse_xml(T)];

parse_xml([{"network",
            Attrs,
            Content}|T]) ->
    [{<<"nic">>,
      map_attrs(Attrs) ++ parse_xml(Content)}
     |parse_xml(T)];

parse_xml([{Node,Attribs,Value}|T])->
    [{list_to_binary(Node), map_attrs(Attribs) ++ lists:flatten(parse_xml(Value))}|parse_xml(T)];

parse_xml(Value)->
    Value.

-spec map_attrs([{string(), string()}]) ->
                       [{binary(), binary()}].
map_attrs(Attrs) ->
    lists:map(fun ({K,V}) ->
                      {list_to_binary(K), list_to_binary(V)}
              end, Attrs).


-spec create_zone_data(Data::[{atom()|binary(), term()}]) -> fifo:vm_config().
create_zone_data(Data) ->
    create_zone_data(Data, [], [],[]).

create_zone_data([], [], [],[]) ->
    [];

create_zone_data([], [], [], Datasets) ->
    [{<<"datasets">>, Datasets}];

create_zone_data([], [], Nics, Datasets) ->
    [{<<"nics">>, Nics}|create_zone_data([], [], [], Datasets)];

create_zone_data([], Disks, Nics, Datasets) ->
    [{<<"disks">>, Disks}|create_zone_data([], [], Nics, Datasets)];

create_zone_data([{<<"disk">>, Disk}|R], Disks, Nics, Datasets) ->
    create_zone_data(R, [create_disk(Disk)|Disks], Nics, Datasets);

create_zone_data([{<<"nic">>, Nic}|R], Disks, Nics, Datasets) ->
    create_zone_data(R, Disks, [create_nic(Nic)|Nics], Datasets);

create_zone_data([{<<"dataset">>, Dataset}|R], Disks, Nics, Datasets) ->
    create_zone_data(R, Disks, Nics, [Dataset|Datasets]);

?RENAME(<<"create-timestamp">>, <<"created_at">>);
?RENAME(<<"owner-uuid">>, <<"owner">>);
?RENAME(<<"dns-domain">>, <<"dns_domain">>);
?REMOVE(<<"ip-type">>);
?REMOVE(<<"debugid">>);
?RENAME_B64(<<"alias">>, <<"alias">>);
?RENAME_BOOL(<<"autoboot">>, <<"autoboot">>);
?RENAME(<<"billing-id">>, <<"billing_id">>);
?RENAME_INT(<<"cpu-cap">>, <<"cpu_cap">>);
?RENAME_BOOL(<<"do-not-inventory">>, <<"do_not_inventory">>);
?RENAME(<<"name">>, <<"zonename">>);
?RENAME(<<"dataset-uuid">>, <<"dataset_uuid">>);
?RENAME_BOOL(<<"never-booted">>, <<"never_booted">>);
?RENAME_B64(<<"qemu-extra_opts">>, <<"qemu_extra_opts">>);
?RENAME_B64(<<"qemu-opts">>, <<"qemu_opts">>);
?RENAME_INT(<<"ram">>, <<"ram">>);
?RENAME_SPLIT(<<"resolvers">>, <<"resolvers">>);
?RENAME_B64(<<"spice-opts">>, <<"spice_opts">>);
?RENAME_B64(<<"spice-password">>, <<"spice_password">>);
?RENAME_INT(<<"spice-port">>, <<"spice_port">>);
?RENAME_INT(<<"tempfs">>, <<"tempfs">>);
?RENAME_INT(<<"vcpus">>, <<"vcpus">>);
?RENAME_INT(<<"virtio-txburst">>, <<"virtio_txburst">>);
?RENAME_INT(<<"virtio-txtimer">>, <<"virtio_txtimer">>);
?RENAME_BOOL(<<"vm-autoboot">>, <<"vm_autoboot">>);
?RENAME_B64(<<"vnc-password">>, <<"vnc_password">>);
?RENAME_INT(<<"vnc-port">>, <<"vnc_port">>);
?RENAME_INT(<<"zoneid">>, <<"zoneid">>);
?RENAME_INT(<<"zone.cpu-cap">>, <<"cpu_cap">>);
?RENAME_INT(<<"zone.cpu-shares">>, <<"cpu_shares">>);
?RENAME_INT(<<"zone.max-locked-memory">>, <<"max_locked_memory">>);
?RENAME_INT(<<"zone.max-lwps">>, <<"max_lwps">>);
?RENAME_INT(<<"zone.max-physical-memory">>, <<"max_physical_memory">>);
?RENAME_INT(<<"zone.max-swap">>, <<"max_swap">>);
?RENAME_INT(<<"zone.zfs-io-priority">>, <<"zfs_io_priority">>);
create_zone_data([P|R], Disks, Nics, Datasets) ->
    [P|create_zone_data(R, Disks, Nics, Datasets)].

?NIC_RENAME(<<"ip">>, <<"ip">>);
?NIC_RENAME(<<"mac-addr">>, <<"mac">>);
?NIC_RENAME(<<"physical">>, <<"interface">>);
?NIC_RENAME_INT(<<"vlan-id">>, <<"vlan_id">>);
?NIC_RENAME(<<"global-nic">>, <<"nic_tag">>);
?NIC_RENAME_BOOL(<<"dhcp-server">>, <<"dhcp_server">>);

?NIC_RENAME(<<"blocked_outgoing_ports">>, <<"blocked_outgoing_ports">>);
create_nic([]) ->
    [];

create_nic([T|R]) ->
    [T|create_nic(R)].

?DISK_RENAME(<<"match">>, <<"path">>);
?DISK_RENAME_BOOL(<<"boot">>, <<"boot">>);
?DISK_RENAME(<<"image-uuid">>, <<"image_uuid">>);
?DISK_RENAME(<<"image-name">>, <<"image_name">>);

create_disk([]) ->
    [];

create_disk([{<<"image-size">>, Value}|R]) ->
    case lists:keyfind(<<"size">>, 1, R) of
        false ->
            {Num, []} = string:to_integer(binary_to_list(Value)),
            [{<<"size">>, Num}
             |create_disk(R)];
        _ ->
            create_disk(R)
    end;

create_disk([{<<"size">>, Value}|R]) ->
    {Num, []} = string:to_integer(binary_to_list(Value)),
    [{<<"size">>, Num}
     |lists:keydelete(<<"size">>, 1, create_disk(R))];

create_disk([T|R]) ->
    [T|create_disk(R)].

%% todo:
%% <<"filesystem">>, {
%%     <<"special">>, <<"source">>,
%%     <<"directory">>, <<"target">>,
%%     <<"type">>, <<"type">>,
%%     <<"raw">>, <<"raw">>
%% },

