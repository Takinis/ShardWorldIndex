local AddModRPCHandler = AddModRPCHandler
local AddClientModRPCHandler = AddClientModRPCHandler
local AddShardModRPCHandler = AddShardModRPCHandler
GLOBAL.setfenv(1, GLOBAL)

local secondary_operation = nil
local forwarded_requests = {}

local function is_master_shard_id(shardid)
    if shardid == nil then
        return false
    end
    shardid = tostring(shardid)
    return shardid == tostring(SHARDID.MASTER) or shardid == "Master"
end

local function is_master_shard_runtime()
    return ShardWorldIndex ~= nil and ShardWorldIndex:IsMasterShard()
end

local function is_secondary_request_from_master(shardid)
    return not is_master_shard_runtime() and is_master_shard_id(shardid)
end

local function is_master_request_from_secondary(shardid)
    return is_master_shard_runtime() and shardid ~= nil and not is_master_shard_id(shardid)
end

local function decode_shard_payload(data)
    if data == nil then
        return {}
    end
    data = DecodeAndUnzipString(data)
    return type(data) == "table" and data or {}
end

local function get_world_index()
    return ShardGameIndex ~= nil and ShardGameIndex.worldindex or nil
end

local function get_runtime_session_id()
    local session_id = TheWorld ~= nil and TheWorld.meta ~= nil and
        TheWorld.meta.session_identifier or nil
    return type(session_id) == "string" and session_id ~= "" and session_id or nil
end

local function get_restart_params(operation)
    local transition = operation == "BeginSecondaryWorldIndex" and "secondary_begin" or
        operation == "AdvanceSecondaryWorldIndex" and "secondary_advance" or "secondary_return"
    return { world_index_transition = transition }
end

local function restart_secondary_transition(worldindex, operation, retry_id)
    local params = get_restart_params(operation)
    if retry_id ~= nil then
        if type(retry_id) ~= "string" or retry_id == "" then
            print("[Shard World Index] Cannot retry a secondary transition without a request id.")
            return false
        end
        if Settings ~= nil and Settings.secondary_transition_retry_id == retry_id then
            print("[Shard World Index] Secondary transition retry failed for "..retry_id.."; keeping the transaction for a later restart.")
            return false
        end
        params.secondary_transition_retry_id = retry_id
    end
    return worldindex:RestartCurrentSlotAfterShardRPC(params) ~= false
end

local function begin_secondary_operation(request_id, phase)
    if type(request_id) ~= "string" or request_id == "" then
        return nil
    end

    if secondary_operation == nil then
        secondary_operation =
        {
            request_id = request_id,
        }
    elseif secondary_operation.request_id ~= request_id or secondary_operation.running then
        return nil
    end

    secondary_operation.phase = phase
    secondary_operation.running = true
    return secondary_operation
end

local function finish_secondary_operation(operation, retain)
    if secondary_operation ~= operation then
        return
    end

    operation.running = false
    if not retain then
        secondary_operation = nil
    end
end

local function reply(worldindex, shardid, opts, operation, phase, success, file_id)
    if type(opts.request_id) ~= "string" or opts.request_id == "" then
        return
    end

    local function send_reply()
        worldindex:SendShardRPC(RPC_NAMESPACE, "SecondaryWorldIndexReply", shardid,
        {
            request_id = opts.request_id,
            operation = operation,
            phase = phase,
            success = success == true,
            file_id = file_id,
        })
    end

    if TheWorld ~= nil then
        TheWorld:DoStaticTaskInTime(0, send_reply)
    else
        send_reply()
    end
end

AddShardModRPCHandler(RPC_NAMESPACE, "ForcePlayersToMaster", function(shardid)
    if is_secondary_request_from_master(shardid) then
        ShardWorldIndex:ForceLocalPlayersToMaster()
    end
end)

