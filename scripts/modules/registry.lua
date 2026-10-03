local normalize_id = normalize_world_index_file_id
    local worlds = {}
    local aliases = {}

    local level_fields =
    {
        "worldgen_preset",
        "settings_preset",
        "preset",
        "current_preset",
        "world_type",
        "location",
        "dlc",
        "mode",
        "overrides",
        "level_options",
    }

    local function normalize_world_id(id)
        if type(id) ~= "string" or id == "" then
            return nil
        end
        return normalize_id(id)
    end

    local function copy_level_fields(definition)
        local level = {}
        local has_value = false
        for _, field in ipairs(level_fields) do
            if definition[field] ~= nil then
                level[field] = deepcopy_safe(definition[field])
                has_value = true
            end
        end
        return has_value and level or nil
    end

    local function build_level(definition)
        local master = deepcopy_safe(definition.master)
        local secondary = deepcopy_safe(definition.secondary)
        local shards = deepcopy_safe(definition.shards)

        if master == nil then
            master = deepcopy_safe(definition.level) or copy_level_fields(definition)
        end

        if secondary ~= nil or shards ~= nil then
            if master == nil then
                return nil
            end
            return
            {
                master = master,
                secondary = secondary,
                shards = shards,
            }
        end

        return master
    end

    local function remove_aliases(world)
        if world == nil then
            return
        end
        for _, alias in ipairs(world.aliases or {}) do
            if aliases[alias] == world.id then
                aliases[alias] = nil
            end
        end
    end

    local function normalize_aliases(id, value)
        local out = { id }
        local seen = { [id] = true }
        if type(value) == "string" then
            value = { value }
        end
        for _, alias in ipairs(type(value) == "table" and value or {}) do
            alias = normalize_world_id(alias)
            if alias ~= nil and not seen[alias] then
                seen[alias] = true
                out[#out + 1] = alias
            end
        end
        return out
    end

    local function register(id, definition)
        if type(id) == "table" and definition == nil then
            definition = id
            id = definition.id
        end
        if type(definition) ~= "table" then
            return nil, "world definition must be a table"
        end

        id = normalize_world_id(id or definition.id)
        if id == nil then
            return nil, "world id is missing"
        end

        local level = build_level(definition)
        local target = deepcopy_safe(definition.target)
        if target == nil then
            if level == nil then
                return nil, "world level or worldgen preset is missing"
            end
            target =
            {
                type = "generated",
                id = id,
                level = level,
            }
        end

        local file_id = normalize_id(definition.file_id or target.file_id or id)
        local secondary_file_id = normalize_id(definition.secondary_file_id or file_id.."_secondary")
        local world =
        {
            id = id,
            label = definition.label or definition.name or id,
            aliases = normalize_aliases(id, definition.aliases),
            file_id = file_id,
            secondary_file_id = secondary_file_id,
            world_type = definition.world_type,
            world_type_aliases = deepcopy_safe(definition.world_type_aliases),
            world_tags = deepcopy_safe(definition.world_tags),
            kind = definition.kind or "world_index",
            reason = definition.reason,
            reuse_existing = definition.reuse_existing ~= false,
            force_players_to_master = definition.force_players_to_master ~= false,
            target = target,
        }
        world.target.type = world.target.type or "generated"
        world.target.id = world.target.id or id
        world.target.file_id = world.target.file_id or file_id
        world.target.world_type = world.target.world_type or definition.world_type

        for _, alias in ipairs(world.aliases) do
            local owner = aliases[alias]
            if owner ~= nil and owner ~= id then
                return nil, "world alias is already registered: "..alias
            end
        end

        remove_aliases(worlds[id])
        worlds[id] = world
        for _, alias in ipairs(world.aliases) do
            aliases[alias] = id
        end
        return deepcopy_safe(world)
    end

    local function resolve_id(id)
        id = normalize_world_id(id)
        return id ~= nil and aliases[id] or nil
    end

    local function get(id)
        id = resolve_id(id)
        return id ~= nil and deepcopy_safe(worlds[id]) or nil
    end

    local function get_all()
        local ids = {}
        for id in pairs(worlds) do
            ids[#ids + 1] = id
        end
        table.sort(ids)

        local out = {}
        for _, id in ipairs(ids) do
            out[#out + 1] = deepcopy_safe(worlds[id])
        end
        return out
    end

    return
    {
        Register = register,
        ResolveID = resolve_id,
        Get = get,
        GetAll = get_all,
    }
