return function(Class)
    local ShardWorldIndex = Class
    local index_state = require("modules/index_state")
    local players = require("modules/players")
    local shards = require("modules/shards")
    local transaction_api = require("modules/transaction")
    local transition = require("modules/transition")
    local world = require("modules/world")

    function ShardWorldIndex:BeginWorldIndex(index, opts, cb)
        index, opts, cb = resolve_index_args(self, index, opts, cb)
        cb = cb or noop
        opts = opts or {}

        local active_state = get_world_index_state(index)
        if active_state ~= nil and active_state.active == true then
            print("[Shard World Index] A world index is already active.")
            cb(false)
            return
        end

        local home_session = index:GetSession()
        if home_session == nil or home_session == "" then
            print("[Shard World Index] Cannot switch without a current world session.")
            cb(false)
            return
        end

        local target = transition.GetTargetFromOpts(opts)
        if target == nil then
            print("[Shard World Index] Missing target world.")
            cb(false)
            return
        end
        if reject_unavailable_world_target(index, target, opts.allow_unknown_world_type) or
            (opts.secondary ~= true and reject_current_world_target(index, target, opts.allow_current_world_target)) then
            cb(false)
            return
        end
        local shardid = shards.GetIndexShard(index)
        local file_id = get_world_index_file_id_for_shard(opts.file_id or transition.GetTargetFileID(target, nil, shardid), shardid)

        read_worldgenoverride_raw(index, function(home_wgo)
            local state = deepcopy_safe(opts.state) or {}
            state.active = true
            state.file_id = get_world_index_file_id_for_shard(state.file_id or file_id, shardid)
            state.kind = state.kind or opts.kind or "world_index"
            state.allow_unknown_world_type = state.allow_unknown_world_type == true or opts.allow_unknown_world_type == true
            state.allow_current_world_target = state.allow_current_world_target == true or opts.allow_current_world_target == true
            state.reuse_existing = opts.reuse_existing ~= false
            if opts.secondary == true then
                state.secondary = true
            end
            state.reason = state.reason or opts.reason or "begin"
            state.sequence_id = state.sequence_id or opts.sequence_id or "default"
            state.slot = state.slot or index:GetSlot()
            state.shard = state.shard or shards.GetIndexShard(index)
            state.started_at = state.started_at or os.time()
            state.updated_at = os.time()
            state.level_sequence = state.level_sequence or deepcopy_safe(opts.level_sequence)
            state.chapter = state.chapter or opts.chapter
            state.current_target = target
            state.current_preset = state.current_preset or transition.GetTargetID(target)
            state.current_session_id = nil
            transaction_api.Begin(state,
            {
                operation = opts.reason or opts.kind or "begin",
                file_id = state.file_id,
                id = opts.transaction_id,
            })

            local is_secondary = state.secondary == true or opts.secondary == true
            local player_sessions = opts.player_sessions
            if player_sessions == nil and not is_secondary and opts.collect_player_sessions ~= false then
                player_sessions = players.CollectPlayerSessions()
            end
            opts.player_sessions = player_sessions
            if state.player_sessions == nil and opts.fallback_player_sessions ~= false then
                state.player_sessions = player_sessions
            end

            local home = state.home or state.main or build_world_index_home_state(index, home_wgo, opts)
            state.home = home
            state.main = state.main or deepcopy_safe(home)

            commit_world_index_target(index, state, target, opts.keep_session, cb)
        end)
    end

    function ShardWorldIndex:BeginSecondaryWorldIndex(index, opts, cb)
        index, opts, cb = resolve_index_args(self, index, opts, cb)
        opts = opts or {}
        opts.secondary = true
        opts.target = transition.GetTargetForShard(transition.GetTargetFromOpts(opts), shards.GetIndexShard(index))
        local state = deepcopy_safe(opts.state) or {}
        state.secondary = true
        opts.state = state
        self:BeginWorldIndex(index, opts, cb)
    end

    function ShardWorldIndex:AdvanceSecondaryWorldIndex(index, opts, cb)
        index, opts, cb = resolve_index_args(self, index, opts, cb)
        opts = opts or {}
        local state = get_world_index_state(index)
        if state == nil or not state.active then
            self:BeginSecondaryWorldIndex(index, opts, cb)
            return
        end
        opts.target = transition.GetTargetForShard(transition.GetTargetFromOpts(opts), shards.GetIndexShard(index))
        self:QueueNextWorld(index, opts, cb)
    end

    function ShardWorldIndex:QueueNextWorld(index, opts, cb)
        index, opts, cb = resolve_index_args(self, index, opts, cb)
        cb = cb or noop
        opts = opts or {}

        local state = get_world_index_state(index)
        if state == nil or not state.active or get_world_index_home_state(state) == nil then
            print("[Shard World Index] No active world index to advance.")
            cb(false)
            return
        end

        local target = transition.GetTargetFromOpts(opts, state)
        if target == nil and opts.chapter ~= nil and type(state.level_sequence) == "table" then
            target = transition.NormalizeTarget(world.GetLevelForShard(state.level_sequence[opts.chapter], shards.GetIndexShard(index)))
        end
        if target == nil then
            print("[Shard World Index] Missing queued world.")
            cb(false)
            return
        end
        if reject_unavailable_world_target(index, target,
            opts.allow_unknown_world_type == true or state.allow_unknown_world_type == true) or
            (state.secondary ~= true and reject_current_world_target(index, target,
                opts.allow_current_world_target == true or state.allow_current_world_target == true)) then
            cb(false)
            return
        end
        local shardid = shards.GetIndexShard(index)
        local current_file_id = normalize_world_index_file_id(state.file_id)
        local queued_file_id = get_world_index_file_id_for_shard(opts.file_id or transition.GetTargetFileID(target, state.file_id, shardid), shardid)
        local previous_state = nil
        if queued_file_id ~= current_file_id then
            previous_state = deepcopy_safe(state)
            state = deepcopy_safe(state) or {}
        end
        state.file_id = queued_file_id

        local pending = deepcopy_safe(opts.pending_generation) or {}
        local player_sessions = pending.player_sessions or opts.player_sessions
        if player_sessions == nil and not state.secondary and opts.collect_player_sessions ~= false then
            player_sessions = players.CollectPlayerSessions()
        end
        if state.track_player_positions ~= false then
            local player_positions = players.GetPlayerPositions(player_sessions)
            set_player_positions_for_session(state, index:GetSession(), player_positions)
            if previous_state ~= nil then
                set_player_positions_for_session(previous_state, index:GetSession(), player_positions)
            end
        end
        pending.reason = pending.reason or opts.reason or "advance"
        pending.chapter = pending.chapter or opts.chapter
        pending.target = pending.target or target
        pending.current_target = pending.current_target or target
        pending.current_preset = pending.current_preset or transition.GetTargetID(target)
        pending.file_id = pending.file_id or queued_file_id
        pending.player_sessions = player_sessions
        if pending.cleanup_session_id == nil and target.cleanup_on_return == true then
            pending.cleanup_session_id = state.current_session_id
        end
        pending.generation_source_session_id = pending.generation_source_session_id or state.current_session_id or index:GetSession()
        pending.generation_recovery_state = pending.generation_recovery_state or
            build_generation_recovery_state(index, state, pending.generation_source_session_id)
        pending.reuse_existing = opts.reuse_existing ~= false
        state.pending_generation = pending
        state.reuse_existing = opts.reuse_existing ~= false
        state.updated_at = os.time()
        transaction_api.Begin(state,
        {
            operation = pending.reason or "advance",
            file_id = queued_file_id,
            id = opts.transaction_id,
        })

        local pending_chapter = pending.chapter

        local function finish_commit(success)
            if success and previous_state ~= nil then
                local parked_state = deepcopy_safe(previous_state)
                parked_state.active = false
                parked_state.pending_generation = nil
                parked_state.checked_existing_world = nil
                parked_state.updated_at = os.time()
                write_world_index_sidecar(index, parked_state, function(parked_saved)
                    if not parked_saved then
                        cb(false, pending_chapter)
                        return
                    end
                    set_world_index_state(index, parked_state, current_file_id)
                    set_world_index_state(index, state, queued_file_id)
                    cb(true, pending_chapter)
                end, current_file_id)
                return
            end

            if not success and previous_state ~= nil then
                write_world_index_sidecar(index, nil, function()
                    set_world_index_state(index, nil, queued_file_id)
                    set_world_index_state(index, previous_state, current_file_id)
                    cb(false, pending_chapter)
                end, queued_file_id)
                return
            end

            cb(success, pending_chapter)
        end

        local function commit_queued_state()
            transition.ApplyPendingGenerationState(state)
            commit_world_index_target(index, state, target, opts.keep_session, function(success)
                finish_commit(success)
            end)
        end

        if previous_state ~= nil then
            read_world_index_sidecar(index, function(existing_state, read_success)
                if read_success == false then
                    finish_commit(false)
                    return
                end
                state.current_session_id = nil
                state.current_worldgenoverride = nil
                state.current_world = nil
                state.current_server = nil
                state.current_enabled_mods = nil
                state.generated = nil
                state.generated_target = nil
                state.player_positions = nil

                if existing_state ~= nil and existing_state.current_session_id ~= nil and existing_state.current_session_id ~= "" then
                    state.current_session_id = existing_state.current_session_id
                    state.current_preset = existing_state.current_preset or state.current_preset
                    state.current_worldgenoverride = existing_state.current_worldgenoverride
                    state.current_world = deepcopy_safe(existing_state.current_world)
                    state.current_server = deepcopy_safe(existing_state.current_server)
                    state.current_enabled_mods = deepcopy_safe(existing_state.current_enabled_mods)
                    state.generated = existing_state.generated == true or nil
                    state.generated_target = deepcopy_safe(existing_state.generated_target)
                    state.world_type = existing_state.world_type or state.world_type
                    state.player_positions = deepcopy_safe(existing_state.player_positions)
                end

                write_world_index_sidecar(index, state, function(saved)
                    if saved then
                        commit_queued_state()
                    else
                        finish_commit(false)
                    end
                end)
            end, queued_file_id)
            return
        end

        write_world_index_sidecar(index, state, function(saved)
            if saved then
                commit_queued_state()
            else
                finish_commit(false)
            end
        end)
    end

    function ShardWorldIndex:ReturnToStoredWorld(index, reason, cb, player_sessions, opts)
        index, reason, cb, player_sessions, opts = resolve_index_args(self, index, reason, cb, player_sessions, opts)
        cb = cb or noop
        opts = opts or {}

        local state = get_world_index_state(index)
        local home = get_world_index_home_state(state)
        if state == nil or not state.active or home == nil then
            print("[Shard World Index] No active world index to return from.")
            cb(false)
            return
        end

        if opts.home_session_verified ~= true then
            players.WorldSessionExists(index, home.session_id, function(exists)
                if not exists then
                    print("[Shard World Index] Stored home session is missing: "..tostring(home.session_id)..".")
                    cb(false)
                    return
                end
                opts.home_session_verified = true
                self:ReturnToStoredWorld(index, reason, cb, player_sessions, opts)
            end)
            return
        end

        local current_index = index_state.Capture(index)
        local current_worldgenoverride = state.current_worldgenoverride
        local cleanup_session_id = should_cleanup_world_index_session(state) and state.current_session_id or nil
        local sessions = player_sessions or state.return_player_sessions

        local player_positions = players.GetPlayerPositions(sessions)
        if player_positions ~= nil then
            set_player_positions_for_session(state, index:GetSession(), player_positions)
        end

        state.return_player_sessions = deepcopy_safe(sessions)
        state.return_pending =
        {
            reason = reason or "return",
            cleanup_session_id = cleanup_session_id,
            parent_world_index_file_id = type(state.parent_world_index_state) == "table" and
                state.parent_world_index_state.file_id or nil,
            started_at = os.time(),
        }
        state.updated_at = os.time()
        transaction_api.Begin(state,
        {
            operation = reason or "return",
            file_id = state.file_id,
            id = opts.transaction_id,
        })

        local function restore_current_index(done)
            index_state.Apply(index, current_index)
            restore_worldgenoverride(index, current_worldgenoverride, function()
                save_index(index, function()
                    set_world_index_state(index, state)
                    done(false)
                end)
            end)
        end

        local function commit_return()
            local finished_state = deepcopy_safe(state)
            finished_state.active = false
            finished_state.finished_at = os.time()
            finished_state.return_reason = reason or "return"
            finished_state.return_player_sessions = nil
            if opts.defer_cleanup and cleanup_session_id ~= nil and cleanup_session_id ~= "" then
                finished_state.deferred_cleanup_session_id = cleanup_session_id
            end
            if opts.defer_cleanup or opts.defer_parent_restore then
                finished_state.deferred_return = true
            end
            if type(finished_state.parent_world_index_state) ~= "table" then
                finished_state.return_pending = nil
            end
            transaction_api.SetPhase(finished_state, opts.defer_cleanup and "finalize_pending" or "committed")

            world.SwitchIndexToExistingWorld(index, home)
            restore_worldgenoverride(index, home.worldgenoverride, function(worldgenoverride_saved)
                if not worldgenoverride_saved then
                    restore_current_index(cb)
                    return
                end
                save_index(index, function(index_saved)
                    if not index_saved then
                        restore_current_index(cb)
                        return
                    end
                    write_world_index_sidecar(index, finished_state, function(sidecar_saved)
                        if not sidecar_saved then
                            restore_current_index(cb)
                            return
                        end
                        set_world_index_state(index, finished_state)
                        if not opts.defer_cleanup and cleanup_session_id ~= nil and cleanup_session_id ~= "" then
                            world.DeleteSessionIfNotHome(cleanup_session_id, home.session_id)
                        end
                        cb(true)
                    end)
                end)
            end)
        end

        write_world_index_sidecar(index, state, function(pending_saved)
            if not pending_saved then
                state.return_pending = nil
                cb(false)
                return
            end

            if sessions ~= nil and #sessions > 0 and TheNet ~= nil and TheNet:GetIsServer() then
                local return_player_positions = home.player_positions
                if opts.ignore_saved_positions then
                    return_player_positions = nil
                end
                players.InjectPlayerSessionsIntoExistingWorld(index, home.session_id, sessions, function(injected, migrated_sessions)
                    if not injected then
                        cb(false)
                        return
                    end
                    state.pending_player_sessions = migrated_sessions
                    state.pending_player_session_id = home.session_id
                    state.return_player_sessions = nil
                    state.last_player_session_injected = home.session_id
                    commit_return()
                end, home.return_position, return_player_positions, opts.spawn_prefab)
                return
            end

            commit_return()
        end)
    end

    local function finalize_world_index_state(index, state, fields, cleanup_session_id, cb, file_id)
        file_id = file_id or state.file_id
        local previous = {}
        for _, field in ipairs(fields) do
            previous[field] = state[field]
            state[field] = nil
        end
        transaction_api.SetPhase(state, "finalized")
        write_world_index_sidecar(index, state, function(saved)
            if not saved then
                for _, field in ipairs(fields) do
                    state[field] = previous[field]
                end
                cb(false)
                return
            end
            set_world_index_state(index, state, file_id)
            local home = get_world_index_home_state(state)
            if cleanup_session_id ~= nil and cleanup_session_id ~= "" and home ~= nil then
                world.DeleteSessionIfNotHome(cleanup_session_id, home.session_id)
            end
            cb(true)
        end, file_id)
    end

    local function finalize_deferred_return(index, state, cb)
        cb = cb or noop
        if state == nil or state.active or state.deferred_return ~= true then
            cb(false)
            return
        end

        local cleanup_session_id = state.deferred_cleanup_session_id
        local function finish()
            finalize_world_index_state(index, state,
                { "deferred_return", "deferred_cleanup_session_id" },
                cleanup_session_id, cb)
        end

        if type(state.parent_world_index_state) == "table" then
            restore_parent_world_index(index, state, function(parent_restored)
                if parent_restored then
                    finish()
                else
                    cb(false)
                end
            end)
        else
            finish()
        end
    end

    local function rollback_deferred_return(index, state, cb)
        cb = cb or noop
        if state == nil or state.active or state.deferred_return ~= true or not world.SwitchIndexToCurrentWorld(index, state) then
            cb(false)
            return
        end

        state.active = true
        state.finished_at = nil
        state.return_reason = nil
        state.return_pending = nil
        state.deferred_return = nil
        state.deferred_cleanup_session_id = nil
        state.updated_at = os.time()
        index_state.Persist(index, state,
        {
            file_id = state.file_id,
            restore_worldgenoverride = true,
            worldgenoverride = state.current_worldgenoverride,
        }, cb)
    end

    function ShardWorldIndex:FinalizeDeferredReturn(index, state, cb)
        index, state, cb = resolve_index_args(self, index, state, cb)
        finalize_deferred_return(index, state, cb)
    end

    function ShardWorldIndex:RollbackDeferredReturn(index, state, cb)
        index, state, cb = resolve_index_args(self, index, state, cb)
        rollback_deferred_return(index, state, cb)
    end

    return
    {
        FinalizeState = finalize_world_index_state,
        FinalizeDeferredReturn = finalize_deferred_return,
        RollbackDeferredReturn = rollback_deferred_return,
    }
end
