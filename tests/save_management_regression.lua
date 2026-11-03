package.path = "scripts/?.lua;"..package.path

local vanilla_scripts = os.getenv("DST_SCRIPTS") or "../../data/databundles/scripts"
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

GLOBAL = _G
deepcopy = copy
noop = function() end
local function complete(cb, ...)
    if cb ~= nil then
        cb(...)
    end
end
function deepcopy_safe(value)
    return value ~= nil and copy(value) or nil
end
function RunInSandboxSafe(raw)
    local fn, err = loadstring(raw or "")
    if fn == nil then
        return false, err
    end
    return pcall(fn)
end
RunInSandbox = RunInSandboxSafe
function GetTableSize(value)
    local size = 0
    for _ in pairs(value) do size = size + 1 end
    return size
end
function resolve_index_args(self, index, ...)
    if self.index ~= nil and (type(index) ~= "table" or index.GetSession == nil) then
        return self.index, index, ...
    end
    return index, ...
end
function is_master_shard_id(id)
    return id == nil or id == "" or id == "1" or id == "Master"
end
function save_index(index, cb)
    index:Save(function(success)
        cb(success == true)
    end)
end
function build_generation_recovery_state(index, state, session_id)
    if state.current_session_id == (session_id or index:GetSession()) then
        local recovery = copy(state)
        recovery.pending_generation = nil
        recovery.generation_recovery_state = nil
        return recovery
    end
end
function get_savedata_table(value)
    if type(value) == "table" then
        return value
    end
    local success, data = RunInSandboxSafe(value)
    return success and data or nil
end
function is_world_index_transition_restart()
    return Settings.world_index_transition ~= nil
end
function world_index_state_has_origin(state)
    return state.slot ~= nil or state.shard ~= nil
end
function world_index_state_matches_index(index, state)
    return (state.slot == nil or state.slot == index:GetSlot()) and
        (state.shard == nil or state.shard == index:GetShard())
end

dofile(vanilla_scripts.."/dumper.lua")
dofile("main/constants.lua")
SHARDID = { MASTER = "1" }
RESET_ACTION = { LOAD_SLOT = "load_slot" }
BRANCH = "dev"
USERFLAGS = { IS_GHOST = 1 }
AllPlayers = {}

local disk, deleted, sent, tasks, failures, delayed_reads
local current_snapshot, saves, index
local function key(slot, shard, filename)
    return tostring(slot).."/"..tostring(shard).."/"..filename
