local manifest = require("modules/manifest")
local transaction = require("modules/transaction")
local worldgenoverride_file = WORLDGENOVERRIDE_FILE
local sidecar_schema_version = 2
    local write_queues = {}

    local function get_write_key(index, filename)
        local slot, shard = get_slot_and_shard(index)
        return tostring(slot or "legacy")..":"..tostring(shard or "legacy")..":"..filename
    end

    local function enqueue_write(index, filename, data, writer, cb)
        cb = cb or noop
        local key = get_write_key(index, filename)
        local queue = write_queues[key]
        if queue == nil then
            queue = { running = false, items = {} }
            write_queues[key] = queue
        end
        queue.items[#queue.items + 1] =
        {
            data = data,
            writer = writer,
            cb = cb,
        }
        if queue.running then
            return
        end

        local function next_write()
            local item = table.remove(queue.items, 1)
            if item == nil then
                queue.running = false
                write_queues[key] = nil
                return
            end
            queue.running = true
            item.writer(item.data, function(success)
                item.cb(success == true)
                next_write()
            end)
        end
        next_write()
    end

    local function read_worldgenoverride_raw(index, cb)
        cb = cb or noop
        local slot, shard = get_slot_and_shard(index)
        local function onload(load_success, str)
            if load_success and str ~= nil and #str > 0 then
                cb(str)
            else
                cb(nil)
            end
        end

        if slot ~= nil and shard ~= nil then
            TheSim:GetPersistentStringInClusterSlot(slot, shard, worldgenoverride_file, onload)
        else
            TheSim:GetPersistentString(worldgenoverride_file, onload)
        end
    end

    local function write_worldgenoverride(index, str, cb)
        cb = cb or noop
        enqueue_write(index, worldgenoverride_file, str, function(data, onwrite)
            local slot, shard = get_slot_and_shard(index)
            if slot ~= nil and shard ~= nil then
                TheSim:SetPersistentStringInClusterSlot(slot, shard, worldgenoverride_file, data, false, onwrite)
            else
                TheSim:SetPersistentString(worldgenoverride_file, data, false, onwrite)
            end
        end, cb)
    end

    local function restore_worldgenoverride(index, raw, cb)
        write_worldgenoverride(index, raw or "return {\n\toverride_enabled = false,\n}\n", cb)
    end

    local function get_sidecar_filename(index, file_id)
        return index:GetShardIndexName().."_"..normalize_world_index_file_id(file_id)
    end

    local function read_named_sidecar(index, file_id, cb)
        cb = cb or noop
        file_id = normalize_world_index_file_id(file_id)
        local filename = get_sidecar_filename(index, file_id)
        local slot, shard = get_slot_and_shard(index)

        local function onload(load_success, str)
            if load_success and str ~= nil and #str > 0 then
                local success, data = RunInSandboxSafe(str)
                if success and type(data) == "table" then
                    data.file_id = normalize_world_index_file_id(data.file_id or file_id)
                    ensure_world_index_home_aliases(data)
                    cb(data, true, true)
                    return
                end
                print("[Shard World Index] Failed to parse "..filename)
                cb(nil, true, false)
                return
            end
            cb(nil, false, true)
        end

        if slot ~= nil and shard ~= nil then
            TheSim:GetPersistentStringInClusterSlot(slot, shard, filename, onload)
        else
            TheSim:GetPersistentString(filename, onload)
        end
    end

    local function write_sidecar(index, data, cb, file_id)
        cb = cb or noop
        file_id = normalize_world_index_file_id(file_id or (data ~= nil and data.file_id or nil))
        ensure_world_index_home_aliases(data)
        if data ~= nil then
            data.file_id = file_id
            data.schema_version = sidecar_schema_version
            transaction.Ensure(data, { file_id = file_id })
            transaction.Touch(data)
        end

        local filename = get_sidecar_filename(index, file_id)
        local serialized = data ~= nil and DataDumper(data, nil, false) or nil
        enqueue_write(index, filename, serialized, function(value, onwrite)
            local slot, shard = get_slot_and_shard(index)
            if value == nil then
                if slot ~= nil and shard ~= nil then
                    TheSim:SetPersistentStringInClusterSlot(slot, shard, filename, "", false, onwrite)
                elseif ErasePersistentString ~= nil then
                    ErasePersistentString(filename, onwrite)
                else
                    TheSim:SetPersistentString(filename, "", false, onwrite)
                end
                return
            end

            if slot ~= nil and shard ~= nil then
                TheSim:SetPersistentStringInClusterSlot(slot, shard, filename, value, false, onwrite)
            else
                TheSim:SetPersistentString(filename, value, false, onwrite)
            end
        end, function(success)
            if not success then
                cb(false)
                return
            end
            if data == nil then
                manifest.Unregister(index, file_id, cb)
            else
                manifest.Register(index, file_id, cb)
            end
        end)
    end

    return
    {
        ReadWorldGenOverrideRaw = read_worldgenoverride_raw,
        WriteWorldGenOverride = write_worldgenoverride,
        RestoreWorldGenOverride = restore_worldgenoverride,
        ReadNamedSidecar = read_named_sidecar,
        WriteSidecar = write_sidecar,
    }
