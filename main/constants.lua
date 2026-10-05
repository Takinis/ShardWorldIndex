GLOBAL.RPC_NAMESPACE = "ShardWorldIndex"
GLOBAL.WORLDGENOVERRIDE_FILE = "../worldgenoverride.lua"

GLOBAL.SECONDARY_SHARD_WAIT_TIMEOUT = 30
GLOBAL.SECONDARY_SHARD_WAIT_POLL_INTERVAL = 0.5
GLOBAL.SECONDARY_SHARD_SETTLE_DELAY = 0.25
GLOBAL.FORWARDED_TRANSITION_TIMEOUT = 150

GLOBAL.WORLD_INDEX_KNOWN_FILE_IDS =
{
    Master =
    {
        "forest",
        "shipwrecked",
        "porkland",
    },
    Caves =
    {
        "caves",
        "volcano",
    },
}

GLOBAL.SECONDARY_WORLD_INDEX_FILE_IDS =
{
    forest = "caves",
    cave = "caves",
    caves = "caves",
    shipwrecked = "volcano",
    volcano = "volcano",
    porkland = "caves",
}

GLOBAL.WORLD_INDEX_WORLD_ALIASES =
{
    dst = "forest",
    forest = "forest",
    cave = "cave",
    caves = "cave",
    sw = "shipwrecked",
    shipwrecked = "shipwrecked",
    volcano = "volcano",
    hamlet = "porkland",
    porkland = "porkland",
}

GLOBAL.PORKLAND_ENTRANCE_DESTINATIONS =
{
    forest = true,
    shipwrecked = true,
    porkland = true,
}
