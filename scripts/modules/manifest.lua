local manifest_filename = "shardindex_manifest"
local manifest_version = 2
local mutation_queues = {}
local default_file_ids =
{
    forest = true,
    shipwrecked = true,
    porkland = true,
    caves = true,
    volcano = true,
}

local function normalize_file_id(file_id)
    if file_id == nil or file_id == "" then
        return "world"
    end
    file_id = string.lower(tostring(file_id)):gsub("[^%w_%-]", "_")
    file_id = file_id:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return file_id ~= "" and file_id or "world"
end

local function get_slot_and_shard(index)
    if index ~= nil and index.GetSlot ~= nil and index.GetShard ~= nil then
        return index:GetSlot(), index:GetShard()
    end
end

local function read_raw(slot, shard, cb)
    if slot ~= nil and shard ~= nil then
        TheSim:GetPersistentStringInClusterSlot(slot, shard, manifest_filename, cb)
    else
        TheSim:GetPersistentString(manifest_filename, cb)
    end
end

local function write_raw(slot, shard, data, cb)
    if slot ~= nil and shard ~= nil then
        TheSim:SetPersistentStringInClusterSlot(slot, shard, manifest_filename, data, false, cb)
    else
        TheSim:SetPersistentString(manifest_filename, data, false, cb)
    end
end

local function default_manifest()
    return
    {
        version = manifest_version,
        sidecars = {},
        cleanup_queue = {},
    }
end

local function normalize_manifest(data)
    local manifest = type(data) == "table" and data or default_manifest()
    manifest.version = manifest_version
    manifest.sidecars = type(manifest.sidecars) == "table" and manifest.sidecars or {}
    manifest.cleanup_queue = type(manifest.cleanup_queue) == "table" and manifest.cleanup_queue or {}
    for file_id in pairs(default_file_ids) do
        manifest.sidecars[normalize_file_id(file_id)] = true
    end
    return manifest
end

local function read_manifest(slot, shard, cb)
    read_raw(slot, shard, function(load_success, str)
        if load_success and type(str) == "string" and #str > 0 then
            local success, data = RunInSandboxSafe(str)
            if success and type(data) == "table" then
                cb(normalize_manifest(data))
                return
            end
        end
        cb(default_manifest())
    end)
end

local function write_manifest(slot, shard, data, cb)
    write_raw(slot, shard, DataDumper(normalize_manifest(data), nil, false), function(success)
        cb(success == true)
    end)
end

local function mutate_at(slot, shard, fn, cb)
    cb = cb or function() end
    local key = tostring(slot or "legacy")..":"..tostring(shard or "legacy")
    local queue = mutation_queues[key]
    if queue == nil then
        queue = { running = false, items = {} }
        mutation_queues[key] = queue
    end
    queue.items[#queue.items + 1] = { fn = fn, cb = cb }
    if queue.running then
        return
    end

    local function next_mutation()
        local item = table.remove(queue.items, 1)
        if item == nil then
            queue.running = false
            mutation_queues[key] = nil
            return
        end
        queue.running = true
        read_manifest(slot, shard, function(data)
            if item.fn(data) == false then
                item.cb(true)
                next_mutation()
                return
            end
            write_manifest(slot, shard, data, function(success)
                item.cb(success == true)
                next_mutation()
            end)
        end)
    end
    next_mutation()
end

local function mutate(index, fn, cb)
    local slot, shard = get_slot_and_shard(index)
    mutate_at(slot, shard, function(data)
        local result = fn(data)
        if index ~= nil then
            index.world_index_manifest = data
        end
        return result
    end, cb)
end

local function read(index, cb)
    local slot, shard = get_slot_and_shard(index)
    read_manifest(slot, shard, function(data)
        if index ~= nil then
            index.world_index_manifest = data
        end
        (cb or function() end)(data)
    end)
end

local function read_by_slot(slot, shard, cb)
    read_manifest(slot, shard or "Master", cb or function() end)
end

local function write(index, data, cb)
    data = type(data) == "table" and data or default_manifest()
    mutate(index, function(current)
        current.version = data.version
        current.sidecars = data.sidecars
        current.cleanup_queue = data.cleanup_queue
    end, cb)
end

local function register(index, file_id, cb)
    file_id = normalize_file_id(file_id)
    mutate(index, function(data)
        data.sidecars[file_id] = true
    end, cb)
end

local function unregister(index, file_id, cb)
    file_id = normalize_file_id(file_id)
    mutate(index, function(data)
        data.sidecars[file_id] = nil
    end, cb)
end

local function get_file_ids(index)
    local data = index ~= nil and index.world_index_manifest or nil
    local ids = {}
    local seen = {}
    for file_id in pairs(default_file_ids) do
        ids[#ids + 1] = file_id
        seen[file_id] = true
    end
    if data ~= nil and type(data.sidecars) == "table" then
        for file_id, enabled in pairs(data.sidecars) do
            file_id = normalize_file_id(file_id)
            if enabled and not seen[file_id] then
                ids[#ids + 1] = file_id
                seen[file_id] = true
            end
        end
    end
    table.sort(ids)
    return ids
end

return
{
    NormalizeFileID = normalize_file_id,
    Read = read,
    ReadBySlot = read_by_slot,
    Write = write,
    Mutate = mutate,
    Register = register,
    Unregister = unregister,
    GetFileIDs = get_file_ids,
}
