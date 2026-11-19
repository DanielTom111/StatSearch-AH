-- StatSearch / Scanner.lua
-- Builds a gear "market" from AUCTION HOUSE BROWSE RESULTS.
--
-- On WoW Forever, Auctionator's Full Scan pages through the normal browse
-- search. Browse results are broadcast to every addon, so StatSearch just
-- listens: Auctionator's Full Scan AND your own searches in the AH both feed
-- the same data. Without Auctionator, StatSearch's own "Scan AH" button
-- pages through the gear categories the same way (see Built-in scan).
--
-- One entry per item key (item + item level + random suffix), e.g.
-- "Archer's Belt of the Owl" and "Archer's Belt of Intellect" are separate.
--
-- Recipes (patterns, plans, formulas...) are kept too. Their tooltip
-- includes the item they craft, so a recipe takes that item's stats and
-- slot and is compared to what you wear like any other gear. Recipes you
-- already know, can't learn with your profession skill, or that don't
-- craft wearable gear are hidden.

local _, ns = ...
local S = {}
ns.Scanner = S

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetInvTypeByID = C_Item and C_Item.GetItemInventoryTypeByID
local RequestLoad = C_Item and C_Item.RequestLoadItemDataByID

local RECIPE_CLASS = 9
local GEAR_CLASSES = { [2] = true, [4] = true, [RECIPE_CLASS] = true } -- Weapon, Armor, Recipe
local SESSION_GAP = 60   -- seconds of silence that separate two Auctionator scans
local ACTIVE_WINDOW = 8  -- a scan counts as "in progress" if results arrived this recently
local STALL_SECONDS = 20 -- give up on items whose data never loads

S.progress = nil

local pending = {}      -- key -> entry awaiting stats
local scan              -- built-in scan state while one is running
local classCache = {}   -- itemID -> classID|false

ns.EQUIPLOC_TO_INVTYPE = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_BODY = 4,
    INVTYPE_CHEST = 5, INVTYPE_WAIST = 6, INVTYPE_LEGS = 7, INVTYPE_FEET = 8,
    INVTYPE_WRIST = 9, INVTYPE_HAND = 10, INVTYPE_FINGER = 11, INVTYPE_TRINKET = 12,
    INVTYPE_WEAPON = 13, INVTYPE_SHIELD = 14, INVTYPE_RANGED = 15, INVTYPE_CLOAK = 16,
    INVTYPE_2HWEAPON = 17, INVTYPE_BAG = 18, INVTYPE_TABARD = 19, INVTYPE_ROBE = 20,
    INVTYPE_WEAPONMAINHAND = 21, INVTYPE_WEAPONOFFHAND = 22, INVTYPE_HOLDABLE = 23,
    INVTYPE_AMMO = 24, INVTYPE_THROWN = 25, INVTYPE_RANGEDRIGHT = 26,
    INVTYPE_QUIVER = 27, INVTYPE_RELIC = 28,
}

---------------------------------------------------------------------------
-- Market storage (saved per realm + faction)
---------------------------------------------------------------------------
function S.GetMarket()
    if not ns.db then return nil end
    local k = ns.RealmKey()
    local m = ns.db.market[k]
    if not m then
        m = { items = {} }
        ns.db.market[k] = m
    end
    return m
end

function S.Key(itemID, itemLevel, itemSuffix)
    return itemID .. ":" .. (itemLevel or 0) .. ":" .. (itemSuffix or 0)
end

function S.MakeItemKey(e)
    if C_AuctionHouse and C_AuctionHouse.MakeItemKey then
        return C_AuctionHouse.MakeItemKey(e.itemID, e.itemLevel, e.itemSuffix)
    end
    return { itemID = e.itemID, itemLevel = e.itemLevel, itemSuffix = e.itemSuffix, battlePetSpeciesID = 0 }
end

-- Is an Auctionator scan currently streaming in?
function S.ScanActive()
    if scan then return true end
    local m = S.GetMarket()
    return m and m.lastScan and (time() - m.lastScan) < ACTIVE_WINDOW
end

---------------------------------------------------------------------------
-- Query tracking (called from Filter.lua hooks)
-- C_AuctionHouse.SendBrowseQuery fires for every browse query; the AH
-- frame's own SendBrowseQuery method only for searches YOU make in the UI.
-- Anything that isn't from the UI is treated as a scan (Auctionator).
---------------------------------------------------------------------------
function S.OnBrowseQuery()
    S.queryFromUI = false
