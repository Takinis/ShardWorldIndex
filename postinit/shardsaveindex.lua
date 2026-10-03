-- Patch vanilla ShardSaveIndex slot bookkeeping so active world indexes keep
-- their saved slot reserved and recoverable.

GLOBAL.setfenv(1, GLOBAL)

local function SlotHasActiveWorldIndexSidecar(index, slot)
    return index.world_index_slot_states ~= nil and index.world_index_slot_states[slot] ~= nil
end

local function RecoverWorldIndexSlot(index, slot, state, cb)
    cb = cb or function() end
    if slot == nil or state == nil then
        cb(false)
        return
    end

    local function recover(shard_index)
        if not shard_index:IsValid() then
            shard_index.preserve_world_index_sidecar = true
            shard_index:NewShardInSlot(slot, "Master")
            shard_index.preserve_world_index_sidecar = nil
        end
        index.slot_cache[slot] = index.slot_cache[slot] or {}
        index.slot_cache[slot].Master = shard_index

        if shard_index:GetSession() == nil or shard_index:GetSession() == "" then
            shard_index.worldindex:SwitchIndexToStoredWorld(state)
            shard_index:Save(function(success)
                cb(success == true)
            end)
            return
        end
        cb(true)
    end

    local shard_index = index.slot_cache[slot] ~= nil and index.slot_cache[slot].Master or nil
    if shard_index ~= nil then
        recover(shard_index)
        return
    end

    shard_index = ShardIndex()
    shard_index:LoadShardInSlot(slot, "Master", function()
        recover(shard_index)
    end)
end

local function RefreshWorldIndexSlots(index, cb)
    cb = cb or function() end
    if index == nil or TheSim == nil then
        cb()
        return
    end

    index.slots = index.slots or {}
    index.world_index_slot_states = {}
    local slot = 1

    local function read_next()
        if slot > NUM_DST_SAVE_SLOTS then
            cb()
            return
        end

        local current_slot = slot
        slot = slot + 1
        ShardWorldIndex:ReadActiveSidecar(current_slot, function(state, read_success)
            if read_success == false then
                print("[Shard World Index] Slot "..tostring(current_slot).." contains a corrupt WorldIndex sidecar.")
                index.world_index_slot_states[current_slot] = { corrupt = true }
                index.slots[current_slot] = index.slots[current_slot] or false
                read_next()
                return
            end
            if state == nil then
                read_next()
                return
            end

            index.world_index_slot_states[current_slot] = state
            index.slots[current_slot] = index.slots[current_slot] or false
            RecoverWorldIndexSlot(index, current_slot, state, function(success)
                if not success then
                    print("[Shard World Index] Failed to recover reserved slot "..tostring(current_slot)..".")
                end
                read_next()
            end)
        end)
    end

    read_next()
end

local _IsSlotEmpty = ShardSaveIndex.IsSlotEmpty
function ShardSaveIndex:IsSlotEmpty(slot)
    if SlotHasActiveWorldIndexSidecar(self, slot) then
        return false
    end
    return _IsSlotEmpty(self, slot)
end

local _GetNextNewSlot = ShardSaveIndex.GetNextNewSlot
function ShardSaveIndex:GetNextNewSlot(force_slot_type)
    if force_slot_type == "cloud" or (force_slot_type ~= "local" and Profile:GetDefaultCloudSaves()) then
        return _GetNextNewSlot(self, force_slot_type)
    end

    local i = 1
    while true do
        if (self.failed_slot_conversions or {})[i] == nil and
            not SlotHasActiveWorldIndexSidecar(self, i) and
            (self.slots[i] == nil or self:IsSlotEmpty(i)) then
            return i
        end
        i = i + 1
    end
end

local _Load = ShardSaveIndex.Load
function ShardSaveIndex:Load(callback)
    _Load(self, function(...)
        local args = { ... }
        RefreshWorldIndexSlots(self, function()
            if callback ~= nil then
                callback(unpack(args))
            end
        end)
    end)
end

local _GetValidSlots = ShardSaveIndex.GetValidSlots
function ShardSaveIndex:GetValidSlots()
    return _GetValidSlots(self)
end

local _Save = ShardSaveIndex.Save
function ShardSaveIndex:Save(callback)
    return _Save(self, callback)
end
