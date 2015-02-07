%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 19 Oct 2012 by Heinz Nikolaus Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------

-module(chunter_spec).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([to_vmadm/3,
         to_sniffle/1,
         create_update/3
        ]).

-spec to_vmadm(Package::fifo:config(), Dataset::fifo:config(),
               OwnerData::fifo:config()) -> fifo:vm_config().

to_vmadm(Package, Dataset, OwnerData) ->
    case lists:keyfind(<<"type">>, 1, Dataset) of
        {<<"type">>,<<"kvm">>} ->
            generate_spec(Package, Dataset, OwnerData);
        {<<"type">>,<<"zone">>} ->
            generate_spec(Package, Dataset, OwnerData)
    end.

-spec to_sniffle(Spec::fifo:vm_config()) -> fifo:config_list().

to_sniffle(Spec) ->
    Spec1 = jsxd:from_list(Spec),
    Type = brand_to_type(jsxd:get(<<"brand">>, <<"joyent">>, Spec1)),
    generate_sniffle(Spec1, Type).

brand_to_type(<<"kvm">>) ->
    kvm;
brand_to_type(<<"lx">>) ->
    zone;
brand_to_type(<<"sngl">>) ->
    zone;
brand_to_type(<<"joyent">>) ->
    zone;
brand_to_type(<<"joyent-minimal">>) ->
    zone.


%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec generate_sniffle(Spec::fifo:vm_config(),
                       Type::fifo:vm_type()) -> fifo:config_list().

generate_sniffle(In, _Type) ->
    KeepKeys =
        [<<"state">>, <<"alias">>, <<"quota">>, <<"cpu_cap">>, <<"routes">>,
         <<"zfs_io_priority">>, <<"disk_driver">>, <<"vcpus">>, <<"nic_driver">>,
         <<"hostname">>, <<"autoboot">>, <<"created_at">>, <<"dns_domain">>,
         <<"resolvers">>, <<"ram">>, <<"uuid">>, <<"cpu_shares">>, <<"max_swap">>,
         <<"kernel_version">>],
    jsxd:fold(fun (<<"internal_metadata">>, Int, Obj) ->
                      jsxd:merge(Int, Obj);
                  (<<"dataset_uuid">>, V, Obj) ->
                      jsxd:set(<<"dataset">>, V, Obj);
                  (<<"image_uuid">>, V, Obj) ->
                      jsxd:set(<<"dataset">>, V, Obj);
                  (<<"brand">>, Brand, Obj) ->
                      case brand_to_type(Brand) of
                          kvm ->
                              jsxd:set(<<"type">>, <<"kvm">>, Obj);
                          zone ->
                              jsxd:set(<<"type">>, <<"zone">>, Obj)
                      end;
                  (<<"max_physical_memory">>, V, Obj) ->
                      jsxd:update(<<"ram">>, fun(E) -> E end, round(V/(1024*1024)), Obj);
                  (<<"zonepath">>, V, Obj) ->
                      case re:split(os:cmd(binary_to_list(<<"/usr/sbin/zfs list -pH ", V/binary>>)), "\t", [{return, list}]) of
                          [_, Used, Avail | _] ->
                              {UsedI, _} = string:to_integer(Used),
                              {AvailI, _} = string:to_integer(Avail),
                              jsxd:thread([{set, <<"zonepath">>, V},
                                           {set, <<"quota">>, round((UsedI + AvailI) / (1024*1024*1024))}], Obj);
                          _ ->
                              jsxd:set(<<"zonepath">>, V, Obj)
                      end;
                  (<<"customer_metadata">>, V, Obj) ->
                      jsxd:fold(fun (<<"root_authorized_keys">>, V1, Obj1) ->
                                        jsxd:set(<<"ssh_keys">>, V1, Obj1);
                                    (K, V1, Obj1) ->
                                        jsxd:set([<<"metadata">>, K], V1, Obj1)
                                end, Obj, V);
                  (<<"disks">>, Disks, Obj) ->
                      {ObjOut, Size} = jsxd:fold(
                                         fun(_, Disk, {Obj1, Sum}) ->
                                                 Size = jsxd:get(<<"size">>, 0, Disk),
                                                 Total = Sum + round(Size / 1024),
                                                 case jsxd:get(<<"image_uuid">>, Disk) of
                                                     {ok, Dataset} ->
                                                         {jsxd:set(<<"dataset">>, Dataset, Obj1), Total};
                                                     _ ->
                                                         {Obj1, Total}
                                                 end
                                         end, {Obj, 0}, Disks),
                      jsxd:thread([{set, <<"quota">>, Size},
                                   {set, <<"disks">>, Disks}], ObjOut);
                  (<<"nics">>, V, Obj) ->
                      jsxd:set(<<"networks">>, V, Obj);
                  (_,_,Obj) ->
                      Obj
              end, jsxd:select(KeepKeys, In), In).

