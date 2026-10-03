package.path = "scripts/?.lua;scripts/?/init.lua;"..package.path

local Class = {}
local index = { marker = "index" }
local instance = setmetatable({ index = index }, { __index = Class })
local state = { active = true }
local called = {}

local function noop()
end

local function resolve(self, first, ...)
    if self ~= Class and self.index ~= nil then
        return self.index, first, ...
    end
    return first, ...
end

local modules =
{
    state = { ReadActiveSidecar = noop },
    world =
    {
        SwitchIndexToGeneratedWorld = function(received)
            called.generated = received
        end,
        SwitchIndexToExistingWorld = noop,
        DeleteSessionIfNotHome = noop,
    },
    registry =
    {
        Get = function(id)
            return id
        end,
        GetAll = function()
            return {}
        end,
    },
    session = { Drain = noop },
    manifest = { Read = noop },
    players = {},
    transition = {},
    index_state = {},
}

local deps =
{
    modules = modules,
    resolve_index_args = resolve,
    noop = noop,
    deepcopy_safe = function(value)
        return value
    end,
    ensure_home_aliases = noop,
    set_state = noop,
    state_has_origin = function()
        return false
    end,
    state_matches_index = function()
        return true
    end,
    clear_sidecar = noop,
    is_transition_restart = function()
        return false
    end,
    is_generation_source_session = function()
        return false
    end,
    recover_generation_source = noop,
    finish_interrupted_return = noop,
    is_generation_saved_without_sidecar = function()
        return false
    end,
    is_pending_generation = function()
        return false
    end,
    prepare_interrupted_regen = noop,
    clear_interrupted_transition = noop,
    needs_generation_postprocess = function()
        return false
    end,
    get_home_state = function()
        return nil
    end,
    get_state = function(received)
        assert(received == index)
        return state
    end,
    read_sidecar = noop,
    write_sidecar = noop,
    get_delete_state = noop,
    should_preserve_pending_generation = function()
        return false
    end,
    should_regenerate_current_session = function()
        return false
    end,
    save_index = noop,
    prepare_current_regen = function()
        return false
    end,
    clear_all_sidecars = noop,
    matches_current_session = function()
        return false
    end,
    get_savedata_table = noop,
    has_pending_player_sessions = function()
        return false
    end,
    write_topology_state = noop,
    finish_generated = noop,
    is_load_slot = function()
        return false
    end,
    reserves_slot = function()
        return true
    end,
    register_file_id = function(id)
        return id
    end,
    register_world = function(id)
        return id
    end,
    build_switch_options = function(id)
        return { id = id }
    end,
    restore_parent = noop,
    suspend_current = noop,
    resume_suspended = noop,
}

package.loaded["modules/index_state"] = modules.index_state
package.loaded["modules/manifest"] = modules.manifest
package.loaded["modules/players"] = modules.players
package.loaded["modules/registry"] = modules.registry
package.loaded["modules/session"] = modules.session
package.loaded["modules/state_store"] = modules.state
package.loaded["modules/transition"] = modules.transition
package.loaded["modules/world"] = modules.world

resolve_index_args = resolve
deepcopy_safe = deps.deepcopy_safe
ensure_world_index_home_aliases = deps.ensure_home_aliases
get_world_index_state = deps.get_state
set_world_index_state = deps.set_state
world_index_state_reserves_slot = deps.reserves_slot
register_world_definition = deps.register_world

local lifecycle = require("modules/lifecycle")(Class)
assert(instance:GetState() == state)
assert(instance:IsActive())
instance:SwitchIndexToGeneratedWorld({})
assert(called.generated == index)
assert(instance:RegisterWorld("test") == "test")
assert(type(lifecycle.ReadActiveSidecar) == "function")

print("module_wiring_test: ok")