end

function S.MarkUIQuery()
    S.queryFromUI = true
    -- A search of yours replaces the scan's results, so the scan can't go on.
    S.StopScan("Scan stopped - you searched in the AH. Press Scan AH to start again.")
end

---------------------------------------------------------------------------
-- Ingest browse results
---------------------------------------------------------------------------
local refreshQueued = false
function S.RequestRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.5, function()
        refreshQueued = false
        if ns.UI then ns.UI:Refresh() end
    end)
end

local function IsGear(itemID)
    local c = classCache[itemID]
    if c == nil then
        c = select(6, GetItemInfoInstant(itemID)) or false
        classCache[itemID] = c
    end
    return GEAR_CLASSES[c] or false
end

function S.Ingest(results)
    if type(results) ~= "table" or not ns.db then return end
    local m = S.GetMarket()
    local now = time()

    local fromScan = not S.queryFromUI
    if fromScan then
        -- The built-in scan sets scanStart itself when it starts.
        if not scan and now - (m.lastScan or 0) > SESSION_GAP then
            m.scanStart = now
        end
        m.lastScan = now
    end

    local sig = ns.Tags.signature
    for _, r in ipairs(results) do
        local k = r.itemKey
        if k and k.itemID and (k.battlePetSpeciesID or 0) == 0 and IsGear(k.itemID) then
            local key = S.Key(k.itemID, k.itemLevel, k.itemSuffix)
            local e = m.items[key]
            if not e then
                e = { itemID = k.itemID, itemLevel = k.itemLevel or 0, itemSuffix = k.itemSuffix or 0 }
                m.items[key] = e
            end
            if scan and fromScan and (e.seen or 0) < scan.start then scan.gear = scan.gear + 1 end
            e.minPrice = r.minPrice
            e.qty = r.totalQuantity
            e.seen = now
            if not e.tags or e.partial or e.sig ~= sig then
                pending[key] = e
            end
        end
    end
    S.KickEnrich()
    S.RequestRefresh()
end

local ScanResultsArrived -- defined in Built-in scan below

function S.OnBrowseUpdated()
    if C_AuctionHouse and C_AuctionHouse.GetBrowseResults then
        S.Ingest(C_AuctionHouse.GetBrowseResults())
    end
    ScanResultsArrived()
end

function S.OnBrowseAdded(added)
    S.Ingest(added)
    ScanResultsArrived()
end

---------------------------------------------------------------------------
-- Stats: read each item key's tooltip (includes the random suffix)
---------------------------------------------------------------------------
local RETRIEVING = (RETRIEVING_ITEM_INFO or "Retrieving item information"):lower()
local scanTip

