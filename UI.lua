-- StatSearch / UI.lua
-- Panel docked to the right of the auction house: tag input with
-- autocomplete, AND/OR toggle, sort (best value / stat total, either
-- direction), and a virtual results list.

local _, ns = ...
local UI = {}
ns.UI = UI

local PANEL_W = 400
local ROW_H = 36
local MAX_SUGGEST = 8
local CHIP_H = 20

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
local FLAT = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 }

local SORT_ORDER = { "value", "total" }
local SORT_LABEL = { value = "Best value", total = "Stat total" }

UI.rows, UI.chips, UI.results, UI.offset = {}, {}, {}, 0

local function Settings() return ns.db.settings end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
-- Gold/silver only; copper is noise at these prices.
local function CompactMoney(c)
    if not c then return "-" end
    local g, s = math.floor(c / 10000), math.floor(c / 100) % 100
    if g > 0 then
        return s > 0 and ("%d|cffffd700g|r %d|cffc7c7cfs|r"):format(g, s) or ("%d|cffffd700g|r"):format(g)
    elseif s > 0 then
        return ("%d|cffc7c7cfs|r"):format(s)
    end
    return "<1|cffc7c7cfs|r"
end

local function QualityColor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function Ago(t)
    local d = time() - (t or 0)
    if d < 60 then return "just now" end
    local n, unit
    if d < 3600 then n, unit = math.floor(d / 60), "min"
    elseif d < 86400 then n, unit = math.floor(d / 3600), "hour"
    else n, unit = math.floor(d / 86400), "day" end
    return ("%d %s%s ago"):format(n, unit, n == 1 and "" or "s")
end

local function Price(e)
    return e.minPrice
end

local function SimpleTooltip(frame, title, text)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title, 1, 1, 1)
        if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
