package.path = "scripts/?.lua;scripts/?/init.lua;"..package.path

RPC_NAMESPACE = "ShardWorldIndex"
FORWARDED_TRANSITION_TIMEOUT = 150
WORLD_INDEX_WORLD_ALIASES = { hamlet = "porkland" }
WORLD_INDEX_KNOWN_FILE_IDS =
{
    Master = { "forest", "shipwrecked", "porkland" },
    Caves = { "caves", "volcano" },
}
PORKLAND_ENTRANCE_DESTINATIONS =
{
    forest = true,
    shipwrecked = true,
    porkland = true,
}

noop = function()
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[key] = copy(child)
    end
    return out
end

deepcopy_safe = copy

local Class = {}
local index = {}
local instance = setmetatable({ index = index }, { __index = Class })
local is_master = false
local sent = nil
local state = nil

resolve_index_args = function(self, first, ...)
    if self ~= Class and self.index ~= nil and first ~= self.index then
        return self.index, first, ...
    end
    return first, ...
end

get_world_index_state = function()
    return state
end

TheWorld =
{
    DoStaticTaskInTime = function()
        return { Cancel = function() end }
    end,
}

package.loaded["modules/registry"] =
{
    Get = function(id)
        return id == "registered" and { id = id } or nil
    end,
}
package.loaded["modules/shards"] =
{
    IsMasterShard = function()
        return is_master
    end,
    GetRuntimeShardId = function()
        return "Caves"
    end,
    SendRPCToMasterShard = function(modname, name, data)
        sent = { modname = modname, name = name, data = data }
    end,
    SendForcePlayersToMasterRPC = function()
    end,
}
package.loaded["modules/world"] =
{
    NormalizeWorldType = function(value)
        return value == "caves" and "cave" or value
    end,
}

local started = nil
local advanced = nil
local returned = nil
Class.StartWorldIndex = function(_, _, opts, cb)
    started = opts
    cb(true)
    return true
end
Class.AdvanceWorldIndex = function(_, _, opts, cb)
    advanced = opts
    cb(true)
    return true
end
Class.ReturnFromWorldIndex = function(_, _, reason, cb)
    returned = reason
    cb(true)
    return true
end
Class.SwitchWorld = function(_, _, world_id, opts, cb)
    started = { world_id = world_id, opts = opts }
    cb(true)
    return true
end

require("modules/forwarding")(Class)

local forwarded_result = nil
assert(instance:RequestWorldDestination("porkland", { reason = "test" }, function(success)
    forwarded_result = success
end))
assert(sent.modname == RPC_NAMESPACE)
assert(sent.name == "ForwardWorldIndexTransition")
assert(sent.data.operation == "destination")
assert(sent.data.opts.target_world_type == "porkland")
assert(instance:HandleForwardedTransitionReply({
    request_id = sent.data.request_id,
    success = true,
}))
assert(forwarded_result == true)

is_master = true
state = nil
local local_result = nil
assert(instance:RequestWorldDestination("porkland", { reason = "local" }, function(success)
    local_result = success
end))
assert(local_result == true)
assert(started.target.world_type == "porkland")

started = nil
assert(instance:RequestWorldDestination("volcano", { reason = "volcano" }, noop))
assert(started.target.world_type == "volcano")

state =
{
    active = true,
    home = { world_type = "forest" },
}
assert(instance:RequestWorldDestination("forest", {
    reason = "home",
    return_if_home = true,
}, noop))
assert(returned == "home")

local custom_called = false
assert(instance:RegisterForwardedTransitionHandler("custom", function(received_index, opts, cb)
    assert(received_index == index)
    assert(opts.value == 1)
    custom_called = true
    cb(true)
end))
assert(instance:RequestForwardedTransition("custom", { value = 1 }, noop))
assert(custom_called)

print("forwarding_test: ok")
