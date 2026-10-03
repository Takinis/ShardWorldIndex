local NODE_TYPE = GLOBAL.NODE_TYPE

-- Keep a normal site for the start layout while leaving unpainted tiles impassable.
AddRoom("HamletSecondaryStartRoom", {
    colour = { r = 0.1, g = 0.6, b = 0.1, a = 0.8 },
    value = WORLD_TILES.IMPASSABLE,
    type = NODE_TYPE.Room,
    contents = {},
})

AddTask("HamletSecondary", {
    locks = LOCKS.NONE,
    keys_given = KEYS.NONE,
    room_choices = {
        Blank = 1,
    },
    room_bg = WORLD_TILES.IMPASSABLE,
    background_room = "Blank",
    colour = { r = 0.05, g = 0.05, b = 0.05, a = 1 },
})
