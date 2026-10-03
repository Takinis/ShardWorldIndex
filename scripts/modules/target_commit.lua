local players = require("modules/players")
local shards = require("modules/shards")
local transaction_api = require("modules/transaction")
local transition = require("modules/transition")
local world = require("modules/world")

    local function get_current_world_type(index)
        local runtime_world_type = world.GetRuntimeWorldType()
        if runtime_world_type ~= nil then
            return runtime_world_type
        end

        local session_id = index ~= nil and index:GetSession() or nil
        local state = get_world_index_state(index)
        if state ~= nil and state.current_session_id == session_id then
            local current_target = transition.NormalizeTarget(state.current_target)
            local world_type = world.NormalizeWorldType(state.world_type)
            if world_type == nil and current_target ~= nil then
                world_type = world.ResolveLevelWorldType(transition.GetGeneratedLevel(current_target, shards.GetIndexShard(index))) or
                    current_target.world_type
            end
            if world_type ~= nil then
                return world_type
            end
        end

        return world.GetStoredWorldType({ world = index.world })
    end

    local function get_current_world_preset(index)
        local session_id = index ~= nil and index:GetSession() or nil
        local state = get_world_index_state(index)
        if state ~= nil and state.current_session_id == session_id then
            local preset = transition.GetPresetID(state.current_preset)
            if preset ~= nil then
                return preset
            end
        end
        return world.GetStoredWorldPreset({ world = index ~= nil and index.world or nil })
    end

    local function is_current_world_target(index, target)
        target = transition.NormalizeTarget(target)
        if index == nil or target == nil then
            return false
        end

        if target.type == "existing" then
            return target.session_id ~= nil and target.session_id == index:GetSession()
        end

        local level = transition.GetGeneratedLevel(target, shards.GetIndexShard(index))
        local target_preset = transition.GetPresetID(level)
        local current_preset = get_current_world_preset(index)
        if target_preset ~= nil and current_preset ~= nil then
            return target_preset == current_preset
        end

        local target_world_type = world.ResolveLevelWorldType(level) or
            target.world_type
        return target_world_type ~= nil and target_world_type == get_current_world_type(index)
    end

    local function reject_current_world_target(index, target, allow_current_world_target)
        if allow_current_world_target ~= true and is_current_world_target(index, target) then
            print("[Shard World Index] Already in target world "..tostring(transition.GetTargetID(target)).."; switch refused.")
            return true
        end
        return false
    end

    local function reject_unavailable_world_target(index, target, allow_unknown_world_type)
        target = transition.NormalizeTarget(target)
        if allow_unknown_world_type == true or target == nil or target.type == "existing" then
            return false
        end

        local shardid = shards.GetIndexShard(index)
        local level = transition.GetGeneratedLevel(target, shardid)
        local world_type = world.ResolveLevelWorldType(level)
        local file_id = get_world_index_file_id_for_shard(world_type, shardid)
        if not is_known_world_index_file_id(file_id, shardid) then
            print("[Shard World Index] World type "..tostring(world_type).." is not available on shard "..tostring(shardid)..".")
            return true
        end
        return false
    end

    local function should_regenerate_current_world_index_session(index, state)
        ensure_world_index_home_aliases(state)

        local home = get_world_index_home_state(state)
        local session_id = index ~= nil and index:GetSession() or nil
        return state ~= nil and
            state.active == true and
            home ~= nil and
            home.session_id ~= nil and
            home.session_id ~= "" and
            session_id ~= nil and
            session_id ~= "" and
            world_index_state_matches_current_session(index, state) and
            session_id ~= home.session_id and
            not is_pending_world_generation_state(state)
    end

    local function get_current_world_index_regen_target(state)
        local generated_target = transition.NormalizeTarget(state.generated_target)
        if generated_target ~= nil and generated_target.type == "generated" then
            return generated_target
        end
        return transition.NormalizeTarget(state.current_target or state.current_preset)
    end

    local function get_current_world_index_regen_worldgenoverride(index, state)
        if state.current_worldgenoverride ~= nil then
            return state.current_worldgenoverride
        end

        local target = get_current_world_index_regen_target(state)
        local level = transition.GetGeneratedLevel(target, shards.GetIndexShard(index))
        return level ~= nil and world.BuildLevelWorldgenOverrideRaw(level) or nil
    end

    local function prepare_current_world_index_regen(index, state, cb)
        cb = cb or noop
        if not should_regenerate_current_world_index_session(index, state) then
            return false
        end

        local player_sessions = state.secondary ~= true and players.CollectPlayerSessions() or nil
        if player_sessions ~= nil then
            state.player_sessions = player_sessions
            local merge_field = state.collected_player_sessions_field
            if type(merge_field) == "string" and merge_field ~= "" then
                state[merge_field] = players.MergeSessionLists(player_sessions, state[merge_field])
            end
        end

        local target = get_current_world_index_regen_target(state)
        if target ~= nil and target.type == "generated" then
            state.current_target = target
            state.current_preset = transition.GetTargetID(target) or state.current_preset
        end

        state.current_session_id = nil
        state.cleanup_session_id = nil
        state.pending_generation = nil
        state.checked_existing_world = nil
        state.generation_source_session_id = nil
        state.generation_recovery_state = nil
        state.last_player_session_injected = nil
        state.updated_at = os.time()
        set_world_index_state(index, state)

        local worldgenoverride = get_current_world_index_regen_worldgenoverride(index, state)
        if worldgenoverride ~= nil then
            state.current_worldgenoverride = worldgenoverride
            restore_worldgenoverride(index, worldgenoverride, function(worldgenoverride_saved)
                if not worldgenoverride_saved then
                    cb(false)
                    return
                end
                write_world_index_sidecar(index, state, cb)
            end)
        else
            write_world_index_sidecar(index, state, cb)
        end
        return true
    end

    local function has_pending_player_sessions(state)
        return type(state.player_sessions) == "table" and #state.player_sessions > 0
    end

    local function should_cleanup_world_index_session(state)
        return state ~= nil and state.cleanup_current_on_return == true
    end

    local function needs_world_generation_postprocess(state, session_identifier)
        return state ~= nil and
            state.active == true and
            state.current_session_id == session_identifier and
            ((has_pending_player_sessions(state) and state.last_player_session_injected ~= session_identifier) or
            (state.cleanup_session_id ~= nil and state.cleanup_session_id ~= ""))
    end

    local function is_world_generation_saved_without_sidecar(state, session_identifier)
        local home = get_world_index_home_state(state)
        return is_pending_world_generation_state(state) and
            session_identifier ~= nil and
            session_identifier ~= "" and
            home ~= nil and
            session_identifier ~= home.session_id and
            session_identifier ~= state.current_session_id
    end

    local function finish_generated_world_index(index, state, session_identifier, savedata, use_existing_world, cb)
        cb = cb or noop

        if state == nil or not state.active then
            cb(true)
            return
        end

        local home = get_world_index_home_state(state)
        if home == nil or home.session_id == nil or home.session_id == "" then
            print("[Shard World Index] Clearing sidecar without a stashed home world.")
            clear_world_index_sidecar(index, cb)
            return
        end

        if session_identifier == nil or session_identifier == "" then
            cb(false)
            return
        end

        local actual_world_type = world.GetSavedataWorldType(savedata)
        if actual_world_type ~= nil then
            local expected_world_type = world.ResolveLevelWorldType(
                transition.GetGeneratedLevel(state.current_target, shards.GetIndexShard(index)))
            if expected_world_type ~= nil and actual_world_type ~= expected_world_type then
                print("[Shard World Index] Generated session world type mismatch: expected "..
                    tostring(expected_world_type)..", got "..tostring(actual_world_type)..".")
            end
            state.world_type = actual_world_type
        end

        if type(state.generation_source_session_id) == "string" and state.generation_source_session_id ~= "" then
            for _, session in ipairs(state.player_sessions or {}) do
                session.origin_session_id = session.origin_session_id or state.generation_source_session_id
            end
        end

        state.current_session_id = session_identifier
        state.updated_at = os.time()
        state.current_world = deepcopy_safe(index.world)
        state.current_server = deepcopy_safe(index.server)
        state.current_enabled_mods = deepcopy_safe(index.enabled_mods)
        state.generation_source_session_id = nil
        state.generation_recovery_state = nil
        transaction_api.SetPhase(state, "committed")
        set_world_index_state(index, state)

        local can_process_sessions = TheNet ~= nil and TheNet:GetIsServer()
        local should_inject_players = can_process_sessions and
            has_pending_player_sessions(state) and
            state.last_player_session_injected ~= session_identifier
        local cleanup_session_id = state.cleanup_session_id

        local function save_state()
            local has_cleanup_session = cleanup_session_id ~= nil and cleanup_session_id ~= ""
            local should_cleanup_session = can_process_sessions and
                should_cleanup_world_index_session(state) and
                has_cleanup_session and
                cleanup_session_id ~= home.session_id

            if not has_cleanup_session or cleanup_session_id == home.session_id then
                state.cleanup_session_id = nil
                write_world_index_sidecar(index, state, cb)
                return
            end

            if not should_cleanup_session then
                state.cleanup_session_id = nil
                write_world_index_sidecar(index, state, cb)
                return
            end

            state.cleanup_session_id = nil
            write_world_index_sidecar(index, state, function(sidecar_saved)
                if not sidecar_saved then
                    state.cleanup_session_id = cleanup_session_id
                    cb(false)
                    return
                end
                state.cleanup_session_id = nil
                world.DeleteSessionIfNotHome(cleanup_session_id, home.session_id)
                cb(true)
            end)
        end

        if should_inject_players then
            local function on_players_injected(success, migrated_sessions)
                if not success then
                    cb(false)
                    return
                end
                state.pending_player_sessions = migrated_sessions
                state.pending_player_session_id = session_identifier
                state.player_sessions = nil
                state.last_player_session_injected = session_identifier
                save_state()
            end

            if use_existing_world then
                players.InjectPlayerSessionsIntoExistingWorld(index, session_identifier, state.player_sessions, on_players_injected, nil, state.player_positions)
            else
                players.InjectPlayerSessionsIntoWorld(index, state.player_sessions, session_identifier, savedata, on_players_injected)
            end
            return
        end

        save_state()
    end

    local function build_world_index_client_state(state)
        if state == nil then
            return nil
        end

        local total_chapters = type(state.level_sequence) == "table" and #state.level_sequence or nil

        return
        {
            active = state.active == true,
            kind = state.kind,
            secondary = state.secondary == true or nil,
            reason = state.reason,
            sequence_id = state.sequence_id,
            chapter = state.chapter,
            current_preset = transition.GetPresetID(state.current_preset),
            current_session_id = state.current_session_id,
            current_target = transition.GetTargetID(state.current_target),
            total_chapters = total_chapters,
            started_at = state.started_at,
            updated_at = state.updated_at,
            finished_at = state.finished_at,
            return_reason = state.return_reason,
        }
    end

    local function write_world_index_topology_state(savedata, state)
        if savedata == nil or savedata.map == nil or savedata.map.topology == nil then
            return
        end

        local client_state = build_world_index_client_state(state)
        savedata.map.topology.world_index_state = client_state
    end

    local function commit_world_index_existing_target(index, state, target, cb, target_verified)
        cb = cb or noop
        target = transition.NormalizeExistingTarget(index, target)
        if target == nil then
            print("[Shard World Index] Missing existing target session.")
            cb(false)
            return
        end

        if target_verified ~= true then
            players.WorldSessionExists(index, target.session_id, function(exists)
                if not exists then
                    print("[Shard World Index] Existing target session is missing: "..tostring(target.session_id)..".")
                    cb(false)
                    return
                end
                commit_world_index_existing_target(index, state, target, cb, true)
            end)
            return
        end

        local cleanup_session_id = state.cleanup_session_id
        local target_file_id = state.file_id
        state.current_target = transition.NormalizeTarget(target)
        state.current_preset = target.current_preset or state.current_preset or target.id or target.session_id
        state.current_session_id = target.session_id
        if cleanup_session_id == target.session_id then
            state.cleanup_session_id = nil
        end
        state.cleanup_current_on_return = target.cleanup_on_return == true
        if not should_cleanup_world_index_session(state) then
            state.cleanup_session_id = nil
        end
        state.updated_at = os.time()
        state.generated = state.generated == true or target.generated == true
        state.generated_target = state.generated_target or deepcopy_safe(target)
        state.world_type = target.world_type or state.world_type
        state.current_worldgenoverride = target.worldgenoverride or state.current_worldgenoverride
        state.current_world = deepcopy_safe(target.world) or state.current_world
        state.current_server = deepcopy_safe(target.server) or state.current_server
        state.current_enabled_mods = deepcopy_safe(target.enabled_mods) or state.current_enabled_mods
        state.player_positions = deepcopy_safe(target.player_positions)
        state.file_id = target_file_id
        transaction_api.SetPhase(state, "prepared")
        set_world_index_state(index, state)

        world.SwitchIndexToExistingWorld(index, target)

        local function finish_commit(migrated_sessions)
            if migrated_sessions ~= nil then
                state.pending_player_sessions = migrated_sessions
                state.pending_player_session_id = target.session_id
                state.player_sessions = nil
                state.last_player_session_injected = target.session_id
            end

            local should_delete = should_cleanup_world_index_session(state) and
                cleanup_session_id ~= nil and cleanup_session_id ~= "" and
                cleanup_session_id ~= target.session_id
            if should_delete then
                state.cleanup_session_id = nil
            end
            transaction_api.SetPhase(state, "committed")
            write_world_index_sidecar(index, state, function(saved)
                if not saved then
                    if should_delete then
                        state.cleanup_session_id = cleanup_session_id
                    end
                    cb(false)
                    return
                end
                if should_delete then
                    world.DeleteSessionIfNotHome(cleanup_session_id, target.session_id)
                end
                cb(true)
            end)
        end

        local function save_target()
            write_world_index_sidecar(index, state, function(sidecar_saved)
                if not sidecar_saved then
                    cb(false)
                    return
                end
                save_index(index, function(index_saved)
                    if not index_saved then
                        cb(false)
                        return
                    end
                    local sessions = state.player_sessions
                    if sessions ~= nil and #sessions > 0 and TheNet ~= nil and TheNet:GetIsServer() then
                        players.InjectPlayerSessionsIntoExistingWorld(index, target.session_id, sessions, function(injected, migrated_sessions)
                            if not injected then
                                cb(false)
                                return
                            end
                            finish_commit(migrated_sessions)
                        end, nil, target.player_positions)
                    else
                        finish_commit()
                    end
                end)
            end)
        end

        if target.worldgenoverride ~= nil then
            restore_worldgenoverride(index, target.worldgenoverride, function(success)
                if success then
                    save_target()
                else
                    cb(false)
                end
            end)
        else
            save_target()
        end
    end

    local function commit_world_index_generated_target(index, state, target, keep_session, cb)
        cb = cb or noop
        target = transition.NormalizeTarget(target)

        local level = transition.GetGeneratedLevel(target, shards.GetIndexShard(index))
        if level == nil then
            print("[Shard World Index] Missing generated target level.")
            cb(false)
            return
        end

        local level_world_type = world.ResolveLevelWorldType(level)
        local target_preset = transition.GetPresetID(level)

        local valid, reason = world.ValidateWorldIndexGeneratedLevel(level)
        if not valid then
            print("[Shard World Index] Refusing to switch world: "..tostring(reason)..".")
            cb(false)
            return
        end

        local file_id = state.file_id
        if not state.checked_existing_world and target.reuse_existing ~= false and state.reuse_existing ~= false then
            state.checked_existing_world = true

            local function generate_target()
                commit_world_index_generated_target(index, state, target, keep_session, cb)
            end

            local function reuse_target(existing_target)
                state.checked_existing_world = nil
                state.generated = existing_target.generated == true or nil
                state.generated_target = transition.NormalizeTarget(target)
                state.cleanup_current_on_return = false
                commit_world_index_existing_target(index, state, existing_target, cb)
            end

            local function check_existing_sidecar()
                read_world_index_sidecar(index, function(existing_state, read_success)
                    if read_success == false then
                        cb(false)
                        return
                    end
                    local session_id = existing_state ~= nil and existing_state.current_session_id or nil
                    if session_id == nil or session_id == "" then
                        generate_target()
                        return
                    end

                    world.ReadWorldSessionWorldType(index, session_id, function(actual_world_type, exists)
                        local target_world_type = target.world_type or level_world_type
                        if exists and actual_world_type == target_world_type and
                            existing_state.current_preset == target_preset then
                            reuse_target({
                                type = "existing",
                                id = existing_state.current_preset or transition.GetTargetID(target),
                                current_preset = existing_state.current_preset,
                                session_id = session_id,
                                worldgenoverride = existing_state.current_worldgenoverride or world.BuildLevelWorldgenOverrideRaw(level),
                                world = existing_state.current_world or { options = world.ResolveLevelOptions(level) },
                                server = existing_state.current_server,
                                enabled_mods = existing_state.current_enabled_mods,
                                world_type = actual_world_type,
                                player_positions = existing_state.player_positions,
                                generated = true,
                                cleanup_on_return = false,
                            })
                            return
                        end

                        if exists and actual_world_type ~= target_world_type then
                            print("[Shard World Index] Stored session "..tostring(session_id)..
                                " is "..tostring(actual_world_type)..", not "..tostring(target_world_type).."; refusing reuse.")
                        elseif exists then
                            print("[Shard World Index] Stored session "..tostring(session_id)..
                                " uses preset "..tostring(existing_state.current_preset)..", not "..
                                tostring(target_preset).."; refusing reuse.")
                        end
                        existing_state.current_session_id = nil
                        existing_state.active = false
                        existing_state.world_type = actual_world_type or existing_state.world_type
                        write_world_index_sidecar(index, existing_state, function(saved)
                            if saved then
                                generate_target()
                            else
                                cb(false)
                            end
                        end, file_id)
                    end)
                end, file_id)
            end

            local home = get_world_index_home_state(state)
            local target_world_type = target.world_type or world.ResolveLevelWorldType(level)
            if home.session_id ~= nil and home.session_id ~= "" then
                world.ReadWorldSessionWorldType(index, home.session_id, function(actual_world_type, exists)
                    if actual_world_type ~= nil then
                        home.world_type = actual_world_type
                    end
                    if exists and actual_world_type == target_world_type and
                        home.current_preset == target_preset then
                        print("[Shard World Index] Reusing stored home world for "..tostring(target_world_type)..".")
                        reuse_target({
                            type = "existing",
                            id = transition.GetTargetID(target),
                            current_preset = home.current_preset,
                            session_id = home.session_id,
                            worldgenoverride = home.worldgenoverride or world.BuildLevelWorldgenOverrideRaw(level),
                            world = home.world or { options = world.ResolveLevelOptions(level) },
                            server = home.server,
                            enabled_mods = home.enabled_mods,
                            world_type = actual_world_type,
                            player_positions = home.player_positions,
                            cleanup_on_return = false,
                        })
                        return
                    end

                    if exists and actual_world_type ~= target_world_type then
                        print("[Shard World Index] Home session "..tostring(home.session_id)..
                            " is "..tostring(actual_world_type)..", not "..tostring(target_world_type).."; refusing reuse.")
                    elseif exists then
                        print("[Shard World Index] Home session "..tostring(home.session_id)..
                            " uses preset "..tostring(home.current_preset)..", not "..
                            tostring(target_preset).."; refusing reuse.")
                    end
                    check_existing_sidecar()
                end)
            else
                check_existing_sidecar()
            end
            return
        end
        state.checked_existing_world = nil

        state.current_target = target
        state.current_preset = target_preset
        state.cleanup_current_on_return = target.cleanup_on_return == true
        state.updated_at = os.time()
        state.generation_source_session_id = state.generation_source_session_id or index:GetSession()
        state.generation_recovery_state = state.generation_recovery_state or
            build_generation_recovery_state(index, state, state.generation_source_session_id)
        state.current_session_id = nil
        state.player_positions = nil
        transaction_api.SetPhase(state, "prepared")
        set_world_index_state(index, state)
        world.SwitchIndexToGeneratedWorld(index, level, keep_session ~= false)

        local worldgenoverride = world.BuildLevelWorldgenOverrideRaw(level)
        write_worldgenoverride_str(index, worldgenoverride, function(worldgenoverride_saved)
            if not worldgenoverride_saved then
                cb(false)
                return
            end
            state.generated = true
            state.generated_target = transition.NormalizeTarget(target)
            state.world_type = level_world_type
            state.current_worldgenoverride = worldgenoverride
            state.current_world = deepcopy_safe(index.world)
            state.current_server = deepcopy_safe(index.server)
            state.current_enabled_mods = deepcopy_safe(index.enabled_mods)
            write_world_index_sidecar(index, state, function(sidecar_saved)
                if not sidecar_saved then
                    cb(false)
                    return
                end
                save_index(index, function(index_saved)
                    cb(index_saved == true)
                end)
            end)
        end)
    end

    local function commit_world_index_target(index, state, target, keep_session, cb)
        target = transition.NormalizeTarget(target)
        if target == nil then
            print("[Shard World Index] Missing target world.")
            cb(false)
            return
        end
        local shardid = shards.GetIndexShard(index)
        state.file_id = get_world_index_file_id_for_shard(state.file_id or transition.GetTargetFileID(target, nil, shardid), shardid)

        if target.type == "existing" then
            commit_world_index_existing_target(index, state, target, cb)
        else
            commit_world_index_generated_target(index, state, target, keep_session, cb)
        end
    end


    return
    {
        RejectCurrentTarget = reject_current_world_target,
        RejectUnavailableTarget = reject_unavailable_world_target,
        ShouldRegenerateCurrentSession = should_regenerate_current_world_index_session,
        PrepareCurrentRegen = prepare_current_world_index_regen,
        HasPendingPlayerSessions = has_pending_player_sessions,
        ShouldCleanupSession = should_cleanup_world_index_session,
        NeedsGenerationPostprocess = needs_world_generation_postprocess,
        IsGenerationSavedWithoutSidecar = is_world_generation_saved_without_sidecar,
        FinishGenerated = finish_generated_world_index,
        WriteTopologyState = write_world_index_topology_state,
        CommitTarget = commit_world_index_target,
    }
