package.path = "scripts/?.lua;scripts/?/init.lua;"..package.path

SHARDID = { MASTER = "Master" }
RESET_ACTION = { LOAD_SLOT = "load_slot" }
Settings = nil

local recovery = require("modules/recovery")
local transaction = require("modules/transaction")

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[copy(key)] = copy(child)
    end
    return out
end

local sidecars = {}
WORLD_INDEX_KNOWN_FILE_IDS =
{
    Master = { "forest", "shipwrecked", "porkland" },
    Caves = { "caves", "volcano" },
}
SECONDARY_WORLD_INDEX_FILE_IDS =
{
    forest = "caves",
    shipwrecked = "volcano",
}

noop = function() end
is_master_shard_id = function(shardid)
    return shardid == nil or shardid == "" or shardid == "Master"
end

local manifest =
{
    GetFileIDs = function()
        return { "orphan_custom" }
    end,
    Read = function(_, cb)
        cb()
    end,
}

local shards =
{
    GetIndexShard = function(index)
        return index.shard or "Master"
    end,
}
local players =
{
    GetPlayerPositions = function()
        return nil
    end,
    MergePlayerPositions = function(existing, updates)
        local merged = copy(existing) or {}
        for userid, position in pairs(updates or {}) do
            merged[userid] = copy(position)
        end
        return next(merged) ~= nil and merged or nil
    end,
}
local storage =
{
    ReadNamedSidecar = function(_, file_id, cb)
        if file_id == "corrupt" then
            cb(nil, true, false)
            return
        end
        cb(copy(sidecars[file_id]))
    end,
    WriteSidecar = function(_, state, cb, file_id)
        sidecars[file_id or state.file_id] = copy(state)
        cb(true)
    end,
}

package.loaded["modules/manifest"] = manifest
package.loaded["modules/players"] = players
package.loaded["modules/recovery"] = recovery
package.loaded["modules/shards"] = shards
package.loaded["modules/storage"] = storage
package.loaded["modules/transaction"] = transaction

local state_store = require("modules/state_store")

assert(state_store.NormalizeFileID(" Pork Land! ") == "pork_land")
local file_id, secondary_file_id = state_store.RegisterFileID("custom", "custom_caves")
assert(file_id == "custom")
assert(secondary_file_id == "custom_caves")
assert(state_store.GetFileIDForShard("custom", "Caves") == "custom_caves")
local known_ids = state_store.GetKnownFileIDs({ shard = "Master" })
local known_by_id = {}
for _, known_id in ipairs(known_ids) do
    known_by_id[known_id] = true
end
assert(known_by_id.orphan_custom == true)

local index =
{
    shard = "Master",
    session_id = "current",
    GetSession = function(self)
        return self.session_id
    end,
}

local older =
{
    active = true,
    file_id = "forest",
    current_session_id = "other",
    home = { session_id = "home" },
    transaction = { revision = 1 },
}
local current =
{
    active = true,
    file_id = "shipwrecked",
    current_session_id = "current",
    home = { session_id = "home" },
    transaction = { revision = 2 },
}
index.world_index_state = older
index.world_index_states = { forest = older, shipwrecked = current }

assert(state_store.GetState(index) == current)
assert(index.world_index_state == current)
assert(state_store.GetCurrentState(index) == current)
assert(state_store.ReservesSlot(current))

local pending =
{
    active = true,
    file_id = "porkland",
    current_target = { id = "target" },
    home = { session_id = "home" },
}
index.world_index_state = pending
index.world_index_states = { porkland = pending }
Settings =
{
    reset_action = RESET_ACTION.LOAD_SLOT,
    world_index_transition = "advance",
    world_index_file_id = "porkland",
}
assert(state_store.GetPendingTransitionState(index) == pending)
assert(state_store.GetDeleteState(index) == pending)

sidecars.porkland =
{
    file_id = "porkland",
    secondary_transition = { request_id = "request" },
}
local found_state = nil
local found_transaction = nil
state_store.FindSidecar(index, "porkland", function(state)
    local transaction = state.secondary_transition
    return transaction ~= nil and transaction.request_id == "request" and transaction or nil
end, function(state, transaction_data)
    found_state = state
    found_transaction = transaction_data
end)
assert(found_state.file_id == "porkland")
assert(found_transaction.request_id == "request")

local corrupt_success = nil
state_store.ReadSidecar(index, function(_, success)
    corrupt_success = success
end, "corrupt")
assert(corrupt_success == false)

print("state_store_test: ok")
