%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Monitor and maintain the vbucket layout of each bucket.
%%
-module(ns_janitor).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([cleanup/2, stop_rebalance_status/1]).

-spec cleanup(Bucket::bucket_name(), Options::list()) ->
                     ok |
                     {error, wait_for_memcached_failed, [node()]} |
                     {error, marking_as_warmed_failed, [node()]} |
                     {error, unsafe_nodes, [node()]}.
cleanup(Bucket, Options) ->
    FullConfig = ns_config:get(),
    case ns_bucket:get_bucket(Bucket, FullConfig) of
        not_present ->
            ok;
        {ok, BucketConfig} ->
            %% temporary fix for possible consequence of MB-27160
            %% to be removed in 5.1 and reimplemented in cluster config upgrade
            ns_bucket:default_sasl_password_fixup(Bucket, BucketConfig),

            case ns_bucket:bucket_type(BucketConfig) of
                membase ->
                    dcp = ns_bucket:replication_type(BucketConfig),
                    cleanup_with_membase_bucket_check_servers(Bucket, Options,
                                                              BucketConfig, FullConfig);
                _ -> ok
            end
    end.

cleanup_with_membase_bucket_check_servers(Bucket, Options, BucketConfig, FullConfig) ->
    case compute_servers_list_cleanup(BucketConfig, FullConfig) of
        none ->
            cleanup_with_membase_bucket_check_map(Bucket, Options, BucketConfig);
        {update_servers, NewServers} ->
            ?log_debug("janitor decided to update servers list"),
            ns_bucket:set_servers(Bucket, NewServers),
            cleanup(Bucket, Options)
    end.

cleanup_with_membase_bucket_check_map(Bucket, Options, BucketConfig) ->
    case proplists:get_value(map, BucketConfig, []) of
        [] ->
            Servers = proplists:get_value(servers, BucketConfig, []),
            true = (Servers =/= []),
            case janitor_agent:wait_for_bucket_creation(Bucket, Servers) of
                [_|_] = Down ->
                    ?log_info("~s: Some nodes (~p) are still not ready to see if we need to recover past vbucket map", [Bucket, Down]),
                    {error, wait_for_memcached_failed, Down};
                [] ->
                    NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),
                    NumReplicas = ns_bucket:num_replicas(BucketConfig),
                    {NewMap, Opts} =
                        case ns_janitor_map_recoverer:read_existing_map(Bucket, Servers, NumVBuckets, NumReplicas) of
                            {ok, M} ->
                                Opts1 = ns_bucket:config_to_map_options(BucketConfig),
                                {M, Opts1};
                            {error, no_map} ->
                                ?log_info("janitor decided to generate initial vbucket map"),
                                ns_rebalancer:generate_initial_map(BucketConfig)
                        end,

                    case ns_rebalancer:unbalanced(NewMap, BucketConfig) of
                        false ->
                            ns_bucket:update_vbucket_map_history(NewMap, Opts);
                        true ->
                            ok
                    end,

                    ns_bucket:set_map(Bucket, NewMap),
                    ns_bucket:set_map_opts(Bucket, Opts),
                    cleanup(Bucket, Options)
            end;
        _ ->
            cleanup_with_membase_bucket_vbucket_map(Bucket, Options, BucketConfig)
    end.

cleanup_with_membase_bucket_vbucket_map(Bucket, Options, BucketConfig) ->
    Servers = proplists:get_value(servers, BucketConfig, []),
    true = (Servers =/= []),
    Timeout = proplists:get_value(query_states_timeout, Options),
    {ok, States, Zombies} = janitor_agent:query_states(Bucket, Servers, Timeout),
    cleanup_with_states(Bucket, Options, BucketConfig, Servers, States,
                        Zombies).

cleanup_with_states(Bucket, _Options, _BucketConfig,
                    _Servers, _States, Zombies) when Zombies =/= [] ->
    ?log_info("Bucket ~p not yet ready on ~p", [Bucket, Zombies]),
    {error, wait_for_memcached_failed, Zombies};
