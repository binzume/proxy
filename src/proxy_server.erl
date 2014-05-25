-module(proxy_server).

-export([
         start_loop/2, start_loop/3,
         loop/1
        ]).

-type start_func() :: {module(), atom(), [term()]}.
%-type proxy() :: {module(), proxy_state()}.
%-type proxy_state() :: term().

-record(state,
        {
          tag = make_ref() :: reference(),
          start_func :: start_func(),
          real_pid :: pid(),
          driver :: proxy_driver:state()
        }).

terminate(Reason, ProxyDriver) ->
    _ = proxy_driver:terminate(Reason, ProxyDriver),
    exit(Reason).

start_loop(StartFunc, ProxySpecs) ->
    start_loop(undefined, StartFunc, ProxySpecs).

start_loop(From, StartFunc0, ProxySpecs) ->
    {InitResult, Driver0} = proxy_driver:init(ProxySpecs),
    case InitResult of
        {stop, Reason} -> terminate(Reason, Driver0);
        ok ->
            _ = process_flag(trap_exit, true),
            {RealPid, StartFunc1, Driver1} = start_real_process(StartFunc0, Driver0),
            _ = case From of
                    undefined -> ok;
                    _         -> reply(From, {ok, RealPid})
                end,
            State = #state{
                       start_func = StartFunc1,
                       real_pid   = RealPid,
                       driver     = Driver1
                      },
            ?MODULE:loop(State)
    end.

loop(State = #state{tag = Tag, real_pid = RealPid}) ->
    receive
        {'EXIT', RealPid, Reason} ->
            {Result, Driver0} = proxy_driver:handle_down(Reason, State#state.driver),
            State2 = State#state{driver = Driver0},
            case Result of
                {restart, After} ->
                    _ = erlang:send_after(After, self(), {Tag, restart}),
                    ?MODULE:loop(State2);
                ok ->
                    _ = terminate(Reason, Driver0)
            end;
        {Tag, restart} ->
            State2 = restart_real_process(State),
            ?MODULE:loop(State2);
        Message ->
            {Result, Driver0} = proxy_driver:handle_message(Message, State#state.driver),
            State2 = State#state{driver = Driver0},
            case Result of
                ignore                    -> ?MODULE:loop(State2);
                {stop, Reason}            -> _ = terminate(Reason, Driver0);
                {ok, {'EXIT', _, Reason}} ->
                    true = exit(RealPid, Reason),
                    ?MODULE:loop(State2);
                {ok, Message1}            ->
                    _ = RealPid ! Message1,
                    ?MODULE:loop(State2)
            end
    end.                    

restart_real_process(State) ->
    {RealPid, StartFunc, Driver} = start_real_process(State#state.start_func, State#state.driver),
    State#state{real_pid = RealPid, driver = Driver, start_func = StartFunc}.

start_real_process(StartFunc0, Driver0) ->
    StartFunc1 =
        case proxy_start_func:get_args(StartFunc0) of
            error       ->
                Driver1 = Driver0,
                StartFunc0;
            {ok, Args0} ->
                {HandleArgResult, Driver1} = proxy_driver:handle_arg(Args0, Driver0),
                case HandleArgResult of
                    {stop, Reason} -> terminate(Reason, Driver1);
                    {ok, Args1}    -> proxy_start_func:set_args(Args1, StartFunc0)
                end
        end,
    case proxy_start_func:start_link(StartFunc1) of
        {error, Reason2} -> terminate(Reason2, Driver1);
        {ok, RealPid}    ->
            {HandleUpResult, Driver2} = proxy_driver:handle_up(RealPid, Driver1),
            case HandleUpResult of
                {stop, Reason3} -> terminate(Reason3, Driver2);
                ok              -> {RealPid, StartFunc1, Driver2}
            end
    end.

reply({Pid, Tag}, Message) ->
    _ = Pid ! {Tag, Message},
    ok.