-- StatSearch / Core.lua
-- Namespace, saved variables, event dispatch, and a frame-budgeted job runner
-- so big scans never hitch the game.

local ADDON, ns = ...
ns.name = ADDON

function ns.Print(...)
    print("|cff33ccffStatSearch|r:", ...)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns:On(event, fn)
    if not handlers[event] then
        -- pcall: an event this client doesn't have is skipped, not an error
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then return end
        handlers[event] = {}
    end
    table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do
        fn(...)
    end
end)

---------------------------------------------------------------------------
-- Job runner: coroutines that get ~BUDGET_MS of CPU per frame.
-- Inside a job call ns.MaybeYield() regularly.
---------------------------------------------------------------------------
local BUDGET_MS = 8
local jobs = {}
local frameStart = 0
local runner = CreateFrame("Frame")
runner:Hide()

function ns.MaybeYield()
    if debugprofilestop() - frameStart > BUDGET_MS then
        coroutine.yield()
    end
end

function ns:StartJob(name, fn, onDone, onError)
    jobs[name] = { co = coroutine.create(fn), onDone = onDone, onError = onError }
    runner:Show()
end

function ns:StopJob(name)
    jobs[name] = nil
end

function ns:IsJobRunning(name)
    return jobs[name] ~= nil
end

runner:SetScript("OnUpdate", function(self)
    local finished = {}
    for name, job in pairs(jobs) do
        frameStart = debugprofilestop()
        local ok, err = coroutine.resume(job.co)
        if not ok then
            jobs[name] = nil
            local msg = tostring(err) .. "\n" .. (debugstack and debugstack(job.co) or "")
            if job.onError then job.onError(msg) else ns.Print("job '" .. name .. "' failed: " .. msg) end
        elseif coroutine.status(job.co) == "dead" then
            jobs[name] = nil
            finished[#finished + 1] = job
        end
    end
    for _, job in ipairs(finished) do
        if job.onDone then job.onDone() end
    end
    if not next(jobs) then self:Hide() end
end)

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------
local DEFAULTS = {
    mode = "AND",          -- "AND" | "OR"
    useAHFilters = true,
    maxPrice = nil,        -- copper; nil = no limit
    sort = "value",        -- "value" | "total"
    tags = {},             -- { { id = "int", min = 10 }, ... }
    open = true,           -- panel open when the AH opens
}

function ns.RealmKey()
    return (GetRealmName() or "?") .. "-" .. (UnitFactionGroup("player") or "?")
end

local function IsAddOnLoadedCompat(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
    if IsAddOnLoaded then return IsAddOnLoaded(name) end
    return false
end

-- Auctionator loads before us (OptionalDeps), so this is accurate from login.
-- When it's present StatSearch uses its Full Scan and hides its own.
function ns.HasAuctionator()
    return IsAddOnLoadedCompat("Auctionator") and true or false
end

ns:On("ADDON_LOADED", function(name)
    if name == ADDON then
        StatSearchDB = StatSearchDB or {}
        local db = StatSearchDB
        db.snapshots = nil -- old format (pre 0.2)
        db.market = db.market or {}
        db.settings = db.settings or {}
        for k, v in pairs(DEFAULTS) do
            if db.settings[k] == nil then
                db.settings[k] = (type(v) == "table") and {} or v
            end
        end
        -- migrate old sort keys
        local s = db.settings.sort
        if s ~= "value" and s ~= "total" then db.settings.sort = "value" end
        db.settings.useAHFilters = true -- always on now
        ns.db = db
    elseif name == "Blizzard_AuctionHouseUI" and ns.db then
        ns.UI:OnAHLoaded()
    end
end)

ns:On("PLAYER_LOGIN", function()
    ns.Filter.Init()
    if IsAddOnLoadedCompat("Blizzard_AuctionHouseUI") then
        ns.UI:OnAHLoaded()
    end
end)

ns:On("AUCTION_HOUSE_SHOW", function()
    ns.ahOpen = true
    ns.Filter.HookUI()
    ns.UI:OnAHShow()
    ns.Scanner.QueueStale()
end)

ns:On("AUCTION_HOUSE_CLOSED", function()
    ns.ahOpen = false
    ns.Scanner.StopScan("Scan stopped - the auction house was closed.")
    ns.UI:OnAHClosed()
end)

ns:On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
    ns.Scanner.OnBrowseUpdated()
end)

ns:On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(added)
    ns.Scanner.OnBrowseAdded(added)
end)

ns:On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
    ns.Scanner.OnThrottleReady()
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_STATSEARCH1 = "/statsearch"
SLASH_STATSEARCH2 = "/ss"
SlashCmdList.STATSEARCH = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "scan" and not ns.HasAuctionator() then
        ns.Scanner.ToggleScan()
    elseif msg == "cancel" then
        ns.Scanner.Cancel()
    elseif msg == "reset" then
        ns.db.market[ns.RealmKey()] = nil
        ns.Print("Saved AH data for this realm cleared.")
        ns.UI:Refresh()
    elseif msg == "tags" then
        local names = {}
        for _, t in ipairs(ns.Tags.list) do names[#names + 1] = t.label end
        ns.Print("Tags: " .. table.concat(names, ", "))
    elseif msg == "help" then
        ns.Print("/ss - toggle panel | /ss tags - list tags"
            .. (ns.HasAuctionator() and "" or " | /ss scan - scan the AH")
            .. " | /ss cancel - stop scanning/reading | /ss reset - clear scan data")
    else
        ns.UI:Toggle()
    end
end