cleanup_with_states(Bucket, Options, BucketConfig, Servers, States,
                    [] = Zombies) ->
    {NewBucketConfig, IgnoredVBuckets} =
        compute_vbucket_map_fixup(Bucket, BucketConfig, States, [] = Zombies),

    case NewBucketConfig =:= BucketConfig of
        true ->
            ok;
        false ->
            ?log_info("Janitor is going to change bucket config for bucket ~p",
                      [Bucket]),
            ?log_info("VBucket states:~n~p", [States]),
            ?log_info("Old bucket config:~n~p", [BucketConfig]),
            ok = ns_bucket:set_bucket_config(Bucket, NewBucketConfig)
    end,

    %% Find all the unsafe nodes (nodes on which memcached restarted within
    %% the auto-failover timeout) using the vbucket states. If atleast one
    %% unsafe node is found then we won't bring the bucket online until we
    %% we reprovision it. Reprovisioning is initiated by the orchestrator at
    %% the end of every janitor run.
    UnsafeNodes = find_unsafe_nodes_with_vbucket_states(
                    NewBucketConfig, States,
                    should_check_for_unsafe_nodes(NewBucketConfig, Options)),

    case UnsafeNodes =/= [] of
        true ->
            {error, unsafe_nodes, UnsafeNodes};
        false ->
            ApplyTimeout = proplists:get_value(apply_config_timeout, Options,
                                               undefined_timeout),
            ok = janitor_agent:apply_new_bucket_config_with_timeout(Bucket, undefined,
                                                                    Servers,
                                                                    NewBucketConfig,
                                                                    IgnoredVBuckets,
                                                                    ApplyTimeout),

            case Zombies =:= [] andalso
                proplists:get_bool(consider_stopping_rebalance_status, Options) of
                true ->
                    maybe_stop_rebalance_status();
                _ -> ok
            end,

            case janitor_agent:mark_bucket_warmed(Bucket, Servers) of
                ok ->
                    ok;
                {error, BadNodes, _BadReplies} ->
                    {error, marking_as_warmed_failed, BadNodes}
            end
    end.

should_check_for_unsafe_nodes(BCfg, Options) ->
    proplists:get_bool(check_for_unsafe_nodes, Options) andalso
        ns_bucket:storage_mode(BCfg) =:= ephemeral.

find_unsafe_nodes_with_vbucket_states(_BucketConfig, _States, false) ->
    [];
find_unsafe_nodes_with_vbucket_states(BucketConfig, States, true) ->
    Map = proplists:get_value(map, BucketConfig, []),
    true = (Map =/= []),
    EnumeratedChains = lists:zip(lists:seq(0, length(Map) - 1), Map),

    lists:foldl(
      fun ({VB, [Master | _ ] = Chain}, UnsafeNodesAcc) ->
              case lists:member(Master, UnsafeNodesAcc) of
                  true ->
                      UnsafeNodesAcc;
                  false ->
                      case data_loss_possible(VB, Chain, States) of
                          {true, Node} ->
                              [Node | UnsafeNodesAcc];
                          false ->
                              UnsafeNodesAcc
                      end
              end
      end, [], EnumeratedChains).

%% Condition that indicates possibility of data loss:
%% A vBucket is "missing" on a node where it is supposed to be active as per the
%% vBucket map, it is not active elsewhere in the cluster, and the vBucket is in
%% replica state on some other node[s]. If such a vBucket is brought online on
%% the node supposed to be its current master, then it will come up empty and
%% when the replication streams are establised the replicas will also lose their
%% data.
data_loss_possible(VBucket, Chain, States) ->
    {_NodeStates, ChainStates, ExtraStates} = construct_vbucket_states(VBucket,
                                                                       Chain,
                                                                       States,
                                                                       []),
    case ChainStates of
        [{Master, State}|ReplicaStates] when State =:= missing ->
            OtherNodeStates = ReplicaStates ++ ExtraStates,
            case [N || {N, active} <- OtherNodeStates] of
                [] ->
                    %% If none of the nodes have the vBucket active check if
                    %% the other nodes have the vBucket in replica state.
                    case [N || {N, replica} <- OtherNodeStates] of
                        [] ->
                            false;
                        Replicas ->
                            ?log_info("vBucket ~p missing on master ~p while "
                                      "replicas ~p are active. Can lead to "
                                      "dataloss.",
                                      [VBucket, Master, Replicas]),
                            {true, Master}
                    end;
                _ ->
                    false
            end;
        [{_,_}|_] ->
            false
    end.

