-module(chunter_api).

-export([call/2]).

-define(MAX_MDATA_SIZE, 1024*1024*32).

call(UUID, [{<<"action">>, <<"snapshot-create">>},
            {<<"comment">>, Comment}]) ->
    case ls_vm:snapshot(UUID, Comment) of
        {ok, SUUID} ->
            {ok, [{uuid, SUUID}]};
        _ ->
            {error, "failed!"}
    end;

call(UUID, [{<<"action">>, <<"snapshot-list">>}]) ->
    case ls_vm:get(UUID) of
        {ok, V} ->
            {ok, ft_vm:snapshots(V)};
        _ ->
            {error, "failed!"}
    end;

call(UUID, [{<<"action">>, <<"snapshot-get">>},
            {<<"uuid">>, SnapID}]) ->
    case ls_vm:get(UUID) of
        {ok, V} ->
            Snaps = ft_vm:snapshots(V),
            case jsxd:get(SnapID, Snaps) of
                {ok, S} ->
                    {ok, S};
                _ ->
                    {error, "not found"}
            end;
        _ ->
            {error, "failed!"}
    end;

call(UUID, [{<<"action">>, <<"metadata-get">>}]) ->
    case ls_vm:get(UUID) of
        {ok, V} ->
            {ok, ft_vm:metadata(V)};
        _ ->
            {error, "failed!"}
    end;

call(UUID, [{<<"action">>, <<"metadata-set">>},
            {<<"data">>, D}]) ->
    case ls_vm:get(UUID) of
        {ok, V} ->
            Size = byte_size(term_to_binary(ft_vm:metadata(V))) +
                byte_size(term_to_binary(D)),
            if
                Size > ?MAX_MDATA_SIZE ->
                    {error, "out of space"};
                true ->
                    ls_vm:set_metadata(UUID, D),
                    {ok, V1} = ls_vm:get(UUID),
                    {ok, ft_vm:metadata(V1)}
            end;
        _ ->
            {error, "failed!"}
    end;

call(UUID, [{<<"action">>, <<"cluster-get">>}]) ->
    case grouping(UUID) of
        {ok, _, G} ->
            {ok, ft_grouping:config(G)};
        E ->
            E
    end;

call(UUID, [{<<"action">>, <<"cluster-set">>},
            {<<"data">>, D}]) ->
    case grouping(UUID) of
        {ok, GID, G} ->
            Size = byte_size(term_to_binary(ft_grouping:config(G))) +
                byte_size(term_to_binary(D)),
            if
                Size > ?MAX_MDATA_SIZE ->
                    {error, "out of space"};
                true ->
                    ls_grouping:set_config(GID, D),
                    {ok, G1} = ls_grouping:get(GID),
                    {ok, ft_grouping:config(G1)}
            end;
        E ->
            E
    end;

call(UUID, [{<<"action">>, <<"stack-get">>}]) ->
    case stack(UUID) of
        {ok, _, S} ->
            {ok, ft_grouping:config(S)};
        E ->
            E
    end;

call(UUID, [{<<"action">>, <<"stack-set">>},
            {<<"data">>, D}]) ->
    case stack(UUID) of
        {ok, SID, S} ->
            Size = byte_size(term_to_binary(ft_grouping:config(S))) +
                byte_size(term_to_binary(D)),
            if
                Size > ?MAX_MDATA_SIZE ->
                    {error, "out of space"};
                true ->
                    ls_grouping:set_config(SID, D),
                    {ok, S1} = ls_grouping:get(SID),
                    {ok, ft_grouping:config(S1)}
            end;
        E ->
            E
    end;

call(UUID, [{<<"action">>, <<"backup-list">>}]) ->
    case ls_vm:get(UUID) of
        {ok, V} ->
            {ok, ft_vm:backups(V)};
        _ ->
            {error, "failed!"}
    end;

call(UUID, [{<<"action">>, <<"backup-create">>},
            {<<"comment">>, Comment},
            {<<"delete">>, Delete}]) ->
    Opts = case Delete of
               true ->
                   [delete, xml];
               _ ->
                   [xml]
           end,
    case ls_vm:full_backup(UUID, Comment, Opts) of
        {ok, BackupID} ->
            {ok, BackupID};
        _ ->
            {error, "failed!"}
    end;

call(UUID, [{<<"action">>, <<"backup-create">>},
            {<<"comment">>, Comment},
            {<<"delete">>, Delete},
            {<<"parent">>, Parent}]) ->
    Opts = case Delete of
               true ->
                   [delete, xml];
               <<"parent">> ->
                   [{delete, parent}, xml];
               <<"both">> ->
                   [{delete, parent}, delete, xml];
               _ ->
                   [xml]
           end,
    case ls_vm:incremental_backup(UUID, Parent, Comment, Opts) of
        {ok, BackupID} ->
            {ok, BackupID};
        _ ->
            {error, "failed!"}
    end;

call(_, Cmd) ->
    lager:warning("[api] Unsupported command: ~p", [Cmd]),
    {error, "unsupported"}.

grouping_id(UUID) ->
    case ls_vm:get(UUID) of
        {ok, V} ->
            case ft_vm:groupings(V) of
                [GID] ->
                    {ok, GID};
                _ ->
                    {error, "not in a cluster"}
            end;
        _ ->
            {error, "failed!"}
    end.

grouping(UUID) ->
    case grouping_id(UUID) of
        {ok, GID} ->
            case ls_grouping:get(GID) of
                {ok, G} ->
                    {ok, GID, G};
                _ ->
                    {error, "cluster not found"}
            end;
        E ->
            E
    end.
stack_id(UUID) ->
    case grouping(UUID) of
        {ok, _, G} ->
            case ft_grouping:groupings(G) of
                [SID | _]  ->
                    {ok, SID};
                _ ->
                    {error, "stack not found"}
            end;
        _ ->
            {error, "stack not found"}
    end.

stack(UUID) ->
    case stack_id(UUID) of
        {ok, SID} ->
            case ls_grouping:get(SID) of
                {ok, S} ->
                    {ok, SID, S};
                _ ->
                    {error, "stack not found"}
            end;
        _ ->
            {error, "stack not found"}
    end.
