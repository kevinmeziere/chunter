-module(ezdoor_behaviour).

-ignore_xref([behaviour_info/1]).

-callback door_event(Pid::pid(), Ref::reference(), Cmd::binary()|down) ->
    {ok, Reply::binary()|iolist()} | ok.