stop_rebalance_status(Fn) ->
    Fun = fun ({rebalance_status, Value}) ->
                  case Value of
                      running ->
                          NewValue = Fn(),
                          {update, {rebalance_status, NewValue}};
                      _ ->
                          skip
                  end;
              ({rebalancer_pid, Pid}) when is_pid(Pid) ->
                  {update, {rebalancer_pid, undefined}};
              (_Other) ->
                  skip
          end,

    ok = ns_config:update(Fun).

maybe_stop_rebalance_status() ->
    Status = try ns_orchestrator:rebalance_progress_full()
             catch E:T ->
                     ?log_error("cannot reach orchestrator: ~p:~p", [E,T]),
                     error
             end,
    case Status of
        %% if rebalance is not actually running according to our
        %% orchestrator, we'll consider checking config and seeing if
        %% we should unmark is at not running
        not_running ->
            stop_rebalance_status(
              fun () ->
                      ale:info(?USER_LOGGER,
                               "Resetting rebalance status "
                               "since it's not really running"),
                      {none, <<"Rebalance stopped by janitor.">>}
              end);
        _ ->
            ok
    end.

%% !!! only purely functional code below (with notable exception of logging) !!!
%% lets try to keep as much as possible logic below this line

compute_servers_list_cleanup(BucketConfig, FullConfig) ->
    case proplists:get_value(servers, BucketConfig) of
        [] ->
            NewServers = ns_cluster_membership:service_active_nodes(FullConfig, kv),
            {update_servers, NewServers};
        Servers when is_list(Servers) ->
            none;
        Else ->
            ?log_error("Some garbage in servers field: ~p", [Else]),
            BucketConfig1 = [{servers, []} | lists:keydelete(servers, 1, BucketConfig)],
            compute_servers_list_cleanup(BucketConfig1, FullConfig)
    end.

enumerate_chains(BucketConfig) ->
    OrigMap = proplists:get_value(map, BucketConfig, []),
    true = ([] =/= OrigMap),
    Map = maybe_adjust_chain_size(OrigMap, BucketConfig),

    FFMap = case proplists:get_value(fastForwardMap, BucketConfig) of
                undefined -> [];
                FFMap0 ->
                    case FFMap0 =:= [] orelse length(FFMap0) =:= length(Map) of
                        true ->
                            FFMap0;
                        false ->
                            ?log_warning("fast forward map length doesn't match map length. Ignoring it"),
                            []
                    end
            end,
    EffectiveFFMap = case FFMap of
                         [] ->
                             [[] || _ <- Map];
                         _ ->
                             FFMap
                     end,
    MapLen = length(Map),
    EnumeratedChains = lists:zip3(lists:seq(0, MapLen - 1),
                                  Map,
                                  EffectiveFFMap),
    {EnumeratedChains, OrigMap, Map}.

compute_vbucket_map_fixup(Bucket, BucketConfig, States, [] = Zombies) ->
    {EnumeratedChains, OrigMap, AdjustedMap} = enumerate_chains(BucketConfig),
    MapUpdates = [sanify_chain(Bucket, States, Chain, FutureChain, VBucket, Zombies)
                  || {VBucket, Chain, FutureChain} <- EnumeratedChains],

    MapLen = length(AdjustedMap),
    IgnoredVBuckets = [VBucket || {VBucket, ignore} <-
                                      lists:zip(lists:seq(0, MapLen - 1),
                                                MapUpdates)],
    NewMap = [case NewChain of
                  ignore -> OldChain;
                  _ -> NewChain
              end || {NewChain, OldChain} <- lists:zip(MapUpdates, AdjustedMap)],
    NewBucketConfig = case NewMap =:= OrigMap of
                          true ->
                              BucketConfig;
                          false ->
                              ?log_debug("Janitor decided to update vbucket map"),
                              lists:keyreplace(map, 1, BucketConfig, {map, NewMap})
                      end,
    {NewBucketConfig, IgnoredVBuckets}.

maybe_adjust_chain_size(Map, BucketConfig) ->
    NumReplicas = ns_bucket:num_replicas(BucketConfig),
    case length(hd(Map)) =:= NumReplicas + 1 of
        true ->
            Map;
        false ->
            ns_janitor_map_recoverer:align_replicas(Map, NumReplicas)
    end.

