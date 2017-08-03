%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
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

-define(ERROR_NOT_FOUND, <<"not_found">>).
-define(ERROR_CONFLICT, <<"conflict">>).
-define(ERROR_NOT_SUPPORTED, <<"operation_not_supported">>).
-define(ERROR_RECOVERY_IMPOSSIBLE, <<"recovery_impossible">>).
-define(ERROR_CBAS_MASTER_EJECT_NOT_SUPPORTED, <<"cbas_master_eject_not_supported">>).

-define(TOPOLOGY_CHANGE_REBALANCE, <<"topology-change-rebalance">>).
-define(TOPOLOGY_CHANGE_FAILOVER, <<"topology-change-failover">>).

-define(TASK_TYPE_REBALANCE, <<"task-rebalance">>).
-define(TASK_TYPE_PREPARED, <<"task-prepared">>).

-define(TASK_STATUS_RUNNING, <<"task-running">>).
-define(TASK_STATUS_FAILED, <<"task-failed">>).

-define(RECOVERY_FULL, <<"recovery-full">>).
-define(RECOVERY_DELTA, <<"recovery-delta">>).
