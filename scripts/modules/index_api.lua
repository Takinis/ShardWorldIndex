return function(Class)
    local players = require("modules/players")
    local shards = require("modules/shards")
    local world = require("modules/world")
    local direct = {
        Noop = noop,
        DeepCopy = deepcopy_safe,
        IsMasterShard = shards.IsMasterShard,
        GetRuntimeWorldType = world.GetRuntimeWorldType,
        GetReturnPosition = get_return_position,
        SavePlayers = players.SavePlayers,
        CollectPlayerSessions = players.CollectPlayerSessions,
        GetCharacterOnlySessions = players.GetCharacterOnlySessions,
        SessionsToUseridMap = players.SessionsToUseridMap,
        SessionListToMap = players.SessionListToMap,
        MergeSessionLists = players.MergeSessionLists,
        GetPlayerSaveSession = players.GetPlayerSaveSession,
        ForceLocalPlayersToMaster = shards.ForceLocalPlayersToMaster,
        SendForcePlayersToMasterRPC = shards.SendForcePlayersToMasterRPC,
        SendShardRPC = shards.SendShardRPC,
        SendRPCToOtherSecondaryShards = shards.SendRPCToOtherSecondaryShards,
        RequestSecondaryWorldIndex = shards.RequestSecondaryWorldIndex,
        CommitSecondaryWorldIndex = shards.CommitSecondaryWorldIndex,
        AbortSecondaryWorldIndex = shards.AbortSecondaryWorldIndex,
        HandleSecondaryWorldIndexReply = shards.HandleSecondaryWorldIndexReply,
        SendRPCToMasterShard = shards.SendRPCToMasterShard,
        GetSecondaryShardPlayerCount = shards.GetSecondaryShardPlayerCount,
        GetSecondaryShardPlayerCounts = shards.GetSecondaryShardPlayerCounts,
        WaitForSecondaryShardPlayersEmpty = shards.WaitForSecondaryShardPlayersEmpty,
        GetLevelForShard = function(level, shardid)
            return world.GetLevelForShard(level, shardid)
        end,
    }
    local indexed = {
        GetSlotAndShard = get_slot_and_shard,
        GetIndexShard = shards.GetIndexShard,
        ReadWorldgenOverrideRaw = read_worldgenoverride_raw,
        RestoreWorldGenOverride = restore_worldgenoverride,
        WriteLevelWorldGenOverride = world.WriteLevelWorldGenOverride,
        InjectPlayerSessionsIntoWorld = players.InjectPlayerSessionsIntoWorld,
        InjectPlayerSessionsIntoExistingWorld = players.InjectPlayerSessionsIntoExistingWorld,
        WorldSessionExists = players.WorldSessionExists,
        RestartCurrentSlotAfterShardRPC = shards.RestartCurrentSlotAfterShardRPC,
    }

    for name, fn in pairs(direct) do
        local method = fn
        Class[name] = function(_, ...)
            return method(...)
        end
    end
    for name, fn in pairs(indexed) do
        local method = fn
        Class[name] = function(self, ...)
            return method(resolve_index_args(self, ...))
        end
    end

    Class.RegisterSecondaryTransitionHandler = function(_, operation, handler)
        if type(operation) ~= "string" or operation == "" or type(handler) ~= "table" then
            return false
        end
        register_secondary_transition_handler(operation, handler)
        return true
    end
    Class.IsSecondaryWorldIndexRequestPending = function()
        return shards.IsSecondaryWorldIndexRequestPending()
    end
    Class.PersistPendingSecondaryFinalize = function(self, request, cb)
        return shards.PersistPendingSecondaryFinalize(self.index, request, cb)
    end
    Class.CompletePendingSecondaryFinalize = function(self, request_id, cb)
        return shards.CompletePendingSecondaryFinalize(self.index, request_id, cb)
    end
    Class.RetryPendingSecondaryFinalize = function(self)
        return shards.RetryPendingSecondaryFinalize(self.index)
    end
end
