%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
-module(replication_manager).

-behavior(gen_server).

-include("ns_common.hrl").

-record(state, {bucket_name :: bucket_name(),
                desired_replications :: [{node(), [vbucket_id()]}]}).

-export([start_link/1,
         get_incoming_replication_map/1,
         set_incoming_replication_map/2,
         change_vbucket_replication/3,
         remove_undesired_replications/2,
         dcp_takeover/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

server_name(Bucket) ->
    list_to_atom("replication_manager-" ++ Bucket).

start_link(Bucket) ->
    gen_server:start_link({local, server_name(Bucket)}, ?MODULE, Bucket, []).

init(Bucket) ->
    {ok, #state{
            bucket_name = Bucket,
            desired_replications = []}}.

get_incoming_replication_map(Bucket) ->
    dcp_replication_manager:get_actual_replications(Bucket).

-spec set_incoming_replication_map(bucket_name(),
                                   [{node(), [vbucket_id(),...]}]) -> ok.
set_incoming_replication_map(Bucket, DesiredReps) ->
    gen_server:call(server_name(Bucket), {set_desired_replications, DesiredReps}, infinity).

-spec remove_undesired_replications(bucket_name(), [{node(), [vbucket_id(),...]}]) -> ok.
remove_undesired_replications(Bucket, DesiredReps) ->
    gen_server:call(server_name(Bucket), {remove_undesired_replications, DesiredReps}, infinity).

-spec change_vbucket_replication(bucket_name(), vbucket_id(), node() | undefined) -> ok.
change_vbucket_replication(Bucket, VBucket, ReplicateFrom) ->
    gen_server:call(server_name(Bucket), {change_vbucket_replication, VBucket, ReplicateFrom}, infinity).

dcp_takeover(Bucket, OldMasterNode, VBucket) ->
    gen_server:call(server_name(Bucket), {dcp_takeover, OldMasterNode, VBucket}, infinity).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

terminate(Reason, State) ->
    ?log_debug("Replication manager died ~p", [{Reason, State}]),
    ok.

handle_info(_Msg, State) ->
    {noreply, State}.

handle_call({remove_undesired_replications, FutureReps}, From, State) ->
    %% Sometimes the state in the replication manager can be out of sync.
    %% E.g. the dcp connections are nuked when rebalance fails,
    %% but the replication_manager might not be aware of it.
    %% Getting current replications from the replicators will greatly
    %% reduce the window where the replication manager is out of sync.
    %% It does not close the window entirely because
    %% at the time of get_actual_replications_as_list(), there may be
    %% some streams in the process of being created or removed which
    %% will not be included in the list.
    %% Closing the window entirely is a non-trvial and risky change.
    CurrentReps = get_actual_replications_as_list(State),
    Diff = replications_difference(FutureReps, CurrentReps),
    CleanedReps0 = [{N, ordsets:intersection(FutureVBs, CurrentVBs)} || {N, FutureVBs, CurrentVBs} <- Diff],
    CleanedReps = [{N, VBs} || {N, [_|_] = VBs} <- CleanedReps0],
    handle_call({set_desired_replications, CleanedReps}, From, State);

handle_call({set_desired_replications, DesiredReps}, _From,
            #state{bucket_name = Bucket} = State) ->

    %% If the cluster is not fully 5.0 then the DCP connections opened by
    %% the replicators won't include XATTRs. But when the cluster turns fully
    %% 5.0 then the DCP connections need to be re-established with XATTRs
    %% set. This code path is invoked by the ns_janitor via the respective
    %% janitor agents. Here we essentially determine if the cluster has
    %% become XATTR aware and whether or not to indicate the downstream
    %% DCP replication modules to drop the existing connections and recreate
    %% them. This could mean that the ongoing rebalance can fail and we are
    %% ok with that as it can be restarted.
    XAttr = cluster_compat_mode:is_cluster_50(),

    RV = dcp_replication_manager:set_desired_replications(Bucket, DesiredReps, XAttr),
    {reply, RV, State#state{desired_replications = DesiredReps}};
handle_call({change_vbucket_replication, VBucket, NewSrc}, _From, State) ->
    CurrentReps = get_actual_replications_as_list(State),
    CurrentReps0 = [{Node, ordsets:del_element(VBucket, VBuckets)}
                    || {Node, VBuckets} <- CurrentReps],
    %% TODO: consider making it faster
    DesiredReps = case NewSrc of
                      undefined ->
                          CurrentReps0;
                      _ ->
                          misc:ukeymergewith(fun ({Node, VBucketsA}, {_, VBucketsB}) ->
                                                     {Node, ordsets:union(VBucketsA, VBucketsB)}
                                             end, 1,
                                             CurrentReps0, [{NewSrc, [VBucket]}])
                  end,
    handle_call({set_desired_replications, DesiredReps}, [], State);
handle_call({dcp_takeover, OldMasterNode, VBucket}, _From,
            #state{bucket_name = Bucket,
                   desired_replications = CurrentReps} = State) ->
    DesiredReps = lists:map(fun ({Node, VBuckets}) ->
                                    case Node of
                                        OldMasterNode ->
                                            {Node, ordsets:del_element(VBucket, VBuckets)};
                                        _ ->
                                            {Node, VBuckets}
                                    end
                            end, CurrentReps),
    {reply, dcp_replicator:takeover(OldMasterNode, Bucket, VBucket),
     State#state{desired_replications = DesiredReps}}.

replications_difference(RepsA, RepsB) ->
    L = [{N, VBs, []} || {N, VBs} <- RepsA],
    R = [{N, [], VBs} || {N, VBs} <- RepsB],
    MergeFn = fun ({N, VBsL, []}, {N, [], VBsR}) ->
                      {N, VBsL, VBsR}
              end,
    misc:ukeymergewith(MergeFn, 1, L, R).

get_actual_replications_as_list(#state{bucket_name = Bucket}) ->
    case dcp_replication_manager:get_actual_replications(Bucket) of
        not_running ->
            [];
        Reps ->
            Reps
    end.
