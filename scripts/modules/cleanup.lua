local manifest = require("modules/manifest")

local function queue(index, session_id, home_session_id, cb)
    cb = cb or function() end
    if session_id == nil or session_id == "" or session_id == home_session_id then
        cb(false)
        return
    end

    manifest.Mutate(index, function(data)
        for _, entry in ipairs(data.cleanup_queue) do
            if entry.session_id == session_id then
                return false
            end
        end
        data.cleanup_queue[#data.cleanup_queue + 1] =
        {
            session_id = session_id,
            home_session_id = home_session_id,
            queued_at = os.time(),
        }
    end, cb)
end

local function drain(index, can_delete, cb)
    cb = cb or function() end
    manifest.Mutate(index, function(data)
        if #data.cleanup_queue == 0 then
            return false
        end

        local pending = {}
        for _, entry in ipairs(data.cleanup_queue) do
            if can_delete(entry.session_id, entry.home_session_id) then
                TheNet:DeleteSession(entry.session_id)
            else
                pending[#pending + 1] = entry
            end
        end
        data.cleanup_queue = pending
    end, cb)
end

return
{
    Queue = queue,
    Drain = drain,
}