AddShardModRPCHandler(RPC_NAMESPACE, "ForwardWorldIndexTransition", function(shardid, data)
    if not is_master_request_from_secondary(shardid) then
        return
    end

    local worldindex = get_world_index()
    if worldindex == nil then
        return
    end

    local request = decode_shard_payload(data)
    if type(request.request_id) ~= "string" or request.request_id == "" or
        type(request.operation) ~= "string" or request.operation == "" or
        type(request.opts) ~= "table" then
        return
    end
    local existing = forwarded_requests[request.request_id]
    if existing ~= nil then
        if existing.completed then
            local function send_cached_reply()
                worldindex:SendShardRPC(RPC_NAMESPACE, "ForwardWorldIndexTransitionReply", shardid,
                {
                    request_id = request.request_id,
                    success = existing.success == true,
                })
            end
            if TheWorld ~= nil then
                TheWorld:DoStaticTaskInTime(0, send_cached_reply)
            else
                send_cached_reply()
            end
        end
        return
    end
    local request_state = {}
    forwarded_requests[request.request_id] = request_state

    local replied = false
    local function reply_forwarded(success)
        if replied then
            return
        end
        replied = true
        request_state.completed = true
        request_state.success = success == true
        local function send_reply()
            worldindex:SendShardRPC(RPC_NAMESPACE, "ForwardWorldIndexTransitionReply", shardid,
            {
                request_id = request.request_id,
                success = success == true,
            })
        end
        if TheWorld ~= nil then
            TheWorld:DoStaticTaskInTime(0, send_reply)
            TheWorld:DoStaticTaskInTime(FORWARDED_TRANSITION_TIMEOUT, function()
                if forwarded_requests[request.request_id] == request_state then
                    forwarded_requests[request.request_id] = nil
                end
            end)
        else
            send_reply()
            forwarded_requests[request.request_id] = nil
        end
    end

    local function execute_forwarded()
        if not worldindex:ExecuteForwardedTransition(request.operation, request.opts, reply_forwarded) then
            reply_forwarded(false)
        end
    end
    if TheWorld ~= nil then
        TheWorld:DoTaskInTime(0, execute_forwarded)
    else
        execute_forwarded()
    end
end)

AddShardModRPCHandler(RPC_NAMESPACE, "ForwardWorldIndexTransitionReply", function(shardid, data)
    if not is_secondary_request_from_master(shardid) then
        return
    end
    local worldindex = get_world_index()
    if worldindex ~= nil then
        worldindex:HandleForwardedTransitionReply(decode_shard_payload(data))
    end
end)

local function add_prepare_handler(operation)
    AddShardModRPCHandler(RPC_NAMESPACE, operation, function(shardid, data)
        if not is_secondary_request_from_master(shardid) then
            return
        end

        local worldindex = get_world_index()
        if worldindex == nil then
            return
        end

        local opts = decode_shard_payload(data)
        local secondary = begin_secondary_operation(opts.request_id, "prepare")
        if secondary == nil then
            reply(worldindex, shardid, opts, operation, "prepare", false)
            return
        end

        worldindex:PrepareSecondaryTransition(operation, opts, function(success, file_id)
            reply(worldindex, shardid, opts, operation, "prepare", success, file_id)
            finish_secondary_operation(secondary, success == true)
        end)
    end)
end

add_prepare_handler("BeginSecondaryWorldIndex")
add_prepare_handler("AdvanceSecondaryWorldIndex")
add_prepare_handler("ReturnSecondaryWorldIndex")

AddShardModRPCHandler(RPC_NAMESPACE, "SecondaryWorldIndexReply", function(shardid, data)
    if not is_master_request_from_secondary(shardid) then
        return
    end

    local worldindex = get_world_index()
    if worldindex ~= nil then
        worldindex:HandleSecondaryWorldIndexReply(shardid, decode_shard_payload(data))
    end
end)

AddShardModRPCHandler(RPC_NAMESPACE, "CommitSecondaryWorldIndex", function(shardid, data)
    if not is_secondary_request_from_master(shardid) then
        return
    end

    local worldindex = get_world_index()
    if worldindex == nil then
        return
    end

    local opts = decode_shard_payload(data)
    local secondary = begin_secondary_operation(opts.request_id, "commit")
    if secondary == nil then
        reply(worldindex, shardid, opts, opts.operation, "commit", false)
        return
    end

    worldindex:CommitPreparedSecondaryTransition(opts.request_id, opts.file_id, function(success, file_id)
        reply(worldindex, shardid, opts, opts.operation, "commit", success, file_id)
        finish_secondary_operation(secondary, success == true)
    end)
end)

