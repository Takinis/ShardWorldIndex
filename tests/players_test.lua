package.path = "scripts/?.lua;scripts/?/init.lua;"..package.path

deepcopy_safe = function(value)
    return value
end

local shards =
{
    GetIndexShard = function()
        return "Master"
    end,
    GetRuntimeShardId = function()
        return "Master"
    end,
}
package.loaded["modules/shards"] = shards

TheNet =
{
    GetIsServer = function()
        return true
    end,
    IsDedicated = function()
        return false
    end,
    GetWorldSessionFileInClusterSlot = function()
        return "missing_session"
    end,
}

TheSim =
{
    GetPersistentStringInClusterSlot = function(_, _, _, _, cb)
        cb(false, nil)
    end,
}

local index =
{
    GetServerData = function()
        return {}
    end,
    GetSlot = function()
        return 1
    end,
}

local players = require("modules/players")
local success = nil
players.InjectPlayerSessionsIntoExistingWorld(index, "missing", {
    {
        userid = "KU_test",
        data = "return { prefab = \"wilson\" }",
    },
}, function(result)
    success = result
end)

assert(success == false)
print("players_test: ok")
