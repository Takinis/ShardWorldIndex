local players = require("modules/players")
local shards = require("modules/shards")
local world = require("modules/world")
local normalize_world_type = world.NormalizeWorldType
local build_generated_level_from_target = world.BuildGeneratedLevelFromTarget
local get_level_for_shard = world.GetLevelForShard
local resolve_level_world_type = world.ResolveLevelWorldType
local get_worldgen_preset_id = world.GetWorldGenPresetID
local get_index_shard = shards.GetIndexShard
local get_file_id_for_shard = get_world_index_file_id_for_shard
local normalize_file_id = normalize_world_index_file_id
local get_player_positions = players.GetPlayerPositions

    local function normalize_world_index_target(target)
        if target == nil then
            return nil
        end

        if type(target) ~= "table" then
            return { type = "generated", level = target }
        end

        local target_type = target.type or target.kind
        if target_type == "existing" or (target.session_id ~= nil and target_type ~= "generated") then
            local out = deepcopy_safe(target) or {}
            out.type = "existing"
            return out
        end

        local out = deepcopy_safe(target) or {}
        out.type = "generated"
        out.world_type = normalize_world_type(out.world_type or out.location or out.dlc or out.mode)

        if out.level == nil then
            if out.current_preset ~= nil then
                out.level = out.current_preset
            elseif out.preset ~= nil then
                out.level = out.preset
            elseif out.id ~= nil or out.worldgen_preset ~= nil or out.settings_preset ~= nil or
                out.overrides ~= nil or out.level_options ~= nil or out.world_type ~= nil then
                out.level = build_generated_level_from_target(out)
            else
                out.level = target
            end
        end

        return out
    end

    local function normalize_world_index_existing_target(index, target)
        target = normalize_world_index_target(target)
        if target == nil or target.type ~= "existing" or target.session_id == nil or target.session_id == "" then
            return nil
        end

        return
        {
            type = "existing",
            session_id = target.session_id,
            worldgenoverride = target.worldgenoverride,
            world = deepcopy_safe(target.world) or deepcopy_safe(index.world) or { options = {} },
            server = deepcopy_safe(target.server) or deepcopy_safe(index.server) or {},
            enabled_mods = deepcopy_safe(target.enabled_mods) or deepcopy_safe(index.enabled_mods) or {},
            return_position = target.return_position,
            player_sessions = deepcopy_safe(target.player_sessions),
            player_positions = deepcopy_safe(target.player_positions) or
                get_player_positions(target.player_sessions),
            cleanup_on_return = target.cleanup_on_return == true,
            world_type = normalize_world_type(target.world_type or target.location or target.dlc or target.mode),
            current_preset = get_worldgen_preset_id(target.current_preset or target.preset),
            id = target.id,
        }
    end

    local function get_world_index_generated_level(target, shardid)
        target = normalize_world_index_target(target)
        if target == nil or target.type == "existing" then
            return nil
        end
        return get_level_for_shard(target.level or target.current_preset or target, shardid)
    end

    local function get_world_index_target_for_shard(target, shardid)
        target = normalize_world_index_target(target)
        if target == nil or target.type == "existing" or is_master_shard_id(shardid) then
            return target
        end

        local level = get_world_index_generated_level(target, shardid)
        if level == nil then
            return target
        end

        target.level = level
        target.world_type = resolve_level_world_type(level)
        return target
    end

    local function get_world_index_preset_id(preset)
        if type(preset) == "table" then
            return preset.id or preset.worldgen_preset or preset.preset or preset.settings_preset or preset.world_type
        end
        return preset
    end

    local function get_world_index_target_id(target)
        target = normalize_world_index_target(target)
        if target == nil then
            return nil
        end
        if target.type == "existing" then
            return target.id or target.session_id
        end
        return get_world_index_preset_id(target.level) or
            get_world_index_preset_id(target.current_preset) or
            target.world_type
    end

    local function get_world_index_target_file_id(target, fallback, shardid)
        target = normalize_world_index_target(target)
        local file_id = fallback
        if target ~= nil then
            if target.file_id ~= nil then
                file_id = target.file_id
            elseif target.world_type ~= nil then
                file_id = target.world_type
            elseif target.type == "existing" then
                file_id = target.id or fallback
            else
                local level = target.level or target.current_preset
                if type(level) == "table" then
                    file_id = normalize_world_type(level.world_type or level.location or level.dlc or level.mode)
                end
                file_id = file_id or get_world_index_target_id(target) or fallback
            end
        end

        return get_file_id_for_shard(file_id, shardid)
    end

    local function get_world_index_target_from_opts(opts, state)
        opts = opts or {}
        return normalize_world_index_target(
            opts.target or opts.world or opts.level or opts.current_preset or state and state.current_target
        )
    end

    local function apply_pending_world_generation_state(state)
        local pending = type(state.pending_generation) == "table" and state.pending_generation or nil
        if pending == nil then
            return
        end
        pending = deepcopy_safe(pending) or pending

        state.reason = pending.reason or state.reason
        state.chapter = pending.chapter or state.chapter
        state.current_target = normalize_world_index_target(
            pending.target or pending.current_target or pending.current_preset or pending.level
        ) or state.current_target
        state.current_preset = get_world_index_preset_id(pending.current_preset) or
            get_world_index_preset_id(pending.level) or
            get_world_index_target_id(state.current_target) or
            state.current_preset
        state.current_session_id = nil
        state.player_sessions = pending.player_sessions
        state.cleanup_session_id = pending.cleanup_session_id
        state.reuse_existing = pending.reuse_existing ~= false
        state.generation_source_session_id = pending.generation_source_session_id or state.generation_source_session_id
        state.generation_recovery_state = deepcopy_safe(pending.generation_recovery_state) or
            state.generation_recovery_state
        if pending.file_id ~= nil then
            state.file_id = normalize_file_id(pending.file_id)
        end

        if type(pending.state) == "table" then
            for key, value in pairs(pending.state) do
                state[key] = value
            end
        end

        if type(pending.clear_fields) == "table" then
            for _, key in ipairs(pending.clear_fields) do
                state[key] = nil
            end
        end

        state.pending_generation = nil
        state.updated_at = os.time()
    end

    return
    {
        NormalizeTarget = normalize_world_index_target,
        NormalizeExistingTarget = normalize_world_index_existing_target,
        GetGeneratedLevel = get_world_index_generated_level,
        GetTargetForShard = get_world_index_target_for_shard,
        GetPresetID = get_world_index_preset_id,
        GetTargetID = get_world_index_target_id,
        GetTargetFileID = get_world_index_target_file_id,
        GetTargetFromOpts = get_world_index_target_from_opts,
        ApplyPendingGenerationState = apply_pending_world_generation_state,
    }
