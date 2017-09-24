%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
%% @doc this module implements access to cbq-engine via REST API
%%

-module(cbas_rest).

-include("ns_common.hrl").

-export([get_stats/0]).

get_stats() ->
    case ns_cluster_membership:should_run_service(ns_config:latest(), cbas, node()) of
        true ->
            do_get_stats();
        false ->
            []
    end.

get_port() ->
    ns_config:read_key_fast({node, node(), cbas_http_port}, 8905).

get_timeout() ->
    30000.

do_get_stats() ->
    NodeInfoURL = lists:flatten(io_lib:format("http://127.0.0.1:~B/~s", [get_port(), "analytics/node/stats"])),
    NodeInfo  = proc_rv(send("GET", NodeInfoURL, get_timeout())),
    {ok, {NodeInfo}}.

proc_rv(RV) ->
    case RV of
        {200, _Headers, BodyRaw} ->
            case (catch ejson:decode(BodyRaw)) of
                {[_ | _] = Stats} ->
                    Stats;
                Err ->
                    ?log_error("Failed to parse analytics stats: ~p", [Err]),
                    []
            end;
        _ ->
            ?log_error("Ignoring. Failed to grab stats: ~p", [RV]),
            []
    end.

send(Method, URL, Timeout) ->
    % MB-26150 - [CX] Add authentication to stats API
    {ok, {{Code, _}, RespHeaders, RespBody}} =
        rest_utils:request(query, URL, Method, [], [], Timeout),
    {Code, RespHeaders, RespBody}.