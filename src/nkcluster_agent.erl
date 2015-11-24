%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkCLUSTER Agent Management
%%
%% For primary nodes:
%% - it tries to connect to other erlang nodes (pinging them)
%%
%% For all:
%% - gets periodic statistics, and tries to send an update for each one
%%     - if it cannot (because of no primary connection) it will try to 
%%       send and announce. The announce will reach nkcluster_nodes, and will
%%       start a new proxy if none is up
%%     - if it cannot (because of no connection) it will try to start a connection
%% - waits for pings from the control, if timeout it will try to connect
%%
-module(nkcluster_agent).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([node_id/0, is_primary/0]).
-export([get_status/0, set_status/1, update_cluster_addr/2, connect/2]).
-export([connect_opts/3, ping_all_nodes/0, join_nodes/1, received_ping/0]).
-export([clear_cluster_addr/0]).
-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3,   
         handle_cast/2, handle_info/2]).

-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").


-type connect_opts() ::
    #{
        password => binary(),
        ?TLS_TYPES
    }.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets current node ID
-spec node_id() ->
    nkcluster:node_id().

node_id() ->
    nkcluster_app:get(node_id).


%% @doc Finds if this node is a control node
-spec is_primary() ->
    boolean().

is_primary() ->
    nkcluster_app:get(type) == primary.


%% @doc Gets current node status
-spec get_status() ->
    nkcluster:node_status().

get_status() ->
    [{Status, _}|_] = nklib_proc:values(?MODULE),
    Status.


%% @doc Sets current node status
-spec set_status(ready|standby|stopped) ->
    ok | {error, term()}.

set_status(Status) when Status==ready; Status==standby; Status==stopped ->
    gen_server:call(?MODULE, {set_status, Status}).


%% @doc Update the announce list
-spec update_cluster_addr(boolean(), [nklib:user_uri()]) ->
    ok | {error, term()}.

