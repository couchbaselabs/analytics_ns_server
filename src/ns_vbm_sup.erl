% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_vbm_sup).

-behaviour(supervisor).

-export([start_link/0,
         kill_children/3,
         kill_all_children/1,
         kill_dst_children/3,
         move/4,
         replicators/2,
         set_replicas/3]).

-export([init/1]).

%% API
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

replicators(Nodes, Bucket) ->
    lists:flatmap(
      fun (Node) ->
              try children(Node) of
                  Children ->
                      [{Node, Dst, VBucket} ||
                          {B, VBuckets, Dst, false} <- Children,
                          VBucket <- VBuckets,
                          B == Bucket]
              catch
                  _:_ -> []
              end
      end, Nodes).

actions(Children) ->
    [{VBucket, Dst} || {_, VBuckets, Dst, false} <- Children,
                       VBucket <- VBuckets].

kill_vbuckets(Node, Bucket, VBuckets) ->
    {ok, States} = ns_memcached:list_vbuckets(Node, Bucket),
    case [X || X = {V, _} <- States, lists:member(V, VBuckets)] of
        [] ->
            ok;
        RemainingVBuckets ->
            error_logger:info_msg("~p:kill_vbuckets: ~w~n",
                                  [?MODULE, RemainingVBuckets]),
            lists:foreach(fun ({V, dead}) ->
                                  ns_memcached:delete_vbucket(Node, Bucket, V);
                              ({V, _}) ->
                                  ns_memcached:set_vbucket_state(Node, Bucket,
                                                                 V, dead),
                                  ns_memcached:delete_vbucket(Node, Bucket, V)
                              end, RemainingVBuckets),
            timer:sleep(100),
            kill_vbuckets(Node, Bucket, VBuckets)
    end.

set_replicas(Node, Bucket, Replicas) ->
    case lists:member(Node, ns_node_disco:nodes_actual_proper()) of
        true ->
            GoodChildren = kill_runaway_children(Node, Bucket, Replicas),
            %% Now filter out the replicas that still have children
            Actions = actions(GoodChildren),
            NeededReplicas = Replicas -- Actions,
            Sorted = lists:keysort(2, NeededReplicas),
            Grouped = misc:keygroup(2, Sorted),
            lists:foreach(
              fun ({Dst, R}) ->
                      VBuckets = [V || {V, _} <- R],
                      error_logger:info_msg(
                        "Starting replica for vbuckets ~w on node ~p~n",
                        [VBuckets, Dst]),
                      kill_vbuckets(Dst, Bucket, VBuckets),
                      lists:foreach(
                        fun (V) ->
                                ns_memcached:set_vbucket_state(Dst, Bucket, V, replica)
                        end, VBuckets),
                      {ok, _Pid} = start_child(Node, Bucket, VBuckets, Dst, false)
              end, Grouped);
        false ->
            {error, nodedown}
    end.

move(Bucket, VBucket, SrcNode, DstNode) ->
    kill_children(SrcNode, Bucket, [VBucket]),
    Args = args(SrcNode, Bucket, [VBucket], DstNode, true),
    %% Delete any data from the target node. This has the added
    %% advantage of crashing us if the target node is not ready
    %% to receive data, or at least delaying us until it is.
    kill_vbuckets(DstNode, Bucket, [VBucket]),
    case misc:spawn_and_wait(
           SrcNode,
           fun () ->
                   apply(ns_port_server, start_link, Args)
           end) of
        normal -> ok;
        Reason -> {error, Reason}
    end.

kill_all_children(Node) ->
    lists:foreach(fun (Child) ->
                          kill_child(Node, Child)
                  end, children(Node)).

kill_child(Node, Child) ->
    supervisor:terminate_child({?MODULE, Node}, Child),
    ok = supervisor:delete_child({?MODULE, Node}, Child).

kill_children(Node, Bucket, VBuckets) ->
    %% Kill any existing children for these VBuckets
    Children = [Id || Id = {B, Vs, _, false} <- children(Node),
                      B == Bucket,
                      lists:subtract(Vs, VBuckets) /= Vs],
    lists:foreach(fun (Child) ->
                          kill_child(Node, Child)
                  end, Children),
    Children.

kill_dst_children(Node, Bucket, Dst) ->
    Children = [Id || Id = {B, _, D, _} <- children(Node),
                      B == Bucket,
                      D == Dst],
    lists:foreach(fun (Child) ->
                          kill_child(Node, Child)
                  end, Children).

kill_runaway_children(Node, Bucket, Replicas) ->
    %% Kill any children not in Replicas
    Children = [Child || Child = {B, _, _, _} <- children(Node), B == Bucket],
    {GoodChildren, Runaways} =
        lists:partition(
          fun ({_, VBuckets, DstNode, false}) ->
                  NodeReplicas = [{V, DstNode} || V <- VBuckets],
                  lists:all(fun (NR) -> lists:member(NR, Replicas) end,
                            NodeReplicas)
          end, Children),
    lists:foreach(
      fun (Runaway) ->
              error_logger:info_msg(
                "~p:kill_runaway_children(): Killling replicator ~p on node ~p~n",
                                               [?MODULE, Runaway, Node]),
                          kill_child(Node, Runaway)
                  end, Runaways),
    GoodChildren.


%% supervisor callbacks
init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.

%% Internal functions
args(Node, Bucket, VBuckets, DstNode, TakeOver) ->
    "default" = Bucket, % vbucketmigrator doesn't support multi-tenancy yet
    Command = "./bin/vbucketmigrator/vbucketmigrator",
    BucketArgs = lists:append([["-b", integer_to_list(B)] || B <- VBuckets]),
    TakeOverArg = case TakeOver of
                      true -> ["-t"];
                      false -> []
                  end,
    OtherArgs = ["-h", ns_memcached:host_port_str(Node),
                 "-d", ns_memcached:host_port_str(DstNode),
                 "-v"],
    Args = lists:append([OtherArgs, TakeOverArg, BucketArgs]),
    [vbucketmigrator, Command, Args, [use_stdio, stderr_to_stdout]].

children(Node) ->
    [Id || {Id, _, _, _} <- supervisor:which_children({?MODULE, Node})].

start_child(Node, Bucket, VBuckets, DstNode, TakeOver) ->
    PortServerArgs = args(Node, Bucket, VBuckets, DstNode, TakeOver),
    error_logger:info_msg("~p:start_child(~p, ~p, ~p, ~p, ~p):~nArgs = ~p~n",
                          [?MODULE, Node, Bucket, VBuckets, DstNode, TakeOver, PortServerArgs]),
    Type = case TakeOver of true -> transient; false -> permanent end,
    ChildSpec = {{Bucket, VBuckets, DstNode, TakeOver},
                 {ns_port_server, start_link, PortServerArgs},
                 Type, 10, worker, [ns_vbm]},
    supervisor:start_child({?MODULE, Node}, ChildSpec).