function UI:Create()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "StatSearchPanel", UIParent, "BackdropTemplate")
    self.frame = f
    f:SetSize(PANEL_W, 580)
    f:SetPoint("CENTER")
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
    f:SetBackdropBorderColor(0.5, 0.5, 0.55, 1)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not UI.docked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Stat Search")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() UI:Hide() end)

    -- Built-in scan: only shown when Auctionator isn't installed.
    local scanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    scanBtn:SetSize(84, 22)
    scanBtn:SetPoint("TOPRIGHT", -30, -8)
    scanBtn:SetScript("OnClick", function() ns.Scanner.ToggleScan(); UI:UpdateScanButton() end)
    SimpleTooltip(scanBtn, "Scan the auction house",
        "Reads every Weapon, Armor and Recipe listing so StatSearch can search them.\nItems that are gone from the AH after a full scan are hidden.\nSearching in the AH yourself stops the scan.")
    self.scanBtn = scanBtn

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", 12, -34)
    status:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    status:SetJustifyH("LEFT")
    self.status = status

    -- Tag input ----------------------------------------------------------
    local eb = CreateFrame("EditBox", "StatSearchTagInput", f, "InputBoxTemplate")
    eb:SetAutoFocus(false)
    eb:SetHeight(22)
    eb:SetPoint("TOPLEFT", 20, -52)
    eb:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    eb:SetMaxLetters(40)
    local ph = eb:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ph:SetPoint("LEFT", 2, 0)
    ph:SetText("Add a stat tag...  e.g. intellect, heal 20, crit")
    local function UpdatePH() ph:SetShown(eb:GetText() == "" and not eb:HasFocus()) end
    eb:SetScript("OnTextChanged", function() UpdatePH(); UI:UpdateSuggestions() end)
    eb:SetScript("OnEnterPressed", function() UI:AcceptSuggestion() end)
    eb:SetScript("OnTabPressed", function() UI:AcceptSuggestion() end)
    eb:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    eb:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then UI:MoveSuggestion(-1) elseif key == "DOWN" then UI:MoveSuggestion(1) end
    end)
    eb:SetScript("OnEditFocusGained", function() UpdatePH(); UI:UpdateSuggestions() end)
    eb:SetScript("OnEditFocusLost", function()
        UpdatePH()
        C_Timer.After(0.15, function() if not eb:HasFocus() then UI.suggest:Hide() end end)
    end)
    self.input = eb

    -- Suggestions dropdown ------------------------------------------------
    local sg = CreateFrame("Frame", nil, f, "BackdropTemplate")
    sg:SetBackdrop(BACKDROP)
    sg:SetBackdropColor(0.08, 0.08, 0.1, 1)
    sg:SetPoint("TOPLEFT", eb, "BOTTOMLEFT", -6, -2)
    sg:SetPoint("TOPRIGHT", eb, "BOTTOMRIGHT", 4, -2)
    sg:SetFrameLevel(f:GetFrameLevel() + 30)
    sg:Hide()
    sg.buttons = {}
    for i = 1, MAX_SUGGEST do
        local b = CreateFrame("Button", nil, sg)
        b:SetHeight(18)
        b:SetPoint("TOPLEFT", 6, -5 - (i - 1) * 18)
        b:SetPoint("RIGHT", sg, "RIGHT", -6, 0)
        b.hl = b:CreateTexture(nil, "BACKGROUND")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(1, 1, 1, 0.12)
        b.hl:Hide()
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", 4, 0)
        b.hint = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        b.hint:SetPoint("RIGHT", -4, 0)
        b:SetScript("OnEnter", function() UI.suggestIndex = i; UI:PaintSuggestions() end)
        b:SetScript("OnMouseDown", function() UI.suggestIndex = i; UI:AcceptSuggestion() end)
        sg.buttons[i] = b
    end
    self.suggest = sg

    -- Chips ---------------------------------------------------------------
    local chips = CreateFrame("Frame", nil, f)
    chips:SetPoint("TOPLEFT", 12, -82)
    chips:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    chips:SetHeight(CHIP_H)
    chips.empty = chips:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    chips.empty:SetPoint("TOPLEFT", 2, -4)
    chips.empty:SetText("No tags - showing all gear that matches the AH filters.")
    self.chipArea = chips

    -- Controls row 1: AND/OR, sort, direction ----------------------------
    local mode = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    mode:SetSize(100, 22)
    mode:SetPoint("TOPLEFT", chips, "BOTTOMLEFT", 0, -6)
    mode:SetScript("OnClick", function()
        local s = Settings()
        s.mode = (s.mode == "AND") and "OR" or "AND"
        UI:UpdateControls(); UI:Refresh()
    end)
    SimpleTooltip(mode, "Filter: AND / OR", "AND: item must have every tag.\nOR: item needs at least one tag.")
    self.modeBtn = mode

    local sortBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sortBtn:SetSize(140, 22)
    sortBtn:SetPoint("LEFT", mode, "RIGHT", 4, 0)
    sortBtn:SetScript("OnClick", function()
        local s = Settings()
        local idx = 1
        for i, k in ipairs(SORT_ORDER) do if k == s.sort then idx = i end end
        s.sort = SORT_ORDER[idx % #SORT_ORDER + 1]
        UI:UpdateControls(); UI:Refresh()
    end)
    SimpleTooltip(sortBtn, "Sort",
        "Only upgrades are listed (better than what you wear, by your tagged stats).\nRecipes count as the item they craft; ones you know or can't learn yet are hidden.\nBest value: cheapest per stat first.\nStat total: highest Str + Agi + Sta + Int + Spi first; good deals are highlighted in gold.")
    self.sortBtn = sortBtn


    -- Controls row 2: max price as gold / silver / copper ------------------
    local mpLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mpLabel:SetPoint("TOPLEFT", mode, "BOTTOMLEFT", 2, -10)
    mpLabel:SetText("Max price:")

    local COINS = {
        { key = "g", icon = "Interface\\MoneyFrame\\UI-GoldIcon",   width = 52, letters = 6 },
        { key = "s", icon = "Interface\\MoneyFrame\\UI-SilverIcon", width = 28, letters = 2 },
        { key = "c", icon = "Interface\\MoneyFrame\\UI-CopperIcon", width = 28, letters = 2 },
    }
    self.maxBoxes = {}
    local prev = mpLabel
    for i, coin in ipairs(COINS) do
        local box = CreateFrame("EditBox", "StatSearchMax" .. coin.key, f, "InputBoxTemplate")
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(coin.letters)
        box:SetSize(coin.width, 20)
        box:SetJustifyH("RIGHT")
        box:SetPoint("LEFT", prev, "RIGHT", (i == 1) and 12 or 6, 0)
        local icon = box:CreateTexture(nil, "ARTWORK")
        icon:SetSize(13, 13)
        icon:SetTexture(coin.icon)
        icon:SetPoint("LEFT", box, "RIGHT", 2, 0)
        box.icon = icon
        box:SetScript("OnEnterPressed", function(self) UI:ApplyMaxPrice(); self:ClearFocus() end)
        box:SetScript("OnEditFocusLost", function() UI:ApplyMaxPrice() end)
        box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnTabPressed", function()
            local nextBox = UI.maxBoxes[(i % #COINS) + 1]
            nextBox:SetFocus()
        end)
        SimpleTooltip(box, "Max price", "Only show items at or below this price. Leave all three empty for no limit.")
        self.maxBoxes[i] = box
        prev = icon
    end

    local mpClear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    mpClear:SetSize(54, 20)
    mpClear:SetPoint("LEFT", prev, "RIGHT", 10, 0)
    mpClear:SetText("Any")
    mpClear:SetScript("OnClick", function()
        Settings().maxPrice = nil
        for _, b in ipairs(UI.maxBoxes) do b:ClearFocus() end
        UI:UpdateMaxBox(); UI:Refresh()
    end)
    SimpleTooltip(mpClear, "No price limit")

    -- Filter summary + count ---------------------------------------------
    local summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("TOPLEFT", mode, "BOTTOMLEFT", 2, -36)
    summary:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(true)
    self.summary = summary

    local count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -6)
    count:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    count:SetJustifyH("LEFT")
    self.countText = count

    -- Results list ---------------------------------------------------------
    local list = CreateFrame("Frame", nil, f, "BackdropTemplate")
    list:SetPoint("TOPLEFT", count, "BOTTOMLEFT", -4, -4)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
    list:SetBackdrop(FLAT)
    list:SetBackdropColor(0, 0, 0, 0.35)
    list:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
    list:EnableMouseWheel(true)
    self.list = list

    local sb = CreateFrame("Slider", nil, list, "BackdropTemplate")
    sb:SetOrientation("VERTICAL")
    sb:SetWidth(10)
    sb:SetPoint("TOPRIGHT", list, "TOPRIGHT", -1, -1)
    sb:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -1, 1)
    sb:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    sb:SetBackdropColor(0, 0, 0, 0.5)
    local thumb = sb:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.6, 0.6, 0.65, 0.9)
    thumb:SetSize(10, 32)
    sb:SetThumbTexture(thumb)
    sb:SetValueStep(1)
    if sb.SetObeyStepOnDrag then sb:SetObeyStepOnDrag(true) end
    sb:SetMinMaxValues(0, 0)
    sb:SetValue(0)
    sb:SetScript("OnValueChanged", function(_, v)
        UI.offset = math.floor(v + 0.5)
        UI:RenderRows()
    end)
    self.scroll = sb
    list:SetScript("OnMouseWheel", function(_, d) sb:SetValue(sb:GetValue() - d * 3) end)
    list:SetScript("OnSizeChanged", function() UI:LayoutRows() end)

    -- Periodic status refresh while visible ---------------------------------
    local acc = 0
    f:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc > 0.5 then acc = 0; UI:UpdateStatus() end
    end)
    f:SetScript("OnShow", function() UI:UpdateControls(); UI:RebuildChips(); UI:Refresh() end)
    f:RegisterEvent("MODIFIER_STATE_CHANGED")
    f:SetScript("OnEvent", function(_, event, key, down)
        if event == "MODIFIER_STATE_CHANGED" then UI:OnModifierChanged(key, down) end
    end)

    return f