-- Returns text lines, plus the item ID of a nested item tooltip if there
-- is one (modern tooltip data puts a recipe's crafted item in a nested
-- block instead of as text lines).
local function LinesFromData(data)
    local lines, nested = {}, nil
    local NESTED = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.NestedBlock
    local ITEM_TT = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
    for _, line in ipairs(data.lines or {}) do
        if line.leftText == nil and TooltipUtil and TooltipUtil.SurfaceArgs then
            TooltipUtil.SurfaceArgs(line)
        end
        if line.leftText and line.leftText ~= "" then lines[#lines + 1] = line.leftText end
        if not nested and type(line.tooltipID) == "number" and line.tooltipID > 0
            and ((NESTED and line.type == NESTED) or (ITEM_TT and line.tooltipType == ITEM_TT)) then
            nested = line.tooltipID
        end
    end
    return lines, nested
end

local function ReadScanTip(setter)
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "StatSearchScanTooltip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    setter(scanTip)
    local lines = {}
    for i = 1, scanTip:NumLines() do
        local fs = _G["StatSearchScanTooltipTextLeft" .. i]
        local t = fs and fs:GetText()
        if t and t ~= "" then lines[#lines + 1] = t end
    end
    scanTip:Hide()
    return lines
end

local function GetTooltipLines(e)
    if C_TooltipInfo and C_TooltipInfo.GetItemKey then
        local data = C_TooltipInfo.GetItemKey(e.itemID, e.itemLevel, e.itemSuffix)
        if data then return LinesFromData(data) end
    end
    return ReadScanTip(function(tip)
        if tip.SetItemKey then
            tip:SetItemKey(e.itemID, e.itemLevel, e.itemSuffix)
        elseif e.link then
            tip:SetHyperlink(e.link) -- last resort: base item, no suffix stats
        end
    end)
end

-- Tooltip lines for a plain item ID (a recipe's crafted item).
local function ItemLines(id)
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then
        local data = C_TooltipInfo.GetItemByID(id)
        if data then return (LinesFromData(data)) end
    end
    return ReadScanTip(function(tip) tip:SetHyperlink("item:" .. id) end)
end

---------------------------------------------------------------------------
-- Recipes
-- Classic-style recipe tooltip:
--   Pattern: Deviate Scale Belt
--   Requires Leatherworking (115)        <- skill needed
--   Already known                        <- only if you know it
--   Use: Teaches you how to craft ...    <- everything after this line is
--   Deviate Scale Belt                      the crafted item's tooltip
--   Waist                                <- slot
--   +6 Stamina ...
--   Requires Deviate Scale (10), ...     <- reagents (ignored)
---------------------------------------------------------------------------
local USE_PREFIX = (ITEM_SPELL_TRIGGER_ONUSE or "Use:"):lower()
local KNOWN_TEXT = (ITEM_SPELL_KNOWN or "Already known"):lower()

local function FormatToPattern(fmt)
    local p = fmt:lower():gsub("%%%d%$s", "%%s"):gsub("%%%d%$d", "%%d")
    p = p:gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1")
    p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. p .. "$"
end
local SKILL_PATTERN = FormatToPattern(ITEM_MIN_SKILL or "Requires %s (%d)")

-- Localised slot name ("Waist", "One-Hand") -> inventory type
local slotByName
local function SlotFromLine(line)
    if not slotByName then
        slotByName = {}
        for loc, id in pairs(ns.EQUIPLOC_TO_INVTYPE) do
            local name = _G[loc]
            if type(name) == "string" and name ~= "" and not slotByName[name:lower()] then
                slotByName[name:lower()] = id
            end
        end
    end
    return slotByName[line]
end

local LEVEL_PATTERN = FormatToPattern(ITEM_MIN_LEVEL or "Requires Level %d")

local function HasRetrieving(lines)
    for _, l in ipairs(lines) do
        if l:lower():find(RETRIEVING, 1, true) then return true end
    end
    return false
end

-- Crafted item known by ID: take its slot, level and stats from the item
-- itself. Returns false while its data is still loading.
local function CraftFromID(e, id)
    e.craftID = id
    local name, _, _, _, minLevel = GetItemInfo(id)
    if not name then
        if RequestLoad then RequestLoad(id) end
        return false
    end
    local lines = ItemLines(id)
    if #lines < 2 or HasRetrieving(lines) then
        if RequestLoad then RequestLoad(id) end
        return false
    end
    local _, _, _, equipLoc, _, classID = GetItemInfoInstant(id)
    local inv = (GetInvTypeByID and GetInvTypeByID(id)) or ns.EQUIPLOC_TO_INVTYPE[equipLoc or ""] or 0
    e.craftName, e.craftLevel = name, minLevel or 0
    e.craftInvType = (GEAR_CLASSES[classID] and classID ~= RECIPE_CLASS and inv > 0) and inv or nil
    e.tags = ns.Tags.Extract(lines)
    return true
end

-- Crafted item written into the recipe tooltip as text.
local function CraftFromLines(e, craft)
    e.craftName = (craft[1]:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    e.craftLevel = 0
    for i = 2, #craft do
        local l = ns.Tags.Normalize(craft[i])
        if not e.craftInvType then e.craftInvType = SlotFromLine(l) end
        local lvl = l:match(LEVEL_PATTERN)
        if lvl then e.craftLevel = tonumber(lvl) or 0 end
    end
    e.tags = ns.Tags.Extract(craft) -- craft[1] (the item name) is skipped
end

-- Fills recipe fields. nestedID = crafted item ID from tooltip data, if
-- the client gives one. Returns false if the crafted item hasn't loaded yet.
function S.ParseRecipe(e, lines, nestedID)
    e.isRecipe = true
    e.known, e.reqSkill, e.reqRank = false, nil, nil
    e.craftInvType, e.craftName, e.craftLevel, e.craftID = nil, nil, nil, nil
    local split
    for i = 2, #lines do
        local l = ns.Tags.Normalize(lines[i])
        if l == KNOWN_TEXT then e.known = true end
        if not split then
            local skill, rank = l:match(SKILL_PATTERN)
            if skill and not e.reqSkill then e.reqSkill, e.reqRank = skill, tonumber(rank) end
            if l:sub(1, #USE_PREFIX) == USE_PREFIX then split = i end
        end
    end

    local done
    if nestedID then
        done = CraftFromID(e, nestedID)
    else
        local craft = {}
        for i = (split or #lines) + 1, #lines do craft[#craft + 1] = lines[i] end
        if #craft >= 2 and not HasRetrieving(craft) then
            CraftFromLines(e, craft)
            done = true
        elseif #craft > 0 and HasRetrieving(craft) then
            done = false
        else
            -- Nothing in the tooltip: try the name ("Pattern: Deviate Scale Belt").
            local guess = (lines[1] or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):match(":%s*(.+)$")
            local id = guess and GetItemInfoInstant(guess)
            if id then
                done = CraftFromID(e, id)
            else
                e.tags = {}
                done = true -- can't tell what it crafts; it stays hidden
            end
        end
    end
    if not done then return false end
    if e.craftInvType then e.invType = e.craftInvType end
    if e.craftLevel and e.craftLevel > 0 then e.minLevel = e.craftLevel end
    return true
end

-- Your professions: lowercased name -> rank. "complete" is false when a
-- skill header is collapsed in the Skills tab (its lines are hidden).
local skills, skillsComplete
local function LoadSkills()
    if skills then return end
    skills, skillsComplete = {}, true
    for i = 1, GetNumSkillLines() do
        local name, isHeader, isExpanded, rank = GetSkillLineInfo(i)
        if isHeader then
            if not isExpanded then skillsComplete = false end
        elseif name and rank then
            skills[name:lower()] = rank
        end
    end
end

function S.CanLearn(e)
    if not e.reqSkill then return true end
    if not (GetNumSkillLines and GetSkillLineInfo) then return true end
    LoadSkills()
    local rank = skills[e.reqSkill]
    if rank then return rank >= (e.reqRank or 0) end
    return not skillsComplete -- can't see it: only hide if the list is complete
end

-- Recipes that should appear in results.
function S.RecipeVisible(e)
    if not e.isRecipe then return true end
    if e.known or not e.craftInvType then return false end
    if not (ns.Equipped.HasSlot and ns.Equipped.HasSlot(e.craftInvType)) then return false end
    if (e.craftLevel or 0) > (UnitLevel("player") or 0) then return false end
    return S.CanLearn(e)
end

ns:On("SKILL_LINES_CHANGED", function()
    skills = nil
    S.RequestRefresh()
end)

-- Learned something: re-read recipe tooltips so "Already known" updates.
local function RequeueRecipes()
    local m = S.GetMarket()
    if not m then return end
    for key, e in pairs(m.items) do
        if e.isRecipe then pending[key] = e end
    end
    S.KickEnrich()
end
ns:On("LEARNED_SPELL_IN_TAB", RequeueRecipes)

-- Returns true when done, false if item data isn't loaded yet.
local function TryEnrich(e)
    local _, _, _, equipLoc, icon, classID, subClassID = GetItemInfoInstant(e.itemID)
    e.classID, e.subClassID, e.equipLoc = classID, subClassID, equipLoc
    e.invType = (GetInvTypeByID and GetInvTypeByID(e.itemID)) or ns.EQUIPLOC_TO_INVTYPE[equipLoc or ""] or 0

    local baseName, link, quality, _, minLevel = GetItemInfo(e.itemID)
    if not baseName then return false end
    e.link = link
    e.minLevel = minLevel or 0
    e.icon = e.icon or icon
    e.quality = e.quality or quality

    -- Suffixed name ("... of the Owl") comes from the item key.
    if C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
        local info = C_AuctionHouse.GetItemKeyInfo(S.MakeItemKey(e))
        if not info then return false end
        e.name = info.itemName or baseName
        e.quality = info.quality or e.quality
        e.icon = info.iconFileID or e.icon
    else
        e.name = baseName
    end

    local lines, nested = GetTooltipLines(e)
    if #lines < 2 or lines[1]:lower():find(RETRIEVING, 1, true) then return false end
    if classID == RECIPE_CLASS then
        if not S.ParseRecipe(e, lines, nested) then return false end
    else
        e.tags = ns.Tags.Extract(lines)
    end
    e.sig = ns.Tags.signature
    e.partial = nil
    return true
end

local function EnrichJob()
    local requested = {}
    local lastProgress = GetTime()
    while true do
        local batch = {}
        for key in pairs(pending) do batch[#batch + 1] = key end
        if #batch == 0 then break end

        local progressed = false
        for i, key in ipairs(batch) do
            local e = pending[key]
            if e then
                if TryEnrich(e) then
                    pending[key] = nil
                    progressed = true
                elseif RequestLoad and not requested[e.itemID] then
                    requested[e.itemID] = true
                    RequestLoad(e.itemID)
                end
            end
            if i % 10 == 0 then
                S.progress = ("Reading stats (%d left)"):format(#batch - i)
                ns.MaybeYield()
            end
        end
        if progressed then lastProgress = GetTime() end
        if GetTime() - lastProgress > STALL_SECONDS then
            for key, e in pairs(pending) do
                e.tags = e.tags or {}
                e.partial = true
                pending[key] = nil
            end
            break
        end
        S.progress = ("Reading stats (%d left)"):format(#batch)
        S.RequestRefresh()
        coroutine.yield()
    end
end

local function OnEnrichError(err)
    S.progress = nil
    wipe(pending)
    ns.Print("Reading stats failed - please send this error so it can be fixed:")
    print(err)
end

function S.KickEnrich()
    if ns:IsJobRunning("enrich") or not next(pending) then return end
    ns:StartJob("enrich", EnrichJob, function()
        S.progress = nil
        S.RequestRefresh()
    end, OnEnrichError)
end

-- Re-read stats for saved items if Tags.lua changed (runs on AH open).
-- Recipes are always re-read so "Already known" is up to date.
function S.QueueStale()
    local m = S.GetMarket()
    if not m then return end
    local sig = ns.Tags.signature
    for key, e in pairs(m.items) do
        if not e.tags or e.partial or e.sig ~= sig or e.isRecipe then pending[key] = e end
    end
    S.KickEnrich()
end

---------------------------------------------------------------------------
-- Visibility: once an Auctionator scan has finished, items it didn't see
-- are treated as sold/expired and hidden (unless you've seen them since in
-- your own searches).
---------------------------------------------------------------------------
function S.IsCurrent(e, m)
    if not (ns.Filter.uiHooked and m.scanStart) then return true end
    if S.ScanActive() then return true end
    return (e.seen or 0) >= m.scanStart
end

---------------------------------------------------------------------------
-- Built-in scan (only offered when Auctionator isn't installed).
-- Sends the same category browse query the AH UI sends when you click
-- Weapons / Armor / Recipes, then asks for more pages until the AH says it
-- has sent everything. Results come in through the normal browse events
-- above, so they're saved exactly like Auctionator's.
---------------------------------------------------------------------------
local SCAN_CLASSES = { 2, 4, RECIPE_CLASS } -- Weapon, Armor, Recipe
local QUALITY_KEYS = { "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality",
                       "EpicQuality", "LegendaryQuality", "ArtifactQuality" }
local STEP_DELAY = 0.1  -- coalesce UPDATED/ADDED events that arrive together
local SCAN_STALL = 10   -- seconds without results before retrying a page
local MAX_STALLS = 3    -- retries before skipping to the next category

local GetClassInfo = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo
local function ClassLabel(id)
    return (GetClassInfo and GetClassInfo(id)) or ("Class " .. id)
end

local function ScanQuery(classID)
    local AHF, SO = Enum and Enum.AuctionHouseFilter, Enum and Enum.AuctionHouseSortOrder
    local filters, sorts = {}, {}
    if AHF then
        for _, k in ipairs(QUALITY_KEYS) do
            if AHF[k] ~= nil then filters[#filters + 1] = AHF[k] end
        end
    end
    if SO then
        sorts[1] = { sortOrder = SO.Price, reverseSort = false }
        sorts[2] = { sortOrder = SO.Name, reverseSort = false }
    end
    return {
        searchString = "", minLevel = 0, maxLevel = 0,
        filters = filters, sorts = sorts,
        itemClassFilters = { { classID = classID } },
    }
end

local function ThrottleReady()
    return not C_AuctionHouse.IsThrottledMessageSystemReady or C_AuctionHouse.IsThrottledMessageSystemReady()
end

local function HasAllResults()
    return not C_AuctionHouse.HasFullBrowseResults or C_AuctionHouse.HasFullBrowseResults()
end

function S.CanScan()
    return C_AuctionHouse and C_AuctionHouse.SendBrowseQuery and C_AuctionHouse.RequestMoreBrowseResults and true or false
end

function S.IsScanning()
    return scan ~= nil
end

function S.ScanText()
    if not scan then return nil end
    local id = SCAN_CLASSES[scan.step]
    return ("Scanning %s (%d/%d, page %d)... %d gear items so far"):format(
        id and ClassLabel(id) or "...", math.min(scan.step, #SCAN_CLASSES), #SCAN_CLASSES, scan.pages, scan.gear)
end

local function FinishScan()
    local m = S.GetMarket()
    local n = 0
    for _, e in pairs(m.items) do
        if (e.seen or 0) >= scan.start then n = n + 1 end
    end
    if scan.ticker then scan.ticker:Cancel() end
    scan = nil
    m.lastScan = time()
    ns.Print(("Scan complete - %d gear items on the auction house."):format(n))
    S.RequestRefresh()
end

local function ScanStep()
    if not scan then return end
    scan.queued = false
    if not ns.ahOpen then S.StopScan("Scan stopped - the auction house was closed.") return end
    if scan.waiting or not ThrottleReady() then return end -- THROTTLED_SYSTEM_READY or results call us again

    if scan.sent then
        if not HasAllResults() then
            scan.waiting, scan.last = true, GetTime()
            scan.pages = scan.pages + 1
            C_AuctionHouse.RequestMoreBrowseResults()
            return
        end
        scan.step, scan.sent, scan.stalls = scan.step + 1, false, 0
    end

    local classID = SCAN_CLASSES[scan.step]
    if not classID then FinishScan() return end
    scan.sent, scan.waiting, scan.last, scan.pages = true, true, GetTime(), 1
    S.ownQuery = true
    local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, ScanQuery(classID))
    S.ownQuery = false
    if not ok then S.StopScan("Scan failed: " .. tostring(err)) end
end

local function QueueStep()
    if not scan or scan.queued then return end
    scan.queued = true
    C_Timer.After(STEP_DELAY, ScanStep)
end

ScanResultsArrived = function()
    if not scan then return end
    scan.waiting, scan.last, scan.stalls = false, GetTime(), 0
    QueueStep()
end

function S.OnThrottleReady()
    QueueStep()
end

function S.StartScan()
    if scan then return end
    if ns.HasAuctionator() then
        ns.Print("Auctionator is installed - use its Full Scan instead.")
        return
    end
    if not ns.ahOpen then ns.Print("Open the auction house to scan it.") return end
    if not S.CanScan() then ns.Print("This client's auction house can't be scanned by addons.") return end
    local m = S.GetMarket()
    scan = {
        step = 1, pages = 0, gear = 0, stalls = 0, start = time(),
        prevStart = m.scanStart, prevLast = m.lastScan,
    }
    m.scanStart = scan.start
    -- Watchdog: if a page never arrives, retry it, then move on.
    scan.ticker = C_Timer.NewTicker(1, function()
        if not scan or not scan.waiting or GetTime() - scan.last < SCAN_STALL then return end
        scan.stalls = scan.stalls + 1
        scan.waiting = false
        if scan.stalls > MAX_STALLS then
            scan.step, scan.sent, scan.stalls = scan.step + 1, false, 0
        elseif scan.pages <= 1 then
            scan.sent = false -- the category query got no answer: resend it
        end
        QueueStep()
    end)
    ns.Print("Scanning the auction house (Weapons, Armor, Recipes)...")
    QueueStep()
    S.RequestRefresh()
end

-- Stops a running scan. An unfinished scan doesn't count as a full scan,
-- so items it didn't reach aren't hidden as sold.
function S.StopScan(msg)
    if not scan then return false end
    local m = S.GetMarket()
    if scan.ticker then scan.ticker:Cancel() end
    m.scanStart, m.lastScan = scan.prevStart, scan.prevLast
    scan = nil
    S.ownQuery = false
    if msg then ns.Print(msg) end
    S.RequestRefresh()
    return true
end

function S.ToggleScan()
    if scan then S.StopScan("Scan stopped.") else S.StartScan() end
end

function S.Cancel()
    local wasScan = S.StopScan()
    local was = ns:IsJobRunning("enrich")
    ns:StopJob("enrich")
    wipe(pending)
    S.progress = nil
    ns.Print((wasScan or was) and "Scan / stat reading cancelled." or "Nothing running.")
end