sanify_chain(Bucket, States, Chain, FutureChain, VBucket, Zombies) ->
    NewChain = do_sanify_chain(Bucket, States, Chain, FutureChain, VBucket, Zombies),
    %% Fill in any missing replicas
    case is_list(NewChain) andalso length(NewChain) < length(Chain) of
        false ->
            NewChain;
        true ->
            NewChain ++ lists:duplicate(length(Chain) - length(NewChain),
                                        undefined)
    end.

construct_vbucket_states(VBucket, Chain, States, Zombies) ->
    NodeStates = [{N, S} || {N, V, S} <- States, V == VBucket],
    ChainStates = lists:map(
                    fun (N) ->
                            case lists:keyfind(N, 1, NodeStates) of
                                %% NOTE: cannot use code below
                                %% due to "stupid" warning by
                                %% dialyzer. Yes indeed our
                                %% Zombies is always [] as of
                                %% now
                                %%
                                %% false -> {N, case lists:member(N, Zombies) of
                                %%                  true -> zombie;
                                %%                  _ -> missing
                                %%              end};
                                false ->
                                    [] = Zombies,
                                    {N, missing};
                                X -> X
                            end
                    end, Chain),
    ExtraStates = [X || X = {N, _} <- NodeStates,
                        not lists:member(N, Chain)],
    {NodeStates, ChainStates, ExtraStates}.

%% this will decide what vbucket map chain is right for this vbucket
do_sanify_chain(Bucket, States, Chain, FutureChain, VBucket, [] = Zombies) ->
    {NodeStates, ChainStates, ExtraStates} = construct_vbucket_states(VBucket,
                                                                      Chain,
                                                                      States,
                                                                      Zombies),
    case ChainStates of
        [{undefined, _}|_] ->
            %% if for some reason (failovers most likely) we don't
            %% have master, there's not much we can do. Or at least
            %% that's how we have been behaving since early days.
            Chain;
        [{Master, State}|ReplicaStates] when State /= active andalso State /= zombie ->
            %% we know master according to map is not active. See if
            %% there's anybody else who is active and if we need to update map
            case [N || {N, active} <- ReplicaStates ++ ExtraStates] of
                [] ->
                    %% We'll let the next pass catch the replicas.
                    ?log_info("Setting vbucket ~p in ~p on ~p from ~p to active.",
                              [VBucket, Bucket, Master, State]),
                    %% nobody else (well, assuming zombies are not
                    %% active) is active. Let's activate according to vbucket map
                    Chain;
                [Node] ->
                    %% somebody else is active.
                    PickFutureChain =
                        case FutureChain of
                            [Node | _] ->
                                %% if active is future master check rest of future chain
                                active = proplists:get_value(hd(FutureChain), NodeStates),
                                %% and if everything fits -- cool
                                %%
                                %% we check expected replicas to be
                                %% replicas. One other allowed
                                %% possibility is if old master is
                                %% replica in ff chain. In which case
                                %% depending on where rebalance was
                                %% stopped it may be dead (if stopped
                                %% right after takeover) or replica
                                %% (if stopped after post-move vbucket
                                %% states are set).
                                lists:all(
                                  fun (undefined = _N) ->
                                          true;
                                      (N) ->
                                          ActualState = proplists:get_value(N, NodeStates),
                                          if
                                              ActualState =:= replica ->
                                                  true;
                                              N =:= Master ->
                                                  %% old master might
                                                  %% be dead or
                                                  %% replica. Replica
                                                  %% is tested above
                                                  ActualState =:= dead;
                                              true ->
                                                  false
                                          end
                                  end, tl(FutureChain));
                            _ ->
                                false
                        end,
                    case PickFutureChain of
                        true ->
                            ?log_warning("Master for vbucket ~p in ~p is not active, but entire fast-forward map chain fits (~p), so using it.", [VBucket, Bucket, FutureChain]),
                            FutureChain;
                        false ->
                            %% One active node, but it's not the
                            %% master.
                            %%
                            %% It's not fast-forward map master, so
                            %% we'll just update vbucket map. Note
                            %% behavior below with losing replicas
                            %% makes little sense as of
                            %% now. Especially with star
                            %% replication. But we can adjust it
                            %% later.
                            case misc:position(Node, Chain) of
                                false ->
                                    %% It's an extra node
                                    ?log_warning(
                                       "Master for vbucket ~p in ~p is not active, but ~p is, so making that the master.",
                                       [VBucket, Bucket, Node]),
                                    [Node];
                                Pos ->
                                    ?log_warning("Master for vbucket ~p in ~p is not active, but ~p is (one of replicas). So making that master.",
                                                 [VBucket, Bucket, Node]),
                                    [Node|lists:nthtail(Pos, Chain)]
                            end
                    end;
                Nodes ->
                    ?log_error("Extra active nodes ~p for vbucket ~p in ~p. This should never happen!",
                               [Nodes, Bucket, VBucket]),
                    %% just do nothing if there are two active
                    %% vbuckets and both are not master according to
                    %% vbucket map
                    ignore
            end;
        [{_,_} | _] ->
            %% NOTE: here we know that master is either active or zombie
            %% just keep existing vbucket map chain
            Chain
    end.

