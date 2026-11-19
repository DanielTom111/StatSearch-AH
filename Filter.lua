-- StatSearch / Filter.lua
-- Captures the filters the native auction house actually sends
-- (category, level range, rarity, usable, search text) by hooking
-- C_AuctionHouse.SendBrowseQuery, then applies them to the snapshot.
-- That way Blizzard's own filter UI drives StatSearch.

local _, ns = ...
local F = {}
ns.Filter = F

F.query = nil
F.hooked = false

local QUALITY_BY_FILTER = {}
local USABLE_FILTER

local CHEST, ROBE = 5, 20

local function BuildEnums()
    local AHF = Enum and Enum.AuctionHouseFilter
    if not AHF then return end
    local map = { PoorQuality = 0, CommonQuality = 1, UncommonQuality = 2, RareQuality = 3,
                  EpicQuality = 4, LegendaryQuality = 5, ArtifactQuality = 6 }
    for k, q in pairs(map) do
        if AHF[k] ~= nil then QUALITY_BY_FILTER[AHF[k]] = q end
    end
    USABLE_FILTER = AHF.UsableOnly
end

function F.Init()
    BuildEnums()
    if not F.hooked and C_AuctionHouse and C_AuctionHouse.SendBrowseQuery then
        -- Every browse query (yours or Auctionator's).
        hooksecurefunc(C_AuctionHouse, "SendBrowseQuery", function(query)
            F.lastRaw = query
            ns.Scanner.OnBrowseQuery()
            -- Without the UI hook, guess: an empty query is a scan, anything
            -- else is you using the AH filters.
            if not F.uiHooked and not ns.Scanner.ownQuery and not F.LooksLikeScan(query) then F.Capture(query) end
        end)
        F.hooked = true
    end
    F.HookUI()
end

-- The AH frame's own method only runs for searches made in the AH UI, and
-- runs right after the C_AuctionHouse call above.
function F.HookUI()
    if F.uiHooked then return end
    local ah = AuctionHouseFrame
    if not ah or type(ah.SendBrowseQuery) ~= "function" then return end
    hooksecurefunc(ah, "SendBrowseQuery", function()
        ns.Scanner.MarkUIQuery()
        if F.lastRaw then F.Capture(F.lastRaw) end
    end)
    F.uiHooked = true
end

function F.LooksLikeScan(query)
    if type(query) ~= "table" then return true end
    local noText = (query.searchString or "") == ""
    local noClass = not query.itemClassFilters or #query.itemClassFilters == 0
    local noLevel = (query.minLevel or 0) == 0 and (query.maxLevel or 0) == 0
    return noText and noClass and noLevel
end

function F.Capture(query)
    if type(query) ~= "table" then return end
    local s = query.searchString or ""
    -- Our own "find in AH" handoff puts an item name in the search box;
    -- don't let that narrow StatSearch's results.
    if F.handoffName and s == F.handoffName then s = "" end

    local q = {
        searchString = s,
        searchLower = s:lower(),
        minLevel = query.minLevel or 0,
        maxLevel = query.maxLevel or 0,
        classFilters = {},
    }
    if type(query.filters) == "table" then
        local quals, any = {}, false
        for _, f in ipairs(query.filters) do
            local qual = QUALITY_BY_FILTER[f]
            if qual then quals[qual] = true; any = true end
            if USABLE_FILTER and f == USABLE_FILTER then q.usableOnly = true end
        end
        if any then q.qualities = quals end
    end
    if type(query.itemClassFilters) == "table" then
        for _, cf in ipairs(query.itemClassFilters) do
            q.classFilters[#q.classFilters + 1] = {
                classID = cf.classID, subClassID = cf.subClassID, inventoryType = cf.inventoryType,
            }
        end
    end
    F.query = q
    if ns.UI then ns.UI:OnFiltersChanged() end
end

local function InvMatches(want, have)
    if not want or want <= 0 then return true end
    if want == have then return true end
    if (want == CHEST and have == ROBE) or (want == ROBE and have == CHEST) then return true end
    return false
end

local function ClassMatches(cf, e)
    if cf.classID and cf.classID >= 0 and cf.classID ~= e.classID then return false end
    if cf.subClassID and cf.subClassID >= 0 and cf.subClassID ~= e.subClassID then return false end
    return InvMatches(cf.inventoryType, e.invType)
end

local EMPTY = {}
local CanUse = C_PlayerInfo and C_PlayerInfo.CanUseItem

-- Returns ok, matchedTagTotal
function F.Match(e, q, reqs, mode)
    if q then
        if q.searchLower ~= "" and not (e.name or ""):lower():find(q.searchLower, 1, true) then return false end
        local lvl = e.minLevel or 0
        if q.minLevel > 0 and lvl < q.minLevel then return false end
        if q.maxLevel > 0 and lvl > q.maxLevel then return false end
        if q.qualities and not q.qualities[e.quality or 1] then return false end
        if q.usableOnly and CanUse and not CanUse(e.itemID) then return false end
        if #q.classFilters > 0 then
            local ok = false
            for _, cf in ipairs(q.classFilters) do
                if ClassMatches(cf, e) then ok = true break end
            end
            if not ok then return false end
        end
    end

    local n = #reqs
    if n == 0 then return true, 0 end
    local tags = e.tags or EMPTY
    local score, matched = 0, 0
    for _, r in ipairs(reqs) do
        local v = tags[r.id]
        if v and (not r.min or v >= r.min) then
            score = score + v
            matched = matched + 1
        elseif mode == "AND" then
            return false
        end
    end
    if matched == 0 then return false end
    return true, score
end

---------------------------------------------------------------------------
-- Human-readable summary of the captured AH filters
---------------------------------------------------------------------------
local INVTYPE_NAME
local function InvName(id)
    if not INVTYPE_NAME then
        INVTYPE_NAME = {}
        for loc, n in pairs(ns.EQUIPLOC_TO_INVTYPE) do
            INVTYPE_NAME[n] = _G[loc] or loc
        end
    end
    return INVTYPE_NAME[id]
end

local function ClassName(cid)
    local fn = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo
    return (fn and fn(cid)) or ("Class " .. cid)
end

local function SubClassName(cid, sid)
    local fn = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
    return (fn and fn(cid, sid)) or ("Sub " .. sid)
end

function F.Describe()
    local q = F.query
    if not q then return nil end
    local parts = {}
    local cf = q.classFilters[1]
    if cf and cf.classID then
        local s = ClassName(cf.classID)
        if cf.subClassID and cf.subClassID >= 0 then s = s .. " > " .. SubClassName(cf.classID, cf.subClassID) end
        if cf.inventoryType and cf.inventoryType > 0 then s = s .. " > " .. (InvName(cf.inventoryType) or "?") end
        if #q.classFilters > 1 then s = s .. (" (+%d)"):format(#q.classFilters - 1) end
        parts[#parts + 1] = s
    else
        parts[#parts + 1] = "All categories"
    end
    if q.minLevel > 0 or q.maxLevel > 0 then
        parts[#parts + 1] = ("Lvl %s-%s"):format(q.minLevel > 0 and q.minLevel or "1", q.maxLevel > 0 and q.maxLevel or "60")
    end
    if q.qualities then
        local names, all = {}, true
        for qual = 0, 5 do
            if q.qualities[qual] then
                names[#names + 1] = _G["ITEM_QUALITY" .. qual .. "_DESC"] or tostring(qual)
            else
                all = false
            end
        end
        if not all then parts[#parts + 1] = table.concat(names, "/") end
    end
    if q.usableOnly then parts[#parts + 1] = "Usable" end
    if q.searchString ~= "" then parts[#parts + 1] = '"' .. q.searchString .. '"' end
    return table.concat(parts, ", ")
end
