local function capture(index)
    return
    {
        session_id = index:GetSession(),
        world = deepcopy_safe(index.world),
        server = deepcopy_safe(index.server),
        enabled_mods = deepcopy_safe(index.enabled_mods),
    }
end

local function apply(index, snapshot)
    snapshot = snapshot or {}
    index.session_id = snapshot.session_id
    index.world = deepcopy_safe(snapshot.world) or { options = {} }
    index.server = deepcopy_safe(snapshot.server) or {}
    index.enabled_mods = deepcopy_safe(snapshot.enabled_mods) or {}
    index:MarkDirty()
end

local function persist(index, state, opts, cb)
    opts = opts or {}
    cb = cb or noop

    local function save_state()
        save_index(index, function(index_saved)
            if not index_saved then
                cb(false)
                return
            end
            write_world_index_sidecar(index, state, function(sidecar_saved)
                if sidecar_saved and opts.set_state ~= false then
                    set_world_index_state(index, state, opts.file_id)
                end
                cb(sidecar_saved == true)
            end, opts.file_id)
        end)
    end

    if opts.restore_worldgenoverride then
        restore_worldgenoverride(index, opts.worldgenoverride, function(restored)
            if restored then
                save_state()
            else
                cb(false)
            end
        end)
    else
        save_state()
    end
end

return
{
    Capture = capture,
    Apply = apply,
    Save = save_index,
    Persist = persist,
}
