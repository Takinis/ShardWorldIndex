local serial = 0

local function next_revision(state)
    return math.floor(tonumber(state ~= nil and state.revision or nil) or 0) + 1
end

local function next_epoch(state)
    local epoch = state ~= nil and state.transaction_epoch or nil
    return math.floor(tonumber(epoch) or 0) + 1
end

local function make_id(opts, epoch)
    serial = serial + 1
    return table.concat({
        tostring(opts.operation or "world_index"),
        tostring(epoch),
        tostring(os.time()),
        tostring(serial),
        tostring(opts.file_id or "world"),
    }, ":")
end

local function normalize_phase(phase)
    if phase == "intent" or phase == "prepared" or phase == "committing" or
        phase == "committed" or phase == "finalize_pending" or phase == "finalized" or
        phase == "aborted" then
        return phase
    end
    return nil
end

local function begin(state, opts)
    if type(state) ~= "table" then
        return nil
    end

    opts = opts or {}
    local epoch = tonumber(opts.epoch) or next_epoch(state)
    local transaction =
    {
        id = opts.id or make_id(opts, epoch),
        epoch = epoch,
        revision = tonumber(opts.revision) or next_revision(state),
        operation = opts.operation or state.reason or "world_index",
        phase = normalize_phase(opts.phase) or "intent",
        updated_at = os.time(),
    }
    state.transaction = transaction
    state.transaction_epoch = math.max(tonumber(state.transaction_epoch) or 0, epoch)
    state.revision = math.max(tonumber(state.revision) or 0, transaction.revision)
    state.updated_at = transaction.updated_at
    return transaction
end

local function ensure(state, opts)
    if type(state) ~= "table" then
        return nil
    end

    opts = opts or {}
    local current = type(state.transaction) == "table" and state.transaction or {}
    if current.id == nil or current.id == "" then
        current.id = make_id(opts, tonumber(current.epoch) or next_epoch(state))
    end
    if current.epoch == nil then
        current.epoch = next_epoch(state)
    end
    if current.revision == nil then
        current.revision = next_revision(state)
    end
    current.operation = current.operation or opts.operation or state.reason or "world_index"
    current.phase = normalize_phase(current.phase) or opts.phase or "intent"
    current.updated_at = os.time()

    state.transaction = current
    state.transaction_epoch = math.max(
        tonumber(state.transaction_epoch) or 0,
        tonumber(current.epoch) or 0
    )
    state.revision = math.max(
        tonumber(state.revision) or 0,
        tonumber(current.revision) or 0
    )
    return current
end

local function touch(state)
    if type(state) ~= "table" then
        return nil
    end

    local current = ensure(state)
    local revision = next_revision(state)
    current.revision = revision
    state.revision = revision
    current.updated_at = os.time()
    state.updated_at = current.updated_at
    return current
end

local function set_phase(state, phase)
    if type(state) ~= "table" then
        return nil
    end

    local current = ensure(state)
    current.phase = normalize_phase(phase) or current.phase
    touch(state)
    return current
end

local function get_epoch(state)
    local current = state ~= nil and state.transaction or nil
    return tonumber(current ~= nil and current.epoch or state ~= nil and state.transaction_epoch or nil) or 0
end

local function get_updated_at(state)
    local current = state ~= nil and state.transaction or nil
    return tonumber(current ~= nil and current.updated_at or state ~= nil and state.updated_at or nil) or 0
end

local function get_revision(state)
    local current = state ~= nil and state.transaction or nil
    return tonumber(current ~= nil and current.revision or state ~= nil and state.revision or nil) or 0
end

local function get_phase(state)
    local current = state ~= nil and state.transaction or nil
    return current ~= nil and normalize_phase(current.phase) or nil
end

local function is_newer(left, right)
    local left_epoch = get_epoch(left)
    local right_epoch = get_epoch(right)
    if left_epoch ~= right_epoch then
        return left_epoch > right_epoch
    end

    local left_revision = get_revision(left)
    local right_revision = get_revision(right)
    if left_revision ~= right_revision then
        return left_revision > right_revision
    end

    local left_updated_at = get_updated_at(left)
    local right_updated_at = get_updated_at(right)
    if left_updated_at ~= right_updated_at then
        return left_updated_at > right_updated_at
    end

    return tostring(left ~= nil and left.file_id or "") >
        tostring(right ~= nil and right.file_id or "")
end

local function has_committed(state)
    local phase = get_phase(state)
    return phase == "committed" or phase == "finalize_pending" or phase == "finalized"
end

return
{
    Begin = begin,
    Ensure = ensure,
    Touch = touch,
    SetPhase = set_phase,
    GetEpoch = get_epoch,
    GetRevision = get_revision,
    GetUpdatedAt = get_updated_at,
    GetPhase = get_phase,
    IsNewer = is_newer,
    HasCommitted = has_committed,
}
