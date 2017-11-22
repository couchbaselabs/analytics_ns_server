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
-module(json_settings_manager).

-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([start_link/1,
         get/3,
         build_settings_json/3,
         get_from_config/4,
         fetch_settings_json/2,
         decode_settings_json/1,
         id_lens/1,
         lens_get_many/2,
         lens_set_many/3,
         update/2,
         update_txn/3
        ]).

start_link(Module) ->
    work_queue:start_link(Module, fun () -> init(Module) end).

get(Module, Key, Default) when is_atom(Key) ->
    case ets:lookup(Module, Key) of
        [{Key, Value}] ->
            Value;
        [] ->
            Default
    end.

get_from_config(M, Config, Key, Default) ->
    case Config =:= ns_config:latest() of
        true ->
            json_settings_manager:get(M, Key, Default);
        false ->
            case ns_config:search(Config, M:cfg_key()) of
                {value, JSON} ->
                    get_from_json(Key, JSON, M:known_settings());
                false ->
                    Default
            end
    end.

init(M) ->
    ets:new(M, [named_table, set, protected]),
    ModCfgKey = M:cfg_key(),
    ns_pubsub:subscribe_link(ns_config_events,
                             fun ({Key, JSON}, Pid) when (Key =:= ModCfgKey) ->
                                     submit_config_update(M, Pid, JSON),
                                     Pid;
                                 ({cluster_compat_version, _}, Pid) ->
                                     submit_full_refresh(M, Pid),
                                     Pid;
                                 (_, Pid) ->
                                     Pid
                             end, self()),
    populate_ets_table(M).

update(M, Props) ->
    work_queue:submit_sync_work(
      M,
      fun () ->
              do_update(M, Props)
      end).

get_from_json(Key, JSON, KSettings) ->
    {_, Lens} = lists:keyfind(Key, 1, KSettings),
    Settings = decode_settings_json(JSON),
    lens_get(Lens, Settings).

update_txn(Props, CfgKey, Settings) ->
    fun (Config, SetFn) ->
            JSON = fetch_settings_json(Config, CfgKey),
            Current = decode_settings_json(JSON),

            New = build_settings_json(Props, Current, Settings),
            {commit, SetFn(CfgKey, New, Config), New}
    end.

do_update(M, Props) ->
    RV = ns_config:run_txn(update_txn(Props, M:cfg_key(), M:known_settings())),
    case RV of
        {commit, _, NewJSON} ->
            populate_ets_table(M, NewJSON),
            {ok, ets:tab2list(M)};
        _ ->
            RV
    end.

submit_full_refresh(M, Pid) ->
    work_queue:submit_work(
      Pid,
      fun () ->
              populate_ets_table(M)
      end).

submit_config_update(M, Pid, JSON) ->
    work_queue:submit_work(
      Pid,
      fun () ->
              populate_ets_table(M, JSON)
      end).

fetch_settings_json(CfgKey) ->
    fetch_settings_json(ns_config:latest(), CfgKey).

fetch_settings_json(Config, CfgKey) ->
    ns_config:search(Config, CfgKey, <<"{}">>).

build_settings_json(Props, Dict, KnownSettings) ->
    NewDict = lens_set_many(KnownSettings, Props, Dict),
    ejson:encode({dict:to_list(NewDict)}).

decode_settings_json(JSON) ->
    {Props} = ejson:decode(JSON),
    dict:from_list(Props).

populate_ets_table(M) ->
    JSON = fetch_settings_json(M:cfg_key()),
    populate_ets_table(M, JSON).

populate_ets_table(M, JSON) ->
    case not M:required_compat_mode()
        orelse erlang:get(prev_json) =:= JSON of
        true ->
            ok;
        false ->
            do_populate_ets_table(M, JSON, M:known_settings())
    end.

do_populate_ets_table(M, JSON, Settings) ->
    Dict = decode_settings_json(JSON),
    NotFound = make_ref(),

    lists:foreach(
      fun ({Key, NewValue}) ->
              OldValue = json_settings_manager:get(M, Key, NotFound),
              case OldValue =:= NewValue of
                  true ->
                      ok;
                  false ->
                      ets:insert(M, {Key, NewValue}),
                      case M =:= index_settings_manager of
                          true ->
                              gen_event:notify(index_events,
                                               {index_settings_change, Key, NewValue});
                          false ->
                              ok
                      end
              end
      end, lens_get_many(Settings, Dict)),

    erlang:put(prev_json, JSON).

id_lens(Key) ->
    Get = fun (Dict) ->
                  dict:fetch(Key, Dict)
          end,
    Set = fun (Value, Dict) ->
                  dict:store(Key, Value, Dict)
          end,
    {Get, Set}.

lens_get({Get, _}, Dict) ->
    Get(Dict).

lens_get_many(Lenses, Dict) ->
    [{Key, lens_get(L, Dict)} || {Key, L} <- Lenses].

lens_set(Value, {_, Set}, Dict) ->
    Set(Value, Dict).

lens_set_many(Lenses, Values, Dict) ->
    lists:foldl(
      fun ({Key, Value}, Acc) ->
              {Key, L} = lists:keyfind(Key, 1, Lenses),
              lens_set(Value, L, Acc)
      end, Dict, Values).