-spec generate_spec(Package::fifo:config(),
                    Dataset::fifo:config(),
                    OwnerData::fifo:config()) -> fifo:vm_config().

generate_spec(Package, Dataset, OwnerData) ->
    {ok, Ram} = jsxd:get(<<"ram">>, Package),
    RamPerc = case string:to_integer(os:cmd("/usr/sbin/prtconf | grep Memor | awk '{print $3}'")) of
                  {TotalMem, _} when is_number(TotalMem),
                                     TotalMem =/= 0 ->
                      io:format("~p~n", [TotalMem]),
                      Ram/TotalMem;
                  _ ->
                      0
              end,
    RamShare = round(1024*RamPerc),
    MaxSwap = jsxd:get(<<"max_swap">>, Ram*2, Package),
    MaxSwap1 = erlang:max(256, MaxSwap),
    Base0 = jsxd:thread([{select, [<<"uuid">>, <<"alias">>, <<"routes">>]},
                         {set, <<"autoboot">>,
                          jsxd:get(<<"autoboot">>, true,  OwnerData)},
                         {set, <<"resolvers">>, [<<"8.8.8.8">>, <<"8.8.4.4">>]},
                         {set, <<"cpu_shares">>, jsxd:get(<<"cpu_shares">>, RamShare, Package)},
                         {set, <<"max_swap">>, MaxSwap1},
                         {set, <<"owner_uuid">>,
                          jsxd:get(<<"owner">>, <<"00000000-0000-0000-0000-000000000000">>,  OwnerData)},
                         {set, <<"zfs_io_priority">>, jsxd:get(<<"zfs_io_priority">>, RamShare, Package)},
                         {set, [<<"internal_metadata">>, <<"package">>],
                          jsxd:get(<<"uuid">>, <<"-">>, Package)},
                         {set, <<"cpu_cap">>, jsxd:get([<<"cpu_cap">>], 100, Package)},
                         {merge, jsxd:select([<<"nic_driver">>,
                                              <<"disk_driver">>], Dataset)}],
                        OwnerData),
    Base1 = case jsxd:get(<<"type">>, Dataset) of
                {ok, <<"kvm">>} ->
                    Base01 = case jsxd:get(<<"cpu_cap">>, Base0) of
                                 {ok, V} ->
                                     jsxd:set(<<"vcpus">>, ceiling(V/100.0), Base0);
                                 _ ->
                                     Base0
                             end,
                    Base02 = jsxd:thread([{set, <<"ram">>, Ram},
                                          {set, <<"brand">>, <<"kvm">>},
                                          {set, <<"max_physical_memory">>, Ram + 1024},
                                          {set, [<<"disks">>, 0, <<"boot">>], true},
                                          %% Hack for dataset bug that image size is handled a string
                                          {set, [<<"disks">>, 0, <<"image_size">>],
                                           case jsxd:get(<<"image_size">>, 0, Dataset) of
                                               I when is_integer(I) ->
                                                   I;
                                               S when is_binary(S) ->
                                                   list_to_integer(binary_to_list(S))
                                           end},
                                          {set, [<<"disks">>, 0, <<"image_uuid">>],
                                           jsxd:get(<<"uuid">>, <<"">>, Dataset)}],
                                         Base01),
                    Base05 = case jsxd:get(<<"quota">>, 0, Package) of
                                 0 ->
                                     Base02;
                                 Q ->
                                     Base03 = jsxd:thread([{set, [<<"disks">>, 1, <<"boot">>], false},
                                                           {set, [<<"disks">>, 1, <<"size">>],
                                                            Q * 1024}],
                                                          Base02),
                                     Base04 = case jsxd:get(<<"blocksize">>, Package) of
                                                  {ok, BS} ->
                                                      jsxd:set([<<"disks">>, 1, <<"blocksize">>], BS, Base03);
                                                  _ ->
                                                      Base03
                                              end,
                                     case jsxd:get(<<"compression">>, Package) of
                                         {ok, Compression} ->
                                             jsxd:set([<<"disks">>, 1, <<"compression">>], Compression, Base04);
                                         _ ->
                                             Base04
                                     end
                             end,
                    case application:get_env(cpu_type) of
                        {ok, qemu64} ->
                            jsxd:set([<<"cpu_type">>], <<"qemu64">>, Base05);
                        {ok, host} ->
                            jsxd:set([<<"cpu_type">>], <<"host">>, Base05);
                        _ ->
                            Base05
                    end;
                {ok, <<"zone">>} ->
                    Base11 = jsxd:thread([{set, <<"max_physical_memory">>, Ram},
                                          {set, <<"brand">>, <<"joyent">>},
                                          {set, <<"quota">>,
                                           jsxd:get(<<"quota">>, 0, Package)},
                                          {set, <<"image_uuid">>,
                                           jsxd:get(<<"uuid">>, <<"">>, Dataset)}],
                                         Base0),
                    Base12 = case jsxd:get(<<"compression">>, Package) of
                                 {ok, Compression} ->
                                     jsxd:set([<<"zfs_root_compression">>], Compression, Base11);
                                 _ ->
                                     Base11
                             end,
                    case jsxd:get([<<"zone_type">>], Dataset) of
                        {ok, <<"lx">>} ->
                            {ok, KVersion} = jsxd:get([<<"kernel_version">>], Dataset),
                            jsxd:thread(
                              [{set, <<"kernel_version">>, KVersion},
                               {set, <<"brand">>, <<"lx">>}], Base12);
                        _ ->
                            Base12
                    end
            end,
    Base2 = jsxd:fold(fun (<<"ssh_keys">>, V, Obj) ->
                              jsxd:set([<<"customer_metadata">>,
                                        <<"root_authorized_keys">>], V, Obj);
                          (<<"resolvers">>, V, Obj) ->
                              jsxd:set(<<"resolvers">>, V, Obj);
                          (<<"hostname">>, V, Obj) ->
                              jsxd:set(<<"hostname">>, V, Obj);
                          (<<"metadata">>, V, Obj) ->
                              jsxd:update(<<"customer_metadata">>,
                                          fun(M) ->
                                                  jsxd:merge(M, V)
                                          end, V, Obj);
                          (<<"note">>, V, Obj) ->
                              jsxd:set([<<"internal_metadata">>, <<"note">>],
                                       V, Obj);
                          (<<"network_map">>, V, Obj) ->
                              jsxd:set([<<"internal_metadata">>,
                                        <<"network_map">>], V, Obj);
                          (K, V, Obj) ->
                              case re:run(K, "_pw$") of
                                  nomatch ->
                                      Obj;
                                  _ ->
                                      jsxd:set([<<"internal_metadata">>, K],
                                               V, Obj)
                              end
                      end, Base1, OwnerData),
    Result = case jsxd:get(<<"networks">>, Dataset) of
                 {ok, Nics} ->
                     jsxd:thread([{set, <<"nics">>, Nics},
                                  {set, [<<"nics">>, 0, <<"primary">>], true}],
                                 Base2);
                 _ ->
                     Base2
             end,
    lager:debug("Converted ~p / ~p / ~p to: ~p.",
                [Package, Dataset, OwnerData, Result]),
    Result.