update_cluster_addr(IsPreferred, ClusterAddr) ->
    case resolve(ClusterAddr, #{}) of
        {ok, Conns} ->
            gen_server:cast(?MODULE, {update_addrs, IsPreferred, Conns});
        {error, Error} ->
            {error, Error}
    end.


%% @private Avoids to reconnect
-spec clear_cluster_addr() ->
    ok.

clear_cluster_addr() ->
    gen_server:cast(?MODULE, {update_addrs, true, []}),
    gen_server:cast(?MODULE, {update_addrs, false, []}).


%% @private Connects to remote node and gets info
-spec connect(nklib:user_uri(), connect_opts()) ->
    {ok, nkcluster:node_id(), map()}.

connect(NodeAddrs, Opts) ->
    case resolve(NodeAddrs, Opts) of
        {ok, Conns} ->
            case do_connect(control, self(), Conns) of
                {ok, Pid, NodeId, Info} ->
                    {ok, NodeId, Info#{conn_pid=>Pid}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private Pings all known nodes in the cluster_addr (primary nodes, to join them)
%% When we connect to a primary node, it will send its list of known primary nodes,
%% and the protocol will call join_nodes/1
%% The password must be for all the local one or be in each URL
-spec ping_all_nodes() ->
    ok | {error, term()}.

ping_all_nodes() ->
    ClusterAddr = nkcluster_app:get(cluster_addr),
    case resolve(ClusterAddr, #{}) of
        {ok, Conns} ->
            lists:foreach(
                fun(Conn) ->
                    case do_connect(control, self(), [Conn]) of
                        {ok, Pid, NodeId, _Info} ->
                            lager:info("NkCLUSTER agent pinged ~s", [NodeId]),
                            nkcluster_protocol:stop(Pid);
                        {error, Error} ->
                            lager:info("NkCLUSTER agent could not ping ~p: ~p", 
                                       [Conn, Error])
                    end
                end,
                Conns);
        {error, Error} ->
            {error, Error}
    end.


%% @private Called from nkcluster_protocol when it is a connected to a remote 
%% primary node and it returns its list of known primary nodes
-spec join_nodes([node()]) ->
    ok.

join_nodes(Nodes) ->
    case is_primary() of
        true -> 
            Fun = case nkcluster_app:get(staged_joins) of
                true -> staged_join;
                false -> join
            end,
            lists:foreach(
                fun(Node) ->
                    case apply(riak_core, Fun, [Node]) of
                        ok -> 
                            lager:notice("NkCLUSTER Primary Node joined ~p", [Node]);
                        {error, Error} ->
                            lager:notice("NkCLUSTER Primary Node could not join ~p: ~p", 
                                         [Node, Error])
                    end
                end,
                Nodes -- [node()|nodes()]);
        false ->
            ok
    end.


%% @private Called from nkcluster_protocol when we receive a ping
%% We check we receive another soon after
received_ping() ->
    gen_server:cast(?MODULE, reset_ping_timer).



%% ===================================================================
%% gen_server
%% ===================================================================


%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


-record(state, {
    cluster_addrs = [] :: [{[nkpacket:raw_connection()], map()}],
    pref_addrs = [] :: [{[nkpacket:raw_connection()], map()}],
    listen = [] :: [nklib:uri()],
    status :: nkcluster:node_status(),
    os_type :: term(),
    connecting1 :: boolean(),
    stats = #{} :: map(),
    ping_timer :: reference()
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}}.

init([]) ->
    ok = update_cluster_addr(false, nkcluster_app:get(cluster_addr)),
    OsType = case os:type() of
        {unix, Type} -> Type;
        _ -> unknown
    end,    
    State = #state{
        listen = nkcluster_app:get(listen),
        status = ready,
        os_type = OsType,
        connecting1 = false
    },
    nklib_proc:put(?MODULE, ready),
    case is_primary() of
        true -> spawn(fun() -> ping_all_nodes() end);
        false -> ok
    end,
    erlang:send_after(1000, self(), get_stats),
    {ok, reset_ping_timer(State)}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.

handle_call(get_status, _From, #state{status=Status}=State) ->
    {reply, {ok, Status}, State};

handle_call({set_status, Status}, _From, #state{status=Status}=State) ->
    {reply, ok, State};

handle_call({set_status, New}, From, #state{status=Old}=State) ->
    case New of
        ready when Old==standby; Old==stopping; Old==stopped ->
            set_updated_status(ready, From, State);
        standby when Old==ready; Old==stopping; Old==stopped ->
            set_updated_status(standby, From, State);
        stopped when Old==ready; Old==standby; Old==stopping ->
            self() ! check_stopped,
            set_updated_status(stopping, From, State);
        _ ->
            {reply, {error, not_allowed}, State}
    end;

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.

handle_cast({update_addrs, true, Addrs}, State) ->
    {noreply, State#state{pref_addrs=Addrs}};

handle_cast({update_addrs, false, Addrs}, State) ->
    {noreply, State#state{cluster_addrs=Addrs}};

handle_cast({send_update, Stats}, State) ->
    State1 = State#state{stats=Stats},
    HasNoAddrs = has_no_addrs(State),
    State2 = case send_update(State1) of
        ok ->
            State1;
        {error, _} when HasNoAddrs ->
            State1;
        {error, _} ->
            % Send announce to all connected primaries
            case nkcluster_protocol:send_announce() of
                ok ->
                    lager:info("NkCLUSTER agent sent announcement", []),
                    State1;
                error ->
                    connect_and_announce(State)
            end
    end,
    Time = nkcluster_app:get(stats_time),
    erlang:send_after(Time, self(), get_stats),
    {noreply, State2};

handle_cast({connecting, false}, State) ->
    {noreply, State#state{connecting1=false}};

handle_cast(reset_ping_timer, State) ->
    {noreply, reset_ping_timer(State)};

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}}.

handle_info(get_stats, State) ->
    spawn(fun() -> get_stats() end),
    {noreply, State};

handle_info(check_stopped, #state{status=stopping}=State) ->
    case nkcluster_jobs:get_tasks() of
        {ok, []} ->
            set_updated_status(stopped, none, State);
        _ ->
            erlang:send_after(1000, self(), check_stopped),
            {noreply, State}
    end;

handle_info(check_stopped, State) ->
    {noreply, State};

handle_info(ping_timeout, #state{connecting1=false}=State) ->
    State1 = case has_no_addrs(State) of
        true ->
            State;
        false ->
            lager:notice("NkCLUSTER agent ping timeout!", State),
            connect_and_announce(State)
    end,
    {noreply, reset_ping_timer(State1)};

handle_info(ping_timeout, #state{connecting1=true}=State) ->
    {noreply, reset_ping_timer(State)};

handle_info(Msg, State) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, _State) ->
    ok.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_stats() ->
    Stats = #{
        cpu => 
            #{
                nprocs => cpu_sup:nprocs(),
                avg1 => cpu_sup:avg1() / 256,
                avg5 => cpu_sup:avg5() / 256,
                avg15 => cpu_sup:avg15() / 256
            },
        memory =>
            maps:from_list(memsup:get_system_memory_data()),
        disks => 
            [
                #{path=>Path, size=>Size div 1024, user=>Use}
                || {Path, Size, Use} <- disksup:get_disk_data()
            ],
        time => 
            nklib_util:l_timestamp()
    },
    gen_server:cast(?MODULE, {send_update, Stats}).


%% @private
-spec send_update(#state{}) ->
    ok | {error, term()}.

send_update(#state{stats=Stats, listen=Listen, status=Status, os_type=OsType}) ->
    Update = #{
        status => Status,
        listen => Listen, 
        meta => nkcluster_app:get(meta),
        stats => Stats#{os_type=>OsType}
    },
    nkcluster_protocol:send_event(nkcluster, {agent_update, Update}).


%% @private
connect_and_announce(#state{connecting1=false}=State) ->
    #state{pref_addrs=Pref, cluster_addrs=Cluster} = State,
    Addrs = Pref ++ nklib_util:randomize(Cluster),
    Self = self(),
    Fun = fun() ->
        case do_connect(worker, Self, Addrs) of
            {ok, Pid, _NodeId, _Info} ->
                nkcluster_protocol:send_announce([Pid]);
            {error, Error} ->
                lager:info("NkCLUSTER agent could not connect to any control node: ~p", 
                           [Error])
        end,
        gen_server:cast(Self, {connecting, false})
    end,
    spawn_link(Fun),
    State#state{connecting1=true};

connect_and_announce(State) ->
    State.


%% @private
do_connect(_Type, _Host, []) ->
    {error, no_connections};

do_connect(Type, Host, [{Conns, Opts}|Rest]) ->
    ConnOpts = connect_opts(Type, Host, Opts),
    lager:info("NkCLUSTER agent connecting to ~p (~p)", [Conns, Type]),
    case catch nkpacket:connect(Conns, ConnOpts) of
        {ok, Pid} ->
            case nkcluster_protocol:wait_auth(Pid) of
                {ok, NodeId, #{remote:=Remote}=Info} -> 
                    lager:info("NkCLUSTER agent connected to ~s", [Remote]),
                    {ok, Pid, NodeId, Info};
                {error, _} -> 
                    do_connect(Type, Host, Rest)
            end;
        {error, Error} ->
            lager:info("NkCLUSTER agent could not connect to ~p: ~p", [Conns, Error]),
            do_connect(Type, Host, Rest);
        {'EXIT', Error} ->
            lager:info("NkCLUSTER agent could not connect to ~p: ~p", 
                       [Conns, {exit, Error}]),
            do_connect(Type, Host, Rest)
    end.


%% @private
set_updated_status(Status, From, State) ->
    nklib_proc:put(?MODULE, Status),
    case From of
        none -> ok;
        _ -> gen_server:reply(From, ok)
    end,
    nkcluster_jobs:updated_status(Status),
    nkcluster_protocol:send_event(nkcluster, {node_status, Status}),
    {noreply, State#state{status=Status}}.


%% @private
-spec connect_opts(worker|{control, pid()}, pid(), map()) ->
    map().

connect_opts(Type, Host, Opts) ->
    TLSKeys = nkpacket_util:tls_keys(),
    TLSOpts = maps:with([host|TLSKeys], Opts),
    TLSOpts#{
        class => nkcluster,
        valid_schemes => [nkcluster],
        monitor => Host,
        idle_timeout => 15000,
        ws_proto => nkcluster,
        tcp_packet => 4,
        user => maps:with([password, type], Opts#{type=>Type})
    }.


%% @private
has_no_addrs(#state{pref_addrs=Pref, cluster_addrs=Cluster}) ->
    Pref==[] andalso Cluster==[].


%% @private
reset_ping_timer(#state{ping_timer=Timer}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = 2 * nkcluster_app:get(ping_time),
    State#state{ping_timer=erlang:send_after(Time, self(), ping_timeout)}.
    
-compile(export_all).

%% @private
resolve(Uri, Opts) ->
    Syntax = #{password=>binary},
    Opts1 = Opts#{valid_schemes=>[nkcluster], syntax=>Syntax},
    nkpacket:multi_resolve(Uri, Opts1).
    

