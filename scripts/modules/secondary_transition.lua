local handlers = {}
local M = {}

function M.Register(operation, handler)
    if type(operation) ~= "string" or operation == "" or type(handler) ~= "table" then
        return false
    end
    handlers[operation] = handler
    return true
end

function M.Install(Class)
    local index_state = require("modules/index_state")
    local manifest = require("modules/manifest")
    local shards = require("modules/shards")
    local state_store = require("modules/state_store")
    local storage = require("modules/storage")
    local transaction_api = require("modules/transaction")
    local transition = require("modules/transition")
    local world = require("modules/world")
    local world_switch = require("modules/world_switch")
    local restore
    local finalize

    local function get_target(index, operation, opts, active_state)
        local target = nil
        local file_id = nil
        local handler = handlers[operation]

        if handler ~= nil and type(handler.GetTarget) == "function" then
            target, file_id = handler.GetTarget(index, opts, active_state)
        elseif operation == "BeginSecondaryWorldIndex" or operation == "AdvanceSecondaryWorldIndex" then
            local shardid = shards.GetIndexShard(index)
            target = transition.GetTargetForShard(
                transition.GetTargetFromOpts(opts, active_state),
                shardid
            )
            file_id = transition.GetTargetFileID(
                target,
                active_state ~= nil and active_state.file_id or opts.file_id,
                shardid
            )
        elseif operation == "ReturnSecondaryWorldIndex" then
            file_id = active_state ~= nil and active_state.file_id or opts.file_id
        end

        return target, manifest.NormalizeFileID(file_id)
    end

    local function validate(index, operation, opts, active_state, target)
        local handler = handlers[operation]
        local is_begin = operation == "BeginSecondaryWorldIndex" or handler ~= nil and handler.is_begin == true
        local allows_active = handler ~= nil and handler.allows_active_world_index == true
        if is_begin then
            if index:GetSession() == nil or index:GetSession() == "" then
                return false, "missing home session"
            end
            if active_state ~= nil and active_state.active and not allows_active then
                return false, "world index already active"
            end
        elseif active_state == nil or not active_state.active then
            return false, "world index is not active"
        end

        if handler ~= nil and type(handler.Validate) == "function" then
            local valid, reason = handler.Validate(index, opts, active_state, target)
            if not valid then
                return false, reason
            end
        end

        local needs_target = handler ~= nil and handler.needs_target ~= false or
            handler == nil and operation ~= "ReturnSecondaryWorldIndex"
        if needs_target and target == nil then
            return false, "missing target world"
        end
        if target ~= nil and target.type == "generated" then
            local level = transition.GetGeneratedLevel(target, shards.GetIndexShard(index))
            local valid, reason = world.ValidateWorldIndexGeneratedLevel(level)
            if not valid then
                return false, reason
            end
        elseif target ~= nil and target.type == "existing" and
            transition.NormalizeExistingTarget(index, target) == nil then
            return false, "missing existing target session"
        end
        return true
    end

    local function find(index, request_id, file_id, cb)
        state_store.FindSidecar(index, file_id, function(state)
            local transaction = state.secondary_transition
            if type(transaction) == "table" and transaction.request_id == request_id then
                return transaction
            end
            local completed = state.secondary_completed_request
            return type(completed) == "table" and completed.request_id == request_id and completed or nil
        end, cb)
    end

    local function write_prepared_marker(index, transaction, cb)
        local handler = handlers[transaction.operation]
        local opts = transaction.opts or {}
        local marker = deepcopy_safe(transaction.original_target_state) or
        {
            active = false,
            kind = opts.kind or (handler ~= nil and handler.kind or "world_index"),
            file_id = transaction.file_id,
            secondary = true,
            slot = index:GetSlot(),
            shard = shards.GetIndexShard(index),
        }
        transaction.status = "prepared"
        transaction_api.Begin(marker,
        {
            id = transaction.request_id,
            epoch = transaction.epoch,
            operation = transaction.operation,
            phase = "prepared",
            file_id = transaction.file_id,
        })
        marker.secondary_transition = transaction
        marker.updated_at = os.time()
        state_store.WriteSidecar(index, marker, function(saved)
            if saved then
                state_store.SetState(index, marker, transaction.file_id)
            end
            cb(saved == true)
        end, transaction.file_id)
    end

    local function prepare(index, operation, opts, cb)
        cb = cb or noop
        opts = deepcopy_safe(opts) or {}
        local request_id = opts.request_id
        if type(request_id) ~= "string" or request_id == "" then
            cb(false)
            return
        end

        local active_state = state_store.GetState(index)
        local target, file_id = get_target(index, operation, opts, active_state)
        state_store.ReadNamedSidecar(index, file_id, function(target_state, _, valid)
            if valid == false then
                print("[Shard World Index] Cannot prepare a transition with a corrupt sidecar.")
                cb(false)
                return
            end
            local completed = target_state ~= nil and target_state.secondary_completed_request or nil
            if completed ~= nil and completed.request_id == request_id and completed.operation == operation then
                cb(true, file_id)
                return
            end
            local existing = target_state ~= nil and target_state.secondary_transition or nil
            if type(existing) == "table" then
                if existing.request_id == request_id and existing.operation == operation then
                    cb(true, file_id)
                    return
                end

                local function retry(success)
                    if success then
                        prepare(index, operation, opts, cb)
                    else
                        cb(false)
                    end
                end
                if existing.status == "committed" then
                    finalize(index, existing.request_id, existing.file_id or file_id, retry)
                else
                    restore(index, existing, retry)
                end
                return
            end

            local valid, reason = validate(index, operation, opts, active_state, target)
            if not valid then
                print("[Shard World Index] Cannot prepare "..tostring(operation)..": "..tostring(reason)..".")
                cb(false)
                return
            end
            -- Save the source world before changing any index or override.
            index:SaveCurrent(function(saved)
                if saved == false then
                    cb(false)
                    return
                end
                storage.ReadWorldGenOverrideRaw(index, function(worldgenoverride)
                    local secondary_transaction =
                    {
                        request_id = request_id,
                        operation = operation,
                        status = "prepared",
                        epoch = transaction_api.GetEpoch(active_state) + 1,
                        file_id = file_id,
                        opts = opts,
                        original_state = deepcopy_safe(active_state),
                        original_state_file_id = active_state ~= nil and active_state.file_id or nil,
                        original_target_state = deepcopy_safe(target_state),
                        original_index = index_state.Capture(index),
                        original_worldgenoverride = worldgenoverride,
                        prepared_at = os.time(),
                    }
                    write_prepared_marker(index, secondary_transaction, function(saved)
                        cb(saved, file_id)
                    end)
                end)
            end)
        end)
    end

    restore = function(index, transaction, cb)
        cb = cb or noop
        index_state.Apply(index, transaction.original_index)
        local function restore_sidecars()
            state_store.WriteSidecar(index, transaction.original_target_state, function(target_restored)
                if not target_restored then
                    cb(false)
                    return
                end
                state_store.SetState(index, transaction.original_target_state, transaction.file_id)

                local original_file_id = transaction.original_state_file_id
                if original_file_id == nil or manifest.NormalizeFileID(original_file_id) == transaction.file_id then
                    cb(true)
                    return
                end
                state_store.WriteSidecar(index, transaction.original_state, function(state_restored)
                    if state_restored then
                        state_store.SetState(index, transaction.original_state, original_file_id)
                    end
                    cb(state_restored == true)
                end, original_file_id)
            end, transaction.file_id)
        end

        storage.RestoreWorldGenOverride(index, transaction.original_worldgenoverride, function(restored)
            if not restored then
                cb(false)
                return
            end
            index_state.Save(index, function(index_restored)
                if index_restored then
                    restore_sidecars()
                else
                    cb(false)
                end
            end)
        end)
    end

    local function dispatch(index, operation, opts, transaction, cb)
        opts.secondary_transition = deepcopy_safe(transaction)
        if operation == "BeginSecondaryWorldIndex" then
            opts.state = deepcopy_safe(opts.state) or {}
            opts.state.secondary_transition = deepcopy_safe(transaction)
            index.worldindex:BeginSecondaryWorldIndex(opts, cb)
        elseif operation == "AdvanceSecondaryWorldIndex" then
            index.worldindex:AdvanceSecondaryWorldIndex(opts, cb)
        elseif operation == "ReturnSecondaryWorldIndex" then
            index.worldindex:ReturnToStoredWorld(opts.reason or "return", cb, nil, { defer_cleanup = true })
        else
            local handler = handlers[operation]
            if handler ~= nil and type(handler.Dispatch) == "function" then
                handler.Dispatch(index, opts, transaction, cb)
            else
                cb(false)
            end
        end
    end

    -- The master persists its commit decision before sending Commit and retries until
    -- every shard acknowledges, so a failed commit must stay retryable: undo the partial
    -- dispatch, then put the prepared transaction back instead of discarding it.
    local function reset_to_prepared(index, transaction, cb)
        restore(index, transaction, function(restored)
            if not restored then
                cb(false)
                return
            end
            write_prepared_marker(index, transaction, cb)
        end)
    end

    local commit

    local function fail_commit(index, transaction, cb)
        reset_to_prepared(index, transaction, function(reset)
            if not reset then
                print("[Shard World Index] Failed to reset commit "..tostring(transaction.request_id)..
                    "; the next retry will restore it first.")
            end
            cb(false)
        end)
    end

    commit = function(index, request_id, file_id, cb)
        cb = cb or noop
        find(index, request_id, file_id, function(marker, transaction, valid)
            if valid == false or transaction == nil then
                cb(false)
                return
            end
            if transaction.status == "committed" or transaction.status == "finalized" then
                cb(true, transaction.file_id)
                return
            end
            if transaction.status == "committing" then
                -- An earlier attempt was interrupted after it started changing the index.
                reset_to_prepared(index, transaction, function(reset)
                    if reset then
                        commit(index, request_id, file_id, cb)
                    else
                        cb(false)
                    end
                end)
                return
            end

            transaction.status = "committing"
            marker.secondary_transition = transaction
            transaction_api.SetPhase(marker, "committing")
            state_store.WriteSidecar(index, marker, function(marked)
                if not marked then
                    transaction.status = "prepared"
                    cb(false)
                    return
                end
                state_store.SetState(index, marker, transaction.file_id)
                dispatch(index, transaction.operation, deepcopy_safe(transaction.opts) or {}, transaction,
                    function(success)
                        if not success then
                            fail_commit(index, transaction, cb)
                            return
                        end

                        local result_state = state_store.GetState(index, transaction.file_id)
                        if result_state == nil then
                            fail_commit(index, transaction, cb)
                            return
                        end
                        transaction.status = "committed"
                        transaction.committed_at = os.time()
                        result_state.secondary_transition = transaction
                        transaction_api.SetPhase(result_state, "committed")
                        state_store.WriteSidecar(index, result_state, function(saved)
                            if not saved then
                                transaction.status = "committing"
                                fail_commit(index, transaction, cb)
                                return
                            end
                            state_store.SetState(index, result_state, transaction.file_id)
                            cb(true, transaction.file_id)
                        end, transaction.file_id)
                    end)
            end, transaction.file_id)
        end)
    end

    local function abort(index, request_id, file_id, cb)
        cb = cb or noop
        find(index, request_id, file_id, function(_, transaction, valid)
            if valid == false then
                cb(false)
            elseif transaction == nil or transaction.status == "finalized" then
                cb(true)
            else
                restore(index, transaction, cb)
            end
        end)
    end

    finalize = function(index, request_id, file_id, cb)
        cb = cb or noop
        find(index, request_id, file_id, function(state, transaction, valid)
            if valid == false then
                cb(false, false)
                return
            end
            if transaction == nil then
                cb(true, false)
                return
            end
            if transaction.status == "finalized" then
                local runtime_session = TheWorld ~= nil and TheWorld.meta ~= nil and
                    TheWorld.meta.session_identifier or nil
                cb(true, state_store.IsPendingGeneration(state) or
                    (runtime_session ~= nil and runtime_session ~= index:GetSession()))
                return
            end
            if transaction.status ~= "committed" then
                cb(false, false)
                return
            end

            local cleanup_session_id = state.deferred_cleanup_session_id
            local function finish()
                local previous_completed = state.secondary_completed_request
                state.secondary_completed_request =
                {
                    request_id = request_id,
                    operation = transaction.operation,
                    file_id = transaction.file_id,
                    status = "finalized",
                    finalized_at = os.time(),
                }
                world_switch.FinalizeState(index, state,
                    { "deferred_return", "deferred_cleanup_session_id", "secondary_transition" },
                    cleanup_session_id,
                    function(saved)
                        if not saved then
                            state.secondary_completed_request = previous_completed
                        end
                        cb(saved, true)
                    end,
                    transaction.file_id)
            end

            if not state.active and type(state.parent_world_index_state) == "table" then
                restore_parent_world_index(index, state, function(parent_restored)
                    if parent_restored then
                        finish()
                    else
                        cb(false, true)
                    end
                end)
            else
                finish()
            end
        end)
    end

    function Class:PrepareSecondaryTransition(index, operation, opts, cb)
        index, operation, opts, cb = resolve_index_args(self, index, operation, opts, cb)
        prepare(index, operation, opts, cb)
    end

    function Class:CommitPreparedSecondaryTransition(index, request_id, file_id, cb)
        index, request_id, file_id, cb = resolve_index_args(self, index, request_id, file_id, cb)
        commit(index, request_id, file_id, cb)
    end

    function Class:AbortPreparedSecondaryTransition(index, request_id, file_id, cb)
        index, request_id, file_id, cb = resolve_index_args(self, index, request_id, file_id, cb)
        abort(index, request_id, file_id, cb)
    end

    function Class:FinalizeSecondaryTransition(index, request_id, file_id, cb)
        index, request_id, file_id, cb = resolve_index_args(self, index, request_id, file_id, cb)
        finalize(index, request_id, file_id, cb)
    end
end

return M
