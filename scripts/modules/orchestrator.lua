return function(Class)
    local players = require("modules/players")
    local shards = require("modules/shards")
    local transition = require("modules/transition")
    local world = require("modules/world")

    local function build_secondary_opts(opts, state, include_fallback)
        local secondary_opts =
        {
            kind = state ~= nil and state.kind or opts.kind,
            reason = opts.reason,
            target = opts.target or opts.world or opts.level or opts.current_preset,
            file_id = opts.file_id,
            reuse_existing = opts.reuse_existing,
            keep_session = opts.keep_session,
            collect_player_sessions = false,
        }
        if include_fallback then
            secondary_opts.fallback_player_sessions = false
        end
        return secondary_opts
    end

    local function save_before_transition(index, opts, next_step, cb)
        if TheWorld ~= nil and TheWorld.ismastersim then
            if opts.force_players_to_master and opts.force_players_to_master_modname ~= nil then
                shards.SendForcePlayersToMasterRPC(
                    opts.force_players_to_master_modname,
                    opts.force_players_to_master_rpcname
                )
            end
            shards.WaitForSecondaryShardPlayersEmpty(function(players_ready)
                if players_ready then
                    if opts.save_current == false then
                        players.SavePlayers()
                        next_step()
                    else
                        index:SaveCurrent(next_step)
                    end
                elseif opts.save_current_on_wait_failure then
                    index:SaveCurrent(function()
                        cb(false, "save")
                    end)
                else
                    cb(false, "save")
                end
            end, opts.secondary_shard_wait_timeout, opts.secondary_shard_wait_poll_interval)
            return
        end

        players.SavePlayers()
        next_step()
    end

    function Class:RunSecondaryWorldIndexTransition(index, opts, local_transition, cb)
        index, opts, local_transition, cb = resolve_index_args(self, index, opts, local_transition, cb)
        cb = cb or noop
        opts = opts or {}
        if index == nil or type(opts.secondary_operation) ~= "string" or
            opts.secondary_operation == "" or type(local_transition) ~= "function" then
            cb(false, "validate")
            return false
        end

        local completed = false
        local function finish(success, phase, request, ...)
            if completed then
                return
            end
            completed = true
            cb(success == true, phase, request, ...)
        end

        local function after_save()
            if type(opts.before_request) == "function" then
                opts.before_request()
            end

            local secondary_data = type(opts.secondary_data) == "function" and
                opts.secondary_data(opts) or opts.secondary_data
            shards.RequestSecondaryWorldIndex(
                opts.secondary_operation,
                secondary_data or {},
                function(secondary_ready, request)
                    if not secondary_ready then
                        print("[Shard World Index] Secondary shards did not prepare the target; Master will not change worlds.")
                        finish(false, "prepare", request)
                        return
                    end

                    local local_completed = false
                    local_transition(function(success, ...)
                        if local_completed then
                            return
                        end
                        local_completed = true
                        if not success then
                            shards.AbortSecondaryWorldIndex(request)
                            finish(false, "local", request, ...)
                            return
                        end

                        local local_results = { ... }
                        shards.CommitSecondaryWorldIndex(request, function(committed)
                            finish(committed == true, "commit", request, unpack(local_results))
                        end, opts.secondary_shard_wait_timeout)
                    end, request)
                end,
                opts.secondary_prepare_timeout,
                opts.rpc_namespace
            )
        end

        save_before_transition(index, opts, after_save, finish)
        return true
    end

    local function run_world_transition(self, index, opts, spec, cb)
        return self:RunSecondaryWorldIndexTransition(index,
        {
            secondary_operation = spec.secondary_operation,
            secondary_data = function()
                return build_secondary_opts(opts, spec.state, spec.include_fallback)
            end,
            secondary_shard_wait_timeout = opts.secondary_shard_wait_timeout,
            secondary_shard_wait_poll_interval = opts.secondary_shard_wait_poll_interval,
            force_players_to_master = spec.force_players,
            force_players_to_master_modname = opts.force_players_to_master_modname,
            force_players_to_master_rpcname = opts.force_players_to_master_rpcname,
            before_request = function()
                if spec.collect_player_sessions and
                    opts.player_sessions == nil and opts.collect_player_sessions ~= false then
                    opts.player_sessions = players.CollectPlayerSessions()
                end
            end,
        }, function(done)
            self[spec.local_method](self, index, opts, done)
        end, function(success)
            if success then
                local state = get_world_index_state(index)
                shards.RestartCurrentSlotAfterShardRPC(index,
                {
                    world_index_transition = opts.reason or spec.default_reason,
                    world_index_file_id = state ~= nil and state.file_id or opts.file_id,
                })
            end
            cb(success == true)
        end)
    end

    function Class:StartWorldIndex(index, opts, cb)
        index, opts, cb = resolve_index_args(self, index, opts, cb)
        cb = cb or noop
        if index == nil then
            cb(false)
            return false
        end
        if TheShard ~= nil and not shards.IsMasterShard() then
            print("[Shard World Index] StartWorldIndex must be called on the master shard.")
            cb(false)
            return false
        end

        opts = opts or {}
        local target = transition.GetTargetFromOpts(opts)
        if target ~= nil and
            (reject_unavailable_world_target(index, target, opts.allow_unknown_world_type) or
            reject_current_world_target(index, target, opts.allow_current_world_target)) then
            cb(false)
            return false
        end

        run_world_transition(self, index, opts,
        {
            secondary_operation = "BeginSecondaryWorldIndex",
            local_method = "BeginWorldIndex",
            default_reason = "begin",
            collect_player_sessions = true,
            include_fallback = true,
            force_players = true,
        }, cb)
        return true
    end

    function Class:AdvanceWorldIndex(index, opts, cb)
        index, opts, cb = resolve_index_args(self, index, opts, cb)
        cb = cb or noop
        if index == nil or not self:IsActive(index) then
            cb(false)
            return false
        end
        if TheShard ~= nil and not shards.IsMasterShard() then
            print("[Shard World Index] AdvanceWorldIndex must be called on the master shard.")
            cb(false)
            return false
        end

        opts = opts or {}
        local state = get_world_index_state(index)
        local target = transition.GetTargetFromOpts(opts, state)
        if target == nil and opts.chapter ~= nil and type(state.level_sequence) == "table" then
            target = transition.NormalizeTarget(
                world.GetLevelForShard(state.level_sequence[opts.chapter], shards.GetIndexShard(index))
            )
        end
        if target ~= nil and
            (reject_unavailable_world_target(index, target,
                opts.allow_unknown_world_type == true or state.allow_unknown_world_type == true) or
            reject_current_world_target(index, target,
                opts.allow_current_world_target == true or state.allow_current_world_target == true)) then
            cb(false)
            return false
        end

        run_world_transition(self, index, opts,
        {
            secondary_operation = "AdvanceSecondaryWorldIndex",
            local_method = "QueueNextWorld",
            default_reason = "advance",
            state = state,
            force_players = true,
        }, cb)
        return true
    end

    function Class:ReturnFromWorldIndex(index, reason, cb)
        index, reason, cb = resolve_index_args(self, index, reason, cb)
        cb = cb or noop
        if index == nil or not self:IsActive(index) then
            cb(false)
            return false
        end

        return self:RunSecondaryWorldIndexTransition(index,
        {
            secondary_operation = "ReturnSecondaryWorldIndex",
            secondary_data =
            {
                reason = reason or "return",
            },
        }, function(done)
            local player_sessions = players.CollectPlayerSessions()
            self:ReturnToStoredWorld(index, reason or "return", done, player_sessions, { defer_cleanup = true })
        end, function(success, phase)
            if success then
                finalize_deferred_return(index, get_world_index_state(index), function(finalized)
                    if not finalized then
                        print("[Shard World Index] Deferred return cleanup will resume after restart.")
                    end
                    shards.RestartCurrentSlotAfterShardRPC(index, {
                        world_index_transition = reason or "return",
                    })
                    cb(true)
                end)
            elseif phase == "commit" then
                rollback_deferred_return(index, get_world_index_state(index), function()
                    cb(false)
                end)
            else
                cb(false)
            end
        end)
    end
end
