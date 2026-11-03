local AddSimPostInit = AddSimPostInit
GLOBAL.setfenv(1, GLOBAL)

local storage = require("modules/storage")

ShardWorldIndex = Class(function(self, index)
    self.index = index
end)

function noop()
end

function deepcopy_safe(value)
    return value ~= nil and deepcopy(value) or nil
end

function save_index(index, cb)
    cb = cb or noop
    index:Save(function(success)
        if success ~= true then
            index:MarkDirty()
        end
        cb(success == true)
    end)
end

function is_shard_index(value)
    return type(value) == "table" and
        type(value.GetSession) == "function" and
        type(value.GetSlot) == "function"
end

function resolve_index_args(self, index, ...)
    if self ~= ShardWorldIndex and self.index ~= nil and not is_shard_index(index) then
        return self.index, index, ...
    end
    return index, ...
end

function is_master_shard_id(shardid)
    return shardid == nil or shardid == "" or shardid == SHARDID.MASTER or shardid == "Master"
end

function get_return_position()
    local player = ThePlayer or (AllPlayers ~= nil and AllPlayers[1]) or nil
    if player ~= nil then
        local x, y, z = player.Transform:GetWorldPosition()
        return { x = x, y = y, z = z }
    end
end

function get_savedata_table(savedata)
    if type(savedata) == "table" then
        return savedata
    end

    if type(savedata) ~= "string" or #savedata <= 0 then
        return nil
    end

    local success, data = RunInSandboxSafe(savedata)
    return success and type(data) == "table" and data or nil
end

local state_store = require("modules/state_store")

local players = require("modules/players")
players.InstallSnapshotHooks(ToolUtil.GetUpvalue(SpawnSaveRecord, "ResolveSaveRecordPosition"))

local shards = require("modules/shards")
local world = require("modules/world")
local registry = require("modules/registry")
local secondary_transition = require("modules/secondary_transition")

function register_world_definition(id, definition)
    local registered_world, reason = registry.Register(id, definition)
    if registered_world == nil then
        print("[Shard World Index] Cannot register world: "..tostring(reason)..".")
        return false, reason
    end

    state_store.RegisterFileID(registered_world.file_id, registered_world.secondary_file_id)
    if registered_world.world_type ~= nil then
        world.RegisterWorldType(
            registered_world.world_type,
            registered_world.world_type_aliases,
            registered_world.world_tags
        )
    end
    return true, registered_world
end

function build_registered_world_switch_options(world_id, opts)
    local registered_world = registry.Get(world_id)
    if registered_world == nil then
        return nil, "world is not registered: "..tostring(world_id)
    end

    local out = deepcopy_safe(opts) or {}
    out.target = out.target or deepcopy_safe(registered_world.target)
    out.file_id = out.file_id or registered_world.file_id
    out.kind = out.kind or registered_world.kind
    out.reason = out.reason or registered_world.reason or "switch_"..registered_world.id
    if out.reuse_existing == nil then
        out.reuse_existing = registered_world.reuse_existing
    end
    if registered_world.force_players_to_master and out.force_players_to_master_modname == nil then
        out.force_players_to_master_modname = RPC_NAMESPACE
        out.force_players_to_master_rpcname = "ForcePlayersToMaster"
    end
    return out, registered_world
end

function RegisterWorld(id, definition)
    return register_world_definition(id, definition)
end

function GetRegisteredWorld(id)
    return registry.Get(id)
end

function GetRegisteredWorlds()
    return registry.GetAll()
end

function SwitchWorld(world_id, opts, cb)
    local worldindex = ShardGameIndex ~= nil and ShardGameIndex.worldindex or nil
    if worldindex == nil then
        if type(cb) == "function" then
            cb(false)
        end
        print("[Shard World Index] ShardWorldIndex is unavailable.")
        return false
    end
    return worldindex:RequestWorldSwitch(world_id, opts, cb)
end

function ShardWorldIndex:IsMasterShard()
    return shards.IsMasterShard()
end

function ShardWorldIndex:GetRuntimeWorldType()
    return world.GetRuntimeWorldType()
end

function ShardWorldIndex:CollectPlayerSessions()
    return players.CollectPlayerSessions()
end

function ShardWorldIndex:GetCharacterOnlySessions(sessions)
    return players.GetCharacterOnlySessions(sessions)
end

function ShardWorldIndex:SessionsToUseridMap(sessions)
    return players.SessionsToUseridMap(sessions)
