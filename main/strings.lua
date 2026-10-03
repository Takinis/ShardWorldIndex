local LoadPOFile = LoadPOFile
GLOBAL.setfenv(1, GLOBAL)

STRINGS.NAMES.PORKLAND_ENTRANCE = "Skyworthy"
STRINGS.RECIPE_DESC.PORKLAND_ENTRANCE = "Hop on. What could possibly go wrong?"
STRINGS.UI.PORKLAND_ENTRANCE =
{
    TITLE = "Travel to another world?",
    BODY = "Where would you like to travel to?",
    FOREST = "Survival",
    SHIPWRECKED = "Shipwrecked",
    PORKLAND = "Hamlet",
    CANCEL = "Cancel",
    UNAVAILABLE = "World switching is unavailable.",
    MASTER_ONLY = "The Skyworthy can only be used in the Master world.",
    MANAGED_EXTERNALLY = "The current world transition is managed by another mod.",
    ALREADY_THERE = "You are already in that world.",
    IN_PROGRESS = "A world switch is already in progress.",
    TRANSITION_FAILED = "Unable to switch worlds. Try again.",
}

local locale = LOC.GetLocaleCode()
if locale == "zh" or locale == "zhr" or locale == "zht" then
    LoadPOFile("strings/chinese.po", locale)
    TranslateStringTable(STRINGS)
end
