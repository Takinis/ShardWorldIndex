package.path = "scripts/?.lua;scripts/?/init.lua;"..package.path

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[copy(key)] = copy(child)
    end
    return out
end

local calls = {}
local stored_state = nil
noop = function() end
deepcopy_safe = copy
save_index = function(index, cb)
    index:Save(cb)
end
restore_worldgenoverride = function(_, raw, cb)
    calls[#calls + 1] = "restore:"..tostring(raw)
    cb(true)
end
write_world_index_sidecar = function(_, state, cb)
    calls[#calls + 1] = "sidecar"
    stored_state = state
    cb(true)
end
set_world_index_state = function(_, state)
    calls[#calls + 1] = "state"
    stored_state = state
end

local module = require("modules/index_state")

local index =
{
    session_id = "session",
    world = { options = { preset = "A" } },
    server = { name = "server" },
    enabled_mods = { mod = true },
    GetSession = function(self)
        return self.session_id
    end,
    MarkDirty = function(self)
        self.dirty = true
    end,
    Save = function(_, cb)
        calls[#calls + 1] = "index"
        cb(true)
    end,
}

local snapshot = module.Capture(index)
index.session_id = "changed"
index.world.options.preset = "B"
module.Apply(index, snapshot)
assert(index.session_id == "session")
assert(index.world.options.preset == "A")
assert(index.dirty == true)

local state = { file_id = "forest" }
local result = nil
module.Persist(index, state, {
    restore_worldgenoverride = true,
    worldgenoverride = "raw",
}, function(success)
    result = success
end)

assert(result == true)
assert(stored_state == state)
assert(table.concat(calls, ",") == "restore:raw,index,sidecar,state")

print("index_state_test: ok")