end

function ShardWorldIndex:SessionListToMap(sessions)
    return players.SessionListToMap(sessions)
end

function ShardWorldIndex:MergeSessionLists(primary, fallback)
    return players.MergeSessionLists(primary, fallback)
end

function ShardWorldIndex:GetPlayerSaveSession(player)
    return players.GetPlayerSaveSession(player)
end

function ShardWorldIndex:ForceLocalPlayersToMaster()
    return shards.ForceLocalPlayersToMaster()
end

function ShardWorldIndex:SendShardRPC(modname, name, shardid, data)
    return shards.SendShardRPC(modname, name, shardid, data)
end

function ShardWorldIndex:SendRPCToMasterShard(modname, name, data)
    return shards.SendRPCToMasterShard(modname, name, data)
end

function ShardWorldIndex:HandleSecondaryWorldIndexReply(shardid, data)
    return shards.HandleSecondaryWorldIndexReply(shardid, data)
end

function ShardWorldIndex:GetSecondaryShardPlayerCount()
    return shards.GetSecondaryShardPlayerCount()
end

function ShardWorldIndex:GetLevelForShard(level, shardid)
    return world.GetLevelForShard(level, shardid)
end

function ShardWorldIndex:GetIndexShard(index)
    index = resolve_index_args(self, index)
    return shards.GetIndexShard(index)
end

function ShardWorldIndex:InjectPlayerSessionsIntoExistingWorld(index, ...)
    return players.InjectPlayerSessionsIntoExistingWorld(resolve_index_args(self, index, ...))
end

function ShardWorldIndex:RestartCurrentSlotAfterShardRPC(index, ...)
    return shards.RestartCurrentSlotAfterShardRPC(resolve_index_args(self, index, ...))
end

function ShardWorldIndex:RegisterSecondaryTransitionHandler(operation, handler)
    return secondary_transition.Register(operation, handler)
end

function ShardWorldIndex:IsSecondaryWorldIndexRequestPending()
    return shards.IsSecondaryWorldIndexRequestPending()
end

function ShardWorldIndex:RegisterWorldIndexFileID(file_id, secondary_file_id)
    return state_store.RegisterFileID(file_id, secondary_file_id)
end

function ShardWorldIndex:DeleteSessionIfNotHome(session_id, home_session_id)
    return world.DeleteSessionIfNotHome(session_id, home_session_id)
end

function ShardWorldIndex:RegisterWorld(id, definition)
    return register_world_definition(id, definition)
end

function ShardWorldIndex:GetRegisteredWorld(id)
    return registry.Get(id)
end

function ShardWorldIndex:GetRegisteredWorlds()
    return registry.GetAll()
end

function ShardWorldIndex:BuildWorldSwitchOptions(id, opts)
    return build_registered_world_switch_options(id, opts)
end

function is_world_index_transition_restart()
    return Settings ~= nil and
        Settings.reset_action == RESET_ACTION.LOAD_SLOT and
        Settings.world_index_transition ~= nil
end

function is_load_slot()
    return Settings ~= nil and Settings.reset_action == RESET_ACTION.LOAD_SLOT
end

function should_preserve_pending_world_generation(index, state)
    return state_store.IsPendingGeneration(state) or
        (is_world_index_transition_restart() and not state_store.MatchesCurrentSession(index, state))
end

function prepare_interrupted_world_index_regen(index)
    index.world = { options = {} }
    index.server = {}
    index.enabled_mods = {}
    index.session_id = nil
    index:MarkDirty()
end

function clear_interrupted_world_index_transition(index, cb)
    cb = cb or noop
    state_store.ClearSidecar(index, function(sidecar_cleared)
        if not sidecar_cleared then
            cb(false)
            return
        end
        storage.RestoreWorldGenOverride(index, nil, cb)
    end)
end

function world_index_state_has_origin(state)
    return state ~= nil and (state.slot ~= nil or state.shard ~= nil)
end

function world_index_state_matches_index(index, state)
    if state.slot ~= nil and state.slot ~= index:GetSlot() then
        return false
    end
    return state.shard == nil or state.shard == shards.GetIndexShard(index)
end

