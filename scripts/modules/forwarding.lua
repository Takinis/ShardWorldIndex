return function(Class)
    local registry = require("modules/registry")
    local shards = require("modules/shards")
    local world = require("modules/world")
    local handlers = {}
    local request_serial = 0
    local pending_request = nil

    local function is_known_destination(world_type)
        world_type = world.NormalizeWorldType(world_type)
        if world_type == nil then
            return false
        end
        for _, ids in pairs(WORLD_INDEX_KNOWN_FILE_IDS or {}) do
            for _, file_id in ipairs(ids) do
                if world.NormalizeWorldType(file_id) == world_type then
                    return true
                end
            end
        end
        for _, alias_target in pairs(WORLD_INDEX_WORLD_ALIASES or {}) do
            if world.NormalizeWorldType(alias_target) == world_type then
                return true
            end
        end
        return false
    end

    local function finish_pending(request, success)
        if pending_request ~= request then
            return false
        end
        pending_request = nil
        if request.timeout_task ~= nil then
            request.timeout_task:Cancel()
            request.timeout_task = nil
        end
        request.cb(success == true)
        return true
    end

    local function get_home_world_type(state)
        local home = state ~= nil and (state.home or state.main) or nil
        return type(home) == "table" and home.world_type or nil
    end

    local function execute(self, index, operation, opts, cb)
        cb = cb or noop
        opts = deepcopy_safe(opts) or {}
        if not shards.IsMasterShard() then
            cb(false)
            return false
        end

        local handler = handlers[operation]
        if handler ~= nil then
            handler(index, opts, cb)
            return true
        end

        local state = get_world_index_state(index)
        if state ~= nil and state.active == true and state.managed_externally == true then
            cb(false)
            return false
        end

        if operation == "registered_switch" then
            local world_id = opts.world_id
            if type(world_id) ~= "string" or registry.Get(world_id) == nil then
                cb(false)
                return false
            end
            opts.world_id = nil
            return self:SwitchWorld(index, world_id, opts, cb)
        elseif operation == "destination" then
            local target_world_type = world.NormalizeWorldType(opts.target_world_type)
            if not is_known_destination(target_world_type) then
                cb(false)
                return false
            end

            opts.target_world_type = nil
            opts.target = opts.target or { type = "generated", world_type = target_world_type }
            opts.file_id = opts.file_id or target_world_type
            opts.kind = opts.kind or "world_index"
            opts.force_players_to_master_modname =
                opts.force_players_to_master_modname or RPC_NAMESPACE
            opts.force_players_to_master_rpcname =
                opts.force_players_to_master_rpcname or "ForcePlayersToMaster"

            if state ~= nil and state.active == true and opts.return_if_home == true and
                target_world_type == world.NormalizeWorldType(get_home_world_type(state)) then
                shards.SendForcePlayersToMasterRPC(RPC_NAMESPACE, "ForcePlayersToMaster")
                return self:ReturnFromWorldIndex(index, opts.reason or "return", cb)
            end
            opts.return_if_home = nil
            if state ~= nil and state.active == true then
                return self:AdvanceWorldIndex(index, opts, cb)
            end
            return self:StartWorldIndex(index, opts, cb)
        elseif operation == "return" then
            shards.SendForcePlayersToMasterRPC(RPC_NAMESPACE, "ForcePlayersToMaster")
            return self:ReturnFromWorldIndex(index, opts.reason or "return", cb)
        end

        cb(false)
        return false
    end

    function Class:RegisterForwardedTransitionHandler(operation, handler)
        if type(operation) ~= "string" or operation == "" or type(handler) ~= "function" then
            return false
        end
        handlers[operation] = handler
        return true
    end

    function Class:ExecuteForwardedTransition(index, operation, opts, cb)
        index, operation, opts, cb = resolve_index_args(self, index, operation, opts, cb)
        return execute(self, index, operation, opts, cb)
    end

    function Class:RequestForwardedTransition(index, operation, opts, cb)
        index, operation, opts, cb = resolve_index_args(self, index, operation, opts, cb)
        cb = cb or noop
        if index == nil or type(operation) ~= "string" or operation == "" then
            cb(false)
            return false
        end
        if shards.IsMasterShard() then
            return execute(self, index, operation, opts, cb)
        end
        if pending_request ~= nil or TheWorld == nil then
            cb(false)
            return false
        end

        request_serial = request_serial + 1
        local request =
        {
            id = table.concat({
                tostring(shards.GetRuntimeShardId(index)),
                tostring(os.time()),
                tostring(request_serial),
            }, ":"),
            cb = cb,
        }
        pending_request = request
        request.timeout_task = TheWorld:DoStaticTaskInTime(
            FORWARDED_TRANSITION_TIMEOUT,
            function()
                request.timeout_task = nil
                finish_pending(request, false)
            end
        )
        shards.SendRPCToMasterShard(RPC_NAMESPACE, "ForwardWorldIndexTransition",
        {
            request_id = request.id,
            operation = operation,
            opts = deepcopy_safe(opts) or {},
        })
        return true
    end

    function Class:HandleForwardedTransitionReply(index, data)
        index, data = resolve_index_args(self, index, data)
        local request = pending_request
        if request == nil or type(data) ~= "table" or data.request_id ~= request.id then
            return false
        end
        return finish_pending(request, data.success == true)
    end

    function Class:RequestWorldSwitch(index, world_id, opts, cb)
        index, world_id, opts, cb = resolve_index_args(self, index, world_id, opts, cb)
        if registry.Get(world_id) ~= nil then
            opts = deepcopy_safe(opts) or {}
            opts.world_id = world_id
            return self:RequestForwardedTransition(index, "registered_switch", opts, cb)
        end

        local world_type = type(world_id) == "string" and
            (WORLD_INDEX_WORLD_ALIASES[string.lower(world_id)] or string.lower(world_id)) or nil
        opts = deepcopy_safe(opts) or {}
        opts.target_world_type = world.NormalizeWorldType(world_type)
        return self:RequestForwardedTransition(index, "destination", opts, cb)
    end

    function Class:RequestWorldDestination(index, world_type, opts, cb)
        index, world_type, opts, cb = resolve_index_args(self, index, world_type, opts, cb)
        opts = deepcopy_safe(opts) or {}
        opts.target_world_type = world_type
        return self:RequestForwardedTransition(index, "destination", opts, cb)
    end

    function Class:RequestWorldReturn(index, reason, cb)
        index, reason, cb = resolve_index_args(self, index, reason, cb)
        return self:RequestForwardedTransition(index, "return", { reason = reason }, cb)
    end
end
