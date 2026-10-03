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
    if state.active == true or state.pending_generation ~= nil or state.return_pending ~= nil or
        state.secondary_transition ~= nil or state.parent_world_index_state ~= nil or
        state.deferred_return == true then
        return contains_session(state, session_id)
    end
    return false
end

local function can_delete(index, session_id, home_session_id)
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
    return true
end

local function delete(index, session_id, home_session_id, cb)
    cb = cb or function() end
    cleanup.Queue(index, session_id, home_session_id, function(saved)
        if saved and can_delete(index, session_id, home_session_id) then
            TheNet:DeleteSession(session_id)
        end
        cb(saved == true)
    end)
    return true
end

local function drain(index, cb)
    cleanup.Drain(index, function(session_id, home_session_id)
        return can_delete(index, session_id, home_session_id)
    end, cb)
end

return
{
    CanDelete = can_delete,
    Delete = delete,
    Drain = drain,
}
