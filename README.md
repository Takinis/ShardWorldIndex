# ShardWorldIndex

`ShardWorldIndex` provides shard-aware world switching for DST server mods.
It includes the shared Hamlet secondary-world generation data and the Porkland
world entrance used by the existing world-switching workflow.

## Quick Start

### 1. Add the dependency

Add the dependency in the consuming mod's `modinfo.lua`.

```lua
mod_dependencies =
{
    {
        ["ShardWorldIndex"] = true,
    },
}
```

### 2. Register worldgen presets

The consuming mod remains responsible for its map content. Register its levels,
tasks, rooms, start locations, and other worldgen data from `modworldgenmain.lua`.

```lua
AddLevel(LEVELTYPE.SURVIVAL, {
    id = "MY_WORLD",
    name = "MY_WORLD",
    desc = "MY_WORLD",
    location = "forest",
    version = 4,
    overrides = {
        task_set = "MY_WORLD_TASKSET",
        start_location = "MyWorldStart",
    },
})
```

`AddLevel` creates worldgen and settings presets with the same ID. A mod may also
register those presets separately.

### 3. Register the switchable world

Call `GLOBAL.RegisterWorld` from the consuming mod's
`modmain.lua`. This API is available during mod initialization.

```lua
local ok, result = GLOBAL.RegisterWorld({
    id = "my_world",
    label = "My World",
    aliases = { "myworld" },
    worldgen_preset = "MY_WORLD",
    settings_preset = "MY_WORLD",
})

if not ok then
    print("[My Mod] Failed to register world: "..tostring(result))
end
```

The registration ID is also used as the default sidecar file ID. The secondary
shard receives `<id>_secondary`, so different registered worlds keep independent
master and secondary sessions.

When the world needs a custom secondary level, add:

```lua
secondary = {
    worldgen_preset = "MY_WORLD_CAVES",
    settings_preset = "MY_WORLD_CAVES",
    world_type = "cave",
    location = "cave",
},
```

Without this field, the API uses a small DST cave as the secondary level.

### 4. Switch worlds

Call the API from authoritative shard server code.

```lua
GLOBAL.SwitchWorld("my_world", {
    reason = "my_portal",
}, function(success)
    print("[My Mod] World switch completed:", success)
end)
```

`SwitchWorld` starts a world index when none is active and advances the active
world index otherwise. It also moves players out of secondary shards before the
transition.

`GLOBAL.SwitchWorld` and the `RequestWorld*` instance methods may also be called
from an authoritative secondary shard. The request is forwarded to the master
shard, which validates and coordinates the existing two-phase transition.

Return to the stored parent world with:

```lua
local worldindex = GLOBAL.ShardGameIndex.worldindex
worldindex:ReturnFromWorldIndex("my_portal_return")
```

The console command also accepts registered IDs and aliases:

```lua
c_switchworld("my_world")
```

## World Definition

Supported registration fields:

| Field | Description |
| --- | --- |
| `id` | Required stable world ID. |
| `label` | Display name retained as registry metadata. |
| `aliases` | Additional IDs accepted by registry lookups and `SwitchWorld`. |
| `worldgen_preset` | Master-shard worldgen preset. |
| `settings_preset` | Master-shard settings preset. |
| `overrides` | Additional master-shard world overrides. |
| `level` | Master level string or table. Replaces the top-level preset fields. |
| `master` | Explicit master level string or table. |
| `secondary` | Optional default secondary level string or table. |
| `shards` | Optional level table keyed by shard ID. |
| `file_id` | Optional master sidecar ID. Defaults to `id`. |
| `secondary_file_id` | Optional secondary sidecar ID. Defaults to `<file_id>_secondary`. |
| `world_type` | Optional custom runtime world type. |
| `world_type_aliases` | Optional aliases used when resolving a custom world type. |
| `world_tags` | Optional world tags used to detect a custom runtime world type. |
| `reuse_existing` | Reuse the previously generated session. Defaults to `true`. |
| `force_players_to_master` | Move secondary-shard players before switching. Defaults to `true`. |
| `target` | Advanced complete target table. |

Different registered presets may use the same base `location`, such as
`location = "forest"`. Preset IDs and sidecar IDs distinguish their sessions.

Registry queries:

```lua
local definition = GLOBAL.GetRegisteredWorld("my_world")
local definitions = GLOBAL.GetRegisteredWorlds()
```

## Instance API

Other mods can access the current instance through
`GLOBAL.ShardGameIndex.worldindex`.

- `RegisterWorld(definition)` or `RegisterWorld(id, definition)`
- `GetRegisteredWorld(id)`
- `GetRegisteredWorlds()`
- `BuildWorldSwitchOptions(id, opts)`
- `SwitchWorld(id, opts, callback)`
- `RequestWorldSwitch(id, opts, callback)`
- `RequestWorldDestination(world_type, opts, callback)`
- `RequestWorldReturn(reason, callback)`
- `RequestForwardedTransition(operation, opts, callback)`
- `RegisterForwardedTransitionHandler(operation, handler)`
- `GetState(file_id)`
- `StartWorldIndex(opts, callback)`
- `AdvanceWorldIndex(opts, callback)`
- `ReturnFromWorldIndex(reason, callback)`
- `SuspendActiveWorldIndex(reason, callback)`
- `ResumeSuspendedWorldIndex(state, callback)`
- `RestoreParentWorldIndex(state, callback)`
- `RegisterWorldIndexFileID(file_id, secondary_file_id)`
- `RegisterSecondaryTransitionHandler(operation, handler)`

The lower-level methods remain available for integrations that build target
tables dynamically.
