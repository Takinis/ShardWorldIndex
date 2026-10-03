local manifest = require("modules/manifest")
local players = require("modules/players")
local recovery = require("modules/recovery")
local shards = require("modules/shards")
local storage = require("modules/storage")
local transaction = require("modules/transaction")
    local registered_file_ids = {}
    local registered_secondary_file_ids = {}

    local function normalize_file_id(file_id)
        if file_id == nil or file_id == "" then
            return "world"
        end

        file_id = string.lower(tostring(file_id)):gsub("[^%w_%-]", "_")
        file_id = file_id:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
        return file_id ~= "" and file_id or "world"
    end

    local function add_file_id(list, seen, file_id)
        file_id = normalize_file_id(file_id)
        if not seen[file_id] then
            seen[file_id] = true
            list[#list + 1] = file_id
        end
    end

    local function register_file_id(file_id, secondary_file_id)
        file_id = normalize_file_id(file_id)
        registered_file_ids[file_id] = true
        if secondary_file_id ~= nil then
            secondary_file_id = normalize_file_id(secondary_file_id)
            registered_file_ids[secondary_file_id] = true
            registered_secondary_file_ids[file_id] = secondary_file_id
        end
        return file_id, secondary_file_id
    end

    local function get_file_id_for_shard(file_id, shardid)
        file_id = normalize_file_id(file_id)
        return not is_master_shard_id(shardid) and
            (registered_secondary_file_ids[file_id] or SECONDARY_WORLD_INDEX_FILE_IDS[file_id]) or file_id
    end

    local function is_known_file_id(file_id, shardid)
        if registered_file_ids[file_id] then
            return true
        end
        local known_ids = is_master_shard_id(shardid) and
            WORLD_INDEX_KNOWN_FILE_IDS.Master or WORLD_INDEX_KNOWN_FILE_IDS.Caves
        for _, known_file_id in ipairs(known_ids) do
            if file_id == known_file_id then
                return true
            end
        end
        return false
    end

    local function get_known_file_ids(index, extra_file_id)
        local ids = {}
        local seen = {}
        local shardid = index ~= nil and shards.GetIndexShard(index) or "Master"

        local function add_known_file_id(file_id)
            file_id = get_file_id_for_shard(file_id, shardid)
            if is_known_file_id(file_id, shardid) then
                add_file_id(ids, seen, file_id)
            end
        end

        if extra_file_id ~= nil then
            add_known_file_id(extra_file_id)
        end
        if Settings ~= nil and Settings.world_index_file_id ~= nil then
            add_known_file_id(Settings.world_index_file_id)
        end

        local known_ids = is_master_shard_id(shardid) and
            WORLD_INDEX_KNOWN_FILE_IDS.Master or WORLD_INDEX_KNOWN_FILE_IDS.Caves
        for _, file_id in ipairs(known_ids) do
            add_file_id(ids, seen, file_id)
        end

        for file_id in pairs(registered_file_ids) do
            add_file_id(ids, seen, get_file_id_for_shard(file_id, shardid))
        end

        for _, manifest_file_id in ipairs(manifest.GetFileIDs(index)) do
            add_file_id(ids, seen, manifest_file_id)
        end

        return ids
    end

    local function get_home_state(state)
        return state ~= nil and (state.home or state.main) or nil
    end

    local function set_player_positions_for_session(state, session_id, player_positions)
        if state == nil then
            return
        end

        state.player_positions = players.MergePlayerPositions(state.player_positions, player_positions)
        local home = get_home_state(state)
        if home ~= nil and home.session_id == session_id then
            home.player_positions = players.MergePlayerPositions(home.player_positions, player_positions)
            if state.main ~= nil then
                state.main.player_positions = players.MergePlayerPositions(state.main.player_positions, player_positions)
            end
        end
    end

    local function ensure_home_aliases(state)
        if state ~= nil then
            state.file_id = normalize_file_id(state.file_id)
            if state.home == nil and state.main ~= nil then
                state.home = state.main
            elseif state.main == nil and state.home ~= nil then
                state.main = state.home
            end
            if state.home ~= nil and state.home.player_positions == nil then
                state.home.player_positions = players.GetPlayerPositions(state.home.player_sessions)
            end
            if state.main ~= nil and state.main.player_positions == nil then
                state.main.player_positions = players.GetPlayerPositions(state.main.player_sessions)
            end
        end
        return state
    end

    local function reserves_slot(state)
        ensure_home_aliases(state)
        local home = get_home_state(state)
        return state ~= nil and
            state.active == true and
            home ~= nil and
            home.session_id ~= nil and
            home.session_id ~= ""
    end

    local function matches_current_session(index, state)
        local session_id = index ~= nil and index.GetSession ~= nil and index:GetSession() or nil
        return session_id ~= nil and
            session_id ~= "" and
            state ~= nil and
            state.current_session_id == session_id
    end

    local function is_pending_generation(state)
        local home = get_home_state(state)
        return state ~= nil and
            state.active == true and
            home ~= nil and
            home.session_id ~= nil and
            home.session_id ~= "" and
            (type(state.pending_generation) == "table" or
            ((state.current_session_id == nil or state.current_session_id == "") and
            (state.current_preset ~= nil or state.current_target ~= nil)))
    end

    local function get_read_priority(index, state, file_id)
        if state == nil or state.active ~= true then
            return nil
        end

        local priority = is_pending_generation(state) and 10 or 0
        local transition_file_id = Settings ~= nil and Settings.world_index_file_id or nil
        if transition_file_id ~= nil and
            normalize_file_id(transition_file_id) == normalize_file_id(file_id) then
            priority = priority + 100
        end
        if matches_current_session(index, state) then
            priority = priority + 1000
        end
        return priority
    end

    local function read_named_sidecar(index, file_id, cb)
        return storage.ReadNamedSidecar(index, file_id, cb)
    end

    local function read_sidecar(index, cb, file_id)
        cb = cb or noop
        if file_id ~= nil then
            read_named_sidecar(index, file_id, function(state, _, valid)
                cb(state, valid ~= false)
            end)
            return
        end

        local ids = get_known_file_ids(index, index.world_index_state ~= nil and index.world_index_state.file_id or nil)
        local active_state = nil
        local active_priority = nil
        local return_recovery_state = nil
        local pending_player_state = nil
        local read_success = true
        local i = 1

        local function read_next()
            if i > #ids then
                cb(active_state or return_recovery_state or pending_player_state, read_success)
                return
            end

            local current_file_id = ids[i]
            i = i + 1
            read_named_sidecar(index, current_file_id, function(state, _, valid)
                if valid == false then
                    read_success = false
                    read_next()
                    return
                end
                if state ~= nil and state.active == true then
                    local priority = get_read_priority(index, state, current_file_id)
                    local candidate_is_newer = false
                    if active_state ~= nil and priority == active_priority then
                        local selected = recovery.ChooseCandidate({
                            { file_id = current_file_id, state = state },
                            { file_id = active_state.file_id, state = active_state },
                        }, transaction)
                        candidate_is_newer = selected ~= nil and selected.file_id == current_file_id
                    end
                    if active_state == nil or priority > active_priority or
                        priority == active_priority and candidate_is_newer then
                        active_state = state
                        active_priority = priority
                        active_state.file_id = normalize_file_id(active_state.file_id or current_file_id)
                    end
                elseif state ~= nil and type(state.return_pending) == "table" and
                    type(state.parent_world_index_state) == "table" then
                    return_recovery_state = return_recovery_state or state
                elseif state ~= nil and type(state.pending_player_sessions) == "table" and
                    #state.pending_player_sessions > 0 and
                    state.pending_player_session_id == index:GetSession() then
                    pending_player_state = pending_player_state or state
                end
                read_next()
            end)
        end

        read_next()
    end

    local function write_sidecar(index, data, cb, file_id)
        return storage.WriteSidecar(index, data, cb, file_id)
    end

    local function get_state_map(index)
        index.world_index_states = index.world_index_states or {}
        return index.world_index_states
    end

    local function choose_state(states, predicate)
        local candidates = {}
        for file_id, state in pairs(states or {}) do
            if predicate == nil or predicate(state) then
                candidates[#candidates + 1] = { file_id = file_id, state = state }
            end
        end
        local selected = recovery.ChooseCandidate(candidates, transaction)
        return selected ~= nil and selected.state or nil
    end

    local function set_state(index, state, file_id)
        if index == nil then
            return
        end

        file_id = normalize_file_id(file_id or (state ~= nil and state.file_id or nil))
        local states = get_state_map(index)
        if state ~= nil then
            state.file_id = file_id
            states[file_id] = ensure_home_aliases(state)
            if index.world_index_state == nil or state.active == true or
                normalize_file_id(index.world_index_state.file_id) == file_id then
                index.world_index_state = states[file_id]
            end
        else
            states[file_id] = nil
            if index.world_index_state ~= nil and
                normalize_file_id(index.world_index_state.file_id) == file_id then
                index.world_index_state = choose_state(states, function(stored_state)
                    return stored_state.active == true
                end)
            end
        end
    end

    local function find_state(index, predicate, choose_newest)
        local current = ensure_home_aliases(index ~= nil and index.world_index_state or nil)
        if predicate(current) then
            return current
        end

        local states = index ~= nil and index.world_index_states or nil
        if states == nil then
            return nil
        end
        if choose_newest then
            local selected = choose_state(states, predicate)
            if selected ~= nil then
                index.world_index_state = selected
                return ensure_home_aliases(selected)
            end
            return nil
        end
        for _, state in pairs(states) do
            if predicate(state) then
                index.world_index_state = state
                return ensure_home_aliases(state)
            end
        end
    end

    local function get_state(index, file_id)
        if index == nil then
            return nil
        end

        if file_id ~= nil then
            file_id = normalize_file_id(file_id)
            local states = index.world_index_states
            if states ~= nil and states[file_id] ~= nil then
                return ensure_home_aliases(states[file_id])
            end
            if index.world_index_state ~= nil and
                normalize_file_id(index.world_index_state.file_id) == file_id then
                return ensure_home_aliases(index.world_index_state)
            end
            return nil
        end

        local matching = find_state(index, function(state)
            return state ~= nil and state.active == true and matches_current_session(index, state)
        end, true)
        if matching ~= nil then
            return matching
        end

        local current = ensure_home_aliases(index.world_index_state)
        if current ~= nil and current.active == true then
            return current
        end

        local active = find_state(index, function(state)
            return state ~= nil and state.active == true
        end, true)
        return active or current
    end

    local function get_current_state(index)
        return find_state(index, function(state)
            return state ~= nil and state.active == true and matches_current_session(index, state)
        end, true)
    end

    local function is_transition_restart()
        return Settings ~= nil and
            Settings.reset_action == RESET_ACTION.LOAD_SLOT and
            Settings.world_index_transition ~= nil
    end

    local function get_pending_transition_state(index)
        if not is_transition_restart() then
            return nil
        end

        local file_id = Settings ~= nil and Settings.world_index_file_id or nil
        if file_id ~= nil then
            local state = get_state(index, file_id)
            return is_pending_generation(state) and state or nil
        end

        return find_state(index, function(state)
            return is_pending_generation(state)
        end, false)
    end

    local function get_pending_state(index)
        return find_state(index, function(state)
            return is_pending_generation(state)
        end, false)
    end

    local function get_delete_state(index)
        return get_current_state(index) or get_pending_transition_state(index) or get_pending_state(index)
    end

    local function clear_sidecar(index, cb, file_id)
        local state = get_state(index)
        file_id = normalize_file_id(file_id or (state ~= nil and state.file_id or nil))
        write_sidecar(index, nil, function(success)
            if success then
                set_state(index, nil, file_id)
            end
            (cb or noop)(success)
        end, file_id)
    end

    local function clear_all_sidecars(index, cb)
        cb = cb or noop
        manifest.Read(index, function()
            local ids = get_known_file_ids(index, index.world_index_state ~= nil and index.world_index_state.file_id or nil)
            local i = 1

            local function clear_next(success)
                if success == false then
                    cb(false)
                    return
                end
                if i > #ids then
                    index.world_index_states = {}
                    index.world_index_state = nil
                    cb(true)
                    return
                end

                local file_id = ids[i]
                i = i + 1
                write_sidecar(index, nil, clear_next, file_id)
            end

            clear_next()
        end)
    end

    local function read_named_sidecar_in_slot(slot, file_id, cb)
        cb = cb or noop
        if slot == nil or TheSim == nil then
            cb(nil, false)
            return
        end

        file_id = normalize_file_id(file_id)
        local filename = "shardindex_"..file_id
        TheSim:GetPersistentStringInClusterSlot(slot, "Master", filename, function(load_success, str)
            if load_success and str ~= nil and #str > 0 then
                local success, data = RunInSandboxSafe(str)
                if success and type(data) == "table" then
                    data.file_id = normalize_file_id(data.file_id or file_id)
                    cb(ensure_home_aliases(data), true, true)
                    return
                end
                cb(nil, true, false)
                return
            end
            cb(nil, false, true)
        end)
    end

    local function read_sidecar_in_slot(slot, cb)
        cb = cb or noop
        manifest.ReadBySlot(slot, "Master", function(data)
            local holder = { world_index_manifest = data }
            local ids = get_known_file_ids(holder)
            local candidates = {}
            local read_success = true
            local i = 1

            local function read_next()
                if i > #ids then
                    local selected = recovery.ChooseCandidate(candidates, transaction)
                    cb(selected ~= nil and selected.state or nil, read_success)
                    return
                end

                local file_id = ids[i]
                i = i + 1
                read_named_sidecar_in_slot(slot, file_id, function(state, _, valid)
                    if valid == false then
                        read_success = false
                        read_next()
                        return
                    end
                    if reserves_slot(state) then
                        candidates[#candidates + 1] = { file_id = file_id, state = state }
                    end
                    read_next()
                end)
            end

            read_next()
        end)
    end

    local function read_active_sidecar(slot, cb)
        cb = cb or noop
        read_sidecar_in_slot(slot, function(state, success)
            cb(reserves_slot(state) and state or nil, success)
        end)
    end

    local function find_sidecar(index, file_id, match, cb)
        local function check(state)
            local value = state ~= nil and match(state) or nil
            if value ~= nil then
                cb(state, value)
                return true
            end
            return false
        end

        if file_id ~= nil then
            local state = get_state(index, file_id)
            if check(state) then
                return
            end
            read_named_sidecar(index, file_id, function(loaded_state, _, valid)
                if valid == false then
                    cb(nil, nil, false)
                    return
                end
                if not check(loaded_state) then
                    cb(nil, nil, true)
                end
            end)
            return
        end

        local ids = get_known_file_ids(index)
        local i = 1
        local function read_next()
            if i > #ids then
                cb(nil, nil, true)
                return
            end
            local current_file_id = ids[i]
            i = i + 1
            read_named_sidecar(index, current_file_id, function(state, _, valid)
                if valid == false then
                    cb(nil, nil, false)
                    return
                end
                if not check(state) then
                    read_next()
                end
            end)
        end
        read_next()
    end

    return
    {
        NormalizeFileID = normalize_file_id,
        RegisterFileID = register_file_id,
        GetFileIDForShard = get_file_id_for_shard,
        IsKnownFileID = is_known_file_id,
        GetKnownFileIDs = get_known_file_ids,
        GetHomeState = get_home_state,
        SetPlayerPositionsForSession = set_player_positions_for_session,
        EnsureHomeAliases = ensure_home_aliases,
        ReservesSlot = reserves_slot,
        MatchesCurrentSession = matches_current_session,
        IsPendingGeneration = is_pending_generation,
        ReadNamedSidecar = read_named_sidecar,
        ReadSidecar = read_sidecar,
        WriteSidecar = write_sidecar,
        SetState = set_state,
        GetState = get_state,
        GetCurrentState = get_current_state,
        GetPendingTransitionState = get_pending_transition_state,
        GetPendingState = get_pending_state,
        GetDeleteState = get_delete_state,
        ClearSidecar = clear_sidecar,
        ClearAllSidecars = clear_all_sidecars,
        ReadActiveSidecar = read_active_sidecar,
        FindSidecar = find_sidecar,
    }