-spec create_update(Original::fifo:config(),
                    Package::fifo:config() | undefined,
                    Config::fifo:config()) -> fifo:config_list().

create_update(_, undefined, Config) ->
    KeepKeys = [<<"resolvers">>, <<"hostname">>, <<"alias">>, <<"remove_nics">>,
                <<"add_nics">>, <<"update_nics">>, <<"autoboot">>,
                <<"max_swap">>, <<"set_routes">>, <<"remove_routes">>],
    MDataFun = fun (<<"ssh_keys">>, V, Obj) ->
                       jsxd:set([<<"set_customer_metadata">>,
                                 <<"root_authorized_keys">>], V, Obj);
                   (<<"metadata">>, V, Obj) ->
                       jsxd:update(<<"set_customer_metadata">>,
                                   fun(M) ->
                                           jsxd:merge(M, V)
                                   end, V, Obj);
                   (<<"note">>, V, Obj) ->
                       jsxd:set([<<"set_internal_metadata">>, <<"note">>],
                                V, Obj);
                   (K, V, Obj) ->
                       case re:run(K, "_pw$") of
                           nomatch ->
                               Obj;
                           _ ->
                               jsxd:set([<<"set_internal_metadata">>, K],
                                        V, Obj)
                       end
               end,
        Result = jsxd:fold(MDataFun, jsxd:select(KeepKeys, Config), Config),
    R1 = jsxd:update([<<"add_nics">>],
                     fun(Ns) ->
                             [jsxd:update([<<"model">>],
                                          fun(D) ->
                                                  D
                                          end, <<"virtio">>, N) ||
                                 N <- Ns]
                     end, [], Result),
    lager:debug("Generated update: ~s.~n", [jsx:encode(R1)]),
    R1;