function build_world_index_home_state(index, worldgenoverride, opts)
    opts = opts or {}
    local home = {
        session_id = opts.session_id or index:GetSession(),
        worldgenoverride = worldgenoverride,
        world = deepcopy_safe(index.world),
        server = deepcopy_safe(index.server),
        enabled_mods = deepcopy_safe(index.enabled_mods),
        return_position = opts.return_position or get_return_position(),
        player_sessions = opts.player_sessions,
        player_positions = players.GetPlayerPositions(opts.player_sessions),
    }
    home.world_type = world.GetRuntimeWorldType() or world.GetStoredWorldType(home)
    home.current_preset = world.GetStoredWorldPreset(home)
    return home
end

function build_generation_recovery_state(index, state, source_session_id)
    source_session_id = source_session_id or index:GetSession()
    if source_session_id == nil or
        source_session_id == "" or
        state.current_session_id ~= source_session_id then
        return nil
    end

    local recovery = deepcopy_safe(state)
    recovery.pending_generation = nil
    recovery.checked_existing_world = nil
    recovery.generation_source_session_id = nil
    recovery.generation_recovery_state = nil
    recovery.updated_at = os.time()
    return recovery
end

function is_generation_source_session(state, session_id)
    if session_id == nil or session_id == "" then
        return false
    end

    if state.generation_source_session_id == session_id then
        return true
    end

    local pending = type(state.pending_generation) == "table" and state.pending_generation or nil
    return pending ~= nil and pending.generation_source_session_id == session_id
end

local index_state = require("modules/index_state")

function finish_interrupted_return_to_stored_world(index, state, cb)
    cb = cb or noop

    local home = state_store.GetHomeState(state)
    if home == nil or home.session_id == nil or home.session_id == "" then
        state_store.ClearSidecar(index, cb)
        return
    end

    state.active = false
    state.finished_at = state.finished_at or os.time()
    state.return_reason = state.return_reason or "interrupted_return"

    world.SwitchIndexToExistingWorld(index, home)
    index_state.Persist(index, state,
    {
        restore_worldgenoverride = true,
        worldgenoverride = home.worldgenoverride,
    }, function(saved)
        if not saved then
            cb(false)
            return
        end
        local cleanup_session_id = type(state.return_pending) == "table" and
            state.return_pending.cleanup_session_id or nil
        if cleanup_session_id ~= nil and cleanup_session_id ~= "" then
            world.DeleteSessionIfNotHome(cleanup_session_id, home.session_id)
        end
        restore_parent_world_index(index, state, cb)
    end)
end

function suspend_current_world_index(index, state, reason, cb)
    cb = cb or noop
    state = state_store.EnsureHomeAliases(state)

    if state == nil or state.active ~= true then
        cb(nil, true)
        return
    end

    local session_id = index:GetSession()
    if session_id ~= nil and session_id ~= "" then
        state.current_session_id = session_id
    end
    state.current_world = deepcopy_safe(index.world) or state.current_world
    state.current_server = deepcopy_safe(index.server) or state.current_server
    state.current_enabled_mods = deepcopy_safe(index.enabled_mods) or state.current_enabled_mods

    local parent_state = deepcopy_safe(state)
    local suspended_state = deepcopy_safe(state)
    suspended_state.active = false
    suspended_state.suspend_reason = reason or "suspended"
    suspended_state.suspended_at = os.time()
    suspended_state.updated_at = os.time()

    state_store.WriteSidecar(index, suspended_state, function(success)
        if not success then
            cb(nil, false)
            return
        end
        state_store.SetState(index, suspended_state)
        cb(parent_state, true)
    end, suspended_state.file_id)
end

function restore_parent_world_index(index, state, cb)
    cb = cb or noop

    local parent_state = type(state) == "table" and state.parent_world_index_state or nil
    if type(parent_state) ~= "table" then
        if type(state) == "table" and state.return_pending ~= nil then
            state.return_pending = nil
            state_store.WriteSidecar(index, state, function(saved)
                cb(saved == true)
            end, state.file_id)
            return
        end
        cb(true)
        return
    end

    parent_state = state_store.EnsureHomeAliases(deepcopy_safe(parent_state))
    parent_state.active = true
    parent_state.updated_at = os.time()
    parent_state.suspend_reason = nil
    parent_state.suspended_at = nil

    local session_id = index:GetSession()
    if session_id ~= nil and session_id ~= "" then
        parent_state.current_session_id = session_id
    end
    parent_state.current_world = deepcopy_safe(index.world) or parent_state.current_world
    parent_state.current_server = deepcopy_safe(index.server) or parent_state.current_server
    parent_state.current_enabled_mods = deepcopy_safe(index.enabled_mods) or parent_state.current_enabled_mods
    parent_state.pending_player_sessions = deepcopy_safe(state.pending_player_sessions)
    parent_state.pending_player_session_id = state.pending_player_session_id

    state_store.WriteSidecar(index, parent_state, function(parent_saved)
        if not parent_saved then
            cb(false)
            return
        end
        state_store.SetState(index, parent_state, parent_state.file_id)

        state.return_pending = nil
        state.parent_world_index_state = nil
        state_store.WriteSidecar(index, state, function(child_saved)
            cb(child_saved == true)
        end, state.file_id)
    end, parent_state.file_id)
