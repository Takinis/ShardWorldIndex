local players = require("modules/players")
local session = require("modules/session")
local read_world_session_raw = players.ReadWorldSessionRaw
local write_worldgenoverride = write_worldgenoverride_str

local function delete_session(session_id, home_session_id)
    session.Delete(ShardGameIndex, session_id, home_session_id)
end

    local WORLD_TYPE_LOCATION =
    {
        forest = "forest",
        caves = "cave",
        cave = "cave",
        shipwrecked = "shipwrecked",
        sw = "shipwrecked",
        volcano = "volcano",
        porkland = "porkland",
        hamlet = "porkland",
    }
    local REGISTERED_WORLD_TYPES = {}
    local REGISTERED_WORLD_TYPE_ORDER = {}

    local DEFAULT_SECONDARY_LEVEL =
    {
        worldgen_preset = "DST_CAVE",
        settings_preset = "DST_CAVE",
        overrides =
        {
            world_size = "small",
        },
    }

    local DEFAULT_VOLCANO_LEVEL =
    {
        world_type = "volcano",
        location = "volcano",
    }

    local PORKLAND_SECONDARY_LEVEL =
    {
        world_type = "cave",
        location = "cave",
        worldgen_preset = "HAMLET_SECONDARY",
        settings_preset = "DST_CAVE",
        overrides =
        {
            task_set = "HAMLET_SECONDARY",
            start_location = "HamletSecondaryStart",
            world_size = "small",
            layout_mode = "LinkNodesByKeys",
            roads = "never",
            boons = "never",
            has_ocean = false,
            keep_disconnected_tiles = true,
            no_wormholes_to_disconnected_tiles = true,
            no_joining_islands = true,
        },
    }

    local function to_plain_options(value, seen)
        if type(value) ~= "table" then
            return value
        end
        seen = seen or {}
        if seen[value] ~= nil then
            return seen[value]
        end
        local out = {}
        seen[value] = out
        for k, v in pairs(value) do
            if type(v) ~= "function" and type(k) ~= "function" then
                out[to_plain_options(k, seen)] = to_plain_options(v, seen)
            end
        end
        return out
    end

    local function get_worldgen_preset_id(level)
        if type(level) == "string" then
            return level
        elseif type(level) == "table" then
            return level.worldgen_preset or level.preset or level.id
        end
    end

    local function get_settings_preset_id(level)
        if type(level) == "string" then
            return level
        elseif type(level) == "table" then
            local settings_preset = level.settings_preset
            if settings_preset == nil then
                settings_preset = level.preset or level.id
            end
            return settings_preset
        end
    end

    local function get_level_overrides(level)
        if type(level) == "table" then
            return level.overrides or
                (type(level.level_options) == "table" and level.level_options.overrides) or nil
        end
    end

    local function normalize_world_type(world_type)
        if world_type == nil then
            return nil
        end
        world_type = string.lower(tostring(world_type))
        return WORLD_TYPE_LOCATION[world_type] or world_type
    end

    local function register_world_type(world_type, aliases, tags)
        world_type = normalize_world_type(world_type)
        if world_type == nil or world_type == "" then
            return false
        end

        if REGISTERED_WORLD_TYPES[world_type] == nil then
            REGISTERED_WORLD_TYPES[world_type] = {}
            REGISTERED_WORLD_TYPE_ORDER[#REGISTERED_WORLD_TYPE_ORDER + 1] = world_type
        end

        local data = REGISTERED_WORLD_TYPES[world_type]
        if type(tags) == "string" then
            tags = { tags }
        end
        data.tags = type(tags) == "table" and deepcopy_safe(tags) or data.tags or {}
        WORLD_TYPE_LOCATION[world_type] = world_type

        if type(aliases) == "string" then
            aliases = { aliases }
        end
        for _, alias in ipairs(type(aliases) == "table" and aliases or {}) do
            if type(alias) == "string" and alias ~= "" then
                WORLD_TYPE_LOCATION[string.lower(alias)] = world_type
            end
        end
        return true
    end

    local function get_savedata_world_type(savedata)
        local data = get_savedata_table(savedata)
        local map = data ~= nil and data.map or nil
        return normalize_world_type(map ~= nil and map.prefab or nil)
    end

    local function read_world_session_world_type(index, session_id, cb)
        read_world_session_raw(index, session_id, function(savedata)
            cb(savedata ~= nil and get_savedata_world_type(savedata) or nil, savedata ~= nil)
        end)
    end

    local function build_generated_level_from_target(target)
        return
        {
            id = target.id,
            worldgen_preset = target.worldgen_preset,
            settings_preset = target.settings_preset,
            preset = target.preset,
            current_preset = target.current_preset,
            world_type = target.world_type,
            location = target.location or target.world_type,
            dlc = target.dlc,
            mode = target.mode,
            overrides = deepcopy_safe(target.overrides),
            level_options = deepcopy_safe(target.level_options),
            master = deepcopy_safe(target.master),
            secondary = deepcopy_safe(target.secondary),
            cave = deepcopy_safe(target.cave),
            caves = deepcopy_safe(target.caves),
            placeholder = deepcopy_safe(target.placeholder),
            shards = deepcopy_safe(target.shards),
        }
    end

    local function is_master_shard_id(shardid)
        return shardid == nil or shardid == "" or shardid == SHARDID.MASTER or shardid == "Master"
    end

    local function get_level_for_shard(level, shardid)
        if is_master_shard_id(shardid) then
            if type(level) == "table" and level.master ~= nil then
                return level.master
            end
            return level
        end

        if type(level) == "table" then
            local shard_levels = level.shards
            if type(shard_levels) == "table" then
                return shard_levels[shardid] or shard_levels.Caves or shard_levels.caves or
                    shard_levels.secondary or shard_levels.default
            end
            local secondary_level = level.secondary or level.cave or level.caves or level.placeholder
            if secondary_level ~= nil then
                return secondary_level
            end

            local world_type = normalize_world_type(level.world_type or level.location or level.dlc or level.mode)
            if world_type == "shipwrecked" then
                return DEFAULT_VOLCANO_LEVEL
            elseif world_type == "porkland" then
                return PORKLAND_SECONDARY_LEVEL
            elseif world_type == "cave" or world_type == "volcano" then
                return level
            end
        end

        return DEFAULT_SECONDARY_LEVEL
    end

    local function find_level_data_by_id(levels, id)
        if id == nil then
            return nil
        end

        if levels.GetDataForLevelID ~= nil then
            local data = levels.GetDataForLevelID(id)
            if data ~= nil then
                return data
            end
        end

        if levels.GetDataForWorldGenID ~= nil then
            local data = levels.GetDataForWorldGenID(id)
            if data ~= nil then
                return data
            end
        end

        if levels.GetDataForSettingsID ~= nil then
            local data = levels.GetDataForSettingsID(id)
            if data ~= nil then
                return data
            end
        end

        local level_lists =
        {
            levels.story_levels,
            levels.sandbox_levels,
            levels.custom_levels,
            levels.cave_levels,
            levels.shipwrecked_levels,
            levels.volcano_levels,
            levels.porkland_levels,
        }

        for _, level_list in ipairs(level_lists) do
            if level_list ~= nil then
                for _, level_data in ipairs(level_list) do
                    if level_data.id == id then
                        return level_data
                    end
                end
            end
        end
    end

    local function find_default_level_data_by_location(levels, location)
        location = normalize_world_type(location)
        if location == nil then
            return nil
        end

        if levels.GetDefaultLevelData ~= nil then
            local data = levels.GetDefaultLevelData(LEVELTYPE.SURVIVAL, location)
            if data ~= nil then
                return data
            end

            for _, leveltype in pairs(LEVELTYPE) do
                if leveltype ~= LEVELTYPE.SURVIVAL then
                    data = levels.GetDefaultLevelData(leveltype, location)
                    if data ~= nil then
                        return data
                    end
                end
            end
        end

        local level_lists =
        {
            levels.sandbox_levels,
            levels.story_levels,
            levels.custom_levels,
            levels.cave_levels,
            levels.shipwrecked_levels,
            levels.volcano_levels,
            levels.porkland_levels,
        }

        for _, level_list in ipairs(level_lists) do
            if level_list ~= nil then
                for _, level_data in ipairs(level_list) do
                    if normalize_world_type(level_data.location) == location then
                        return level_data
                    end
                end
            end
        end
    end

    local function get_level_world_type(level)
        return type(level) == "table" and
            normalize_world_type(level.world_type or level.location or level.dlc or level.mode) or nil
    end

    local function resolve_level_world_type(level)
        local world_type = get_level_world_type(level)
        if world_type ~= nil then
            return world_type
        end

        local preset_id = get_worldgen_preset_id(level)
        if preset_id == nil then
            return nil
        end

        return get_level_world_type(find_level_data_by_id(require("map/levels"), preset_id))
    end

    local function get_stored_world_type(stored_world)
        if type(stored_world) ~= "table" then
            return nil
        end

        local world_type = normalize_world_type(stored_world.world_type)
        if world_type ~= nil then
            return world_type
        end

        local world = stored_world.world
        world_type = resolve_level_world_type(type(world) == "table" and world.options or nil)
        if world_type ~= nil then
            return world_type
        end

        return resolve_level_world_type(get_savedata_table(stored_world.worldgenoverride))
    end

    local function get_stored_world_preset(stored_world)
        if type(stored_world) ~= "table" then
            return nil
        end

        local preset = get_worldgen_preset_id(stored_world.current_preset)
        if preset ~= nil then
            return preset
        end

        local world = stored_world.world
        preset = get_worldgen_preset_id(type(world) == "table" and world.options or nil)
        if preset ~= nil then
            return preset
        end

        return get_worldgen_preset_id(get_savedata_table(stored_world.worldgenoverride))
    end

    local function get_runtime_world_type()
        if TheWorld == nil then
            return nil
        end

        for _, world_type in ipairs(REGISTERED_WORLD_TYPE_ORDER) do
            local data = REGISTERED_WORLD_TYPES[world_type]
            if TheWorld:HasTag(world_type) then
                return world_type
            end
            for _, tag in ipairs(data.tags or {}) do
                if TheWorld:HasTag(tag) then
                    return world_type
                end
            end
        end

        if TheWorld:HasTag("island") then
            return "shipwrecked"
        end

        for _, world_type in ipairs({ "porkland", "volcano", "shipwrecked", "cave", "forest" }) do
            if TheWorld:HasTag(world_type) then
                return world_type
            end
        end

        local prefab = normalize_world_type(TheWorld.prefab)
        for _, world_type in pairs(WORLD_TYPE_LOCATION) do
            if prefab == world_type then
                return world_type
            end
        end
    end

    local function worldgen_preset_exists(levels, preset)
        return type(preset) == "string" and preset ~= "" and
            levels.GetDataForWorldGenID ~= nil and levels.GetDataForWorldGenID(preset) ~= nil
    end

    local function settings_preset_exists(levels, preset)
        return preset == nil or preset == false or
            (type(preset) == "string" and preset ~= "" and
            levels.GetDataForSettingsID ~= nil and levels.GetDataForSettingsID(preset) ~= nil)
    end

    local function validate_world_index_generated_level(level)
        local Levels = require("map/levels")
        local world_type = get_level_world_type(level)
        local worldgen_preset = get_worldgen_preset_id(level)
        local settings_preset = get_settings_preset_id(level)

        if worldgen_preset == nil and world_type ~= nil then
            local level_data = find_default_level_data_by_location(Levels, world_type)
            if level_data == nil then
                return false, "no default preset exists for world type "..tostring(world_type)
            end
            worldgen_preset = get_worldgen_preset_id(level_data)
            settings_preset = settings_preset or get_settings_preset_id(level_data)
        end

        if worldgen_preset == nil or worldgen_preset == false then
            return false, "target worldgen preset is missing"
        end

        if not worldgen_preset_exists(Levels, worldgen_preset) then
            return false, "target worldgen preset does not exist: "..tostring(worldgen_preset)
        end

        if not settings_preset_exists(Levels, settings_preset) then
            return false, "target settings preset does not exist: "..tostring(settings_preset)
        end

        return true
    end

    local function get_default_level_data(levels)
        if levels.GetDefaultLevelData ~= nil and GetLevelType ~= nil and
            ShardGameIndex ~= nil and ShardGameIndex.GetGameMode ~= nil then
            local data = levels.GetDefaultLevelData(GetLevelType(ShardGameIndex:GetGameMode()), nil)
            if data ~= nil then
                return data
            end
        end

        return levels.story_levels ~= nil and levels.story_levels[1] or {}
    end

    local function resolve_level_options(level)
        local Levels = require("map/levels")
        local preset_id = get_worldgen_preset_id(level)
        local world_type = get_level_world_type(level)
        local data = type(level) == "table" and level.level_options or nil
        data = data or find_level_data_by_id(Levels, preset_id)
        data = data or find_default_level_data_by_location(Levels, world_type)
        if data == nil then
            data = get_default_level_data(Levels)
        end
        data = to_plain_options(data or {})

        local overrides = get_level_overrides(level)
        if overrides ~= nil then
            data.overrides = MergeMapsDeep(data.overrides or {}, to_plain_options(overrides))
        end

        return data
    end

    local function build_worldgenoverride_data(level)
        local data =
        {
            override_enabled = true,
        }

        local worldgen_preset = get_worldgen_preset_id(level)
        local settings_preset = get_settings_preset_id(level)
        local world_type = get_level_world_type(level)
        if worldgen_preset == nil and world_type ~= nil then
            local Levels = require("map/levels")
            local level_data = find_default_level_data_by_location(Levels, world_type)
            worldgen_preset = get_worldgen_preset_id(level_data)
            settings_preset = settings_preset or get_settings_preset_id(level_data)
        end
        if worldgen_preset ~= nil and worldgen_preset ~= false then
            data.worldgen_preset = worldgen_preset
        end
        if settings_preset ~= nil and settings_preset ~= false then
            data.settings_preset = settings_preset
        end

        local overrides = get_level_overrides(level)
        if overrides ~= nil then
            data.overrides = to_plain_options(overrides)
        end

        return data
    end

    local function build_level_worldgenoverride_raw(level)
        return DataDumper(build_worldgenoverride_data(level), nil, false).."\n"
    end

    local function write_level_worldgenoverride(index, level, cb)
        write_worldgenoverride(index, build_level_worldgenoverride_raw(level), cb)
    end

    local function switch_index_to_generated_world(index, level, keep_session)
        index.world = { options = resolve_level_options(level) }
        if not keep_session then
            index.session_id = nil
        end
        index:MarkDirty()
    end

    local function switch_index_to_existing_world(index, home)
        index.session_id = home.session_id
        index.world = deepcopy_safe(home.world) or { options = {} }
        index.server = deepcopy_safe(home.server) or {}
        index.enabled_mods = deepcopy_safe(home.enabled_mods) or {}
        index:MarkDirty()
    end

    local function switch_index_to_current_world(index, state)
        if state == nil or state.current_session_id == nil or state.current_session_id == "" then
            return false
        end

        local home = state.home or state.main or {}
        index.session_id = state.current_session_id
        index.world = deepcopy_safe(state.current_world) or { options = {} }
        index.server = deepcopy_safe(state.current_server) or deepcopy_safe(home.server) or {}
        index.enabled_mods = deepcopy_safe(state.current_enabled_mods) or
            deepcopy_safe(home.enabled_mods) or {}
        index:MarkDirty()
        return true
    end

    local function delete_session_if_not_home(session_id, home_session_id)
        if session_id ~= nil and session_id ~= "" and session_id ~= home_session_id then
            delete_session(session_id, home_session_id)
        end
    end

    return
    {
        ToPlainOptions = to_plain_options,
        GetWorldGenPresetID = get_worldgen_preset_id,
        GetSettingsPresetID = get_settings_preset_id,
        GetLevelOverrides = get_level_overrides,
        NormalizeWorldType = normalize_world_type,
        RegisterWorldType = register_world_type,
        GetSavedataWorldType = get_savedata_world_type,
        ReadWorldSessionWorldType = read_world_session_world_type,
        BuildGeneratedLevelFromTarget = build_generated_level_from_target,
        GetLevelForShard = get_level_for_shard,
        FindLevelDataByID = find_level_data_by_id,
        FindDefaultLevelDataByLocation = find_default_level_data_by_location,
        GetLevelWorldType = get_level_world_type,
        ResolveLevelWorldType = resolve_level_world_type,
        GetStoredWorldType = get_stored_world_type,
        GetStoredWorldPreset = get_stored_world_preset,
        GetRuntimeWorldType = get_runtime_world_type,
        ValidateWorldIndexGeneratedLevel = validate_world_index_generated_level,
        ResolveLevelOptions = resolve_level_options,
        BuildWorldgenOverrideData = build_worldgenoverride_data,
        BuildLevelWorldgenOverrideRaw = build_level_worldgenoverride_raw,
        WriteLevelWorldgenOverride = write_level_worldgenoverride,
        SwitchIndexToGeneratedWorld = switch_index_to_generated_world,
        SwitchIndexToExistingWorld = switch_index_to_existing_world,
        SwitchIndexToCurrentWorld = switch_index_to_current_world,
        DeleteSessionIfNotHome = delete_session_if_not_home,
    }
