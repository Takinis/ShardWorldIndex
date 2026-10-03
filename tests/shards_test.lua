package.path = "scripts/?.lua;scripts/?/init.lua;"..package.path

RPC_NAMESPACE = "ShardWorldIndex"
SECONDARY_SHARD_WAIT_TIMEOUT = 10
SECONDARY_SHARD_WAIT_POLL_INTERVAL = 1
SECONDARY_SHARD_SETTLE_DELAY = 0
SHARDID = { MASTER = "Master" }
USERFLAGS = { IS_GHOST = 1 }
ShardList = { Caves = true }

noop = function()
end
deepcopy_safe = function(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[key] = deepcopy_safe(child)
    end
    return out
end

local sent = {}
local persisted = {}
local completed = {}
local persist_callback = nil
local durable_state = {}

get_world_index_state = function()
    return durable_state
end

Shard_IsMaster = function()
    return true
end
TheNet =
{
    GetIsMasterSimulation = function()
        return true
    end,
}
TheShard =
{
    GetShardId = function()
        return "Master"
    end,
    IsMaster = function()
        return true
    end,
    IsSecondary = function()
        return false
    end,
}
TheWorld =
{
    DoStaticTaskInTime = function(_, delay, fn)
        if delay == 0 then
            fn()
        end
        return { Cancel = function() end }
    end,
}

GetShardModRPC = function(_, name)
    return name
end
ZipAndEncodeString = function(value)
    return value
end
SendModRPCToShard = function(rpc, shardid, payload)
    sent[#sent + 1] = { rpc = rpc, shardid = shardid, payload = payload }
end

ShardGameIndex =
{
    worldindex =
    {
        PersistPendingSecondaryFinalize = function(_, request, cb)
            persisted[#persisted + 1] = request.id
            durable_state.secondary_finalize_pending =
            {
                request_id = request.id,
                operation = request.operation,
                rpc_namespace = request.rpc_namespace,
                shardids = deepcopy_safe(request.shardids),
                prepared = deepcopy_safe(request.prepared),
                timeout = request.timeout,
            }
            persist_callback = cb
        end,
        CompletePendingSecondaryFinalize = function(_, request_id, cb)
            completed[#completed + 1] = request_id
            durable_state.secondary_finalize_pending = nil
            cb(true)
        end,
    },
}

local shards = require("modules/shards")

local prepared_request = nil
shards.RequestSecondaryWorldIndex("BeginSecondaryWorldIndex", {}, function(success, request)
    assert(success == true)
    prepared_request = request
end)
assert(sent[#sent].rpc == "BeginSecondaryWorldIndex")

shards.HandleSecondaryWorldIndexReply("Caves", {
    request_id = sent[#sent].payload.request_id,
    operation = "BeginSecondaryWorldIndex",
    phase = "prepare",
    success = true,
    file_id = "caves",
})
assert(prepared_request ~= nil)

local commit_result = nil
shards.CommitSecondaryWorldIndex(prepared_request, function(success)
    commit_result = success
end)
assert(#persisted == 1)
assert(sent[#sent].rpc == "BeginSecondaryWorldIndex")
persist_callback(true)
assert(sent[#sent].rpc == "CommitSecondaryWorldIndex")

shards.HandleSecondaryWorldIndexReply("Caves", {
    request_id = prepared_request.id,
    operation = "BeginSecondaryWorldIndex",
    phase = "commit",
    success = true,
})
assert(sent[#sent].rpc == "FinalizeSecondaryWorldIndex")

shards.HandleSecondaryWorldIndexReply("Caves", {
    request_id = prepared_request.id,
    operation = "BeginSecondaryWorldIndex",
    phase = "finalize",
    success = true,
})
assert(commit_result == true)
assert(completed[1] == prepared_request.id)

local retry_request = nil
shards.RequestSecondaryWorldIndex("AdvanceSecondaryWorldIndex", {}, function(success, request)
    assert(success == true)
    retry_request = request
end)
local retry_request_id = sent[#sent].payload.request_id
shards.HandleSecondaryWorldIndexReply("Caves", {
    request_id = retry_request_id,
    operation = "AdvanceSecondaryWorldIndex",
    phase = "prepare",
    success = true,
    file_id = "caves",
})
assert(retry_request ~= nil)

local retry_result = nil
shards.CommitSecondaryWorldIndex(retry_request, function(success)
    retry_result = success
end)
persist_callback(true)
shards.HandleSecondaryWorldIndexReply("Caves", {
    request_id = retry_request.id,
    operation = "AdvanceSecondaryWorldIndex",
    phase = "commit",
    success = false,
})
assert(retry_result == true)
assert(shards.IsSecondaryWorldIndexRequestPending())

local rejected = nil
assert(shards.RequestSecondaryWorldIndex("BeginSecondaryWorldIndex", {}, function(success)
    rejected = success
end) == false)
assert(rejected == false)

assert(shards.RetryPendingSecondaryFinalize(ShardGameIndex))
assert(sent[#sent].rpc == "CommitSecondaryWorldIndex")
shards.HandleSecondaryWorldIndexReply("Caves", {
    request_id = retry_request.id,
    operation = "AdvanceSecondaryWorldIndex",
    phase = "commit",
    success = true,
})
assert(sent[#sent].rpc == "FinalizeSecondaryWorldIndex")
shards.HandleSecondaryWorldIndexReply("Caves", {
    request_id = retry_request.id,
    operation = "AdvanceSecondaryWorldIndex",
    phase = "finalize",
    success = true,
})
assert(not shards.IsSecondaryWorldIndexRequestPending())

print("shards_test: ok")
