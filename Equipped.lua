-- StatSearch / Equipped.lua
-- Works out "% improvement vs what you're wearing" for each result.
-- Score = sum of the stats you're searching for (your tags). With no tags,
-- falls back to the primary stat total (Str+Agi+Sta+Int+Spi).
-- Two-slot items (rings, trinkets, one-hand weapons) compare against the
-- weaker of your two.

local _, ns = ...
local E = {}
ns.Equipped = E

-- Enum.InventoryType -> character slot ids
local SLOTS = {
    [1] = { 1 },        -- head
    [2] = { 2 },        -- neck
    [3] = { 3 },        -- shoulder
    [4] = { 4 },        -- shirt
    [5] = { 5 },        -- chest
    [20] = { 5 },       -- robe
    [6] = { 6 },        -- waist
    [7] = { 7 },        -- legs
    [8] = { 8 },        -- feet
    [9] = { 9 },        -- wrist
    [10] = { 10 },      -- hands
    [11] = { 11, 12 },  -- finger
    [12] = { 13, 14 },  -- trinket
    [16] = { 15 },      -- back
    [13] = { 16, 17 },  -- one-hand
    [21] = { 16 },      -- main hand
    [17] = { 16 },      -- two-hand
    [22] = { 17 },      -- off-hand weapon
    [14] = { 17 },      -- shield
    [23] = { 17 },      -- held in off-hand
    [15] = { 18 },      -- ranged
    [25] = { 18 },      -- thrown
    [26] = { 18 },      -- ranged (wand/gun/crossbow)
    [28] = { 18 },      -- relic
    [19] = { 19 },      -- tabard
}

local RETRIEVING = (RETRIEVING_ITEM_INFO or "Retrieving item information"):lower()
local tagsByLink = {}   -- link -> tags (session cache)
local slotTags = {}     -- slot -> tags | false (empty) ; nil = unknown yet
local waiting = {}      -- slots whose item data hasn't loaded yet
local scanTip

local function LinesForLink(link)
    local lines = {}
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local data = C_TooltipInfo.GetHyperlink(link)
        if data and data.lines then
            for _, line in ipairs(data.lines) do
                if line.leftText == nil and TooltipUtil and TooltipUtil.SurfaceArgs then
                    TooltipUtil.SurfaceArgs(line)
                end
                if line.leftText and line.leftText ~= "" then lines[#lines + 1] = line.leftText end
            end
            return lines
        end
    end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "StatSearchEquipTooltip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetHyperlink(link)
    for i = 1, scanTip:NumLines() do
        local fs = _G["StatSearchEquipTooltipTextLeft" .. i]
        local t = fs and fs:GetText()
        if t and t ~= "" then lines[#lines + 1] = t end
    end
    scanTip:Hide()
    return lines
end

-- Tags for the item in a character slot; false = empty slot; nil = not loaded yet.
local function SlotTags(slot)
    local cached = slotTags[slot]
    if cached ~= nil then return cached end
    local link = GetInventoryItemLink("player", slot)
    if not link then
        slotTags[slot] = false
        return false
    end
    local tags = tagsByLink[link]
    if not tags then
        local lines = LinesForLink(link)
        if #lines < 2 or lines[1]:lower():find(RETRIEVING, 1, true) then
            waiting[slot] = true
            return nil
        end
        tags = ns.Tags.Extract(lines)
        tagsByLink[link] = tags
    end
    slotTags[slot] = tags
    waiting[slot] = nil
    return tags
end

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local function WearingTwoHander()
    local id = GetInventoryItemID("player", 16)
    return id and select(4, GetItemInfoInstant(id)) == "INVTYPE_2HWEAPON"
end

local function Score(tags, reqs)
    if not tags then return 0 end
    if #reqs == 0 then return ns.Tags.PrimaryTotal(tags) end
    local n = 0
    for _, r in ipairs(reqs) do n = n + (tags[r.id] or 0) end
    return n
end

-- Is this an inventory type you can wear (has a character slot)?
function E.HasSlot(invType)
    return SLOTS[invType or 0] ~= nil
end

-- Equipped score for an inventory type (weaker of two slots), or nil if
-- unknown. Second value: true if that weaker slot is empty.
local function EquippedScore(invType, reqs)
    local slots = SLOTS[invType or 0]
    if not slots then return nil end
    -- Off-hand items vs someone wielding a two-hander: compare to the two-hander.
    if slots[1] == 17 or (slots[2] == 17 and not GetInventoryItemLink("player", 17)) then
        if not GetInventoryItemLink("player", 17) and WearingTwoHander() then slots = { 16 } end
    end
    local best, bestEmpty
    for _, slot in ipairs(slots) do
        local tags = SlotTags(slot)
        if tags == nil then return nil end           -- still loading
        local empty = (tags == false)
        local s = empty and 0 or Score(tags, reqs)
        if best == nil or s < best or (s == best and empty) then best, bestEmpty = s, empty end
    end
    return best, bestEmpty
end

-- Adds imprPct / imprNew / imprScore / imprEquipped / imprBasis to a result.
function E.Annotate(r, reqs)
    local e = r.e
    local eq, empty = EquippedScore(e.invType, reqs)
    if eq == nil then return end
    local mine = Score(e.tags, reqs)
    r.imprScore, r.imprEquipped = mine, eq
    r.imprBasis = (#reqs == 0) and "primary stats" or "tagged stats"
    if empty then
        r.imprNew = true -- nothing in that slot: anything you can wear beats it
    elseif eq == 0 then
        if mine > 0 then r.imprNew = true else r.imprPct = 0 end
    else
        r.imprPct = (mine - eq) / eq * 100
    end
end

-- Set of what you're wearing, keyed by itemID + (suffixed) name, so
-- "Belt of the Owl" equipped doesn't hide "Belt of the Monkey".
local equippedSet
local GetItemInfoE = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function BuildEquippedSet()
    local set, complete = {}, true
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local id = GetInventoryItemID("player", slot)
            local name = GetItemInfoE(link)
            if id and name then
                set[id .. ":" .. name:lower()] = true
            else
                complete = false
            end
        end
    end
    return set, complete
end

function E.IsEquipped(entry)
    if not equippedSet then
        local set, complete = BuildEquippedSet()
        if complete then equippedSet = set else return (set[(entry.itemID or 0) .. ":" .. (entry.name or ""):lower()]) == true end
    end
    return equippedSet[(entry.itemID or 0) .. ":" .. (entry.name or ""):lower()] == true
end

function E.Invalidate()
    wipe(slotTags)
    wipe(waiting)
    equippedSet = nil
end

ns:On("PLAYER_EQUIPMENT_CHANGED", function()
    E.Invalidate()
    if ns.Scanner then ns.Scanner.RequestRefresh() end
end)

ns:On("GET_ITEM_INFO_RECEIVED", function()
    -- an equipped item's data may have just arrived
    if next(waiting) and ns.Scanner then ns.Scanner.RequestRefresh() end
end)