create_update(Original, Package, Config) ->
    Base = create_update(Original, undefined, Config),
    {ok, Ram} = jsxd:get(<<"ram">>, Package),
    RamPerc = case string:to_integer(os:cmd("/usr/sbin/prtconf | grep Memor | awk '{print $3}'")) of
                  {TotalMem, _} when is_number(TotalMem),
                                     TotalMem =/= 0 ->
                      io:format("~p~n", [TotalMem]),
                      Ram/TotalMem;
                  _ ->
                      0
              end,
    RamShare = round(1024*RamPerc),
    MaxSwap = jsxd:get(<<"max_swap">>, Ram*2, Package),
    MaxSwap1 = erlang:max(256, MaxSwap),

    Base0 = jsxd:thread([{set, [<<"set_internal_metadata">>, <<"package">>],
                          jsxd:get(<<"uuid">>, <<"-">>, Package)},
                         {set, <<"cpu_shares">>, jsxd:get(<<"cpu_shares">>, RamShare, Package)},
                         {set, <<"zfs_io_priority">>, jsxd:get(<<"zfs_io_priority">>, RamShare*2, Package)},
                         {set, <<"max_swap">>, MaxSwap1},
                         {merge, jsxd:select([<<"cpu_cap">>], Package)}],
                        Base),
    Result = case brand_to_type(jsxd:get(<<"brand">>, <<"joyent">>, Original)) of
                 kvm ->
                     Base01 = case jsxd:get(<<"cpu_cap">>, Base0) of
                                  {ok, V} ->
                                      jsxd:set(<<"vcpus">>, ceiling(V/100.0), Base0);
                                  _ ->
                                      Base0
                              end,
                     Base02 = jsxd:thread([{set, <<"ram">>, Ram},
                                           {set, <<"max_physical_memory">>, Ram + 1024}],
                                          Base01),
                     case update_disk(jsxd:get(<<"disks">>, [], Original)) of
                         {ok, Path} ->
                             Size = jsxd:get(<<"quota">>, 0, Package) * 1024,
                             jsxd:set(<<"update_disks">>,
                                      [[{<<"path">>, Path}, {<<"size">>, Size}]],
                                      Base02);
                         _ ->
                             Base02
                     end;
                 zone ->
                     jsxd:thread([{set, <<"max_physical_memory">>, Ram},
                                  {set, <<"quota">>,
                                   jsxd:get(<<"quota">>, 0, Package)}],
                                 Base0)
             end,
    lager:debug("Created Update package ~p / ~p / ~p to: ~p.", [Original, Package, Config, Result]),
    Result.