end

function resume_suspended_world_index(index, parent_state, cb)
    cb = cb or noop
    parent_state = state_store.EnsureHomeAliases(deepcopy_safe(parent_state))
    if parent_state == nil or not world.SwitchIndexToCurrentWorld(index, parent_state) then
        cb(false)
        return
    end

    parent_state.active = true
    parent_state.suspend_reason = nil
    parent_state.suspended_at = nil
    parent_state.updated_at = os.time()
    local home = state_store.GetHomeState(parent_state)
    local worldgenoverride = parent_state.current_worldgenoverride or (home ~= nil and home.worldgenoverride or nil)
    index_state.Persist(index, parent_state,
    {
        file_id = parent_state.file_id,
        restore_worldgenoverride = true,
        worldgenoverride = worldgenoverride,
    }, cb)
end

function recover_interrupted_generation_source(index, state, cb)
    cb = cb or noop

    local recovery = type(state.generation_recovery_state) == "table" and deepcopy_safe(state.generation_recovery_state) or nil
    if recovery == nil or not world.SwitchIndexToCurrentWorld(index, recovery) then
        print("[Shard World Index] Returning to stored world after interrupted world generation.")
        finish_interrupted_return_to_stored_world(index, state, cb)
        return
    end

    print("[Shard World Index] Restoring previous world after interrupted world generation.")
    recovery.active = true
    recovery.pending_generation = nil
    recovery.checked_existing_world = nil
    recovery.generation_source_session_id = nil
    recovery.generation_recovery_state = nil
    recovery.updated_at = os.time()

    local home = state_store.GetHomeState(recovery)
    local worldgenoverride = recovery.current_worldgenoverride or (home ~= nil and home.worldgenoverride or nil)
    index_state.Persist(index, recovery,
    {
        restore_worldgenoverride = true,
        worldgenoverride = worldgenoverride,
    }, cb)
end

require("modules/lifecycle")(ShardWorldIndex)
require("modules/world_switch").Install(ShardWorldIndex)

secondary_transition.Install(ShardWorldIndex)
require("modules/orchestrator")(ShardWorldIndex)
require("modules/forwarding")(ShardWorldIndex)

function ShardWorldIndex:HasActiveSidecar(slot, cb)
    cb = cb or noop
    state_store.ReadActiveSidecar(slot, function(state, success)
        cb(state ~= nil or success == false)
    end)
end

function ShardWorldIndex:ReadActiveSidecar(slot, cb)
    state_store.ReadActiveSidecar(slot, cb)
end

function ShardWorldIndex:SwitchIndexToStoredWorld(index, state)
    index, state = resolve_index_args(self, index, state)
    local home = state_store.GetHomeState(state)
    if home ~= nil then
        world.SwitchIndexToExistingWorld(index, home)
        return true
    end
    return false
end

local _Shard_OnShardConnected = Shard_OnShardConnected
if type(_Shard_OnShardConnected) == "function" then
    function Shard_OnShardConnected(world_id, ...)
        _Shard_OnShardConnected(world_id, ...)
        if not shards.IsMasterShard() or TheWorld == nil then
            return
        end
        TheWorld:DoStaticTaskInTime(0, function()
            if ShardGameIndex ~= nil and ShardGameIndex.worldindex ~= nil then
                shards.RetryPendingSecondaryFinalize(ShardGameIndex)
            end
        end)
    end
end

AddSimPostInit(function()
    if TheWorld ~= nil and TheWorld.ismastersim and shards.IsMasterShard() then
        TheWorld:DoStaticTaskInTime(0, function()
            if ShardGameIndex ~= nil then
                shards.RetryPendingSecondaryFinalize(ShardGameIndex)
            end
        end)
    end
end)
