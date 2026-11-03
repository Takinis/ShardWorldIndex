local cleanup = require("modules/cleanup")

local function contains_session(value, session_id, seen)
    if type(value) ~= "table" then
        return false
    end
    seen = seen or {}
    if seen[value] then
        return false
    end
    seen[value] = true
    for key, child in pairs(value) do
        if (key == "session_id" or key == "current_session_id" or key == "cleanup_session_id" or
            key == "deferred_cleanup_session_id" or key == "generation_source_session_id" or
            key == "origin_session_id" or key == "pending_player_session_id") and
            child == session_id then
            return true
        end
        if contains_session(child, session_id, seen) then
            return true
        end
    end
    return false
end

local function state_references_session(state, session_id)
    if type(state) ~= "table" then
        return false
    end
    if contains_session(state.home, session_id) or contains_session(state.main, session_id) then
        return true
    end
    if contains_session(state.pending_player_sessions, session_id) then
        return true
    end
    if state.current_session_id == session_id and state.cleanup_current_on_return ~= true then
        return true
    end
    if state.active == true or state.pending_generation ~= nil or state.return_pending ~= nil or
        state.secondary_transition ~= nil or state.secondary_finalize_pending ~= nil or state.parent_world_index_state ~= nil or
        state.deferred_return == true then
        return contains_session(state, session_id)
    end
    return false
end

local function can_delete(index, session_id, home_session_id, stored_states)
    if session_id == nil or session_id == "" or session_id == home_session_id then
        return false
    end
    if index ~= nil and index.GetSession ~= nil and index:GetSession() == session_id then
        return false
    end
    if index ~= nil then
        for _, state in pairs(index.world_index_states or {}) do
            if state_references_session(state, session_id) then
                return false
            end
        end
        if state_references_session(index.world_index_state, session_id) then
            return false
        end
    end
    for _, state in pairs(stored_states or {}) do
        if state_references_session(state, session_id) then
            return false
        end
    end
    return true
end

local function drain(index, cb)
    cb = cb or function() end
    if index == nil then
        cb(false)
        return
    end
    require("modules/state_store").ReadAllSidecars(index, function(states, valid)
        if not valid then
            cb(false)
            return
        end
        cleanup.Drain(index, function(session_id, home_session_id)
            return can_delete(index, session_id, home_session_id, states)
        end, cb)
    end)
end

local function delete(index, session_id, home_session_id, cb)
    cb = cb or function() end
    if index == nil then
        cb(false)
        return false
    end
    cleanup.Queue(index, session_id, home_session_id, function(saved)
        if not saved then
            cb(false)
            return
        end
        drain(index, cb)
    end)
    return true
end

return
{
    Delete = delete,
    Drain = drain,
}
