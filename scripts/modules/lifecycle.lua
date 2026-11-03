return function(Class)
    local index_state = require("modules/index_state")
    local manifest = require("modules/manifest")
    local players = require("modules/players")
    local session = require("modules/session")
    local state_store = require("modules/state_store")
    local target_commit = require("modules/target_commit")
    local transition = require("modules/transition")
    local world = require("modules/world")
    local world_switch = require("modules/world_switch")

    local function load_world_index_sidecar_state(index, state, cb)
        cb = cb or noop
        state_store.EnsureHomeAliases(state)

        if state == nil then
            state_store.SetState(index, state)
            cb(true)
            return
        end

        if not state.active then
            state_store.SetState(index, state)
            if state.deferred_return == true and state.secondary_transition == nil and
                state.secondary_finalize_pending == nil then
                world_switch.FinalizeDeferredReturn(index, state, cb)
                return
            end
            cb(true)
            return
        end

        if world_index_state_has_origin(state) and not world_index_state_matches_index(index, state) then
            print("[Shard World Index] Clearing sidecar from another slot or shard.")
            state_store.ClearSidecar(index, cb)
            return
        end

        local session_id = index:GetSession()
        if is_world_index_transition_restart() then
            state_store.SetState(index, state)
            cb()
            return
        end
        local secondary = state.secondary_transition
        if state.secondary_finalize_pending ~= nil or
            (secondary ~= nil and secondary.status == "committed") then
            state_store.SetState(index, state)
            cb(true)
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

        if session_id ~= nil and session_id ~= "" and
            target_commit.IsGenerationSavedWithoutSidecar(state, session_id) then
            players.WorldSessionExists(index, session_id, function(exists)
                if exists then
                    print("[Shard World Index] Finishing interrupted world generation.")
                    transition.ApplyPendingGenerationState(state)
                    target_commit.FinishGenerated(index, state, session_id, nil, true, cb)
                else
                    print("[Shard World Index] Generated session is missing; returning to stashed home world.")
                    finish_interrupted_return_to_stored_world(index, state, cb)
                end
            end)
            return
        end

        if session_id == nil or session_id == "" then
            if state_store.IsPendingGeneration(state) then
                print("[Shard World Index] Resuming interrupted world generation.")
                transition.ApplyPendingGenerationState(state)
                state_store.SetState(index, state)
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
                    state_store.SetState(index, state)
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
                    if target_commit.NeedsGenerationPostprocess(state, session_id) then
                        print("[Shard World Index] Finishing pending world generation postprocess.")
                        target_commit.FinishGenerated(index, state, session_id, nil, true, cb)
                    else
                        state_store.SetState(index, state)
                        cb()
                    end
                else
                    print("[Shard World Index] Current generated session is missing; returning to stashed home world.")
                    finish_interrupted_return_to_stored_world(index, state, cb)
                end
            end)
            return
        end

        local home = state_store.GetHomeState(state)
        if home ~= nil and home.session_id == session_id then
            print("[Shard World Index] Finishing interrupted return to stored world.")
            finish_interrupted_return_to_stored_world(index, state, cb)
            return
        end

        print("[Shard World Index] Clearing stale sidecar for unrelated session.")
        state_store.ClearSidecar(index, cb)
    end

    function Class:RollbackPendingGeneration(index, cb, file_id)
        index, cb, file_id = resolve_index_args(self, index, cb, file_id)
        cb = cb or noop

        local state = state_store.GetState(index, file_id)
        local session_id = index ~= nil and index:GetSession() or nil
        local pending = state ~= nil and type(state.pending_generation) == "table" and state.pending_generation or nil
        local source_session_id = state ~= nil and
            (state.generation_source_session_id or (pending ~= nil and pending.generation_source_session_id or nil)) or nil
        local recovery = state ~= nil and
            (state.generation_recovery_state or (pending ~= nil and pending.generation_recovery_state or nil)) or nil
        if state == nil or
            state.active ~= true or
            not state_store.IsPendingGeneration(state) then
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

    function Class:GetState(index, file_id)
        index, file_id = resolve_index_args(self, index, file_id)
        return state_store.GetState(index, file_id)
    end

    function Class:ReadSidecar(index, cb, file_id)
        index, cb, file_id = resolve_index_args(self, index, cb, file_id)
        return state_store.ReadSidecar(index, cb, file_id)
    end

    function Class:WriteSidecar(index, state, cb, file_id)
        index, state, cb, file_id = resolve_index_args(self, index, state, cb, file_id)
        return state_store.WriteSidecar(index, state, cb, file_id)
    end

    function Class:RestoreParentWorldIndex(index, state, cb)
        index, state, cb = resolve_index_args(self, index, state, cb)
        return restore_parent_world_index(index, state, cb)
    end

    function Class:ClearAllSidecars(index, cb)
        index, cb = resolve_index_args(self, index, cb)
        return state_store.ClearAllSidecars(index, cb)
    end

    function Class:IsActive(index)
        index = resolve_index_args(self, index)
        local state = state_store.GetState(index)
        return state ~= nil and state.active == true
    end

    function Class:SwitchWorld(world_id, opts, cb)
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

    function Class:SuspendActiveWorldIndex(index, reason, cb)
        index, reason, cb = resolve_index_args(self, index, reason, cb)
        suspend_current_world_index(index, state_store.GetState(index), reason, cb)
    end

    function Class:ResumeSuspendedWorldIndex(index, state, cb)
        index, state, cb = resolve_index_args(self, index, state, cb)
        resume_suspended_world_index(index, state, cb)
    end

    function Class:LoadSidecar(index, cb, file_id)
        index, cb, file_id = resolve_index_args(self, index, cb, file_id)
        local function load()
            state_store.ReadSidecar(index, function(state, read_success)
                if read_success == false then
                    print("[Shard World Index] Refusing to load a corrupt WorldIndex sidecar.")
                    if cb ~= nil then
                        cb(false)
                    end
                    return
                end
                load_world_index_sidecar_state(index, state, function(...)
                    local args = { ... }
                    session.Drain(index, function(cleaned)
                        if cb ~= nil then
                            if cleaned == false then
                                cb(false)
                            else
                                cb(unpack(args))
                            end
                        end
                    end)
                end)
            end, file_id)
        end
        manifest.Read(index, function(_, valid)
            if valid == false then
                (cb or noop)(false)
                return
            end
            load()
        end)
    end

    function Class:NeedsGenerationOnLoad(index)
        index = resolve_index_args(self, index)
        return is_load_slot() and state_store.IsPendingGeneration(state_store.GetState(index))
    end

    function Class:ReservesSlot(index)
        index = resolve_index_args(self, index)
        local state = state_store.GetState(index)
        return state_store.ReservesSlot(state) and not is_load_slot()
    end

    function Class:PreservePendingGenerationOnDelete(index, save_options, cb)
        index, save_options, cb = resolve_index_args(self, index, save_options, cb)
        local state = state_store.GetDeleteState(index)
        if save_options and
            state ~= nil and
            state.active and
            should_preserve_pending_world_generation(index, state) and
            not target_commit.ShouldRegenerateCurrentSession(index, state) then
            local staged_index = index_state.Capture(index)
            local home = state_store.GetHomeState(state)
            if home ~= nil and home.session_id ~= nil and home.session_id ~= "" and
                (staged_index.session_id == nil or staged_index.session_id == "") then
                world.SwitchIndexToExistingWorld(index, home)
            end

            index:MarkDirty()
            save_index(index, function(index_saved)
                index_state.Apply(index, staged_index)
                state_store.SetState(index, state)
                if not index_saved then
                    if cb ~= nil then
                        cb(false)
                    end
                    return
                end
                state_store.WriteSidecar(index, state, cb)
            end)
            return true
        end

        return false
    end

    function Class:PrepareDelete(index, save_options, cb)
        index, save_options, cb = resolve_index_args(self, index, save_options, cb)
        local state = state_store.GetDeleteState(index)
        if save_options and state ~= nil and state.active then
            if target_commit.PrepareCurrentRegen(index, state, cb) then
                return
            end
            prepare_interrupted_world_index_regen(index)
        end

        state_store.ClearAllSidecars(index, cb)
    end

    function Class:PrepareSetServerShardData(index, cb)
        index, cb = resolve_index_args(self, index, cb)
        local state = state_store.GetState(index)
        -- Dedicated startup refreshes server data after loading an existing shard.
        if state ~= nil and
            state.active and
            not state_store.MatchesCurrentSession(index, state) and
            not should_preserve_pending_world_generation(index, state) then
            prepare_interrupted_world_index_regen(index)
            clear_interrupted_world_index_transition(index, cb)
            return true
        end

        return false
    end

    function Class:BeforeGenerateNewWorld(index, savedata, metadataStr, session_identifier)
        index, savedata, metadataStr, session_identifier = resolve_index_args(self, index, savedata, metadataStr, session_identifier)
        local state = state_store.GetState(index)
        if state ~= nil and state.active then
            transition.ApplyPendingGenerationState(state)
            local world_table = get_savedata_table(savedata)
            state.current_session_id = session_identifier
            state.updated_at = os.time()
            if type(world_table) == "table" and target_commit.HasPendingPlayerSessions(state) then
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
            target_commit.WriteTopologyState(world_table, state)
            if type(savedata) == "string" and type(world_table) == "table" then
                savedata = DataDumper(world_table, nil, BRANCH ~= "dev")
            end
        end
        return savedata, metadataStr
    end

    function Class:AfterGenerateNewWorld(index, savedata, session_identifier, cb)
        index, savedata, session_identifier, cb = resolve_index_args(self, index, savedata, session_identifier, cb)
        cb = cb or noop

        local state = state_store.GetState(index)
        if state ~= nil and state.active then
            target_commit.FinishGenerated(index, state, session_identifier, savedata, false, cb)
            return
        end

        cb()
    end

end
