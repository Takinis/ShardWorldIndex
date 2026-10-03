local transaction = require("modules/transaction")
local default_rpc_namespace = RPC_NAMESPACE
local wait_timeout = SECONDARY_SHARD_WAIT_TIMEOUT
local wait_poll_interval = SECONDARY_SHARD_WAIT_POLL_INTERVAL
local settle_delay = SECONDARY_SHARD_SETTLE_DELAY

    local request_serial = 0
    local pending_request = nil
    local prepared_requests = {}
    local restart_pending = false
    local finish_request

    local function get_durable_pending_request()
        local index = ShardGameIndex
        local state = index ~= nil and get_world_index_state(index) or nil
        return state ~= nil and state.secondary_finalize_pending or nil
    end

    local function is_master_shard()
        if Shard_IsMaster ~= nil then
            return Shard_IsMaster()
        end
        if TheShard ~= nil and TheShard.IsMaster ~= nil and TheShard:IsMaster() then
            return true
        end
        return TheNet ~= nil and TheShard ~= nil and
            TheNet:GetIsMasterSimulation() and
            (TheShard.IsSecondary == nil or not TheShard:IsSecondary())
    end

    local function get_index_shard(index)
        local shard = index ~= nil and index.GetShard ~= nil and index:GetShard() or nil
        if shard ~= nil and shard ~= "" then
            return shard
        end
        if TheShard ~= nil and TheShard.IsSecondary ~= nil and TheShard:IsSecondary() then
            return "Caves"
        end
        return "Master"
    end

    local function is_master_shard_id(shardid)
        return shardid == nil or shardid == "" or shardid == SHARDID.MASTER or shardid == "Master"
    end

    local function get_runtime_shard_id(index)
        local shardid = TheShard ~= nil and TheShard.GetShardId ~= nil and TheShard:GetShardId() or nil
        if shardid ~= nil and shardid ~= "" then
            return shardid
        end

        shardid = get_index_shard(index)
        return is_master_shard_id(shardid) and SHARDID.MASTER or shardid
    end

    local function force_local_players_to_master()
        if TheWorld == nil or not TheWorld.ismastersim or TheShard == nil or is_master_shard() then
            return
        end

        local players = {}
        if AllPlayers ~= nil then
            for _, player in ipairs(AllPlayers) do
                table.insert(players, player)
            end
        end

        for _, player in ipairs(players) do
            if player:IsValid() and player.userid ~= nil and player.userid ~= "" then
                TheWorld:PushEvent("ms_playerdespawnandmigrate",
                {
                    player = player,
                    portalid = nil,
                    worldid = SHARDID.MASTER,
                    x = 0,
                    y = 0,
                    z = 0,
                })
            end
        end
    end

    local function send_force_players_to_master_rpc(modname, rpcname)
        if SendModRPCToShard == nil or GetShardModRPC == nil or ShardList == nil or TheShard == nil then
            return
        end

        local rpc = GetShardModRPC(modname, rpcname or "ForcePlayersToMaster")
        if rpc == nil then
            return
        end

        local self_shard = TheShard:GetShardId()
        for shardid in pairs(ShardList) do
            if shardid ~= nil and shardid ~= self_shard and shardid ~= SHARDID.MASTER then
                SendModRPCToShard(rpc, shardid)
            end
        end
    end

    local function send_shard_rpc(modname, name, shardid, data)
        if SendModRPCToShard == nil or GetShardModRPC == nil then
            return
        end

        local rpc = GetShardModRPC(modname, name)
        if rpc == nil then
            return
        end

        local payload = data ~= nil and ZipAndEncodeString(data) or nil
        if payload ~= nil then
            SendModRPCToShard(rpc, shardid, payload)
        else
            SendModRPCToShard(rpc, shardid)
        end
    end

    local function send_rpc_to_other_secondary_shards(modname, name, data)
        if SendModRPCToShard == nil or GetShardModRPC == nil or ShardList == nil or TheShard == nil then
            return
        end

        local rpc = GetShardModRPC(modname, name)
        if rpc == nil then
            return
        end

        local payload = data ~= nil and ZipAndEncodeString(data) or nil
        local self_shard = TheShard:GetShardId()
        for shardid in pairs(ShardList) do
            if shardid ~= nil and shardid ~= self_shard and shardid ~= SHARDID.MASTER then
                if payload ~= nil then
                    SendModRPCToShard(rpc, shardid, payload)
                else
                    SendModRPCToShard(rpc, shardid)
                end
            end
        end
    end

    local function get_secondary_shard_ids()
        local shardids = {}
        if ShardList == nil or TheShard == nil then
            return shardids
        end

        local self_shard = tostring(TheShard:GetShardId())
        local master_shard = tostring(SHARDID.MASTER)
        for shardid in pairs(ShardList) do
            shardid = shardid ~= nil and tostring(shardid) or nil
            if shardid ~= nil and shardid ~= self_shard and shardid ~= master_shard then
                table.insert(shardids, shardid)
            end
        end
        table.sort(shardids, function(a, b)
            return tostring(a) < tostring(b)
        end)
        return shardids
    end

    local function send_request_rpc(request, rpc)
        for _, shardid in ipairs(request.shardids or {}) do
            local prepared = request.prepared ~= nil and request.prepared[shardid] or nil
            SendModRPCToShard(rpc, shardid, ZipAndEncodeString({
                request_id = request.id,
                operation = request.operation,
                file_id = prepared ~= nil and prepared.file_id or nil,
            }))
        end
    end

    local function start_waiting_for_replies(request, phase, timeout, label)
        request.phase = phase
        request.waiting = {}
        for _, shardid in ipairs(request.shardids or {}) do
            request.waiting[shardid] = true
        end
        pending_request = request
        request.timeout_task = TheWorld:DoStaticTaskInTime(timeout or wait_timeout, function()
            request.timeout_task = nil
            if pending_request ~= request then
                return
            end
            local missing = {}
            for shardid in pairs(request.waiting) do
                missing[#missing + 1] = tostring(shardid)
            end
            table.sort(missing)
            print("[Shard World Index] Timed out waiting for "..tostring(label)..
                " replies from shards: "..table.concat(missing, ", ")..".")
            finish_request(request, false)
        end)
    end

    local function send_secondary_world_index_abort(request)
        if request == nil then
            return
        end

        local rpc = GetShardModRPC(request.rpc_namespace or default_rpc_namespace, "AbortSecondaryWorldIndex")
        if rpc == nil then
            return
        end
        send_request_rpc(request, rpc)
        prepared_requests[request.id] = nil
    end

    local function send_secondary_world_index_finalize(request, timeout)
        local rpc = GetShardModRPC(request.rpc_namespace or default_rpc_namespace, "FinalizeSecondaryWorldIndex")
        if rpc == nil then
            return false
        end

        start_waiting_for_replies(request, "finalize", timeout, "finalize")
        send_request_rpc(request, rpc)
        return true
    end

    local function send_secondary_world_index_commit(request, timeout)
        local rpc = GetShardModRPC(request.rpc_namespace or default_rpc_namespace, "CommitSecondaryWorldIndex")
        if rpc == nil then
            return false
        end

        request.commit_decision_persisted = true
        start_waiting_for_replies(request, "commit", timeout, "commit")
        send_request_rpc(request, rpc)
        return true
    end

    finish_request = function(request, success)
        if pending_request ~= request then
            return
        end

        pending_request = nil
        if request.timeout_task ~= nil then
            request.timeout_task:Cancel()
            request.timeout_task = nil
        end
        local cb = request.cb or noop
        if request.phase == "finalize" then
            local worldindex = ShardGameIndex ~= nil and ShardGameIndex.worldindex or nil
            if success and worldindex ~= nil then
                worldindex:CompletePendingSecondaryFinalize(request.id, function(saved)
                    if not saved then
                        print("[Shard World Index] Finalize completed, but clearing the durable decision failed; retry remains pending.")
                    end
                    cb(true, request)
                end)
            else
                print("[Shard World Index] Finalize acknowledgements are incomplete; the request will be retried after shard reconnect.")
                cb(true, request)
            end
            return
        end

        if request.phase == "commit" and request.commit_decision_persisted and not success then
            prepared_requests[request.id] = nil
            print("[Shard World Index] Commit acknowledgements are incomplete; the durable commit decision will be retried.")
            cb(true, request)
            return
        end

        local should_abort = false
        local should_finalize = false
        local should_complete = true
        if request.phase == "prepare" and success then
            prepared_requests[request.id] = request
        elseif request.phase == "prepare" then
            should_abort = true
        elseif request.phase == "commit" then
            prepared_requests[request.id] = nil
            should_finalize = success
            should_abort = not success
            should_complete = not success
        elseif request.phase == "finalize" then
            prepared_requests[request.id] = nil
        end

        local function finish()
            if should_abort then
                send_secondary_world_index_abort(request)
            elseif should_finalize then
                should_complete = false
                if not send_secondary_world_index_finalize(request, request.timeout) then
                    print("[Shard World Index] Finalize RPC is unavailable; the durable commit decision remains pending.")
                    cb(true, request)
                end
            end
            if should_complete then
                cb(success, success and request or nil)
            end
        end
        if TheWorld ~= nil then
            TheWorld:DoStaticTaskInTime(0, finish)
        else
            finish()
        end
    end

    local function request_secondary_world_index(name, data, cb, timeout, rpc_namespace)
        cb = cb or noop
        if not is_master_shard() or SendModRPCToShard == nil or GetShardModRPC == nil or TheWorld == nil then
            print("[Shard World Index] Cannot request secondary WorldIndex preparation from this shard.")
            cb(false)
            return false
        end
        if pending_request ~= nil or next(prepared_requests) ~= nil or get_durable_pending_request() ~= nil then
            print("[Shard World Index] Another secondary WorldIndex request is still pending.")
            cb(false)
            return false
        end

        local shardids = get_secondary_shard_ids()
        if #shardids == 0 then
            cb(true, nil)
            return true
        end

        rpc_namespace = rpc_namespace or default_rpc_namespace
        local rpc = GetShardModRPC(rpc_namespace, name)
        if rpc == nil then
            print("[Shard World Index] Missing shard RPC for "..tostring(name)..".")
            cb(false)
            return false
        end

        request_serial = request_serial + 1
        local request_id = table.concat({ tostring(TheShard:GetShardId()), tostring(os.time()), tostring(request_serial) }, ":")
        local payload_data = deepcopy_safe(data) or {}
        payload_data.request_id = request_id

        local request =
        {
            id = request_id,
            operation = name,
            rpc_namespace = rpc_namespace,
            shardids = shardids,
            prepared = {},
            cb = cb,
            timeout = timeout,
        }
        start_waiting_for_replies(request, "prepare", timeout, name)

        local payload = ZipAndEncodeString(payload_data)
        for _, shardid in ipairs(shardids) do
            print("[Shard World Index] Requesting "..tostring(name).." from shard "..tostring(shardid).." ("..request_id..").")
            SendModRPCToShard(rpc, shardid, payload)
        end
        return true
    end

    local function commit_secondary_world_index_request(request, cb, timeout)
        cb = cb or noop
        if request == nil then
            cb(true)
            return true
        end
        if prepared_requests[request.id] ~= request or pending_request ~= nil then
            cb(false)
            return false
        end

        local rpc = GetShardModRPC(request.rpc_namespace or default_rpc_namespace, "CommitSecondaryWorldIndex")
        if rpc == nil then
            send_secondary_world_index_abort(request)
            cb(false)
            return false
        end

        local worldindex = ShardGameIndex ~= nil and ShardGameIndex.worldindex or nil
        if worldindex == nil then
            send_secondary_world_index_abort(request)
            cb(false)
            return false
        end

        pending_request = request
        request.phase = "persist_commit"
        request.cb = cb
        request.timeout = timeout
        worldindex:PersistPendingSecondaryFinalize(request, function(saved)
            if pending_request == request then
                pending_request = nil
            end
            if not saved then
                send_secondary_world_index_abort(request)
                cb(false)
                return
            end
            if not send_secondary_world_index_commit(request, timeout) then
                cb(true, request)
            end
        end)
        return true
    end

    local function abort_secondary_world_index_request(request)
        if request == nil then
            return
        end
        if pending_request == request then
            pending_request = nil
            if request.timeout_task ~= nil then
                request.timeout_task:Cancel()
                request.timeout_task = nil
            end
        end
        send_secondary_world_index_abort(request)
    end

    local function handle_secondary_world_index_reply(shardid, data)
        local request = pending_request
        shardid = shardid ~= nil and tostring(shardid) or nil
        if request == nil or type(data) ~= "table" or data.request_id ~= request.id or
            data.operation ~= request.operation or data.phase ~= request.phase or request.waiting[shardid] ~= true then
            return false
        end

        if data.success ~= true then
            print("[Shard World Index] Shard "..tostring(shardid).." failed during "..tostring(request.phase)..
                " for "..tostring(request.operation)..".")
            finish_request(request, false)
            return true
        end

        request.waiting[shardid] = nil
        if request.phase == "prepare" then
            request.prepared[shardid] = { file_id = data.file_id }
        end
        print("[Shard World Index] Shard "..tostring(shardid).." completed "..tostring(request.phase)..
            " for "..tostring(request.operation).." ("..request.id..").")
        if next(request.waiting) == nil then
            finish_request(request, true)
        end
        return true
    end

    local function persist_pending_secondary_finalize(index, request, cb)
        cb = cb or noop
        if index == nil or request == nil then
            cb(false)
            return
        end

        local state = get_world_index_state(index)
        if state == nil then
            cb(false)
            return
        end

        local previous_pending = deepcopy_safe(state.secondary_finalize_pending)
        local previous_transaction = deepcopy_safe(state.transaction)
        local previous_epoch = state.transaction_epoch
        local previous_revision = state.revision
        local previous_updated_at = state.updated_at
        state.secondary_finalize_pending =
        {
            request_id = request.id,
            operation = request.operation,
            status = "commit",
            rpc_namespace = request.rpc_namespace,
            shardids = deepcopy_safe(request.shardids),
            prepared = deepcopy_safe(request.prepared),
            timeout = request.timeout,
            file_id = state.file_id,
            updated_at = os.time(),
        }
        transaction.SetPhase(state, "finalize_pending")
        write_world_index_sidecar(index, state, function(saved)
            if not saved then
                state.secondary_finalize_pending = previous_pending
                state.transaction = previous_transaction
                state.transaction_epoch = previous_epoch
                state.revision = previous_revision
                state.updated_at = previous_updated_at
            end
            cb(saved == true)
        end, state.file_id)
    end

    local function complete_pending_secondary_finalize(index, request_id, cb)
        cb = cb or noop
        local state = index ~= nil and get_world_index_state(index) or nil
        local pending = state ~= nil and state.secondary_finalize_pending or nil
        if pending == nil or pending.request_id ~= request_id then
            cb(false)
            return
        end

        state.secondary_finalize_pending = nil
        transaction.SetPhase(state, "finalized")
        write_world_index_sidecar(index, state, function(saved)
            if not saved then
                state.secondary_finalize_pending = pending
                transaction.SetPhase(state, "finalize_pending")
            end
            cb(saved == true)
        end, state.file_id)
    end

    local function retry_pending_secondary_finalize(index)
        if index == nil or pending_request ~= nil or next(prepared_requests) ~= nil then
            return false
        end

        local state = get_world_index_state(index)
        local pending = state ~= nil and state.secondary_finalize_pending or nil
        if pending == nil or type(pending.request_id) ~= "string" or pending.request_id == "" then
            return false
        end

        local request =
        {
            id = pending.request_id,
            operation = pending.operation,
            rpc_namespace = pending.rpc_namespace or default_rpc_namespace,
            phase = "finalize",
            shardids = deepcopy_safe(pending.shardids) or {},
            prepared = deepcopy_safe(pending.prepared) or {},
            timeout = pending.timeout,
            cb = noop,
            commit_decision_persisted = true,
        }
        if #request.shardids == 0 then
            return false
        end
        prepared_requests[request.id] = request
        local sent = send_secondary_world_index_commit(request, request.timeout)
        if not sent then
            prepared_requests[request.id] = nil
        end
        return sent
    end

    local function send_rpc_to_master_shard(modname, name, data)
        send_shard_rpc(modname, name, SHARDID.MASTER, data)
    end

    local function get_secondary_shard_player_counts()
        if TheWorld == nil or TheShard == nil or TheShard.GetSecondaryShardPlayerCounts == nil or not is_master_shard() then
            return 0, 0
        end

        local secondary_players, secondary_ghosts = TheShard:GetSecondaryShardPlayerCounts(USERFLAGS.IS_GHOST)
        return secondary_players or 0, secondary_ghosts or 0
    end

    local function get_secondary_shard_player_count()
        local secondary_players = get_secondary_shard_player_counts()
        return secondary_players
    end

    local function wait_for_secondary_shard_players_empty(cb, timeout, poll_interval)
        cb = cb or noop

        if TheWorld == nil or TheShard == nil or TheShard.GetSecondaryShardPlayerCounts == nil or not is_master_shard() then
            cb(true)
            return
        end

        timeout = timeout or wait_timeout
        poll_interval = poll_interval or wait_poll_interval

        local started_at = GetTime()
        local function poll()
            local secondary_players = get_secondary_shard_player_counts()

            if secondary_players <= 0 then
                TheWorld:DoTaskInTime(settle_delay, function()
                    cb(true)
                end)
                return
            end

            if GetTime() - started_at >= timeout then
                print("[Shard World Index] Timed out waiting for secondary shard players to return to master. Remaining secondary players: "..tostring(secondary_players))
                cb(false)
                return
            end

            TheWorld:DoTaskInTime(poll_interval, poll)
        end

        poll()
    end

    local function restart_current_slot(index, extra_params)
        local params = extra_params or {}
        params.reset_action = RESET_ACTION.LOAD_SLOT
        params.save_slot = index:GetSlot()
        StartNextInstance(params)
    end

    local function restart_current_slot_after_shard_rpc(index, extra_params)
        if restart_pending then
            return false
        end
        restart_pending = true

        if TheWorld ~= nil then
            TheWorld:DoStaticTaskInTime(settle_delay, function()
                restart_current_slot(index, extra_params)
            end)
        else
            restart_current_slot(index, extra_params)
        end
        return true
    end

    return
    {
        IsMasterShard = is_master_shard,
        GetIndexShard = get_index_shard,
        GetRuntimeShardId = get_runtime_shard_id,
        ForceLocalPlayersToMaster = force_local_players_to_master,
        SendForcePlayersToMasterRPC = send_force_players_to_master_rpc,
        SendShardRPC = send_shard_rpc,
        SendRPCToOtherSecondaryShards = send_rpc_to_other_secondary_shards,
        RequestSecondaryWorldIndex = request_secondary_world_index,
        CommitSecondaryWorldIndex = commit_secondary_world_index_request,
        AbortSecondaryWorldIndex = abort_secondary_world_index_request,
        IsSecondaryWorldIndexRequestPending = function()
            return pending_request ~= nil or next(prepared_requests) ~= nil or
                get_durable_pending_request() ~= nil
        end,
        HandleSecondaryWorldIndexReply = handle_secondary_world_index_reply,
        PersistPendingSecondaryFinalize = persist_pending_secondary_finalize,
        CompletePendingSecondaryFinalize = complete_pending_secondary_finalize,
        RetryPendingSecondaryFinalize = retry_pending_secondary_finalize,
        SendRPCToMasterShard = send_rpc_to_master_shard,
        GetSecondaryShardPlayerCount = get_secondary_shard_player_count,
        GetSecondaryShardPlayerCounts = get_secondary_shard_player_counts,
        WaitForSecondaryShardPlayersEmpty = wait_for_secondary_shard_players_empty,
        RestartCurrentSlotAfterShardRPC = restart_current_slot_after_shard_rpc,
    }