update_disk([]) ->
    error;
update_disk([Disk | Rest]) ->
    case {jsxd:get(<<"media">>, Disk), jsxd:get(<<"boot">>, Disk)} of
        {{ok, <<"disk">>}, {ok, false}} ->
            jsxd:get(<<"path">>, Disk);
        _ ->
            update_disk([Disk | Rest])
    end.

-spec ceiling(X::float()) -> integer().

ceiling(X) ->
    T = erlang:trunc(X),
    case (X - T) of
        Neg when Neg < 0 -> T;
        Pos when Pos > 0 -> T + 1;
        _ -> T
    end.




-ifdef(TEST).

type_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"zone">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"alias">>, <<"a">>}, {<<"hostname">>, <<"h">>}, {<<"uuid">>, <<"z">>}]),
    In = apply_defaults(InP, InD, InO),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

autoboot_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"zone">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"alias">>, <<"a">>}, {<<"hostname">>, <<"h">>},
                          {<<"uuid">>, <<"z">>}, {<<"autoboot">>, false}]),
    In0 = apply_defaults(InP, InD, InO),
    In = jsxd:set(<<"autoboot">>, false, In0),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

disk_driver_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"kvm">>}, {<<"uuid">>, <<"d">>},
                          {<<"disk_driver">>, <<"virtio">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults_kvm(InP, InD, InO),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

created_at_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"kvm">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In0 = apply_defaults_kvm(InP, InD, InO),
    In = jsxd:set(<<"created_at">>, 123, In0),
    VMData = jsxd:set(<<"created_at">>, 123, to_vmadm(InP, InD, InO)),
    ?assertEqual(In, ordsets:from_list(to_sniffle(VMData))).


nic_driver_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"kvm">>}, {<<"uuid">>, <<"d">>},
                          {<<"nic_driver">>, <<"virtio">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults_kvm(InP, InD, InO),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

zone_ram_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 1024}]),
    InD = jsxd:from_list([{<<"type">>, <<"zone">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults(InP, InD, InO),
    VMData = to_vmadm(InP, InD, InO),
    VMData1 = jsxd:set(<<"max_physical_memory">>, 1024*1024*1024, VMData),
    ?assertEqual(In, ordsets:from_list(to_sniffle(VMData1))).

kvm_ram_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 1024}]),
    InD = jsxd:from_list([{<<"type">>, <<"kvm">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults_kvm(InP, InD, InO),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

kvm_cpu_cap1_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}, {<<"cpu_cap">>, 100}]),
    InD = jsxd:from_list([{<<"type">>, <<"kvm">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults_kvm(InP, InD, InO),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

kvm_cpu_cap14_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}, {<<"cpu_cap">>, 140}]),
    InD = jsxd:from_list([{<<"type">>, <<"kvm">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults_kvm(InP, InD, InO, 140, 2),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

kvm_cpu_cap15_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}, {<<"cpu_cap">>, 150}]),
    InD = jsxd:from_list([{<<"type">>, <<"kvm">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults_kvm(InP, InD, InO, 150, 2),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

kvm_cpu_cap2_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}, {<<"cpu_cap">>, 200}]),
    InD = jsxd:from_list([{<<"type">>, <<"kvm">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults_kvm(InP, InD, InO, 200, 2),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

kvm_cpu_cap21_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}, {<<"cpu_cap">>, 210}]),
    InD = jsxd:from_list([{<<"type">>, <<"kvm">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults_kvm(InP, InD, InO, 210, 3),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).


resolver_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"zone">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}, {<<"resolvers">>, [<<"8.8.8.8">>]}]),
    In0 = apply_defaults(InP, InD, InO),
    In = jsxd:set(<<"resolvers">>, [<<"8.8.8.8">>], In0),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

