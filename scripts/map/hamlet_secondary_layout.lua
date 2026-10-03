GLOBAL.setfenv(1, GLOBAL)
require("constants")

local StaticLayout = require("map/static_layout")
local AllLayouts = require("map/layouts").Layouts

AllLayouts["hamlet_secondary_start"] = StaticLayout.Get("map/static_layouts/hamlet_secondary_start", {
    start_mask = PLACE_MASK.IGNORE_IMPASSABLE_BARREN_RESERVED,
    fill_mask = PLACE_MASK.IGNORE_IMPASSABLE_BARREN_RESERVED,
    layout_position = LAYOUT_POSITION.CENTER,
})