AddShardModRPCHandler(RPC_NAMESPACE, "AbortSecondaryWorldIndex", function(shardid, data)
    if not is_secondary_request_from_master(shardid) then
        return
    end

    local worldindex = get_world_index()
    if worldindex == nil then
        return
    end

    local opts = decode_shard_payload(data)
    local abort_transition
    abort_transition = function()
        if secondary_operation ~= nil then
            if secondary_operation.request_id ~= opts.request_id then
                return
            end
            if not secondary_operation.running then
                secondary_operation = nil
            else
                if TheWorld ~= nil then
                    TheWorld:DoStaticTaskInTime(0, abort_transition)
                end
                return
            end
        end

        local secondary = begin_secondary_operation(opts.request_id, "abort")
        if secondary == nil then
            return
        end

        worldindex:AbortPreparedSecondaryTransition(opts.request_id, opts.file_id, function(success)
            if not success then
                local restarting = restart_secondary_transition(worldindex, opts.operation, opts.request_id)
                finish_secondary_operation(secondary, not restarting)
                return
            end

            local running_session_id = get_runtime_session_id()
            local indexed_session_id = ShardGameIndex ~= nil and ShardGameIndex:GetSession() or nil
            local restart_required = running_session_id ~= nil and indexed_session_id ~= nil and
                running_session_id ~= indexed_session_id
            if restart_required then
                restart_secondary_transition(worldindex, opts.operation)
            end
            finish_secondary_operation(secondary, false)
        end)
    end
    abort_transition()
end)

AddShardModRPCHandler(RPC_NAMESPACE, "FinalizeSecondaryWorldIndex", function(shardid, data)
    if not is_secondary_request_from_master(shardid) then
        return
    end

    local worldindex = get_world_index()
    if worldindex == nil then
        return
    end

    local opts = decode_shard_payload(data)
    local secondary = begin_secondary_operation(opts.request_id, "finalize")
    if secondary == nil then
        return
    end

    worldindex:FinalizeSecondaryTransition(opts.request_id, opts.file_id, function(success, committed)
        reply(worldindex, shardid, opts, opts.operation, "finalize", success == true, opts.file_id)
        if success and committed then
            restart_secondary_transition(worldindex, opts.operation)
            finish_secondary_operation(secondary, false)
        elseif not success then
            local restarting = restart_secondary_transition(worldindex, opts.operation, opts.request_id)
            finish_secondary_operation(secondary, not restarting)
        else
            finish_secondary_operation(secondary, false)
        end
    end)
end)

AddModRPCHandler(RPC_NAMESPACE, "PorklandEntranceTravel", function(player, guid, target)
    if player == nil or not player:IsValid() or type(guid) ~= "number" or
        (target ~= "forest" and target ~= "shipwrecked" and target ~= "porkland") then
        return
    end

    local inst = Ents[guid]
    if inst ~= nil and inst:IsValid() and inst.prefab == "porkland_entrance" and
        inst.TravelToWorld ~= nil then
        inst:TravelToWorld(player, target)
    end
end)

AddClientModRPCHandler(RPC_NAMESPACE, "WorldSwitchDenied", function(message)
    if ThePlayer ~= nil and ThePlayer.components.talker ~= nil then
        ThePlayer.components.talker:Say(message or STRINGS.UI.TELEPORTFAIL or "World switching is unavailable.")
    end
end)

local PopupDialogScreen = require("screens/redux/popupdialog")
AddClientModRPCHandler(RPC_NAMESPACE, "PorklandEntranceDialog", function(guid, current_world)
    if type(guid) ~= "number" or type(current_world) ~= "string" then
        return
    end

    local labels =
    {
        forest = STRINGS.UI.PORKLAND_ENTRANCE.FOREST,
        shipwrecked = STRINGS.UI.PORKLAND_ENTRANCE.SHIPWRECKED,
        porkland = STRINGS.UI.PORKLAND_ENTRANCE.PORKLAND,
    }
    local buttons = {}
    for _, target in ipairs({ "porkland", "shipwrecked", "forest" }) do
        if target ~= current_world then
            local destination = target
            table.insert(buttons,
            {
                text = labels[destination],
                cb = function()
                    TheFrontEnd:PopScreen()
                    SendModRPCToServer(GetModRPC(RPC_NAMESPACE, "PorklandEntranceTravel"), guid, destination)
                end,
            })
        end
    end
    table.insert(buttons,
    {
        text = STRINGS.UI.PORKLAND_ENTRANCE.CANCEL,
        cb = function()
            TheFrontEnd:PopScreen()
        end,
    })

    TheFrontEnd:PushScreen(PopupDialogScreen(
        STRINGS.UI.PORKLAND_ENTRANCE.TITLE,
        STRINGS.UI.PORKLAND_ENTRANCE.BODY,
        buttons,
        nil,
        "big",
        "dark_wide"
    ))
end)
