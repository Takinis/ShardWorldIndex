local shards = require("modules/shards")
local get_index_shard = shards.GetIndexShard
local get_runtime_shard_id = shards.GetRuntimeShardId

    local function save_players()
        if AllPlayers ~= nil then
            for _, player in ipairs(AllPlayers) do
                if player.userid ~= nil and #player.userid > 0 then
                    SerializeUserSession(player)
                end
            end
        elseif ThePlayer ~= nil then
            SerializeUserSession(ThePlayer)
        end
    end

    local function get_player_session_metadata(player)
        return DataDumper({ character = player.prefab }, nil, BRANCH ~= "dev")
    end

    local function get_current_session_id()
        local session_id = TheWorld ~= nil and TheWorld.meta ~= nil and
            TheWorld.meta.session_identifier or nil
        return type(session_id) == "string" and session_id ~= "" and session_id or nil
    end

    local function get_character_only_record(playerinfo)
        local skinner = type(playerinfo.data) == "table" and playerinfo.data.skinner or nil
        return
        {
            prefab = playerinfo.prefab,
            skinname = playerinfo.skinname,
            skin_id = playerinfo.skin_id,
            alt_skin_ids = deepcopy_safe(playerinfo.alt_skin_ids),
            data = skinner ~= nil and
            {
                skinner =
                {
                    skin_name = skinner.skin_name,
                    skin_mode = skinner.skin_mode,
                    clothing =
                    {
                        body = skinner.clothing ~= nil and skinner.clothing.body or "",
                        hand = skinner.clothing ~= nil and skinner.clothing.hand or "",
                        legs = skinner.clothing ~= nil and skinner.clothing.legs or "",
                        feet = skinner.clothing ~= nil and skinner.clothing.feet or "",
                    },
                },
            } or nil,
        }
    end

    local function get_character_only_sessions(sessions)
        if sessions == nil then
            return nil
        end

        local stripped = {}
        for _, session in ipairs(sessions) do
            if session.data ~= nil then
                local success, playerinfo = RunInSandboxSafe(session.data)
                if success and type(playerinfo) == "table" and playerinfo.prefab ~= nil then
                    stripped[#stripped + 1] =
                    {
                        userid = session.userid,
                        prefab = session.prefab or playerinfo.prefab,
                        data = DataDumper(get_character_only_record(playerinfo), nil, BRANCH ~= "dev"),
                        metadata = session.metadata,
                        mode = "character_only",
                        origin_session_id = session.origin_session_id,
                    }
                end
            end
        end

        return #stripped > 0 and stripped or nil
    end

    local function collect_player_sessions()
        if AllPlayers == nil or not TheNet:GetIsServer() then
            return nil
        end

        save_players()

        local sessions = {}
        for _, player in ipairs(AllPlayers) do
            if player.userid ~= nil and #player.userid > 0 and player.prefab ~= nil then
                sessions[#sessions + 1] =
                {
                    userid = player.userid,
                    prefab = player.prefab,
                    data = DataDumper(player:GetSaveRecord(), nil, BRANCH ~= "dev"),
                    metadata = get_player_session_metadata(player),
                    mode = "full",
                    origin_session_id = get_current_session_id(),
                }
            end
        end

        return #sessions > 0 and sessions or nil
    end

    local function sessions_to_userid_map(sessions)
        local map = {}
        for _, session in ipairs(sessions or {}) do
            if session.userid ~= nil and session.userid ~= "" then
                map[session.userid] = true
            end
        end
        return map
    end

    local function session_list_to_map(sessions)
        local map = {}
        for _, session in ipairs(sessions or {}) do
            if session.userid ~= nil and session.userid ~= "" then
                map[session.userid] = session
            end
        end
        return map
    end

    local function merge_session_lists(primary, fallback)
        local merged = {}
        local seen = {}

        for _, session in ipairs(primary or {}) do
            if session.userid ~= nil and session.userid ~= "" then
                merged[#merged + 1] = session
                seen[session.userid] = true
            end
        end

        for _, session in ipairs(fallback or {}) do
            if session.userid ~= nil and session.userid ~= "" and not seen[session.userid] then
                merged[#merged + 1] = session
                seen[session.userid] = true
            end
        end

        return #merged > 0 and merged or nil
    end

    local function get_player_save_session(player)
        if player == nil or player.userid == nil or player.userid == "" or player.prefab == nil then
            return nil
        end

        return
        {
            userid = player.userid,
            prefab = player.prefab,
            data = DataDumper(player:GetSaveRecord(), nil, BRANCH ~= "dev"),
            metadata = get_player_session_metadata(player),
            mode = "full",
            origin_session_id = get_current_session_id(),
        }
    end

    local function normalize_position(pos)
        if type(pos) ~= "table" then
            return nil
        end

        local x = tonumber(pos.x or pos[1])
        local y = tonumber(pos.y or pos[2])
        local z = tonumber(pos.z or pos[3])
        if x == nil or z == nil then
            return nil
        end

        return
        {
            x = x,
            y = y or 0,
            z = z,
            puid = pos.puid,
            rx = tonumber(pos.rx),
            ry = tonumber(pos.ry),
            rz = tonumber(pos.rz),
        }
    end

    local function get_player_positions(sessions)
        local positions = {}
        for _, session in ipairs(sessions or {}) do
            if session.userid ~= nil and session.userid ~= "" and type(session.data) == "string" then
                local success, data = RunInSandboxSafe(session.data)
                local position = success and normalize_position(data) or nil
                if position ~= nil then
                    positions[session.userid] = position
                end
            end
        end
        return next(positions) ~= nil and positions or nil
    end

    local function merge_player_positions(existing, updates)
        local positions = deepcopy_safe(existing) or {}
        for userid, position in pairs(updates or {}) do
            positions[userid] = deepcopy_safe(position)
        end
        return next(positions) ~= nil and positions or nil
    end

    local function get_spawn_position_from_savedata(savedata)
        if type(savedata) ~= "string" or #savedata <= 0 then
            return { x = 0, y = 0, z = 0 }
        end

        local success, world = RunInSandboxSafe(savedata)
        if not success or world == nil or world.ents == nil then
            return { x = 0, y = 0, z = 0 }
        end

        for _, prefab in ipairs({
            "spawnpoint_master",
            "spawnpoint_multiplayer",
            "multiplayer_portal",
            "quagmire_portal",
            "lavaarena_portal",
            "spawnpoint",
        }) do
            local ents = world.ents[prefab]
            if ents ~= nil and ents[1] ~= nil then
                return
                {
                    x = ents[1].x or 0,
                    y = ents[1].y or 0,
                    z = ents[1].z or 0,
                }
            end
        end

        return { x = 0, y = 0, z = 0 }
    end

    local function get_prefab_position_from_savedata(savedata, prefab)
        if type(savedata) ~= "string" or #savedata <= 0 or
            type(prefab) ~= "string" or prefab == "" then
            return nil
        end

        local success, world = RunInSandboxSafe(savedata)
        local ents = success and world ~= nil and world.ents ~= nil and world.ents[prefab] or nil
        if ents ~= nil and ents[1] ~= nil then
            return
            {
                x = ents[1].x or 0,
                y = ents[1].y or 0,
                z = ents[1].z or 0,
            }
        end
    end

    local function read_world_session_raw(index, session_id, cb)
        cb = cb or function() end
        if session_id == nil or session_id == "" then
            cb(nil)
            return
        end

        local server = index:GetServerData()
        if not TheNet:IsDedicated() and server ~= nil and not server.use_legacy_session_path then
            local slot = index:GetSlot()
            local shard = get_index_shard(index)
            local file = TheNet:GetWorldSessionFileInClusterSlot(slot, shard, session_id)
            if file ~= nil then
                TheSim:GetPersistentStringInClusterSlot(slot, shard, file, function(load_success, str)
                    cb(load_success and type(str) == "string" and #str > 0 and str or nil)
                end)
                return
            end
        else
            local file = TheNet:GetWorldSessionFile(session_id)
            if file ~= nil then
                TheSim:GetPersistentString(file, function(load_success, str)
                    cb(load_success and type(str) == "string" and #str > 0 and str or nil)
                end)
                return
            end
        end

        cb(nil)
    end

    local function world_session_exists(index, session_id, cb)
        read_world_session_raw(index, session_id, function(savedata)
            (cb or function() end)(savedata ~= nil)
        end)
    end

    local function build_target_player_sessions(sessions, build_data)
        local migrated = {}
        for i, session in ipairs(sessions or {}) do
            if session.userid ~= nil and session.userid ~= "" and session.data ~= nil then
                local target_session = deepcopy_safe(session)
                target_session.data = build_data(session, i)
                migrated[#migrated + 1] = target_session
            end
        end
        return migrated
    end

    local function move_player_record_to_spawn(data, spawn, spawn_index, origin_session_id, destination_session_id, shard_index)
        if type(data) ~= "table" then
            return nil
        end

        local offset = (spawn_index or 1) - 1
        local radius = offset > 0 and math.min(2 + offset, 8) or 0
        local angle = offset * 2.399963229728653
        data.x = (spawn.x or 0) + math.cos(angle) * radius
        data.y = spawn.y
        data.z = (spawn.z or 0) + math.sin(angle) * radius
        data.puid = spawn.puid
        data.rx = spawn.rx
        data.ry = spawn.ry
        data.rz = spawn.rz

        if type(data.data) == "table" then
            local migration = type(data.data.migration) == "table" and data.data.migration or nil
            origin_session_id = origin_session_id or (migration ~= nil and migration.sessionid or nil)
            if type(origin_session_id) == "string" and origin_session_id ~= "" and
                origin_session_id ~= destination_session_id then
                data.data.migration =
                {
                    worldid = get_runtime_shard_id(shard_index),
                    sessionid = origin_session_id,
                }
            else
                data.data.migration = nil
            end
        end
        return data
    end

    local function build_migrated_user_session_data(session, spawn, spawn_index, destination_session_id, shard_index)
        local success, data = RunInSandboxSafe(session.data or "")
        if not success or type(data) ~= "table" or data.prefab == nil then
            return session.data
        end

        move_player_record_to_spawn(
            data,
            spawn,
            spawn_index,
            session.origin_session_id,
            destination_session_id,
            shard_index
        )
        return DataDumper(data, nil, BRANCH ~= "dev")
    end

    local function inject_player_sessions_into_world(index, sessions, session_identifier, savedata, cb)
        cb = cb or function() end
        if sessions == nil or #sessions <= 0 or session_identifier == nil or
            session_identifier == "" or not TheNet:GetIsServer() then
            cb(true)
            return
        end

        local spawn = get_spawn_position_from_savedata(savedata)
        local migrated = build_target_player_sessions(sessions, function(player_session, i)
            return build_migrated_user_session_data(player_session, spawn, i, session_identifier, index)
        end)
        cb(true, migrated)
    end

    local function inject_player_sessions_into_existing_world(index, session_id, sessions, cb, spawn_override, player_positions, spawn_prefab)
        cb = cb or function() end
        if session_id == nil or session_id == "" or sessions == nil or #sessions <= 0 or
            not TheNet:GetIsServer() then
            cb(true)
            return
        end

        read_world_session_raw(index, session_id, function(savedata)
            if savedata == nil then
                cb(false)
                return
            end
            local spawn = get_prefab_position_from_savedata(savedata, spawn_prefab) or
                normalize_position(spawn_override) or get_spawn_position_from_savedata(savedata)
            local migrated = build_target_player_sessions(sessions, function(player_session, i)
                local saved_position = player_positions ~= nil and
                    normalize_position(player_positions[player_session.userid]) or nil
                return build_migrated_user_session_data(
                    player_session,
                    saved_position or spawn,
                    saved_position ~= nil and 1 or i,
                    session_id,
                    index
                )
            end)
            cb(true, migrated)
        end)
    end

    local function get_pending_player_session(session_id, userid)
        local index = ShardGameIndex
        local state = index ~= nil and index.worldindex ~= nil and get_world_index_state(index) or nil
        if state == nil or state.pending_player_session_id ~= session_id or
            type(state.pending_player_sessions) ~= "table" then
            return nil, nil, nil
        end

        for _, player_session in ipairs(state.pending_player_sessions) do
            if player_session.userid == userid and player_session.data ~= nil then
                local success, data = RunInSandboxSafe(player_session.data)
                if success and type(data) == "table" and data.prefab ~= nil then
                    return data, state, index, player_session
                end
                print("[Shard World Index] Failed to parse pending player session for "..tostring(userid)..".")
                return nil, state, index
            end
        end
        return nil, state, index
    end

    local pending_state_save_index
    local pending_state_save_state
    local pending_state_save_running = false
    local pending_state_save_dirty = false

    local function request_pending_player_state_save(index, state)
        pending_state_save_index = index
        pending_state_save_state = state
        pending_state_save_dirty = true
        if pending_state_save_running then
            return
        end

        local function save_latest()
            local pending_index = pending_state_save_index
            local save_state = pending_state_save_state
            pending_state_save_dirty = false
            pending_state_save_running = true
            write_world_index_sidecar(pending_index, save_state, function(saved)
                pending_state_save_running = false
                if not saved then
                    print("[Shard World Index] Failed to save pending player session state.")
                end
                if pending_state_save_dirty then
                    save_latest()
                end
            end, save_state.file_id)
        end
        save_latest()
    end

    local function consume_pending_player_session(index, state, userid)
        if index == nil or state == nil or type(state.pending_player_sessions) ~= "table" then
            return
        end

        for i = #state.pending_player_sessions, 1, -1 do
            if state.pending_player_sessions[i].userid == userid then
                table.remove(state.pending_player_sessions, i)
            end
        end
        if #state.pending_player_sessions == 0 then
            state.pending_player_sessions = nil
            state.pending_player_session_id = nil
        end
        state.updated_at = os.time()
        request_pending_player_state_save(index, state)
    end

    local function spawn_pending_snapshot_player(data, userid)
        if resolve_save_record_position == nil then
            print("[Shard World Index] Cannot resolve saved player position.")
            return nil
        end

        local player = SpawnPrefab(data.prefab)
        if player == nil then
            return nil
        end

        player.userid = userid
        player.is_snapshot_user_session = true
        player:SetPersistData(data.data or {})
        local x, y, z, platform = resolve_save_record_position(data)
        player.Physics:Teleport(x, y, z)
        if platform ~= nil then
            player.components.walkableplatformplayer:TestForPlatform()
            player._snapshot_platform = platform
        end
        return player.player_classified ~= nil and player.player_classified.entity or nil
    end

    local api =
    {
        SavePlayers = save_players,
        CollectPlayerSessions = collect_player_sessions,
        GetCharacterOnlySessions = get_character_only_sessions,
        SessionsToUseridMap = sessions_to_userid_map,
        SessionListToMap = session_list_to_map,
        MergeSessionLists = merge_session_lists,
        GetPlayerSaveSession = get_player_save_session,
        GetPlayerPositions = get_player_positions,
        MergePlayerPositions = merge_player_positions,
        InjectPlayerSessionsIntoWorld = inject_player_sessions_into_world,
        InjectPlayerSessionsIntoExistingWorld = inject_player_sessions_into_existing_world,
        WorldSessionExists = world_session_exists,
        ReadWorldSessionRaw = read_world_session_raw,
        GetCurrentSessionID = get_current_session_id,
    }

    local original_restore_snapshot = RestoreSnapshotUserSession
    local original_resume_existing = ResumeExistingUserSession
    function api.InstallSnapshotHooks()
        function RestoreSnapshotUserSession(session_id, userid)
            local data, state, _, pending_session = get_pending_player_session(session_id, userid)
            if data == nil then
                return original_restore_snapshot(session_id, userid)
            end

            local source_file = pending_session ~= nil and
                type(pending_session.origin_session_id) == "string" and
                pending_session.origin_session_id ~= "" and
                TheNet:GetUserSessionFile(pending_session.origin_session_id, userid) or nil
            if source_file == nil then
                local home = get_world_index_home_state(state)
                source_file = home ~= nil and type(home.session_id) == "string" and
                    home.session_id ~= "" and TheNet:GetUserSessionFile(home.session_id, userid) or nil
            end
            source_file = source_file or TheNet:GetUserSessionFile(session_id, userid)
            source_file = source_file or TheNet:GetWorldSessionFile(session_id)
            if source_file == nil then
                return spawn_pending_snapshot_player(data, userid)
            end
            TheNet:DeserializeUserSession(source_file, function()
                return spawn_pending_snapshot_player(data, userid)
            end)
        end

        function ResumeExistingUserSession(data, guid)
            local player = Ents[guid]
            local userid = player ~= nil and player.userid or nil
            local pending, state, index = get_pending_player_session(
                TheWorld ~= nil and TheWorld.meta ~= nil and TheWorld.meta.session_identifier or nil,
                userid
            )
            local result = original_resume_existing(pending or data, guid)
            if pending ~= nil and player ~= nil then
                consume_pending_player_session(index, state, userid)
            end
            return result
        end
    end

    return api