end

---------------------------------------------------------------------------
-- Docking / visibility
---------------------------------------------------------------------------
function UI:Dock(ah)
    local f = self:Create()
    f:SetParent(ah)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", ah, "TOPRIGHT", 2, 0)
    f:SetPoint("BOTTOMLEFT", ah, "BOTTOMRIGHT", 2, 0)
    f:SetWidth(PANEL_W)
    f:SetFrameStrata(ah:GetFrameStrata())
    f:SetFrameLevel(ah:GetFrameLevel() + 5)
    self.docked = true

    if not self.tab then
        local t = CreateFrame("Button", nil, ah, "UIPanelButtonTemplate")
        t:SetSize(96, 22)
        t:SetPoint("TOPLEFT", ah, "TOPRIGHT", 2, -6)
        t:SetText("Stat Search")
        t:SetScript("OnClick", function() UI:Show() end)
        self.tab = t
    end

    local box = ah.SearchBar and ah.SearchBar.SearchBox
    if box and not self.hookedBox then
        box:HookScript("OnTextChanged", function(_, userInput)
            if userInput then ns.Filter.handoffName = nil end
        end)
        self.hookedBox = true
    end
end

function UI:OnAHLoaded()
    ns.Filter.HookUI()
    if self.docked or not AuctionHouseFrame then return end
    self:Dock(AuctionHouseFrame)
    self:UpdateTab()
