GLOBAL.setfenv(1, GLOBAL)

local function get_console_world_index()
    local worldindex = ShardGameIndex ~= nil and ShardGameIndex.worldindex or nil
    if worldindex == nil then
        print("[Shard World Index] ShardWorldIndex is unavailable.")
    end
    return worldindex
end

local function get_console_world_index_target(world_type)
    if type(world_type) == "table" then
        return world_type, world_type.file_id or world_type.world_type or world_type.location or world_type.id or world_type.session_id
    end

    if world_type == nil or world_type == "" then
        print("[Shard World Index] Usage: c_switchworld(\"porkland\"), c_shipwrecked(), c_volcano(), c_porkland(), c_forestworld().")
        return nil
    end

    local key = string.lower(tostring(world_type))
    local target_world_type = WORLD_INDEX_WORLD_ALIASES[key] or key
    return { type = "generated", world_type = target_world_type }, target_world_type
end

function c_switchworld(world_type)
    local worldindex = get_console_world_index()
    if worldindex == nil then
        return false
    end
    local state = worldindex:GetState()
    if state ~= nil and state.active == true and state.managed_externally == true then
        print("[Shard World Index] Active world index is managed by another mod.")
        return false
    end

    local registered_world = type(world_type) == "string" and worldindex:GetRegisteredWorld(world_type) or nil
    if registered_world ~= nil then
        local action = worldindex:IsActive() and "Advancing" or "Switching"
        print("[Shard World Index] "..action.." to "..registered_world.id..".")
        return worldindex:RequestWorldSwitch(world_type,
        {
            reason = worldindex:IsActive() and "console_advance" or "console_switch",
        })
    end

    local target, file_id = get_console_world_index_target(world_type)
    if target == nil then
        return false
    end

    local opts =
    {
        kind = "world_index",
        reason = "console_switch",
        target = target,
        file_id = file_id,
        reuse_existing = true,
        force_players_to_master_modname = RPC_NAMESPACE,
        force_players_to_master_rpcname = "ForcePlayersToMaster",
    }

    opts.reason = worldindex:IsActive() and "console_advance" or "console_switch"
    print("[Shard World Index] Requesting transition to "..tostring(file_id or world_type)..".")
    return worldindex:RequestWorldDestination(file_id, opts)
end

function c_returnworld(reason)
    local worldindex = get_console_world_index()
    if worldindex == nil then
        return false
    end

    local state = worldindex:GetState()
    if state == nil or state.active ~= true then
        print("[Shard World Index] No active world index to return from.")
        return false
    end
    if state.managed_externally == true then
        print("[Shard World Index] Active world index is managed by another mod.")
        return false
    end
    return worldindex:RequestWorldReturn(reason or "console_return")
end

function c_forestworld()
    return c_switchworld("forest")
end

function c_forest()
    return c_forestworld()
end

function c_shipwrecked()
    return c_switchworld("shipwrecked")
end

function c_volcano()
    return c_switchworld("volcano")
end

function c_porkland()
    return c_switchworld("porkland")
end
