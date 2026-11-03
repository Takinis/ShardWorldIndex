-- Patch vanilla ShardIndex lifecycle methods for WorldIndex state.

GLOBAL.setfenv(1, GLOBAL)

local snapshot = require("modules/snapshot")

local _ctor = ShardIndex._ctor
function ShardIndex._ctor(self, ...)
    _ctor(self, ...)
    self.worldindex = ShardWorldIndex(self)
end

local _SaveCurrent = ShardIndex.SaveCurrent
function ShardIndex:SaveCurrent(callback, isshutdown)
    if self.world_index_load_failed then
        (callback or noop)(false)
        return
    end
    snapshot.BeforeSave(self, function(success)
        if success then
            _SaveCurrent(self, function(...)
                local args = { ... }
                if args[1] == false then
                    (callback or noop)(false)
                    return
                end
                snapshot.AfterSave(self, function(saved)
                    if callback ~= nil then
                        if saved then
                            callback(unpack(args))
                        else
                            callback(false)
                        end
                    end
                end)
            end, isshutdown)
        elseif callback ~= nil then
            callback(false)
        end
    end)
end

local _SerializeWorldSession = SerializeWorldSession
function SerializeWorldSession(data, session_id, callback, metadata)
    return _SerializeWorldSession(snapshot.Attach(ShardGameIndex, data, session_id), session_id, callback, metadata)
end

local function restore_snapshot(index, savedata, callback)
    snapshot.Restore(index, savedata, function(success)
        assert(success, "[Shard World Index] Cannot load a snapshot before the current world transition or with an invalid checkpoint.")
        callback(savedata)
    end)
end

local _GetSaveData = ShardIndex.GetSaveData
function ShardIndex:GetSaveData(callback)
    assert(not self.world_index_load_failed, "[Shard World Index] Refusing to load a world with an unreadable sidecar or manifest.")
    return _GetSaveData(self, function(savedata)
        restore_snapshot(self, savedata, callback)
    end)
end

local _GetSaveDataFile = ShardIndex.GetSaveDataFile
function ShardIndex:GetSaveDataFile(file, callback)
    assert(not self.world_index_load_failed, "[Shard World Index] Refusing to load a world with an unreadable sidecar or manifest.")
    return _GetSaveDataFile(self, file, function(savedata)
        restore_snapshot(self, savedata, callback)
    end)
end

local _WorldRollbackFromSim = WorldRollbackFromSim
function WorldRollbackFromSim(count)
    if ShardGameIndex ~= nil and not snapshot.CanRollback(ShardGameIndex, count) then
        print("[Shard World Index] Rollback refused: the requested snapshot precedes the current world transition or a transition is incomplete.")
        return false
    end
    return _WorldRollbackFromSim(count)
end

local _Load = ShardIndex.Load
local function LoadWorldIndexState(self, callback)
    self.worldindex:LoadSidecar(function(success)
        self.world_index_load_failed = success == false or nil
        if callback ~= nil then
            callback(success)
        end
    end)
end

function ShardIndex:Load(callback)
    _Load(self, function(...)
        local args = { ... }
        LoadWorldIndexState(self, function(success)
            if callback ~= nil then
                if success == false then
                    callback(false)
                else
                    callback(unpack(args))
                end
            end
        end)
    end)
end

local _LoadShardInSlot = ShardIndex.LoadShardInSlot
function ShardIndex:LoadShardInSlot(slot, shard, callback)
    _LoadShardInSlot(self, slot, shard, function(...)
        local args = { ... }
        LoadWorldIndexState(self, function(success)
            if callback ~= nil then
                if success == false then
                    callback(false)
                else
                    callback(unpack(args))
                end
            end
        end)
    end)
end

local _NewShardInSlot = ShardIndex.NewShardInSlot
function ShardIndex:NewShardInSlot(slot, shard)
    _NewShardInSlot(self, slot, shard)
    if not self.preserve_world_index_sidecar then
        self.clear_world_index_sidecars_before_save = true
    end
end

local _Save = ShardIndex.Save
function ShardIndex:Save(callback)
    if self.world_index_load_failed then
        (callback or noop)(false)
        return
    end
    if not self.clear_world_index_sidecars_before_save then
        return _Save(self, callback)
    end

    self.clear_world_index_sidecars_before_save = nil
    self.worldindex:ClearAllSidecars(function(success)
        if success then
            _Save(self, callback)
        elseif callback ~= nil then
            callback(false)
        end
    end)
end

local _IsEmpty = ShardIndex.IsEmpty
function ShardIndex:IsEmpty()
    assert(not self.world_index_load_failed, "[Shard World Index] Refusing to generate or load a world with an unreadable sidecar or manifest.")
    if self.worldindex:NeedsGenerationOnLoad() then
        return true
    end
    if self.worldindex:ReservesSlot() then
        return false
    end
    return _IsEmpty(self)
end

local _Delete = ShardIndex.Delete
function ShardIndex:Delete(cb, save_options)
    if self.worldindex:PreservePendingGenerationOnDelete(save_options, cb) then
        return
    end

    self.worldindex:PrepareDelete(save_options, function(success)
        if success then
            _Delete(self, cb, save_options)
        elseif cb ~= nil then
            cb(false)
        end
    end)
end

local _SetServerShardData = ShardIndex.SetServerShardData
function ShardIndex:SetServerShardData(customoptions, serverdata, onsavedcb)
    local function set_server_shard_data(success)
        if success ~= false then
            _SetServerShardData(self, customoptions, serverdata, onsavedcb)
        elseif onsavedcb ~= nil then
            onsavedcb(false)
        end
    end

    if not self.worldindex:PrepareSetServerShardData(set_server_shard_data) then
        set_server_shard_data()
    end
end

local _OnGenerateNewWorld = ShardIndex.OnGenerateNewWorld
function ShardIndex:OnGenerateNewWorld(savedata, metadataStr, session_identifier, cb)
    print("ShardIndex:OnGenerateNewWorld")
    local generated_savedata = savedata
    savedata, metadataStr = self.worldindex:BeforeGenerateNewWorld(savedata, metadataStr, session_identifier)
    if savedata ~= generated_savedata then
        local callback_savedata = type(cb) == "function" and ToolUtil.GetUpvalue(cb, "savedata") or nil
        if callback_savedata ~= nil then
            ToolUtil.SetUpvalue(cb, "savedata", savedata)
        else
            print("[Shard World Index] Failed to update generated world runtime save data.")
        end
    end
    _OnGenerateNewWorld(self, savedata, metadataStr, session_identifier, function(...)
        local args = { ... }
        self.worldindex:AfterGenerateNewWorld(savedata, session_identifier, function(success)
            if cb ~= nil then
                if success == false then
                    cb(false)
                else
                    cb(unpack(args))
                end
            end
        end)
    end)
end