end

function UI:OnAHShow()
    if not self.docked then self:OnAHLoaded() end
    if Settings().open then self:Show() else self:UpdateTab() end
end

function UI:OnAHClosed()
    if self.suggest then self.suggest:Hide() end
    if not self.docked and self.frame then self.frame:Hide() end
end

function UI:UpdateTab()
    if self.tab then self.tab:SetShown(not (self.frame and self.frame:IsShown())) end
end

function UI:Show()
    local f = self:Create()
    Settings().open = true
    f:Show()
    self:UpdateTab()
end

function UI:Hide()
    if self.frame then self.frame:Hide() end
    Settings().open = false
    self:UpdateTab()
end

function UI:Toggle()
    if self.frame and self.frame:IsShown() then self:Hide() else self:Show() end
end

---------------------------------------------------------------------------
-- Suggestions
---------------------------------------------------------------------------
function UI:UpdateSuggestions()
    local name = ns.Tags.ParseInput(self.input:GetText())
    local matches = (name ~= "") and ns.Tags.Search(name) or {}
    self.suggestions = matches
    if #matches == 0 or not self.input:HasFocus() then
        self.suggest:Hide()
        return
    end
    self.suggestIndex = 1
    local n = math.min(#matches, MAX_SUGGEST)
    for i, b in ipairs(self.suggest.buttons) do
        local m = matches[i]
        if i <= n then
            b.text:SetText(m.tag.label)
            b.hint:SetText(m.via or "")
            b:Show()
        else
            b:Hide()
        end
    end
    self.suggest:SetHeight(10 + n * 18)
    self.suggest:Show()
    self:PaintSuggestions()
end

function UI:PaintSuggestions()
    for i, b in ipairs(self.suggest.buttons) do
        b.hl:SetShown(i == self.suggestIndex)
    end
end

function UI:MoveSuggestion(delta)
    if not self.suggest:IsShown() then return end
    local n = math.min(#(self.suggestions or {}), MAX_SUGGEST)
    if n == 0 then return end
    self.suggestIndex = ((self.suggestIndex or 1) - 1 + delta) % n + 1
    self:PaintSuggestions()
end

function UI:AcceptSuggestion()
    local text = self.input:GetText() or ""
    local name, min = ns.Tags.ParseInput(text)
    if name == "" then return end
    local m = self.suggestions and self.suggestions[self.suggestIndex or 1]
    if not m then
        ns.Print(("No stat tag matches '%s'. Type /ss tags for the list."):format(name))
        return
    end
    self:AddTag(m.tag.id, min)
    self.input:SetText("")
    self.suggest:Hide()
end

---------------------------------------------------------------------------
-- Tags / chips
---------------------------------------------------------------------------
function UI:AddTag(id, min)
    local tags = Settings().tags
    for _, r in ipairs(tags) do
        if r.id == id then
            r.min = min
            self:RebuildChips(); self:Refresh()
            return
        end
    end
    tags[#tags + 1] = { id = id, min = min }
    self:RebuildChips(); self:Refresh()
end

function UI:RemoveTag(id)
    local tags = Settings().tags
    for i = #tags, 1, -1 do
        if tags[i].id == id then table.remove(tags, i) end
    end
    self:RebuildChips(); self:Refresh()
end

function UI:NewChip()
    local c = CreateFrame("Button", nil, self.chipArea, "BackdropTemplate")
    c:SetHeight(CHIP_H)
    c:SetBackdrop(FLAT)
    c:SetBackdropColor(0.12, 0.3, 0.55, 0.6)
    c:SetBackdropBorderColor(0.35, 0.6, 0.95, 0.9)
    c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.text:SetPoint("CENTER")
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            local tag = ns.Tags.byId[self.req.id]
            UI.input:SetText(tag.label .. " " .. (self.req.min or ""))
            UI.input:SetFocus()
        else
            UI:RemoveTag(self.req.id)
        end
    end)
    SimpleTooltip(c, "Stat tag", "Left-click: remove\nRight-click: edit minimum (type e.g. \"intellect 10\")")
    self.chips[#self.chips + 1] = c
    return c
end

function UI:RebuildChips()
    if not self.chipArea then return end
    for _, c in ipairs(self.chips) do c:Hide() end
    local maxW = PANEL_W - 24
    local x, y, used = 0, 0, 0
    local sep = (Settings().mode == "AND") and "AND" or "OR"
    for _, req in ipairs(Settings().tags) do
        local tag = ns.Tags.byId[req.id]
        if tag then
            used = used + 1
            local c = self.chips[used] or self:NewChip()
            c.req = req
            local label = tag.label .. (req.min and (" >= " .. req.min) or "")
            c.text:SetText(label .. "  |cffff7070x|r")
            local w = c.text:GetStringWidth() + 14
            c:SetWidth(w)
            if x > 0 and x + w > maxW then x = 0; y = y + CHIP_H + 4 end
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", self.chipArea, "TOPLEFT", x, -y)
            c:Show()
            x = x + w + 4
        end
    end
    self.chipArea.empty:SetShown(used == 0)
    self.chipArea:SetHeight(used == 0 and 16 or (y + CHIP_H))
    self.chipSep = sep
end

---------------------------------------------------------------------------
-- Controls / status
---------------------------------------------------------------------------
function UI:ApplyMaxPrice()
    local b = self.maxBoxes
    local g, s, c = tonumber(b[1]:GetText()), tonumber(b[2]:GetText()), tonumber(b[3]:GetText())
    if not g and not s and not c then
        Settings().maxPrice = nil
    else
        Settings().maxPrice = (g or 0) * 10000 + math.min(s or 0, 99) * 100 + math.min(c or 0, 99)
    end
    self:UpdateMaxBox()
    self:Refresh()
end

function UI:UpdateMaxBox()
    local b = self.maxBoxes
    if not b then return end
    for _, box in ipairs(b) do if box:HasFocus() then return end end
    local v = Settings().maxPrice
    if not v then
        for _, box in ipairs(b) do box:SetText("") end
        return
    end
    local g, s, c = math.floor(v / 10000), math.floor(v / 100) % 100, v % 100
    b[1]:SetText(g > 0 and tostring(g) or "")
    b[2]:SetText(s > 0 and tostring(s) or "")
    b[3]:SetText(c > 0 and tostring(c) or "")
end

function UI:UpdateScanButton()
    local b = self.scanBtn
    if not b then return end
    if ns.HasAuctionator() then b:Hide() return end
    b:SetText(ns.Scanner.IsScanning() and "Stop scan" or "Scan AH")
    b:SetEnabled(ns.ahOpen and true or false)
    b:Show()
end

function UI:UpdateControls()
    if not self.frame then return end
    local s = Settings()
    self:UpdateMaxBox()
    self:UpdateScanButton()
    self.modeBtn:SetText(s.mode == "AND" and "Filter: AND" or "Filter: OR")
    self.sortBtn:SetText("Sort: " .. (SORT_LABEL[s.sort] or s.sort))

    self:UpdateSummary()
end

function UI:UpdateSummary()
    if not self.summary then return end
    local s = Settings()
    if not s.useAHFilters then
        self.summary:SetText("|cff888888AH filters: ignored|r")
    elseif not ns.Filter.hooked then
        self.summary:SetText("|cffff8080AH filters: couldn't hook this client's auction house.|r")
    else
        local d = ns.Filter.Describe()
        self.summary:SetText(d and ("|cffbbbbbbAH filters:|r " .. d)
            or "|cffffaa00AH filters: none yet - pick a category or press Search in the AH.|r")
    end
end

function UI:OnFiltersChanged()
    if self.frame and self.frame:IsShown() then
        self:UpdateSummary()
        self:Refresh()
    end
end

function UI:UpdateStatus()
    if not self.status then return end
    self:UpdateScanButton()
    local m = ns.Scanner.GetMarket()
    local count = self.totalCurrent or 0
    local hasAuc = ns.HasAuctionator()
    if ns.Scanner.IsScanning() then
        self.status:SetText("|cffffd100" .. ns.Scanner.ScanText() .. "|r")
    elseif ns.Scanner.ScanActive() then
        self.status:SetText(("|cffffd100%s in progress... %d gear items so far|r"):format(
            hasAuc and "Auctionator scan" or "Scan", count))
    elseif ns.Scanner.progress then
        self.status:SetText("|cffffd100" .. ns.Scanner.progress .. "|r")
    elseif m and m.lastScan then
        local age = time() - m.lastScan
        local color = (age > 86400) and "|cffff8080" or ((age > 3600) and "|cffffd100" or "|cff7fff7f")
        self.status:SetText(("%sScanned %s|r - %d gear items"):format(color, Ago(m.lastScan), count))
    elseif count > 0 then
        self.status:SetText(("|cffffd100No %s yet|r - %d gear items from your AH searches"):format(
            hasAuc and "Auctionator scan" or "full scan", count))
    else
        self.status:SetText(hasAuc and "|cffff8080No data yet - run Auctionator's Full Scan with the AH open.|r"
            or "|cffff8080No data yet - press Scan AH.|r")
    end
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------
local function SortResults(res, key, desc)
    local HUGE = math.huge
    table.sort(res, function(a, b)
        if key == "value" then
            -- items with no primary stats or no price always last
            local av, bv = a.cps or HUGE, b.cps or HUGE
            if (av == HUGE) ~= (bv == HUGE) then return av ~= HUGE end
            if av ~= bv then if desc then return av > bv else return av < bv end end
        elseif key == "total" then
            if a.total ~= b.total then if desc then return a.total > b.total else return a.total < b.total end end
        end
        -- price (primary for "price", tiebreak for the others)
        local ap, bp = a.price or HUGE, b.price or HUGE
        if (ap == HUGE) ~= (bp == HUGE) then return ap ~= HUGE end
        if ap ~= bp then
            if key == "price" and desc then return ap > bp end
            return ap < bp
        end
        return (a.e.name or "") < (b.e.name or "")
    end)
end

-- A "bargain" costs at least 25% less per stat than the typical (median)
-- item in the current results. Stats = your tagged stats, or the primary
-- total when you have no tags. Needs 5+ priced results to be meaningful.
local BARGAIN_RATIO = 0.75
function UI.MarkBargains(res)
    local list = {}
    for _, r in ipairs(res) do
        local denom = (r.score and r.score > 0) and r.score or r.total
        if r.price and denom and denom > 0 then
            r.dealCps = r.price / denom
            list[#list + 1] = r.dealCps
        end
    end
    if #list < 5 then return end
    table.sort(list)
    local mid = #list / 2
    local median = (#list % 2 == 1) and list[math.ceil(mid)] or (list[mid] + list[mid + 1]) / 2
    for _, r in ipairs(res) do
        if r.dealCps and r.dealCps <= median * BARGAIN_RATIO then
            r.bargain = true
            r.bargainPct = math.floor((1 - r.dealCps / median) * 100 + 0.5)
        end
    end
end

function UI:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    local s = Settings()
    local m = ns.Scanner.GetMarket()
    local res, current = {}, 0
    if m then
        local q = s.useAHFilters and ns.Filter.query or nil
        local reqs, mode = s.tags, s.mode
        local maxPrice = s.maxPrice
        for _, e in pairs(m.items) do
            if e.tags and ns.Scanner.IsCurrent(e, m) and not ns.Equipped.IsEquipped(e)
                and ns.Scanner.RecipeVisible(e)
                and not (maxPrice and (not e.minPrice or e.minPrice > maxPrice)) then
                current = current + 1
                local ok, score = ns.Filter.Match(e, q, reqs, mode)
                if ok then
                    local total = ns.Tags.PrimaryTotal(e.tags)
                    local price = Price(e)
                    local r = {
                        e = e, score = score, total = total, price = price,
                        cps = (price and total > 0) and (price / total) or nil,
                    }
                    ns.Equipped.Annotate(r, reqs)
                    -- Upgrades only (by the same stats, vs what you wear), in every sort.
                    -- Items whose equipped comparison isn't known yet stay visible.
                    local isUpgrade = r.imprNew or (r.imprPct and r.imprPct > 0) or (r.imprScore == nil)
                    if isUpgrade then
                        res[#res + 1] = r
                    end
                end
            end
        end
        SortResults(res, s.sort, s.sort == "total") -- value: best first; total: high -> low
        if s.sort == "total" then UI.MarkBargains(res) end
    end
    self.results = res
    self.totalCurrent = current

    local upg = " |cff7fff7f(upgrades only)|r"
    self.countText:SetText(current > 0 and ("%d items%s  |cff888888hold Ctrl over an item for its tooltip|r"):format(#res, upg) or "")
    self:UpdateStatus()
    self:UpdateScroll()
end

function UI:ImprovementText(r)
    local pct = r.imprPct
    if r.imprNew then return "|cff7fff7fnew slot|r" end
    if not pct then return "" end
    if math.abs(pct) < 0.5 then return "|cffaaaaaa=  equipped|r" end
    local color = pct > 0 and "|cff7fff7f" or "|cffff7070"
    return ("%s%+d%%|r |cffaaaaaavs equipped|r"):format(color, math.floor(pct + (pct > 0 and 0.5 or -0.5)))
end

function UI:ShowRowTooltip(row)
    local r = row and row.result
    if not r then return end
    local e = r.e
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if GameTooltip.SetItemKey then
        GameTooltip:SetItemKey(e.itemID, e.itemLevel, e.itemSuffix)
    elseif e.link then
        GameTooltip:SetHyperlink(e.link)
    end
    GameTooltip:AddLine(" ")
    if e.seen then
        local ago = time() - e.seen
        GameTooltip:AddDoubleLine("Last seen", ago < 60 and "just now" or (math.floor(ago / 60) .. " min ago"), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    if r.bargain then
        GameTooltip:AddLine(("Deal: %d%% cheaper per stat than typical results"):format(r.bargainPct or 0), 1, 0.82, 0)
    end
    if e.isRecipe then
        GameTooltip:AddLine("Recipe - compared as " .. (e.craftName or "the crafted item") .. " (recipe price only, reagents not included)", 0.4, 0.75, 1, true)
    end
    if r.imprScore then
        GameTooltip:AddDoubleLine("vs equipped (" .. (r.imprBasis or "stats") .. ")",
            ("%s  (%s vs %s)"):format(UI:ImprovementText(r), r.imprScore, r.imprEquipped or 0), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    GameTooltip:AddLine("|cff00ff00Click|r: open in AH   |cff00ff00Shift-click|r: link   |cff00ff00Alt-click|r: preview", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end

-- Show/hide the hovered row's tooltip as Ctrl goes down/up.
function UI:OnModifierChanged(key, down)
    if not (key == "LCTRL" or key == "RCTRL") then return end
    local row = self.hoverRow
    if not (row and row:IsShown() and row:IsMouseOver()) then return end
    if down == 1 then
        self:ShowRowTooltip(row)
    elseif GameTooltip:IsOwned(row) then
        GameTooltip:Hide()
    end
end

function UI:CreateRow(i)
    local row = CreateFrame("Button", nil, self.list)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", self.list, "TOPLEFT", 2, -2 - (i - 1) * ROW_H)
    row:SetPoint("RIGHT", self.list, "RIGHT", -13, 0)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.deal = row:CreateTexture(nil, "BACKGROUND")
    row.deal:SetAllPoints()
    row.deal:SetColorTexture(1, 0.82, 0, 0.14)
    row.deal:Hide()
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(30, 30)
    row.icon:SetPoint("LEFT", 2, 0)

    row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.price:SetPoint("TOPRIGHT", -2, -4)
    row.price:SetJustifyH("RIGHT")

    row.impr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.impr:SetPoint("BOTTOMRIGHT", -2, 4)
    row.impr:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -1)
    row.name:SetPoint("RIGHT", row, "RIGHT", -100, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.stats = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.stats:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 1)
    row.stats:SetPoint("RIGHT", row, "RIGHT", -100, 0)
    row.stats:SetJustifyH("LEFT")
    row.stats:SetWordWrap(false)

    -- Item tooltips only while Ctrl is held, so scrolling the list
    -- doesn't keep covering it.
    row:SetScript("OnEnter", function(self)
        UI.hoverRow = self
        if IsControlKeyDown() then UI:ShowRowTooltip(self) end
    end)
    row:SetScript("OnLeave", function(self)
        if UI.hoverRow == self then UI.hoverRow = nil end
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    row:SetScript("OnClick", function(self)
        local r = self.result
        if not r then return end
        if IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
            if r.e.link then ChatEdit_InsertLink(r.e.link) end
        elseif IsAltKeyDown() and DressUpItemLink then
            if r.e.link then DressUpItemLink(r.e.link) end
        else
            UI:FindInAH(r.e)
        end
    end)
    return row
end

function UI:LayoutRows()
    if not self.list then return end
    local h = self.list:GetHeight() or 0
    local n = math.max(1, math.floor((h - 4) / ROW_H))
    self.visibleRows = n
    for i = 1, n do
        if not self.rows[i] then self.rows[i] = self:CreateRow(i) end
    end
    for i = n + 1, #self.rows do self.rows[i]:Hide() end
    self:UpdateScroll()
end

function UI:UpdateScroll()
    if not self.scroll then return end
    local maxOff = math.max(0, #self.results - (self.visibleRows or 1))
    self.scroll:SetMinMaxValues(0, maxOff)
    if self.offset > maxOff then self.offset = maxOff end
    self.scroll:SetValue(self.offset)
    self.scroll:SetShown(maxOff > 0)
    self:RenderRows()
end

function UI:StatLine(e)
    if e.partial then return "|cff888888stats unavailable (item data didn't load)|r" end
    local tags = e.tags or {}
    local parts, seen = {}, {}
    -- Tags you're searching for can hide their "twin" (Heal <-> SP).
    for _, r in ipairs(Settings().tags) do
        local t = ns.Tags.byId[r.id]
        if t and t.hides then
            for _, id in ipairs(t.hides) do seen[id] = true end
        end
    end
    local function push(tag, v, color)
        local val = ns.Tags.FormatValue(tag, v)
        parts[#parts + 1] = color .. ((val ~= "" and (val .. " ") or "") .. tag.short) .. "|r"
    end
    for _, r in ipairs(Settings().tags) do
        local tag, v = ns.Tags.byId[r.id], tags[r.id]
        if tag and v then push(tag, v, "|cff7fff7f"); seen[r.id] = true end
    end
    for _, tag in ipairs(ns.Tags.list) do
        if #parts >= 7 then break end
        local v = tags[tag.id]
        if v and not seen[tag.id] and not tag.hidden and tag.id ~= "armor" then push(tag, v, "|cffb0b0b0") end
    end
    return table.concat(parts, "  ")
end

function UI:RenderRows()
    self:RenderRowsInner()
    local row = self.hoverRow
    if row and row:IsShown() and row:IsMouseOver() then
        if IsControlKeyDown() then self:ShowRowTooltip(row) end
    end
end

function UI:RenderRowsInner()
    for i = 1, self.visibleRows or 0 do
        local row = self.rows[i]
        local r = self.results[self.offset + i]
        if r then
            local e = r.e
            row.result = r
            row.icon:SetTexture(e.icon or 134400)
            if e.usable == false then row.icon:SetVertexColor(1, 0.35, 0.35) else row.icon:SetVertexColor(1, 1, 1) end
            row.name:SetText(e.name or "?")
            row.name:SetTextColor(QualityColor(e.quality))
            row.stats:SetText(self:StatLine(e))
            if e.minPrice then
                row.price:SetText((r.bargain and "|cffffd100Deal|r  " or "") .. CompactMoney(e.minPrice))
            else
                row.price:SetText("-")
            end
            row.impr:SetText(UI:ImprovementText(r))
            row.deal:SetShown(r.bargain == true)
            row:Show()
        else
            row.result = nil
            row:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Hand-off to the native AH (buying stays 100% Blizzard UI)
---------------------------------------------------------------------------
function UI:FindInAH(e)
    local ah = AuctionHouseFrame
    local bar = ah and ah.SearchBar
    if not (ah and ah:IsShown() and bar and bar.SearchBox) then
        ns.Print("Open the auction house to find " .. (e.link or e.name or "item"))
        return
    end
    -- Best: open this exact item key (incl. random suffix) in the AH's buy view.
    if ah.SelectBrowseResult then
        local ok = pcall(ah.SelectBrowseResult, ah, {
            itemKey = ns.Scanner.MakeItemKey(e), minPrice = e.minPrice, totalQuantity = e.qty or 1,
        })
        if ok then return end
    end
    -- Fallback: search by name.
    local name = (e.name or ""):gsub("%s+$", "")
    ns.Filter.handoffName = name
    bar.SearchBox:SetText(name)
    local ok = pcall(function()
        if bar.StartSearch then
            bar:StartSearch()
        elseif bar.SearchButton then
            bar.SearchButton:Click()
        end
    end)
    if not ok then ns.Print("Couldn't start the AH search; the name is in the search box - press Search.") end
end
