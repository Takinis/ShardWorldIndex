return function(Class)
    local ShardWorldIndex = Class
    local index_state = require("modules/index_state")
    local manifest = require("modules/manifest")
    local players = require("modules/players")
    local registry = require("modules/registry")
    local session = require("modules/session")
    local state_store = require("modules/state_store")
    local transition = require("modules/transition")
    local world = require("modules/world")

    local function load_world_index_sidecar_state(index, state, cb)
        cb = cb or noop
        ensure_world_index_home_aliases(state)

        if state == nil then
            set_world_index_state(index, state)
            cb(true)
            return
        end

        if not state.active then
            set_world_index_state(index, state)
            cb(true)
            return
        end

        if world_index_state_has_origin(state) and not world_index_state_matches_index(index, state) then
            print("[Shard World Index] Clearing sidecar from another slot or shard.")
            clear_world_index_sidecar(index, cb)
            return
        end

        local session_id = index:GetSession()
        if is_world_index_transition_restart() then
            set_world_index_state(index, state)
            cb()
            return
        end

        if is_generation_source_session(state, session_id) then
            players.WorldSessionExists(index, session_id, function(exists)
                if exists then
                    recover_interrupted_generation_source(index, state, cb)
                else
                    print("[Shard World Index] Previous world session is missing; returning to stashed home world.")
                    finish_interrupted_return_to_stored_world(index, state, cb)
                end
            end)
            return
        end

        if session_id ~= nil and session_id ~= "" and is_world_generation_saved_without_sidecar(state, session_id) then
            players.WorldSessionExists(index, session_id, function(exists)
                if exists then
                    print("[Shard World Index] Finishing interrupted world generation.")
                    transition.ApplyPendingGenerationState(state)
                    finish_generated_world_index(index, state, session_id, nil, true, cb)
                else
                    print("[Shard World Index] Generated session is missing; returning to stashed home world.")
                    finish_interrupted_return_to_stored_world(index, state, cb)
                end
            end)
            return
        end

        if session_id == nil or session_id == "" then
            if is_pending_world_generation_state(state) then
                print("[Shard World Index] Resuming interrupted world generation.")
                transition.ApplyPendingGenerationState(state)
                set_world_index_state(index, state)
                cb()
                return
            end

            if world_index_state_matches_index(index, state) then
                print("[Shard World Index] Restoring stored world after interrupted transition.")
                finish_interrupted_return_to_stored_world(index, state, cb)
            else
                print("[Shard World Index] Clearing interrupted transition before regenerating the slot.")
                prepare_interrupted_world_index_regen(index)
                clear_interrupted_world_index_transition(index, cb)
            end
            return
        end

        if type(state.pending_generation) == "table" then
            players.WorldSessionExists(index, session_id, function(exists)
                if exists then
                    set_world_index_state(index, state)
                    cb()
                else
                    print("[Shard World Index] Current generated session is missing; returning to stashed home world.")
                    finish_interrupted_return_to_stored_world(index, state, cb)
                end
            end)
            return
        end

        if state.current_session_id == session_id then
            players.WorldSessionExists(index, session_id, function(exists)
                if exists then
                    if needs_world_generation_postprocess(state, session_id) then
                        print("[Shard World Index] Finishing pending world generation postprocess.")
                        finish_generated_world_index(index, state, session_id, nil, true, cb)
                    else
                        set_world_index_state(index, state)
                        cb()
                    end
                else
                    print("[Shard World Index] Current generated session is missing; returning to stashed home world.")
                    finish_interrupted_return_to_stored_world(index, state, cb)
                end
            end)
            return
        end

        local home = get_world_index_home_state(state)
        if home ~= nil and home.session_id == session_id then
            print("[Shard World Index] Finishing interrupted return to stored world.")
            finish_interrupted_return_to_stored_world(index, state, cb)
            return
        end

        print("[Shard World Index] Clearing stale sidecar for unrelated session.")
        clear_world_index_sidecar(index, cb)
    end

    local read_active_world_index_sidecar = state_store.ReadActiveSidecar

    function ShardWorldIndex:RollbackPendingGeneration(index, cb, file_id)
        index, cb, file_id = resolve_index_args(self, index, cb, file_id)
        cb = cb or noop

        local state = get_world_index_state(index, file_id)
        local session_id = index ~= nil and index:GetSession() or nil
        local pending = state ~= nil and type(state.pending_generation) == "table" and state.pending_generation or nil
        local source_session_id = state ~= nil and
            (state.generation_source_session_id or (pending ~= nil and pending.generation_source_session_id or nil)) or nil
        local recovery = state ~= nil and
            (state.generation_recovery_state or (pending ~= nil and pending.generation_recovery_state or nil)) or nil
        if state == nil or
            state.active ~= true or
            not is_pending_world_generation_state(state) then
            cb(false, false)
            return false
        end
        if session_id == nil or
            session_id == "" or
            source_session_id ~= session_id or
            type(recovery) ~= "table" or
            recovery.current_session_id ~= session_id then
            print("[Shard World Index] Refusing to roll back an unrelated pending world generation.")
            cb(false, true)
            return false
        end

        local rollback_state = deepcopy_safe(state)
        rollback_state.generation_source_session_id = source_session_id
        rollback_state.generation_recovery_state = deepcopy_safe(recovery)
        recover_interrupted_generation_source(index, rollback_state, function(success)
            cb(success, true)
        end)
        return true
    end

    local indexed_methods =
    {
        SwitchIndexToGeneratedWorld = world.SwitchIndexToGeneratedWorld,
        SwitchIndexToExistingWorld = world.SwitchIndexToExistingWorld,
        GetState = get_world_index_state,
        SetState = set_world_index_state,
        ReadSidecar = read_world_index_sidecar,
        WriteSidecar = write_world_index_sidecar,
        ClearSidecar = clear_world_index_sidecar,
        ClearAllSidecars = clear_all_world_index_sidecars,
        RestoreParentWorldIndex = restore_parent_world_index,
    }
    for name, fn in pairs(indexed_methods) do
        local method = fn
        ShardWorldIndex[name] = function(self, ...)
            return method(resolve_index_args(self, ...))
        end
    end

    local direct_methods =
    {
        DeleteSessionIfNotHome = world.DeleteSessionIfNotHome,
        RegisterWorldIndexFileID = register_world_index_file_id,
        RegisterWorld = register_world_definition,
        GetRegisteredWorld = registry.Get,
        GetRegisteredWorlds = registry.GetAll,
        BuildWorldSwitchOptions = build_registered_world_switch_options,
    }
    for name, fn in pairs(direct_methods) do
        local method = fn
        ShardWorldIndex[name] = function(_, ...)
            return method(...)
        end
    end

    function ShardWorldIndex:IsActive(index)
        index = resolve_index_args(self, index)
        local state = get_world_index_state(index)
        return state ~= nil and state.active == true
    end

    function ShardWorldIndex:SwitchWorld(world_id, opts, cb)
        local switch_opts, reason = build_registered_world_switch_options(world_id, opts)
        if switch_opts == nil then
            print("[Shard World Index] Cannot switch world: "..tostring(reason)..".")
            if cb ~= nil then
                cb(false)
            end
            return false
        end

        if self:IsActive() then
            return self:AdvanceWorldIndex(switch_opts, cb)
        end
        return self:StartWorldIndex(switch_opts, cb)
    end

    function ShardWorldIndex:SuspendActiveWorldIndex(index, reason, cb)
        index, reason, cb = resolve_index_args(self, index, reason, cb)
        suspend_current_world_index(index, get_world_index_state(index), reason, cb)
    end

    function ShardWorldIndex:ResumeSuspendedWorldIndex(index, state, cb)
        index, state, cb = resolve_index_args(self, index, state, cb)
        resume_suspended_world_index(index, state, cb)
    end

    function ShardWorldIndex:LoadSidecar(index, cb, file_id)
        index, cb, file_id = resolve_index_args(self, index, cb, file_id)
        local function load()
            read_world_index_sidecar(index, function(state, read_success)
                if read_success == false then
                    print("[Shard World Index] Refusing to load a corrupt WorldIndex sidecar.")
                    if cb ~= nil then
                        cb(false)
                    end
                    return
                end
                load_world_index_sidecar_state(index, state, function(...)
                    local args = { ... }
                    session.Drain(index, function()
                        if cb ~= nil then
                            cb(unpack(args))
                        end
                    end)
                end)
            end, file_id)
        end
        manifest.Read(index, function()
            load()
        end)
    end

    function ShardWorldIndex:NeedsGenerationOnLoad(index)
        index = resolve_index_args(self, index)
        return is_load_slot() and is_pending_world_generation_state(get_world_index_state(index))
    end

    function ShardWorldIndex:ReservesSlot(index)
        index = resolve_index_args(self, index)
        local state = get_world_index_state(index)
        return world_index_state_reserves_slot(state) and not is_load_slot()
    end

    function ShardWorldIndex:PreservePendingGenerationOnDelete(index, save_options, cb)
        index, save_options, cb = resolve_index_args(self, index, save_options, cb)
        local state = get_world_index_delete_state(index)
        if save_options and
            state ~= nil and
            state.active and
            should_preserve_pending_world_generation(index, state) and
            not should_regenerate_current_world_index_session(index, state) then
            local staged_index = index_state.Capture(index)
            local home = get_world_index_home_state(state)
            if home ~= nil and home.session_id ~= nil and home.session_id ~= "" and
                (staged_index.session_id == nil or staged_index.session_id == "") then
                world.SwitchIndexToExistingWorld(index, home)
            end

            index:MarkDirty()
            save_index(index, function(index_saved)
                index_state.Apply(index, staged_index)
                set_world_index_state(index, state)
                if not index_saved then
                    if cb ~= nil then
                        cb(false)
                    end
                    return
                end
                write_world_index_sidecar(index, state, cb)
            end)
            return true
        end

        return false
    end

    function ShardWorldIndex:PrepareDelete(index, save_options, cb)
        index, save_options, cb = resolve_index_args(self, index, save_options, cb)
        local state = get_world_index_delete_state(index)
        if save_options and state ~= nil and state.active then
            if prepare_current_world_index_regen(index, state, cb) then
                return
            end
            prepare_interrupted_world_index_regen(index)
        end

        clear_all_world_index_sidecars(index, cb)
    end

    function ShardWorldIndex:PrepareSetServerShardData(index, cb)
        index, cb = resolve_index_args(self, index, cb)
        local state = get_world_index_state(index)
        -- Dedicated startup refreshes server data after loading an existing shard.
        if state ~= nil and
            state.active and
            not world_index_state_matches_current_session(index, state) and
            not should_preserve_pending_world_generation(index, state) then
            prepare_interrupted_world_index_regen(index)
            clear_interrupted_world_index_transition(index, cb)
            return true
        end

        return false
    end

    function ShardWorldIndex:BeforeGenerateNewWorld(index, savedata, metadataStr, session_identifier)
        index, savedata, metadataStr, session_identifier = resolve_index_args(self, index, savedata, metadataStr, session_identifier)
        local state = get_world_index_state(index)
        if state ~= nil and state.active then
            transition.ApplyPendingGenerationState(state)
            local world_table = get_savedata_table(savedata)
            state.current_session_id = session_identifier
            state.updated_at = os.time()
            if type(world_table) == "table" and has_pending_player_sessions(state) then
                world_table.snapshot = type(world_table.snapshot) == "table" and world_table.snapshot or {}
                world_table.snapshot.players = type(world_table.snapshot.players) == "table" and world_table.snapshot.players or {}
                local seen = {}
                for _, userid in ipairs(world_table.snapshot.players) do
                    seen[userid] = true
                end
                for _, session in ipairs(state.player_sessions) do
                    if session.userid ~= nil and session.userid ~= "" and not seen[session.userid] then
                        table.insert(world_table.snapshot.players, session.userid)
                        seen[session.userid] = true
                    end
                end
            end
            write_world_index_topology_state(world_table, state)
            if type(savedata) == "string" and type(world_table) == "table" then
                savedata = DataDumper(world_table, nil, BRANCH ~= "dev")
            end
        end
        return savedata, metadataStr
    end

    function ShardWorldIndex:AfterGenerateNewWorld(index, savedata, session_identifier, cb)
        index, savedata, session_identifier, cb = resolve_index_args(self, index, savedata, session_identifier, cb)
        cb = cb or noop

        local state = get_world_index_state(index)
        if state ~= nil and state.active then
            finish_generated_world_index(index, state, session_identifier, savedata, false, cb)
            return
        end

        cb()
    end


    return
    {
        ReadActiveSidecar = read_active_world_index_sidecar,
    }
end
