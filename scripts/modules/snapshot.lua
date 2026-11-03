local state_store = require("modules/state_store")
local restored_savedata = setmetatable({}, { __mode = "k" })
local durable_fields =
{
    "secondary_transition",
    "secondary_finalize_pending",
    "secondary_completed_request",
}

local function get_transaction_id(state)
    return state ~= nil and state.transaction ~= nil and state.transaction.id or nil
end

local function before_save(index, cb)
    local state = state_store.GetState(index)
    local session_id = TheWorld ~= nil and TheWorld.meta ~= nil and TheWorld.meta.session_identifier or nil
    if session_id ~= nil and index:GetSession() ~= session_id then
        print("[Shard World Index] Refusing to save a world after its index has switched sessions.")
        cb(false)
        return
    end
    if state == nil or session_id == nil then
        cb(true)
        return
    end
    if state_store.HasPendingRecovery(state) or
        (state.active == true and state.current_session_id ~= session_id) then
        print("[Shard World Index] Refusing to save during an incomplete world transition.")
        cb(false)
        return
    end

    local transaction_id = get_transaction_id(state)
    local previous = deepcopy_safe(state)
    local same_visit = state.rollback_session_id == session_id and state.rollback_transaction_id == transaction_id
    state.rollback_session_id = session_id
    state.rollback_transaction_id = transaction_id
    if not same_visit then
        state.rollback_min_snapshot = TheNet:GetCurrentSnapshot()
        state.rollback_checkpoint_saved = nil
    end
    state.last_saved_snapshot = TheNet:GetCurrentSnapshot()
    state_store.WriteSidecar(index, state, function(saved)
        if not saved then
            state.rollback_session_id = previous.rollback_session_id
            state.rollback_transaction_id = previous.rollback_transaction_id
            state.rollback_min_snapshot = previous.rollback_min_snapshot
            state.rollback_checkpoint_saved = previous.rollback_checkpoint_saved
            state.last_saved_snapshot = previous.last_saved_snapshot
        end
        cb(saved == true)
    end)
end

local function after_save(index, cb)
    local state = state_store.GetState(index)
    if state == nil or state.rollback_checkpoint_saved == true then
        cb(true)
        return
    end
    state.rollback_checkpoint_saved = true
    state_store.WriteSidecar(index, state, function(saved)
        if not saved then
            state.rollback_checkpoint_saved = nil
        end
        cb(saved == true)
    end)
end

local function attach(index, data, session_id)
    if index == nil or type(data) ~= "table" or type(data.map) ~= "string" then
        return data
    end
    local success, map = RunInSandboxSafe(data.map)
    if not success or type(map) ~= "table" then
        return data
    end
    local state = state_store.GetState(index)
    -- PersistData is excluded from the server's client-facing temporary save.
    map.persistdata = map.persistdata or {}
    map.persistdata.world_index_checkpoint =
    {
        version = 1,
        session_id = session_id,
        snapshot = TheNet:GetCurrentSnapshot(),
        state = deepcopy_safe(state),
    }
    local out = {}
    for key, value in pairs(data) do
        out[key] = value
    end
    out.map = DataDumper(map, nil, BRANCH ~= "dev")
    return out
end

local function restore(index, savedata, cb)
    if type(savedata) ~= "table" or restored_savedata[savedata] or
        not TheNet:GetIsServer() or
        (Settings ~= nil and Settings.world_index_transition ~= nil) then
        cb(true)
        return
    end
    local map = savedata.map
    local checkpoint = map ~= nil and map.persistdata ~= nil and
        map.persistdata.world_index_checkpoint or nil
    local live = state_store.GetState(index)
    local session_id = savedata.meta ~= nil and savedata.meta.session_identifier or nil
    if checkpoint == nil then
        -- Legacy saves remain loadable until this visit has a checkpoint.
        cb(live == nil or live.rollback_session_id ~= session_id or live.rollback_checkpoint_saved ~= true)
        return
    end
    if type(checkpoint) ~= "table" or checkpoint.version ~= 1 or
        checkpoint.session_id ~= session_id or checkpoint.session_id ~= index:GetSession() or
        (checkpoint.state ~= nil and not require("modules/storage").IsValidState(checkpoint.state)) then
        cb(false)
        return
    end
    local state = checkpoint.state
    if live ~= nil and live.rollback_checkpoint_saved == true and live.rollback_session_id == session_id and
        (get_transaction_id(state) ~= get_transaction_id(live) or
        (tonumber(checkpoint.snapshot) or -1) < (tonumber(live.rollback_min_snapshot) or 0)) then
        cb(false)
        return
    end
    if live ~= nil and (state_store.HasPendingRecovery(live) or
        (tonumber(checkpoint.snapshot) or 0) >= (tonumber(live.last_saved_snapshot) or 0)) then
        restored_savedata[savedata] = true
        cb(true)
        return
    end
    if state == nil then
        restored_savedata[savedata] = true
        cb(true)
        return
    end
    state = deepcopy_safe(state)
    if live ~= nil then
        for _, field in ipairs(durable_fields) do
            state[field] = deepcopy_safe(live[field])
        end
        state.rollback_session_id = live.rollback_session_id
        state.rollback_transaction_id = live.rollback_transaction_id
        state.rollback_min_snapshot = live.rollback_min_snapshot
        state.rollback_checkpoint_saved = live.rollback_checkpoint_saved
        state.last_saved_snapshot = checkpoint.snapshot
        state.transaction = deepcopy_safe(live.transaction)
        state.transaction_epoch = live.transaction_epoch
        state.revision = live.revision
    end
    state_store.WriteSidecar(index, state, function(saved)
        if saved then
            state_store.SetState(index, state, state.file_id)
            restored_savedata[savedata] = true
        end
        cb(saved == true)
    end)
end

local function can_rollback(index, count)
    local state = state_store.GetState(index)
    if count <= 0 then
        return true
    end
    for _, stored in pairs(index.world_index_states or {}) do
        if state_store.HasPendingRecovery(stored) then
            return false
        end
    end
    if state == nil then
        return true
    end
    if state_store.HasPendingRecovery(state) or
        state.rollback_session_id ~= index:GetSession() or
        state.rollback_min_snapshot == nil or state.rollback_checkpoint_saved ~= true then
        return false
    end
    local autosaver = TheWorld ~= nil and TheWorld.net ~= nil and TheWorld.net.components.autosaver or nil
    if autosaver == nil or GetTime() - autosaver:GetLastSaveTime() < 30 then
        count = count + 1
    end
    return TheNet:GetCurrentSnapshot() - count >= state.rollback_min_snapshot
end

return
{
    BeforeSave = before_save,
    AfterSave = after_save,
    Attach = attach,
    Restore = restore,
    CanRollback = can_rollback,
}