end
TheSim = {}
function TheSim:GetPersistentStringInClusterSlot(slot, shard, filename, cb)
    local function read()
        local value = disk[key(slot, shard, filename)]
        cb(value ~= nil, value or "")
    end
    if delayed_reads ~= nil then
        delayed_reads[#delayed_reads + 1] = read
    else
        read()
    end
end
function TheSim:SetPersistentStringInClusterSlot(slot, shard, filename, value, encode, cb)
    if failures[filename] then
        failures[filename] = nil
        complete(cb, false)
        return
    end
    disk[key(slot, shard, filename)] = value
    complete(cb, true)
end
function TheSim:GetPersistentString(filename, cb)
    self:GetPersistentStringInClusterSlot(0, nil, filename, cb)
end
function TheSim:SetPersistentString(filename, value, encode, cb)
    self:SetPersistentStringInClusterSlot(0, nil, filename, value, encode, cb)
end

TheNet = {}
function TheNet:GetIsServer() return true end
function TheNet:GetIsClient() return false end
function TheNet:IsDedicated() return false end
function TheNet:GetIsMasterSimulation() return true end
function TheNet:GetCurrentSnapshot() return current_snapshot end
function TheNet:DeleteSession(session_id) deleted[#deleted + 1] = session_id end
TheShard = {}
function TheShard:IsMaster() return true end
function TheShard:IsSecondary() return false end
function TheShard:GetShardId() return "1" end
function TheShard:GetSecondaryShardPlayerCounts() return 0, 0 end
function GetTime() return 100 end
function GetShardModRPC(namespace, name) return name end
function ZipAndEncodeString(data) return data end
function SendModRPCToShard(rpc, shardid, payload)
    sent[#sent + 1] = { rpc = rpc, shardid = shardid, data = payload }
end
RestoreSnapshotUserSession = noop
ResumeExistingUserSession = noop

local state_store = require("modules/state_store")
local manifest = require("modules/manifest")
local shards = require("modules/shards")
local session = require("modules/session")
local target_commit = require("modules/target_commit")
local snapshot = require("modules/snapshot")
local Class = {}
require("modules/lifecycle")(Class)
require("modules/world_switch").Install(Class)
require("modules/secondary_transition").Install(Class)
require("modules/orchestrator")(Class)

local function reset(session_id)
    disk, deleted, sent, tasks, failures = {}, {}, {}, {}, {}
    delayed_reads = nil
    current_snapshot, saves = 10, 0
    Settings = { reset_action = RESET_ACTION.LOAD_SLOT }
    TheWorld = {
        ismastersim = true,
        meta = { session_identifier = session_id or "B" },
        net = { components = { autosaver = { GetLastSaveTime = function() return 0 end } } },
    }
    function TheWorld:DoStaticTaskInTime(delay, fn)
        local task = { fn = fn, delay = delay }
        function task:Cancel() self.cancelled = true end
        tasks[#tasks + 1] = task
        return task
    end
    TheWorld.DoTaskInTime = TheWorld.DoStaticTaskInTime
    index = { session_id = session_id or "B", world = { options = {} }, server = {}, enabled_mods = {} }
    function index:GetSlot() return 1 end
    function index:GetShard() return "Master" end
    function index:GetSession() return self.session_id end
    function index:GetServerData() return self.server end
    function index:GetShardIndexName() return "shardindex" end
    function index:MarkDirty() self.dirty = true end
    function index:Save(cb)
        TheSim:SetPersistentStringInClusterSlot(1, "Master", "shardindex", DataDumper({
            session_id = self.session_id, world = self.world,
            server = self.server, enabled_mods = self.enabled_mods, version = 5,
        }), false, cb)
    end
    function index:SaveCurrent(cb)
        saves = saves + 1
        complete(cb)
    end
    index.worldindex = setmetatable({ index = index }, { __index = Class })
    ShardGameIndex = index
    return index
end
local function store(state, select)
    local saved
    state_store.WriteSidecar(index, state, function(success) saved = success end, state.file_id)
    assert(saved == true)
    if select then state_store.SetState(index, state) end
    return state
end
local function read(file_id)
    local state, valid
    state_store.ReadSidecar(index, function(value, success) state, valid = value, success end, file_id)
    assert(valid == true)
    return state
end
local function active(file_id)
    return {
        active = true, file_id = file_id or "porkland",
        home = { session_id = "HOME" }, current_session_id = index:GetSession(),
        transaction = { id = "visit", phase = "finalized", epoch = 1, revision = 1 },
        current_worldgenoverride = "return { override_enabled = false }",
    }
end
local count = 0
local function test(name, fn)
    reset()
    fn()
    count = count + 1
    print("PASS "..name)
end

test("cleanup protects references in unselected disk sidecars", function()
    store(active(), true)
    store({ active = false, file_id = "shipwrecked", home = { session_id = "C" }, current_session_id = "D" })
    local finished
    session.Delete(index, "C", "HOME", function(ok) finished = ok end)
    assert(finished == true and #deleted == 0)
end)

test("cleanup deletes an unreferenced session and removes its queue entry", function()
    store(active(), true)
    session.Delete(index, "UNUSED", "HOME", noop)
    assert(deleted[1] == "UNUSED")
    manifest.Read(index, function(data) assert(#data.cleanup_queue == 0) end)
end)

test("cleanup retains the current session of an inactive reusable world", function()
    store(active(), true)
    store({ active = false, file_id = "shipwrecked", current_session_id = "C" })
    session.Delete(index, "C", "HOME", noop)
    assert(#deleted == 0)
end)

test("cleanup fails safely when no shard index is available", function()
    local result
    assert(session.Delete(nil, "C", "HOME", function(ok) result = ok end) == false)
    assert(result == false and #deleted == 0)
end)

test("cleanup rejects corrupt sidecars", function()
    store(active(), true)
    disk[key(1, "Master", "shardindex_shipwrecked")] = "invalid lua!"
    local result
    session.Delete(index, "UNUSED", "HOME", function(ok) result = ok end)
    assert(result == false and #deleted == 0)
end)

test("corrupt manifest blocks reads and writes without overwriting files", function()
    store(active(), true)
    local original = disk[key(1, "Master", "shardindex_porkland")]
    disk[key(1, "Master", "shardindex_manifest")] = "invalid lua!"
    local result
    state_store.WriteSidecar(index, active(), function(ok) result = ok end)
    assert(result == false and disk[key(1, "Master", "shardindex_porkland")] == original)
    index.worldindex:LoadSidecar(function(ok) result = ok end)
    assert(result == false)
    session.Delete(index, "UNUSED", "HOME", function(ok) result = ok end)
    assert(result == false and #deleted == 0)
end)

test("failed cross-file commit restores existing target and source index", function()
    store(active(), true)
    store({
        active = false, file_id = "shipwrecked", home = { session_id = "HOME" },
        current_session_id = "C", current_preset = "ISLAND",
    })
    local original_commit = target_commit.CommitTarget
    target_commit.CommitTarget = function(target_index, state, target, keep, cb)
        target_index.session_id = "C"
        target_index.world = { options = { changed = true } }
        cb(false)
    end
    local result
    index.worldindex:QueueNextWorld({
        target = { type = "existing", session_id = "C", file_id = "shipwrecked" },
        file_id = "shipwrecked", collect_player_sessions = false,
    }, function(ok) result = ok end)
    target_commit.CommitTarget = original_commit
    assert(result == false and read("shipwrecked").current_session_id == "C")
    assert(index:GetSession() == "B" and index.world.options.changed == nil)
    assert(state_store.GetState(index).file_id == "porkland")
end)

test("unread corrupt target survives a failed switch", function()
    store(active(), true)
    disk[key(1, "Master", "shardindex_shipwrecked")] = "invalid lua!"
    local result
    index.worldindex:QueueNextWorld({
        target = { type = "existing", session_id = "C", file_id = "shipwrecked" },
        file_id = "shipwrecked", collect_player_sessions = false,
    }, function(ok) result = ok end)
    assert(result == false and disk[key(1, "Master", "shardindex_shipwrecked")] == "invalid lua!")
end)

test("failed source parking restores both sidecars and the raw override", function()
    store(active(), true)
    store({ active = false, file_id = "shipwrecked", current_session_id = "C" })
    local raw_override = "return { override_enabled = true, custom = 'unchanged' }"
    disk[key(1, "Master", WORLDGENOVERRIDE_FILE)] = raw_override
    local original_commit = target_commit.CommitTarget
    target_commit.CommitTarget = function(target_index, state, target, keep, cb)
        target_index.session_id = "C"
        failures.shardindex_porkland = true
        cb(true)
    end
    local result
    index.worldindex:QueueNextWorld({
        target = { type = "existing", session_id = "C", file_id = "shipwrecked" },
        file_id = "shipwrecked", collect_player_sessions = false,
    }, function(ok) result = ok end)
    target_commit.CommitTarget = original_commit
    assert(result == false and index:GetSession() == "B")
    assert(read("porkland").active == true and read("shipwrecked").current_session_id == "C")
    assert(disk[key(1, "Master", WORLDGENOVERRIDE_FILE)] == raw_override)
end)

test("secondary preparation waits for source world save", function()
    store(active(), true)
    local finish_save
    function index:SaveCurrent(cb) saves = saves + 1; finish_save = cb end
    local result
    index.worldindex:PrepareSecondaryTransition("ReturnSecondaryWorldIndex", { request_id = "r1" }, function(ok) result = ok end)
    assert(saves == 1 and result == nil and read("porkland").secondary_transition == nil)
    finish_save()
    assert(result == true and read("porkland").secondary_transition.status == "prepared")
end)

test("failed secondary save leaves its sidecar unchanged", function()
    store(active(), true)
    function index:SaveCurrent(cb) cb(false) end
    local result
    index.worldindex:PrepareSecondaryTransition("ReturnSecondaryWorldIndex", { request_id = "r1" }, function(ok) result = ok end)
    assert(result == false and read("porkland").secondary_transition == nil)
end)

test("finalized transactions accept commit and finalize replay after restart", function()
    local state = active()
    state.secondary_transition = {
        request_id = "r1", operation = "BeginSecondaryWorldIndex",
        status = "committed", file_id = "porkland",
    }
    store(state, true)
    local result
    index.worldindex:FinalizeSecondaryTransition("r1", "porkland", function(ok) result = ok end)
    assert(result == true)
    state = read("porkland")
    assert(state.secondary_transition == nil and state.secondary_completed_request.request_id == "r1")
    index.world_index_states, index.world_index_state = nil, nil
    index.worldindex:CommitPreparedSecondaryTransition("r1", "porkland", function(ok) result = ok end)
    assert(result == true)
    index.worldindex:FinalizeSecondaryTransition("r1", "porkland", function(ok) result = ok end)
    assert(result == true)
    index.worldindex:AbortPreparedSecondaryTransition("r1", "porkland", function(ok) result = ok end)
    assert(result == true and index:GetSession() == "B")
end)

test("failed finalize retains transaction and does not publish its receipt", function()
    local state = active()
    state.secondary_transition = { request_id = "r1", operation = "BeginSecondaryWorldIndex", status = "committed", file_id = "porkland" }
    store(state, true)
    failures.shardindex_porkland = true
    local result
    index.worldindex:FinalizeSecondaryTransition("r1", "porkland", function(ok) result = ok end)
    assert(result == false and state.secondary_transition ~= nil and state.secondary_completed_request == nil)
    assert(read("porkland").secondary_transition ~= nil)
end)

test("startup selects inactive commit decisions and deferred returns", function()
    store({ active = false, file_id = "porkland", home = { session_id = "HOME" }, secondary_finalize_pending = { request_id = "r2" }, deferred_return = true })
    local state
    state_store.ReadSidecar(index, function(value, valid) assert(valid); state = value end)
    assert(state ~= nil and state.secondary_finalize_pending.request_id == "r2")
end)

test("startup caches inactive recovery alongside the active parent", function()
    store(active("forest"))
    store({ active = false, file_id = "porkland", secondary_finalize_pending = { request_id = "r2", operation = "ReturnSecondaryWorldIndex", shardids = { "2" }, prepared = { ["2"] = { file_id = "caves" } } } })
    state_store.ReadSidecar(index, function(value, valid) assert(valid); state_store.SetState(index, value) end)
    assert(state_store.GetState(index).file_id == "forest")
    assert(shards.IsSecondaryWorldIndexRequestPending())
    assert(shards.RetryPendingSecondaryFinalize(index))
    assert(sent[#sent].rpc == "CommitSecondaryWorldIndex")
    local message = sent[#sent]
    shards.HandleSecondaryWorldIndexReply("2", {
        request_id = message.data.request_id, operation = message.data.operation, phase = "commit", success = true,
    })
    for _, task in ipairs(tasks) do
        if task.delay == 0 and not task.cancelled then task.fn() end
    end
    assert(sent[#sent].rpc == "FinalizeSecondaryWorldIndex")
    shards.HandleSecondaryWorldIndexReply("2", {
        request_id = "r2", operation = "ReturnSecondaryWorldIndex", phase = "finalize", success = true,
    })
    assert(read("porkland").secondary_finalize_pending == nil)
end)

test("snapshot checkpoint is server-only and does not mutate serializer input", function()
    store(active(), true)
    snapshot.BeforeSave(index, function(ok) assert(ok) end)
    local data = { map = DataDumper({ topology = { ids = {} }, persistdata = {} }) }
    local out = snapshot.Attach(index, data, "B")
    local _, original_map = RunInSandboxSafe(data.map)
    local _, map = RunInSandboxSafe(out.map)
    assert(original_map.persistdata.world_index_checkpoint == nil)
    assert(map.topology.world_index_checkpoint == nil)
    assert(map.persistdata.world_index_checkpoint.state.file_id == "porkland")
end)

test("normal restart does not restore consumed migration records", function()
    local state = active()
    state.pending_player_sessions = { { userid = "user", data = "old" } }
    state.pending_player_session_id = "B"
    store(state, true)
    snapshot.BeforeSave(index, function(ok) assert(ok) end)
    local out = snapshot.Attach(index, { map = DataDumper({ persistdata = {} }) }, "B")
    snapshot.AfterSave(index, function(ok) assert(ok) end)
    state.pending_player_sessions, state.pending_player_session_id = nil, nil
    store(state, true)
    local _, map = RunInSandboxSafe(out.map)
    snapshot.Restore(index, { map = map, meta = { session_identifier = "B" } }, function(ok) assert(ok) end)
    assert(state_store.GetState(index).pending_player_sessions == nil)
end)

test("rollback restores checkpoint player state while preserving commit decisions", function()
    local state = active()
    state.pending_player_sessions = { { userid = "user", data = "snapshot" } }
    state.pending_player_session_id = "B"
    store(state, true)
    snapshot.BeforeSave(index, function(ok) assert(ok) end)
    local out = snapshot.Attach(index, { map = DataDumper({ persistdata = {} }) }, "B")
    snapshot.AfterSave(index, function(ok) assert(ok) end)
    state.pending_player_sessions = nil
    state.last_saved_snapshot = 12
    state.secondary_completed_request = { request_id = "done", status = "finalized" }
    store(state, true)
    local _, map = RunInSandboxSafe(out.map)
    local savedata = { map = map, meta = { session_identifier = "B" } }
    snapshot.Restore(index, savedata, function(ok) assert(ok) end)
    local restored = state_store.GetState(index)
    assert(restored.pending_player_sessions[1].data == "snapshot")
    assert(restored.secondary_completed_request.request_id == "done")
    assert(restored.last_saved_snapshot == 10)
end)

test("rollback rejects snapshots from a previous visit", function()
    local state = active()
    store(state, true)
    snapshot.BeforeSave(index, function(ok) assert(ok) end)
    snapshot.AfterSave(index, function(ok) assert(ok) end)
    local previous = copy(state)
    previous.transaction.id = "previous_visit"
    local result
    snapshot.Restore(index, {
        meta = { session_identifier = "B" },
        map = { persistdata = { world_index_checkpoint = {
            version = 1, session_id = "B", snapshot = 1, state = previous,
        } } },
    }, function(ok) result = ok end)
    assert(result == false and state_store.GetState(index).transaction.id == "visit")
    current_snapshot = 12
    assert(snapshot.CanRollback(index, 1))
    assert(not snapshot.CanRollback(index, 3))
end)

test("saving rejects mismatched runtime and index sessions", function()
    store(active(), true)
    index.session_id = "C"
    local result
    snapshot.BeforeSave(index, function(ok) result = ok end)
    assert(result == false)
end)

test("failed snapshot sidecar write restores baseline fields", function()
    local state = store(active(), true)
    failures.shardindex_porkland = true
    local result
    snapshot.BeforeSave(index, function(ok) result = ok end)
    assert(result == false and state.rollback_min_snapshot == nil and state.last_saved_snapshot == nil)
end)

test("orchestration stops after failed source save", function()
    function index:SaveCurrent(cb) cb(false) end
    local transitioned, result
    index.worldindex:RunSecondaryWorldIndexTransition({
        secondary_operation = "BeginSecondaryWorldIndex",
    }, function() transitioned = true end, function(ok) result = ok end)
    for _, task in ipairs(tasks) do
        if not task.cancelled then task.fn() end
    end
    assert(result == false and transitioned == nil and #sent == 0)
end)

test("cleanup rechecks in-memory references after asynchronous disk reads", function()
    store(active(), true)
    delayed_reads = {}
    local finished
    session.Delete(index, "C", "HOME", function(ok) finished = ok end)
    state_store.SetState(index, {
        active = false, file_id = "forest", home = { session_id = "C" },
    }, "forest")
    while #delayed_reads > 0 do
        table.remove(delayed_reads, 1)()
    end
    delayed_reads = nil
    assert(finished == true and #deleted == 0)
end)

test("unknown manifest and sidecar versions are rejected", function()
    disk[key(1, "Master", "shardindex_manifest")] = "return { version = 99 }"
    local valid
    manifest.Read(index, function(_, success) valid = success end)
    assert(valid == false)
    disk[key(1, "Master", "shardindex_manifest")] = nil
    disk[key(1, "Master", "shardindex_porkland")] = "return { schema_version = 99 }"
    state_store.ReadSidecar(index, function(_, success) valid = success end, "porkland")
    assert(valid == false)
    disk[key(1, "Master", "shardindex_porkland")] = "return { home = 'invalid' }"
    state_store.ReadSidecar(index, function(_, success) valid = success end, "porkland")
    assert(valid == false)
end)

test("startup finalizes an interrupted local deferred return without players", function()
    index.session_id = "HOME"
    store({
        active = false, file_id = "porkland", home = { session_id = "HOME" },
        current_session_id = "B", deferred_return = true, deferred_cleanup_session_id = "B",
        cleanup_current_on_return = true,
    })
    local result
    index.worldindex:LoadSidecar(function(ok) result = ok end)
    assert(result == true and read("porkland").deferred_return == nil)
    assert(deleted[1] == "B")
end)

test("startup preserves a durable generation decision on its source session", function()
    local state = active()
    state.current_session_id = nil
    state.current_target = { type = "generated", id = "NEXT" }
    state.generation_source_session_id = "B"
    state.secondary_finalize_pending = { request_id = "r1" }
    store(state)
    local result
    index.worldindex:LoadSidecar(function(ok) result = ok end)
    assert(result == true and read("porkland").secondary_finalize_pending.request_id == "r1")
end)

test("saving and rollback are blocked while a transaction is incomplete", function()
    local state = store(active(), true)
    state.secondary_finalize_pending = { request_id = "r1" }
    local result
    snapshot.BeforeSave(index, function(ok) result = ok end)
    assert(result == false and not snapshot.CanRollback(index, 1))
end)

test("secondary restart is still required when finalize is replayed before generation", function()
    local state = active()
    state.current_session_id = nil
    state.current_target = { type = "generated", id = "NEXT" }
    state.secondary_completed_request = { request_id = "r1", status = "finalized", file_id = "porkland" }
    store(state, true)
    local result, restart
    index.worldindex:FinalizeSecondaryTransition("r1", "porkland", function(ok, needed) result, restart = ok, needed end)
    assert(result == true and restart == true)
end)

test("rollback is blocked by a pending decision on an inactive child", function()
    store(active(), true)
    snapshot.BeforeSave(index, function(ok) assert(ok) end)
    snapshot.AfterSave(index, function(ok) assert(ok) end)
    state_store.SetState(index, {
        active = false, file_id = "shipwrecked", secondary_finalize_pending = { request_id = "r1" },
    }, "shipwrecked")
    current_snapshot = 12
    assert(not snapshot.CanRollback(index, 1))
end)

test("legacy snapshots remain loadable until a checkpoint save succeeds", function()
    store(active(), true)
    snapshot.BeforeSave(index, function(ok) assert(ok) end)
    local result
    snapshot.Restore(index, { map = {}, meta = { session_identifier = "B" } }, function(ok) result = ok end)
    assert(result == true)
    snapshot.AfterSave(index, function(ok) assert(ok) end)
    snapshot.Restore(index, { map = {}, meta = { session_identifier = "B" } }, function(ok) result = ok end)
    assert(result == false)
end)

test("finalize timeout schedules another commit attempt without reconnect", function()
    local state = active()
    state.secondary_finalize_pending = {
        request_id = "r4", operation = "BeginSecondaryWorldIndex",
        shardids = { "2" }, prepared = { ["2"] = { file_id = "caves" } },
    }
    store(state, true)
    assert(shards.RetryPendingSecondaryFinalize(index))
    shards.HandleSecondaryWorldIndexReply("2", {
        request_id = "r4", operation = "BeginSecondaryWorldIndex", phase = "commit", success = true,
    })
    for _, task in ipairs(tasks) do
        if task.delay == 0 and not task.cancelled then task.fn() end
    end
    local timeout = tasks[#tasks]
    assert(timeout.delay == 30)
    timeout.fn()
    local retry = tasks[#tasks]
    assert(retry.delay == 5)
    retry.fn()
    assert(sent[#sent].rpc == "CommitSecondaryWorldIndex")
    shards.HandleSecondaryWorldIndexReply("2", {
        request_id = "r4", operation = "BeginSecondaryWorldIndex", phase = "commit", success = true,
    })
    for _, task in ipairs(tasks) do
        if task.delay == 0 and not task.cancelled then task.cancelled = true; task.fn() end
    end
    shards.HandleSecondaryWorldIndexReply("2", {
        request_id = "r4", operation = "BeginSecondaryWorldIndex", phase = "finalize", success = true,
    })
end)

test("failed secondary commit stays prepared so the master retry can commit it", function()
    store(active(), true)
    local dispatches = 0
    require("modules/secondary_transition").Register("RetryableCommit", {
        needs_target = false,
        GetTarget = function() return nil, "porkland" end,
        Dispatch = function(target_index, opts, transaction, cb)
            dispatches = dispatches + 1
            target_index.session_id = "PARTIAL"
            cb(dispatches > 1)
        end,
    })
    local result
    index.worldindex:PrepareSecondaryTransition("RetryableCommit", { request_id = "r5" }, function(ok) result = ok end)
    assert(result == true)

    index.worldindex:CommitPreparedSecondaryTransition("r5", "porkland", function(ok) result = ok end)
    assert(result == false and index:GetSession() == "B")
    assert(read("porkland").secondary_transition.status == "prepared")

    index.world_index_states, index.world_index_state = nil, nil
    index.worldindex:CommitPreparedSecondaryTransition("r5", "porkland", function(ok) result = ok end)
    assert(result == true and dispatches == 2)
    assert(read("porkland").secondary_transition.status == "committed")
end)

test("interrupted secondary commit is restored before it is dispatched again", function()
    store(active(), true)
    local sessions_seen = {}
    require("modules/secondary_transition").Register("InterruptedCommit", {
        needs_target = false,
        GetTarget = function() return nil, "porkland" end,
        Dispatch = function(target_index, opts, transaction, cb)
            sessions_seen[#sessions_seen + 1] = target_index:GetSession()
            cb(true)
        end,
    })
    local result
    index.worldindex:PrepareSecondaryTransition("InterruptedCommit", { request_id = "r6" }, function(ok) result = ok end)
    assert(result == true)
    local state = read("porkland")
    state.secondary_transition.status = "committing"
    store(state, true)
    index.session_id = "PARTIAL"

    index.worldindex:CommitPreparedSecondaryTransition("r6", "porkland", function(ok) result = ok end)
    assert(result == true and sessions_seen[1] == "B")
    assert(read("porkland").secondary_transition.status == "committed")
end)

test("vanilla ShardIndex integration captures checkpoints and blocks failed loads", function()
    dofile(vanilla_scripts.."/class.lua")
    dofile(vanilla_scripts.."/shardindex.lua")
    local sim_postinit
    AddSimPostInit = function(fn) sim_postinit = fn end
    SpawnSaveRecord = noop
    ToolUtil = { GetUpvalue = function() return function() return 0, 0, 0 end end }
    WorldRollbackFromSim = noop
    known_assert = assert
    function TheSim:HasEnoughFreeDiskSpace() return true end
    function TheNet:GetSessionIdentifier() return TheWorld.meta.session_identifier end
    function TheNet:GetWorldSessionFileInClusterSlot() return "world_mock" end
    function TheNet:TryDefaultEncodeUserPath() return false end
    function SerializeWorldSession(data, session_id, cb)
        local success, map = true, data.map
        if type(map) == "string" then
            success, map = RunInSandboxSafe(map)
        end
        assert(success)
        disk[key(1, "Master", "world_mock")] = DataDumper({
            map = map, meta = { session_identifier = session_id },
        })
        current_snapshot = current_snapshot + 1
        cb()
    end
    function SaveGame(isshutdown, cb)
        SerializeWorldSession({ map = DataDumper({ topology = {}, persistdata = {} }) }, "B", cb)
    end
    dofile("postinit/shardworldindex.lua")
    dofile("postinit/shardindex.lua")
    local patched = ShardIndex()
    patched.slot, patched.shard, patched.session_id = 1, "Master", "B"
    patched.valid, patched.ismaster = true, true
    index, ShardGameIndex = patched, patched
    local state = store(active(), true)
    local saved
    patched:SaveCurrent(function(ok) saved = ok ~= false end)
    assert(saved == true and state.rollback_checkpoint_saved == true)
    patched:GetSaveData(function(savedata)
        assert(savedata.map.persistdata.world_index_checkpoint.state.file_id == "porkland")
    end)
    assert(type(sim_postinit) == "function")
    sim_postinit()
    patched:Save()
    disk[key(1, "Master", "shardindex_manifest")] = "invalid lua!"
    -- The native continuation ignores callback arguments; IsEmpty must still stop it.
    local continued
    patched:LoadShardInSlot(1, "Master", function() continued = true end)
    assert(continued and patched.world_index_load_failed)
    assert(not pcall(function() patched:IsEmpty() end))
    assert(not pcall(function() patched:GetSaveData(noop) end))
    patched:Save(function(ok) saved = ok end)
    assert(saved == false)
end)

test("instance and explicit-index restart calls preserve transition parameters", function()
    index.worldindex = ShardWorldIndex(index)
    local original_restart = shards.RestartCurrentSlotAfterShardRPC
    local calls = {}
    shards.RestartCurrentSlotAfterShardRPC = function(target_index, params)
        calls[#calls + 1] = { index = target_index, params = params }
        return true
    end
    local params = {
        adventure_transition = "begin",
        world_index_transition = "begin",
        world_index_file_id = "adventure",
        secondary_transition_retry_id = "retry",
    }
    index.worldindex:RestartCurrentSlotAfterShardRPC(params)
    ShardWorldIndex:RestartCurrentSlotAfterShardRPC(index, params)
    index.worldindex:RestartCurrentSlotAfterShardRPC()
    shards.RestartCurrentSlotAfterShardRPC = original_restart
    assert(calls[1].index == index and calls[1].params == params)
    assert(calls[2].index == index and calls[2].params == params)
    assert(calls[3].index == index and calls[3].params == nil)
end)

test("player injection facade preserves session id and optional argument positions", function()
    index.worldindex = ShardWorldIndex(index)
    local players = require("modules/players")
    local original_inject = players.InjectPlayerSessionsIntoExistingWorld
    local calls = {}
    players.InjectPlayerSessionsIntoExistingWorld = function(...)
        calls[#calls + 1] = { count = select("#", ...), ... }
        return "forwarded"
    end
    local sessions = { { userid = "late_joiner" } }
    local positions = { late_joiner = { x = 1, y = 0, z = 2 } }
    local callback = function() end
    local result = index.worldindex:InjectPlayerSessionsIntoExistingWorld(
        "HOME", sessions, callback, nil, positions, "adventure_portal"
    )
    ShardWorldIndex:InjectPlayerSessionsIntoExistingWorld(
        index, "HOME", sessions, callback, nil, positions, "adventure_portal"
    )
    players.InjectPlayerSessionsIntoExistingWorld = original_inject
    assert(result == "forwarded")
    for _, call in ipairs(calls) do
        assert(call.count == 7 and call[1] == index and call[2] == "HOME")
        assert(call[3] == sessions and call[4] == callback and call[5] == nil)
        assert(call[6] == positions and call[7] == "adventure_portal")
    end
end)

local adventure_mod = os.getenv("DST_ADVENTURE_MOD") or "../Adventure-Mode"
local adventure_source = io.open(adventure_mod.."/postinit/shardadventureindex.lua", "r")
if adventure_source ~= nil then
    adventure_source:close()
    test("adventure start survives reload and finishes native world generation", function()
        local original_levels = package.loaded["map/levels"]
        local function level(id)
            return {
                id = id, worldgen_preset = id, settings_preset = id,
                location = "forest", overrides = { is_adventure = true },
            }
        end
        package.loaded["map/levels"] = {
            GetDataForWorldGenID = level,
            GetDataForSettingsID = level,
        }
        function TheWorld:HasTag(tag) return tag == "forest" end
        index.worldindex = ShardWorldIndex(index)
        dofile(adventure_mod.."/postinit/shardadventureindex.lua")
        dofile(adventure_mod.."/postinit/shardindex.lua")
        index.adventure = ShardAdventureIndex(index)
        local restart_params
        StartNextInstance = function(params) restart_params = copy(params) end
        local result
        assert(index.adventure:Start({
            level_sequence = { "WINTER", "RAINY", "DARKNESS", "ENDING" },
        }, function(ok) result = ok end))
        local i = 1
        while i <= #tasks do
            local task = tasks[i]
            i = i + 1
            if not task.cancelled then task.fn() end
        end
        assert(result == true and restart_params ~= nil)
        assert(restart_params.world_index_transition == "begin")
        assert(restart_params.world_index_file_id == "adventure")
        assert(restart_params.adventure_transition == "begin")
        Settings = restart_params
        TheWorld = nil
        local reloaded = ShardIndex()
        ShardGameIndex = reloaded
        local loaded
        reloaded:LoadShardInSlot(1, "Master", function(ok) loaded = ok ~= false end)
        local run = reloaded.adventure:GetState()
        assert(loaded == true and run ~= nil and run.active == true)
        assert(run.current_preset == "WINTER" and run.current_session_id == nil)
        assert(run.home.session_id == "B" and reloaded:IsEmpty())
        local generated
        reloaded:OnGenerateNewWorld({
            meta = { session_identifier = "ADVENTURE" },
            map = { prefab = "forest", topology = { overrides = { is_adventure = true } } },
        }, "", "ADVENTURE", function(ok) generated = ok ~= false end)
        run = reloaded.adventure:GetState()
        assert(generated == true and run.active == true)
        assert(run.current_session_id == "ADVENTURE" and run.current_preset == "WINTER")
        assert(run.home.session_id == "B" and reloaded:GetSession() == "ADVENTURE")
        assert(not reloaded:IsEmpty() and #deleted == 0)
        package.loaded["map/levels"] = original_levels
    end)
else
    print("SKIP adventure integration: sibling Adventure-Mode mod is unavailable")
end

print("save_management_regression: "..count.." tests passed")
