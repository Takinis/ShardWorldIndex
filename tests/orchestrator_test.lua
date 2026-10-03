package.path = "scripts/?.lua;scripts/?/init.lua;"..package.path

local Class = {}
local index = {}
local instance = setmetatable({ index = index }, { __index = Class })
local calls = {}
local wait_success = true
local local_success = true

noop = function()
end

resolve_index_args = function(self, first, ...)
    if self ~= Class and self.index ~= nil and first ~= self.index then
        return self.index, first, ...
    end
    return first, ...
end

TheWorld = { ismastersim = true }

local players =
{
    SavePlayers = function()
        calls[#calls + 1] = "save_players"
    end,
    CollectPlayerSessions = function()
        calls[#calls + 1] = "collect_players"
        return { { userid = "KU_test" } }
    end,
}

local shards =
{
    SendForcePlayersToMasterRPC = function(modname, rpcname)
        calls[#calls + 1] = "force:"..tostring(modname)..":"..tostring(rpcname)
    end,
    WaitForSecondaryShardPlayersEmpty = function(cb)
        calls[#calls + 1] = "wait"
        cb(wait_success)
    end,
    RequestSecondaryWorldIndex = function(operation, data, cb, _, namespace)
        calls[#calls + 1] = "request:"..operation..":"..tostring(namespace)..":"..tostring(data.marker)
        cb(true, { id = "request" })
    end,
    AbortSecondaryWorldIndex = function(request)
        calls[#calls + 1] = "abort:"..request.id
    end,
    CommitSecondaryWorldIndex = function(request, cb)
        calls[#calls + 1] = "commit:"..request.id
        cb(true)
    end,
    RestartCurrentSlotAfterShardRPC = noop,
    IsMasterShard = function()
        return true
    end,
}

package.loaded["modules/players"] = players
package.loaded["modules/shards"] = shards
package.loaded["modules/transition"] = {}
package.loaded["modules/world"] = {}

index.SaveCurrent = function(_, cb)
    calls[#calls + 1] = "save_current"
    cb(true)
end

require("modules/orchestrator")(Class)

local result = nil
local phase = nil
local started = instance:RunSecondaryWorldIndexTransition(
{
    secondary_operation = "TestTransition",
    secondary_data = { marker = "data" },
    rpc_namespace = "TestNamespace",
    force_players_to_master = true,
    force_players_to_master_modname = "TestMod",
    force_players_to_master_rpcname = "ForcePlayers",
}, function(done)
    calls[#calls + 1] = "local"
    done(local_success, "local_result")
end, function(success, completed_phase, _, local_result)
    result = success
    phase = completed_phase
    assert(local_result == "local_result")
end)

assert(started == true)
assert(result == true)
assert(phase == "commit")
assert(table.concat(calls, ",") ==
    "force:TestMod:ForcePlayers,wait,save_current,request:TestTransition:TestNamespace:data,local,commit:request")

calls = {}
result = nil
phase = nil
local_success = false
instance:RunSecondaryWorldIndexTransition(
{
    secondary_operation = "TestTransition",
}, function(done)
    calls[#calls + 1] = "local"
    done(false)
end, function(success, completed_phase)
    result = success
    phase = completed_phase
end)

assert(result == false)
assert(phase == "local")
assert(table.concat(calls, ",") == "wait,save_current,request:TestTransition:nil:nil,local,abort:request")

calls = {}
result = nil
phase = nil
local_success = true
instance:RunSecondaryWorldIndexTransition(
{
    secondary_operation = "TestTransition",
    save_current = false,
}, function(done)
    calls[#calls + 1] = "local"
    done(true)
end, function(success, completed_phase)
    result = success
    phase = completed_phase
end)

assert(result == true)
assert(phase == "commit")
assert(table.concat(calls, ",") ==
    "wait,save_players,request:TestTransition:nil:nil,local,commit:request")

calls = {}
result = nil
phase = nil
wait_success = false
instance:RunSecondaryWorldIndexTransition(
{
    secondary_operation = "TestTransition",
    save_current_on_wait_failure = true,
}, function()
    error("local transition should not run")
end, function(success, completed_phase)
    result = success
    phase = completed_phase
end)

assert(result == false)
assert(phase == "save")
assert(table.concat(calls, ",") == "wait,save_current")

calls = {}
result = nil
wait_success = true
Class.IsActive = function()
    return true
end
Class.ReturnToStoredWorld = function(_, _, _, done)
    calls[#calls + 1] = "return_local"
    done(true)
end
get_world_index_state = function()
    return { active = false }
end
finalize_deferred_return = function(_, _, cb)
    calls[#calls + 1] = "finalize"
    cb(true)
end
rollback_deferred_return = function()
    error("rollback should not run")
end
shards.RestartCurrentSlotAfterShardRPC = function()
    calls[#calls + 1] = "restart"
end

instance:ReturnFromWorldIndex("return_test", function(success)
    result = success
end)

assert(result == true)
assert(table.concat(calls, ",") ==
    "wait,save_current,request:ReturnSecondaryWorldIndex:nil:nil,collect_players,return_local,commit:request,finalize,restart")

print("orchestrator_test: ok")
