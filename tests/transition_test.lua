package.path = "scripts/?.lua;scripts/?/init.lua;"..package.path

local function copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] ~= nil then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    for key, child in pairs(value) do
        out[copy(key, seen)] = copy(child, seen)
    end
    return out
end

deepcopy_safe = copy
normalize_world_index_file_id = function(value)
    return value
end
get_world_index_file_id_for_shard = function(value)
    return value
end
is_master_shard_id = function()
    return true
end

package.loaded["modules/players"] =
{
    GetPlayerPositions = function()
        return nil
    end,
}
package.loaded["modules/shards"] =
{
    GetIndexShard = function()
        return "Master"
    end,
}
package.loaded["modules/world"] =
{
    NormalizeWorldType = function(value)
        return value
    end,
}

local transition = require("modules/transition")
local sessions = { { userid = "KU_test" } }
local state =
{
    pending_generation =
    {
        player_sessions = sessions,
        state =
        {
            chapter_start_player_sessions = sessions,
            adventure_player_sessions = sessions,
        },
    },
}

transition.ApplyPendingGenerationState(state)
assert(state.player_sessions == state.chapter_start_player_sessions)
assert(state.chapter_start_player_sessions == state.adventure_player_sessions)
print("transition_test: ok")
