%%%-------------------------------------------------------------------
%%% @author Richard Jonas <richard.jonas@erlang-solutions.com>
%%% @copyright (C) 2014, Erlang Solution Ltd.
%%% @doc Registry for elarm servers
%%% @end
%%%-------------------------------------------------------------------
-module(elarm_registry).

-behaviour(gen_server).

-export([start_link/0,
         subscribe/0,
         unsubscribe/0,
         server_started/1,
         server_stopped/1]).

-export([init/1,
         handle_cast/2,
         handle_call/3,
         handle_info/2,
         terminate/2,
         code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).

-record(state, {
          servers = []      :: [{atom(), pid()}],   %% ServerName & Pid
          subscribers = []  :: [{pid(), reference()}]
         }).

%%%===================================================================
%%% API functions
%%%===================================================================

%%%-------------------------------------------------------------------
%%% @doc
%%% Start elarm registry server with {local, elarm_registy} name.
%%% @end
%%%-------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%-------------------------------------------------------------------
%%% @doc
%%% Subscribe to listening elarm server events, e.g. starting
%%% new elarm server, stop elarm server, elarm server crashed.
%%% The subscriber process - identified by self() - will get messages
%%% when an elarm event happens.
%%% <dl>
%%%   <dt>{elarm_started, Name}</dt>
%%%   <dd>when an elarm server is started</dd>
%%%   <dt>{elarm_down, Name}</dt>
%%%   <dd>when an elarm server is stopped or crashed</dd>
%%% </dl>
%%% @end
%%%-------------------------------------------------------------------
-spec subscribe() -> {ok, [{atom(), pid()}]}.
subscribe() ->
    gen_server:call(?SERVER, {subscribe, self()}).

%%%-------------------------------------------------------------------
%%% @doc
%%% Unsubscribe from elarm events
%%% @end
%%%-------------------------------------------------------------------
-spec unsubscribe() -> ok.
unsubscribe() ->
    gen_server:call(?SERVER, {unsubscribe, self()}).

%%%-------------------------------------------------------------------
%%% @doc
%%% An elarm server has to call this when it is started in order that
%%% registry listeners knows about that elarm server.
%%% @end
%%%-------------------------------------------------------------------
-spec server_started(atom()) -> term().
server_started(Name) ->
    gen_server:cast(?SERVER, {elarm_started, Name, self()}).

%%%-------------------------------------------------------------------
%%% @doc
%%% Elarm server may call this when it terminates. Registry will send
%%% a message to its subscribers about that event. Elarm server is
%%% monitored by the registry, so calling this function is optional.
%%% @end
%%%-------------------------------------------------------------------
-spec server_stopped(atom()) -> term().
server_stopped(Name) ->
    gen_server:cast(?SERVER, {elarm_stopped, Name, self()}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_) ->
    {ok, #state{}}.

handle_call({subscribe, Pid}, _From, State) ->
    {reply, {ok, State#state.servers}, handle_subscribe(Pid, State)};
handle_call({unsubscribe, Pid}, _From, State) ->
    {reply, ok, handle_unsubscribe(Pid, State)}.

handle_cast({elarm_started, Name, Pid}, State) ->
    {noreply, handle_server_started(Name, Pid, State)};
handle_cast({elarm_stopped, Name, Pid}, State) ->
    {noreply, handle_server_down(Name, Pid, State)};
handle_cast(_Req, State) ->
    {noreply, State}.

handle_info({'DOWN', _MRef, _Type, {Name, Node}, _Info}, State)
  when Node =:= node() ->
    %% An elarm server went down
    case lists:keyfind(Name, 1, State#state.servers) of
        {Name, Pid} ->
            {noreply, handle_server_down(Name, Pid, State)};
        false ->
            {noreply, State}
    end;
handle_info({'DOWN', _MRef, _Type, Pid, _Info}, State) ->
    %% An external subscriber went down
    {noreply, handle_unsubscribe(Pid, State)};
handle_info(Info, State) ->
    lager:debug("Unknown message ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_subscribe(Pid, #state{subscribers = Subs} = State) ->
    case lists:keyfind(Pid, 1, Subs) of
        false ->
            Mon = erlang:monitor(process, Pid),
            State#state{subscribers = [{Pid, Mon} | Subs]};
        _ ->
            %% already subscribed
            State
    end.

handle_unsubscribe(Pid, #state{subscribers = Subs} = State) ->
    case lists:keyfind(Pid, 1, Subs) of
        false ->
            %% already unsubscribed somehow
            State;
        {_, Mon} ->
            erlang:demonitor(Mon),
            State#state{subscribers = lists:keydelete(Pid, 1, Subs)}
    end.

handle_server_down(Name, Pid, #state{servers = Servers} = State) ->
    [Sub ! {elarm_down, Name, Pid}
        || {Sub, _Mon} <- State#state.subscribers],
    State#state{servers = lists:keydelete(Name, 1, Servers)}.

handle_server_started(Name, Pid, #state{servers = Servers} = State) ->
    erlang:monitor(process, Name),
    [Sub ! {elarm_started, Name, Pid}
        || {Sub, _Mon} <- State#state.subscribers],
    case lists:keyfind(Name, 1, Servers) of
        false ->
            State#state{servers = [{Name, Pid} | Servers]};
        _ ->
            State
    end.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).

subscribe_test_() ->
    GetMsg = fun() ->
                 receive
                     Msg ->
                         Msg
                 after
                     100 ->
                         {error, no_message}
                 end
             end,
    {setup,
     local,
     fun() ->
         application:set_env(elarm, alarmlist_cb, elarm_alarmlist),
         application:set_env(elarm, config_cb, elarm_config),
         application:set_env(elarm, log_cb, elarm_log),
         application:set_env(elarm, event_cb, elarm_event),
         application:set_env(elarm, def_alarm_mapping,
                                      [{severity, indeterminate},
                                       {probable_cause, <<>>},
                                       {proposed_repair_action, <<>>},
                                       {description, <<>>},
                                       {additional_information, undefined},
                                       {correlated_events, []},
                                       {comments, []},
                                       {trend, undefined},
                                       {threshold, undefined},
                                       {manual_clear_allowed, true},
                                       {no_ack_required, false},
                                       {log, true},
                                       {ignore, false}]),
         {ok, P} = elarm_registry:start_link(),
         erlang:unlink(P),
         elarm_registry:subscribe()
     end,
     fun(_) ->
         exit(whereis(?MODULE), kill)
     end,
     [?_assertMatch({elarm_started, test, _},
                    begin
                        {ok, P} = elarm_server:start_link(test, []),
                        erlang:unlink(P),
                        GetMsg()
                    end),
      ?_assertMatch({elarm_down, test, _},
                    begin
                        exit(whereis(test), shutdown),
                        GetMsg()
                    end),
      ?_assertEqual({error, no_message},
                    begin
                        elarm_registry:unsubscribe(),
                        {ok, P} = elarm_server:start_link(test2, []),
                        erlang:unlink(P),
                        GetMsg()
                    end)]
     }.

-endif.