ssh_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"zone">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>},
                          {<<"ssh_keys">>,
                           <<"ssh-rsa">>}]),
    In = apply_defaults(InP, InD, InO),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

passwd_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"zone">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>},
                          {<<"admin_pw">>, <<"admin">>},
                          {<<"root_pw">>, <<"root">>}]),
    In = apply_defaults(InP, InD, InO),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

metadata_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10}, {<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"zone">>}, {<<"uuid">>, <<"d">>}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>},
                          {<<"admin_pw">>, <<"admin">>},
                          {<<"metadata">>, [{<<"key">>, <<"value">>}]}]),
    In = apply_defaults(InP, InD, InO),
    ?assertEqual(In, ordsets:from_list(to_sniffle(to_vmadm(InP, InD, InO)))).

nics_test() ->
    InP = jsxd:from_list([{<<"uuid">>, <<"p">>}, {<<"quota">>, 10},{<<"ram">>, 0}]),
    InD = jsxd:from_list([{<<"type">>, <<"zone">>}, {<<"uuid">>, <<"d">>},
                          {<<"networks">>, [[{<<"ip">>, <<"127.0.0.1">>},
                                             {<<"nic_tag">>, <<"admin">>}]]}]),
    InD1 = jsxd:from_list([{<<"type">>, <<"zone">>}, {<<"uuid">>, <<"d">>},
                           {<<"networks">>, [[{<<"ip">>, <<"127.0.0.1">>},
                                              {<<"nic_tag">>, <<"admin">>},
                                              {<<"primary">>, true}]]}]),
    InO = jsxd:from_list([{<<"uuid">>, <<"z">>}]),
    In = apply_defaults(InP, InD1, InO),
    Expected = to_sniffle(to_vmadm(InP, InD, InO)),
    ?assertEqual(In, Expected).

apply_defaults(InP, InD, InO) ->
    Swap = erlang:max(256, jsxd:get(<<"ram">>, 0, InP)*2),
    {ok, Dataset} = jsxd:get(<<"uuid">>, InD),
    InD1 = jsxd:delete(<<"uuid">>, InD),
    jsxd:thread([{merge, InP},
                 {set, <<"autoboot">>, true},
                 {set, <<"cpu_cap">>, 100},
                 {set, <<"max_swap">>, Swap},
                 {delete, <<"name">>},
                 {set, <<"package">>, <<"p">>},
                 {set, <<"resolvers">>, [<<"8.8.8.8">>, <<"8.8.4.4">>]},
                 {merge, InD1},
                 {set, <<"dataset">>, Dataset},
                 {set, <<"cpu_shares">>, 0},
                 {set, <<"uuid">>, <<"z">>},
                 {set, <<"zfs_io_priority">>, 0}],
                InO).

apply_defaults_kvm(InP, InD, InO) ->
    apply_defaults_kvm(InP, InD, InO, 100, 1).

apply_defaults_kvm(InP, InD, InO, Cap, N) ->
    In0 = apply_defaults(InP, InD, InO),
    jsxd:thread([{set, <<"cpu_cap">>, Cap},
                 {set, <<"disks">>,
                  [[{<<"boot">>, true},
                    {<<"image_size">>, 0},
                    {<<"image_uuid">>, <<"d">>}],
                   [{<<"boot">>, false},
                    {<<"size">>, 10240}]]},
                 {set, <<"vcpus">>, N}],
                In0).
-endif.