sanify_basic_test() ->
    %% normal case when everything matches vb map
    [a, b] = do_sanify_chain("B", [{a, 0, active}, {b, 0, replica}],
                             [a, b], [], 0, []),

    %% yes, the code will keep both masters as long as expected master
    %% is there. Possibly something to fix in future
    [a, b] = do_sanify_chain("B", [{a, 0, active}, {b, 0, active}],
                             [a, b], [], 0, []),

    %% main chain doesn't match but fast-forward chain does
    [b, c] = do_sanify_chain("B", [{a, 0, dead}, {b, 0, active}, {c, 0, replica}],
                             [a, b], [b, c], 0, []),

    %% main chain doesn't match but ff chain does. And old master is already deleted
    [b, c] = do_sanify_chain("B", [{b, 0, active}, {c, 0, replica}],
                             [a, b], [b, c], 0, []),

    %% lets make sure we touch all paths just in case
    %% this runs "there are >1 unexpected master" case
    ignore = do_sanify_chain("B", [{a, 0, active}, {b, 0, active}],
                             [c, a, b], [], 0, []),
    %% this runs "master is one of replicas" case
    [b] = do_sanify_chain("B", [{b, 0, active}, {c, 0, replica}],
                          [a, b], [], 0, []),
    %% and this runs "master is some non-chain member node" case
    [c] = do_sanify_chain("B", [{c, 0, active}],
                          [a, b], [], 0, []),

    %% lets also test rebalance stopped prior to complete takeover
    [a, b] = do_sanify_chain("B", [{a, 0, dead}, {b, 0, replica},
                                   {c, 0, pending}, {d, 0, replica}],
                             [a, b], [c, d], 0, []),
    ok.

sanify_doesnt_lose_replicas_on_stopped_rebalance_test() ->
    %% simulates the following: We've completed move that switches
    %% replica and active but rebalance was stopped before we updated
    %% vbmap. We have code in sanify to detect this condition using
    %% fast-forward map and is supposed to recover perfectly from this
    %% condition.
    [a, b] = do_sanify_chain("B", [{a, 0, active}, {b, 0, dead}],
                            [b, a], [a, b], 0, []),

    %% rebalance can be stopped after updating vbucket states but
    %% before vbucket map update
    [a, b] = do_sanify_chain("B", [{a, 0, active}, {b, 0, replica}],
                            [b, a], [a, b], 0, []),
    %% same stuff but prior to takeover
    [a, b] = do_sanify_chain("B", [{a, 0, dead}, {b, 0, pending}],
                             [a, b], [b, a], 0, []),
    %% lets test more usual case too
    [c, d] = do_sanify_chain("B", [{a, 0, dead}, {b, 0, replica},
                                   {c, 0, active}, {d, 0, replica}],
                             [a, b], [c, d], 0, []),
    %% but without FF map we're (too) conservative (should be fixable
    %% someday)
    [c] = do_sanify_chain("B", [{a, 0, dead}, {b, 0, replica},
                                {c, 0, active}, {d, 0, replica}],
                          [a, b], [], 0, []).
