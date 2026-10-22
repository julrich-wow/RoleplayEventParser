-- Initialize addon variables and viewer frame.
local addonName, addonTable = ...
local frameName = "RoleplayEventParserFrame"

-------------------------------------------------------------------------------
-- 0. Configuration & Performance Caches
-------------------------------------------------------------------------------
local GetTime, date, UnitName, Ambiguate = GetTime, date, UnitName, Ambiguate
local IsInGroup, IsInRaid, IsInInstance = IsInGroup, IsInRaid, IsInInstance
local GetNumGroupMembers, GetNumSubgroupMembers = GetNumGroupMembers, GetNumSubgroupMembers
local table_insert, table_remove, table_sort, math_max = table.insert, table.remove, table.sort, math.max

local VEP_CONFIG = {
    DEFAULT_WIDTH = 750, DEFAULT_HEIGHT = 400,
    MIN_WIDTH = 740, MIN_HEIGHT = 200, MAX_WIDTH = 1400, MAX_HEIGHT = 1000,
    DOUBLE_CLICK_THRESHOLD = 0.3, TOOLTIP_DELAY = 1.0,
    COLUMNS = {
        { name = "Time",         width = 75,  wrap = false, key = "time" },
        { name = "Character",    width = 145, wrap = true,  key = "character" },
        { name = "Avatar Name",  width = 135, wrap = true,  key = "avatar" },
        { name = "Emote Result", width = 140, wrap = true,  key = "marker" },
        { name = "Emote Text",   width = 220, wrap = true,  key = "text" }
    },
    KEYWORDS = { "damage", "safe", "guarding", "intercepting", "hitpoints", "hit points", "hit-points", "heal" },
    EVENTS = {
        "ADDON_LOADED", "CHAT_MSG_SAY", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
        "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
        "CHAT_MSG_EMOTE", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "READY_CHECK"
    }
}

local MARKER_WEIGHTS = {
    ["{star}"] = 1, ["{rt1}"] = 1, ["{yellow}"] = 1, ["★"] = 1,
    ["{circle}"] = 2, ["{rt2}"] = 2, ["{orange}"] = 2, ["●"] = 2,
    ["{diamond}"] = 3, ["{rt3}"] = 3, ["{purple}"] = 3, ["◆"] = 3,
    ["{triangle}"] = 4, ["{rt4}"] = 4, ["{green}"] = 4, ["▼"] = 4,
    ["{moon}"] = 5, ["{rt5}"] = 5, ["{silver}"] = 5, ["{white}"] = 5, ["♦"] = 5,
    ["{square}"] = 6, ["{rt6}"] = 6, ["{blue}"] = 6, ["■"] = 6, ["⬛"] = 6,
    ["{cross}"] = 7, ["{rt7}"] = 7, ["{x}"] = 7, ["{red}"] = 7, ["✖"] = 7, ["✕"] = 7, ["X"] = 7,
    ["{skull}"] = 8, ["{rt8}"] = 8, ["☠"] = 8, ["▲"] = 8
}

-------------------------------------------------------------------------------
-- 1. Helper Functions
-------------------------------------------------------------------------------
local function trim(s) return s and s:gsub("^%s*(.-)%s*$", "%1") or "" end
local function EscapePattern(s) return s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") end

local function ExtractFirstName(fullName)
    if not fullName or fullName == "" then return nil end
    return trim(fullName:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")):match("^(%S+)")
end

local function AttachDelayedTooltip(btn, text, delay)
    btn:SetScript("OnEnter", function(self)
        if self.timer then self.timer:Cancel() end
        self.timer = C_Timer.NewTimer(delay or VEP_CONFIG.TOOLTIP_DELAY, function()
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(text, nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
    end)
    btn:SetScript("OnLeave", function(self)
        if self.timer then self.timer:Cancel(); self.timer = nil end
        GameTooltip:Hide()
    end)
end

local function GetActiveKeywords()
    local str = REP_SavedDB and REP_SavedDB.keywordsText
    if not str or str == "" then return VEP_CONFIG.KEYWORDS end
    local list = {}
    for word in str:gmatch("[^,%s]+") do table_insert(list, word:lower()) end
    return (#list > 0) and list or VEP_CONFIG.KEYWORDS
end

local function GetFirstRaidMarkerWeight(text)
    if not text or text == "" then return 99 end
    local lower, pos, weight = text:lower(), nil, 99

    local texIndex = lower:match("raidtargetingicon_(%d)")
    if texIndex then
        local p = lower:find("raidtargetingicon_")
        if p then pos, weight = p, tonumber(texIndex) end
    end

    for token, w in pairs(MARKER_WEIGHTS) do
        local p = lower:find(token, 1, true)
        if p and (not pos or p < pos) then pos, weight = p, w end
    end
    return weight
end

-------------------------------------------------------------------------------
-- 2. Main Frame Construction
-------------------------------------------------------------------------------
local vep_mainframe = CreateFrame("Frame", frameName, UIParent, "BasicFrameTemplateWithInset")
vep_mainframe:SetSize(VEP_CONFIG.DEFAULT_WIDTH, VEP_CONFIG.DEFAULT_HEIGHT)
vep_mainframe:SetPoint("CENTER")
vep_mainframe:SetMovable(true)
vep_mainframe:SetResizable(true)
vep_mainframe:SetResizeBounds(VEP_CONFIG.MIN_WIDTH, VEP_CONFIG.MIN_HEIGHT, VEP_CONFIG.MAX_WIDTH, VEP_CONFIG.MAX_HEIGHT)
vep_mainframe:EnableMouse(true)
vep_mainframe:RegisterForDrag("LeftButton")
vep_mainframe:SetScript("OnDragStart", vep_mainframe.StartMoving)
vep_mainframe:SetScript("OnDragStop", vep_mainframe.StopMovingOrSizing)
vep_mainframe:SetClampedToScreen(true)
vep_mainframe:SetToplevel(true)
vep_mainframe:SetScript("OnMouseDown", function(self) self:Raise() end)

if vep_mainframe.TitleBg then vep_mainframe.TitleBg:SetHeight(30) end
vep_mainframe.title = vep_mainframe:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
vep_mainframe.title:SetPoint("LEFT", vep_mainframe.TitleBg or vep_mainframe, "LEFT", 10, vep_mainframe.TitleBg and 1 or -6)

local addonVersion = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")) or GetAddOnMetadata(addonName, "Version") or ""
vep_mainframe.title:SetText(addonVersion)

vep_mainframe:HookScript("OnShow", function() if REP_SavedDB then REP_SavedDB.isVisible = true end end)
vep_mainframe:HookScript("OnHide", function() if REP_SavedDB then REP_SavedDB.isVisible = false end end)

-- Confirmation Dialog
local confirmFrame = CreateFrame("Frame", nil, vep_mainframe, "BasicFrameTemplateWithInset")
confirmFrame:SetSize(300, 110)
confirmFrame:SetPoint("CENTER")
confirmFrame:SetFrameLevel(vep_mainframe:GetFrameLevel() + 20)
confirmFrame:Hide()
if confirmFrame.TitleBg then confirmFrame.TitleBg:SetHeight(24) end

confirmFrame.title = confirmFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
confirmFrame.title:SetPoint("LEFT", confirmFrame.TitleBg or confirmFrame, "LEFT", 8, confirmFrame.TitleBg and 0 or -6)
confirmFrame.title:SetText("Confirm Action")

local confirmText = confirmFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
confirmText:SetPoint("TOP", 0, -32)

local function CreateButton(parent, width, height, text, tooltip, onClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width, height)
    btn:SetText(text)
    if tooltip then AttachDelayedTooltip(btn, tooltip) end
    if onClick then btn:SetScript("OnClick", onClick) end
    return btn
end

CreateButton(confirmFrame, 80, 22, "Yes", nil, function() if confirmFrame.onConfirm then confirmFrame.onConfirm() end; confirmFrame:Hide() end):SetPoint("BOTTOMLEFT", 45, 12)
CreateButton(confirmFrame, 80, 22, "No", nil, function() confirmFrame:Hide() end):SetPoint("BOTTOMRIGHT", -45, 12)

local function ShowConfirmDialog(text, cb)
    confirmText:SetText(text)
    confirmFrame.onConfirm = cb
    confirmFrame:Show()
end

-------------------------------------------------------------------------------
-- 3. Header, Search & Scroll Setup
-------------------------------------------------------------------------------
local resetButton = CreateButton(vep_mainframe, 50, 20, "Reset", "Deletes all entries.", function(self)
    GameTooltip:Hide()
    local t = GetTime()
    if (t - (self.lastClick or 0)) <= VEP_CONFIG.DOUBLE_CLICK_THRESHOLD then
        vep_mainframe:ClearLog(); confirmFrame:Hide(); self.lastClick = 0
    else
        self.lastClick = t
        ShowConfirmDialog("Clear all entries from the log?", function() vep_mainframe:ClearLog() end)
    end
end)
resetButton:SetPoint("BOTTOMLEFT", 12, 8)

local cleanUpButton = CreateButton(vep_mainframe, 100, 20, "Clean Up Logs", "Deletes entries based on settings.", function(self)
    GameTooltip:Hide()
    local t = GetTime()
    if (t - (self.lastClick or 0)) <= VEP_CONFIG.DOUBLE_CLICK_THRESHOLD then
        vep_mainframe:CleanUpLog(); confirmFrame:Hide(); self.lastClick = 0
    else
        self.lastClick = t
        ShowConfirmDialog("Clean up log entries according to rules?", function() vep_mainframe:CleanUpLog() end)
    end
end)
cleanUpButton:SetPoint("LEFT", resetButton, "RIGHT", 6, 0)

vep_mainframe.innerElements = { resetButton, cleanUpButton }

local searchEditBox = CreateFrame("EditBox", nil, vep_mainframe, "InputBoxTemplate")
searchEditBox:SetSize(160, 20)
searchEditBox:SetPoint("BOTTOMRIGHT", -32, 8)
searchEditBox:SetAutoFocus(false)
searchEditBox:SetMaxLetters(50)
searchEditBox.instructions = searchEditBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
searchEditBox.instructions:SetPoint("LEFT", searchEditBox, "LEFT", 4, 0)
searchEditBox.instructions:SetText("Search log...")

searchEditBox:SetScript("OnTextChanged", function(self)
    if self:GetText() ~= "" then self.instructions:Hide() else self.instructions:Show() end
    vep_mainframe:SortAndRefreshRows()
end)
searchEditBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
searchEditBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
AttachDelayedTooltip(searchEditBox, "Filter log entries by character, avatar, text, or markers.")
table_insert(vep_mainframe.innerElements, searchEditBox)

local headerFrame = CreateFrame("Frame", nil, vep_mainframe)
headerFrame:SetPoint("TOPLEFT", 12, -32)
headerFrame:SetPoint("TOPRIGHT", -32, -32)
headerFrame:SetHeight(22)

local headerButtons, currentOffsetX = {}, 0

local function UpdateHeaderVisuals()
    local rules = (REP_SavedDB and REP_SavedDB.sortRules) or { { col = "character", asc = true }, { col = "time", asc = false } }
    for i, col in ipairs(VEP_CONFIG.COLUMNS) do
        local btn = headerButtons[i]
        if btn then
            local rIdx, rFound
            for idx, r in ipairs(rules) do if r.col == col.key then rIdx, rFound = idx, r; break end end
            if rFound then
                btn.text:SetText(col.name .. " [" .. (rFound.asc and "+" or "-") .. rIdx .. "]")
                btn.text:SetTextColor(1, 0.82, 0)
            else
                btn.text:SetText(col.name)
                btn.text:SetTextColor(0.9, 0.9, 0.9)
            end
        end
    end
end

for i, col in ipairs(VEP_CONFIG.COLUMNS) do
    local header = CreateFrame("Button", nil, headerFrame, "BackdropTemplate")
    header:SetSize(col.width, 22)
    header:SetPoint("LEFT", headerFrame, "LEFT", currentOffsetX, 0)
    header:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    header:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
    header:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    header.text = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header.text:SetPoint("LEFT", 6, 0)
    header.text:SetText(col.name)
    header.columnKey = col.key
    AttachDelayedTooltip(header, "Left-Click: Set Primary Sort || Shift-Click: Add Secondary Sort || Right-Click: Reset Sort")

    header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    header:SetScript("OnClick", function(self, button)
        REP_SavedDB = REP_SavedDB or {}
        REP_SavedDB.sortRules = REP_SavedDB.sortRules or { { col = "character", asc = true }, { col = "time", asc = false } }
        local rules = REP_SavedDB.sortRules

        if button == "RightButton" then
            REP_SavedDB.sortRules = { { col = "character", asc = true }, { col = "time", asc = false } }
        else
            local isShift, targetKey, existingIdx = IsShiftKeyDown(), self.columnKey, nil
            for idx, r in ipairs(rules) do if r.col == targetKey then existingIdx = idx; break end end
            if isShift then
                if existingIdx then rules[existingIdx].asc = not rules[existingIdx].asc
                else table_insert(rules, { col = targetKey, asc = true }) end
            else
                if existingIdx == 1 then rules[1].asc = not rules[1].asc
                else REP_SavedDB.sortRules = { { col = targetKey, asc = existingIdx and rules[existingIdx].asc or true } } end
            end
        end
        UpdateHeaderVisuals()
        vep_mainframe:SortAndRefreshRows()
    end)
    headerButtons[i] = header
    currentOffsetX = currentOffsetX + col.width
end

local scrollFrame = CreateFrame("ScrollFrame", nil, vep_mainframe, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -4)
scrollFrame:SetPoint("BOTTOMRIGHT", -32, 36)

local contentFrame = CreateFrame("Frame", nil, scrollFrame)
contentFrame:SetSize(700, 1)
scrollFrame:SetScrollChild(contentFrame)

local resizeBackdrop = CreateFrame("Frame", nil, vep_mainframe, "BackdropTemplate")
resizeBackdrop:SetSize(24, 24)
resizeBackdrop:SetPoint("BOTTOMRIGHT", -3, 3)
resizeBackdrop:SetFrameLevel(vep_mainframe:GetFrameLevel() + 10)
resizeBackdrop:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
resizeBackdrop:SetBackdropColor(0.1, 0.1, 0.1, 0.85)
resizeBackdrop:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)

local resizeButton = CreateFrame("Button", nil, resizeBackdrop)
resizeButton:SetSize(16, 16)
resizeButton:SetPoint("CENTER")
resizeButton:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeButton:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeButton:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
resizeButton:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then vep_mainframe:StartSizing("BOTTOMRIGHT") end end)
resizeButton:SetScript("OnMouseUp", function() vep_mainframe:StopMovingOrSizing() end)

-------------------------------------------------------------------------------
-- 4. Compact Settings Window
-------------------------------------------------------------------------------
local settingsFrame = CreateFrame("Frame", "RoleplayEventParserSettingsFrame", UIParent, "BasicFrameTemplateWithInset")
settingsFrame:SetSize(410, 420)
settingsFrame:SetPoint("CENTER")
settingsFrame:SetMovable(true)
settingsFrame:EnableMouse(true)
settingsFrame:RegisterForDrag("LeftButton")
settingsFrame:SetScript("OnDragStart", settingsFrame.StartMoving)
settingsFrame:SetScript("OnDragStop", settingsFrame.StopMovingOrSizing)
settingsFrame:SetClampedToScreen(true)
settingsFrame:SetToplevel(true)
settingsFrame:Hide()

if settingsFrame.TitleBg then settingsFrame.TitleBg:SetHeight(30) end
settingsFrame.title = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
settingsFrame.title:SetPoint("LEFT", settingsFrame.TitleBg or settingsFrame, "LEFT", 10, settingsFrame.TitleBg and 1 or -6)
settingsFrame.title:SetText(addonVersion .. " - Settings")

settingsFrame:HookScript("OnShow", function() if REP_SavedDB then REP_SavedDB.isSettingsVisible = true end end)
settingsFrame:HookScript("OnHide", function() if REP_SavedDB then REP_SavedDB.isSettingsVisible = false end end)

local function CreateCheckbox(parent, text, x, y, tbl, key)
    local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local cbText = cb.Text or _G[cb:GetName() .. "Text"]
    if cbText then cbText:SetText(text); cbText:SetFontObject("GameFontHighlightSmall") end
    cb:SetScript("OnClick", function(self)
        if REP_SavedDB then
            if tbl then REP_SavedDB[tbl] = REP_SavedDB[tbl] or {}; REP_SavedDB[tbl][key] = self:GetChecked()
            else REP_SavedDB[key] = self:GetChecked() end
        end
    end)
    return cb
end

local function AddHeader(parent, text, x, y)
    local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    h:SetText(text)
    return h
end

AddHeader(settingsFrame, "Channels to Capture", 16, -36)
local cbSay = CreateCheckbox(settingsFrame, "Say (/say)", 18, -54, "channels", "say")
local cbParty = CreateCheckbox(settingsFrame, "Party (/party)", 18, -74, "channels", "party")
local cbRaid = CreateCheckbox(settingsFrame, "Raid / Raid Warning", 18, -94, "channels", "raid")
local cbEmote = CreateCheckbox(settingsFrame, "Emote (/emote)", 18, -114, "channels", "emote")
local cbInstance = CreateCheckbox(settingsFrame, "Instance Chat", 18, -134, "channels", "instance")

AddHeader(settingsFrame, "Parse Text When", 215, -36)
local cbModeUngrouped = CreateCheckbox(settingsFrame, "Ungrouped", 217, -54, "modes", "ungrouped")
local cbModeParty = CreateCheckbox(settingsFrame, "In a party", 217, -74, "modes", "party")
local cbModeRaid = CreateCheckbox(settingsFrame, "In a raid", 217, -94, "modes", "raid")

AddHeader(settingsFrame, "General Options & Matching Rules", 16, -164)
local cbMatchMarkers = CreateCheckbox(settingsFrame, "Match raid markers", 18, -182, nil, "matchRaidMarkers")
AttachDelayedTooltip(cbMatchMarkers, "Match events with raid markers", VEP_CONFIG.TOOLTIP_DELAY)
local cbMatchDigits = CreateCheckbox(settingsFrame, "Match digits", 217, -182, nil, "matchDigits")
AttachDelayedTooltip(cbMatchDigits, "Match events with digits", VEP_CONFIG.TOOLTIP_DELAY)
local cbMatchMyName = CreateCheckbox(settingsFrame, "Match my name", 18, -202, nil, "matchMyName")
AttachDelayedTooltip(cbMatchMyName, "Match events mentioning your name", VEP_CONFIG.TOOLTIP_DELAY)
local cbDisableInstanced = CreateCheckbox(settingsFrame, "Disable in instanced content", 217, -202, nil, "disableInstanced")
AttachDelayedTooltip(cbDisableInstanced, "Disable matching in instances", VEP_CONFIG.TOOLTIP_DELAY)

AddHeader(settingsFrame, "Log Clean Up Behavior", 16, -230)
local cbCleanPredates = CreateCheckbox(settingsFrame, "Delete entries before last ready check", 18, -248, "cleanup", "predates")
local cbCleanDimmed = CreateCheckbox(settingsFrame, "Delete dimmed log entries", 18, -268, "cleanup", "dimmed")
local cbReadyDim = CreateCheckbox(settingsFrame, "Auto-dim old entries on ready check", 18, -288, nil, "readyCheckDim")

AddHeader(settingsFrame, "Keywords", 16, -318)
local keywordsEditBox = CreateFrame("EditBox", nil, settingsFrame, "InputBoxTemplate")
keywordsEditBox:SetSize(255, 20)
keywordsEditBox:SetPoint("TOPLEFT", 22, -338)
keywordsEditBox:SetAutoFocus(false)
keywordsEditBox:SetScript("OnTextChanged", function(self, user) if user and REP_SavedDB then REP_SavedDB.keywordsText = self:GetText() end end)
keywordsEditBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
keywordsEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local resetKeywordsBtn = CreateButton(settingsFrame, 105, 20, "Reset Keywords", "Reset keywords to defaults.", function()
    ShowConfirmDialog("Reset keywords to default values?", function()
        local defStr = table.concat(VEP_CONFIG.KEYWORDS, ", ")
        if REP_SavedDB then REP_SavedDB.keywordsText = defStr end
        keywordsEditBox:SetText(defStr)
    end)
end)
resetKeywordsBtn:SetPoint("LEFT", keywordsEditBox, "RIGHT", 10, 0)

local settingsButton = CreateButton(vep_mainframe, 65, 20, "Settings", "Configure addon settings.", function()
    if settingsFrame:IsShown() then settingsFrame:Hide() else settingsFrame:Show() end
end)
settingsButton:SetPoint("LEFT", cleanUpButton, "RIGHT", 6, 0)
table_insert(vep_mainframe.innerElements, settingsButton)
table_insert(vep_mainframe.innerElements, headerFrame)
table_insert(vep_mainframe.innerElements, scrollFrame)
table_insert(vep_mainframe.innerElements, resizeBackdrop)

-------------------------------------------------------------------------------
-- 5. Minimize Controller
-------------------------------------------------------------------------------
local isMinimized, savedWidth, savedHeight = false, VEP_CONFIG.DEFAULT_WIDTH, VEP_CONFIG.DEFAULT_HEIGHT
local minimizeButton = CreateButton(vep_mainframe, 20, 20, "_", nil, function() ApplyMinimizedState(not isMinimized) end)
local closeBtn = vep_mainframe.CloseButton or vep_mainframe.closeButton
if closeBtn then minimizeButton:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
else minimizeButton:SetPoint("TOPRIGHT", -26, -5) end

function ApplyMinimizedState(minimized)
    isMinimized = minimized
    confirmFrame:Hide()
    if isMinimized then
        savedWidth = vep_mainframe:GetWidth()
        savedHeight = vep_mainframe:GetHeight()
        if REP_SavedDB then REP_SavedDB.savedWidth, REP_SavedDB.savedHeight = savedWidth, savedHeight end
        vep_mainframe:SetResizable(false)
        vep_mainframe:SetSize(200, 28)
        for _, el in ipairs(vep_mainframe.innerElements) do el:Hide() end
        if vep_mainframe.Bg then vep_mainframe.Bg:Hide() end
        if vep_mainframe.NineSlice then vep_mainframe.NineSlice:Hide() end
        if vep_mainframe.Inset then vep_mainframe.Inset:Hide() end
        if vep_mainframe.TopTileStreaks then vep_mainframe.TopTileStreaks:Hide() end
        minimizeButton:SetText("+")
    else
        vep_mainframe:SetSize((REP_SavedDB and REP_SavedDB.savedWidth) or savedWidth, (REP_SavedDB and REP_SavedDB.savedHeight) or savedHeight)
        vep_mainframe:SetResizable(true)
        for _, el in ipairs(vep_mainframe.innerElements) do el:Show() end
        if vep_mainframe.Bg then vep_mainframe.Bg:Show() end
        if vep_mainframe.NineSlice then vep_mainframe.NineSlice:Show() end
        if vep_mainframe.Inset then vep_mainframe.Inset:Show() end
        if vep_mainframe.TopTileStreaks then vep_mainframe.TopTileStreaks:Show() end
        minimizeButton:SetText("_")
        vep_mainframe:UpdateLayoutWidths()
    end
    if REP_SavedDB then REP_SavedDB.isMinimized = isMinimized end
end

vep_mainframe:SetSize(VEP_CONFIG.DEFAULT_WIDTH, VEP_CONFIG.DEFAULT_HEIGHT)
vep_mainframe:Hide()

-------------------------------------------------------------------------------
-- 6. Dynamic Layout & Row Processing
-------------------------------------------------------------------------------
vep_mainframe.rows = {}
vep_mainframe.lastReadyCheckTime = 0

function vep_mainframe:DeleteRow(row)
    if not row then return end
    for i = #self.rows, 1, -1 do if self.rows[i] == row then table_remove(self.rows, i); break end end
    if REP_SavedDB and REP_SavedDB.rows then
        for i = #REP_SavedDB.rows, 1, -1 do if REP_SavedDB.rows[i].timestamp == row.timestamp then table_remove(REP_SavedDB.rows, i); break end end
    end
    row:Hide(); row:SetParent(nil)
    self:SortAndRefreshRows()
end

function vep_mainframe:UpdateLayoutWidths()
    if isMinimized then return end
    local availWidth = math_max(scrollFrame:GetWidth() - 5, 700)
    local fixedWidths = VEP_CONFIG.COLUMNS[1].width + VEP_CONFIG.COLUMNS[2].width + VEP_CONFIG.COLUMNS[3].width + VEP_CONFIG.COLUMNS[4].width
    VEP_CONFIG.COLUMNS[5].width = math_max(availWidth - fixedWidths, 120)
    contentFrame:SetWidth(availWidth)

    local offsetX = 0
    for i, col in ipairs(VEP_CONFIG.COLUMNS) do
        if headerButtons[i] then headerButtons[i]:SetWidth(col.width); headerButtons[i]:SetPoint("LEFT", headerFrame, "LEFT", offsetX, 0) end
        offsetX = offsetX + col.width
    end

    for _, row in ipairs(self.rows) do
        row:SetWidth(availWidth)
        local rHeight = 22
        local cOffset = 0
        for i, col in ipairs(VEP_CONFIG.COLUMNS) do
            if row.cells[i] then
                row.cells[i]:SetWidth(col.width - 10)
                row.cells[i]:SetPoint("TOPLEFT", row, "TOPLEFT", cOffset + 6, -4)
                rHeight = math_max(rHeight, row.cells[i]:GetStringHeight() + 8)
            end
            cOffset = cOffset + col.width
        end
        row:SetHeight(rHeight)
    end
    self:SortAndRefreshRows()
end

vep_mainframe:SetScript("OnSizeChanged", function() vep_mainframe:UpdateLayoutWidths() end)

function vep_mainframe:ClearLog()
    for _, row in ipairs(self.rows) do row:Hide(); row:SetParent(nil) end
    vep_mainframe.rows = {}
    if REP_SavedDB then REP_SavedDB.rows = {} end
    contentFrame:SetHeight(1)
end

function vep_mainframe:CleanUpLog()
    local keptRows, keptSaved, hasRC = {}, {}, (self.lastReadyCheckTime and self.lastReadyCheckTime > 0)
    local delPredates = REP_SavedDB and REP_SavedDB.cleanup and REP_SavedDB.cleanup.predates
    local delDimmed = REP_SavedDB and REP_SavedDB.cleanup and REP_SavedDB.cleanup.dimmed

    for _, row in ipairs(self.rows) do
        local predates = hasRC and (row.timestamp and row.timestamp < self.lastReadyCheckTime)
        if (delPredates and predates) or (delDimmed and row.isDimmed) then
            row:Hide(); row:SetParent(nil)
        else
            table_insert(keptRows, row)
            if REP_SavedDB and REP_SavedDB.rows then
                for _, sData in ipairs(REP_SavedDB.rows) do if sData.timestamp == row.timestamp then table_insert(keptSaved, sData); break end end
            end
        end
    end
    self.rows = keptRows
    if REP_SavedDB then REP_SavedDB.rows = keptSaved end
    self:SortAndRefreshRows()
end

local function GetRowValue(row, key)
    if key == "time" then return row.timestamp or 0
    elseif key == "character" then return (row.characterName or ""):lower()
    elseif key == "avatar" then return (row.avatarName or ""):lower()
    elseif key == "marker" then return GetFirstRaidMarkerWeight((row.emoteResult or "") .. " " .. (row.emoteText or ""))
    elseif key == "text" then return (row.emoteText or ""):lower() end
    return 0
end

function vep_mainframe:SortAndRefreshRows()
    local rules = (REP_SavedDB and REP_SavedDB.sortRules) or { { col = "character", asc = true }, { col = "time", asc = false } }
    local filter = searchEditBox and searchEditBox:GetText():lower() or ""

    table_sort(self.rows, function(a, b)
        for _, r in ipairs(rules) do
            local vA, vB = GetRowValue(a, r.col), GetRowValue(b, r.col)
            if vA ~= vB then return r.asc and vA < vB or vA > vB end
        end
        return false
    end)

    local offsetY, vIndex = 0, 0
    for _, row in ipairs(self.rows) do
        local match = true
        if filter ~= "" then
            local combined = ((row.characterName or "") .. " " .. (row.avatarName or "") .. " " .. (row.emoteResult or "") .. " " .. (row.emoteText or "")):lower()
            local direct = combined:find(filter, 1, true)
            local tWeight = MARKER_WEIGHTS[filter] or MARKER_WEIGHTS["{" .. filter .. "}"]
            local markerMatch = tWeight and (GetFirstRaidMarkerWeight((row.emoteResult or "") .. " " .. (row.emoteText or "")) == tWeight)
            if not direct and not markerMatch then match = false end
        end

        if match then
            row:Show(); row:ClearAllPoints()
            row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, -offsetY)
            vIndex = vIndex + 1
            row.rowIndex = vIndex
            row:SetBackdropColor(vIndex % 2 == 0 and 0.1 or 0.2, vIndex % 2 == 0 and 0.1 or 0.2, vIndex % 2 == 0 and 0.1 or 0.2, vIndex % 2 == 0 and 0.4 or 0.2)
            offsetY = offsetY + row:GetHeight()
        else
            row:Hide()
        end
    end
    contentFrame:SetHeight(math_max(offsetY, 1))
end

function vep_mainframe:AddRow(timeStr, charName, avName, resText, emoteText, isDimmed, timestamp, skipSave)
    local width = contentFrame:GetWidth()
    local row = CreateFrame("Button", nil, contentFrame, "BackdropTemplate")
    row.characterName, row.avatarName, row.timeString = charName or "", avName or "", timeStr or ""
    row.timestamp, row.emoteResult, row.emoteText = timestamp or GetTime(), resText or "", emoteText or ""
    row.cells, row.isDimmed = {}, isDimmed or false

    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    local alpha = row.isDimmed and 0.5 or 1.0

    row:SetScript("OnEnter", function(self) self:SetBackdropColor(0.25, 0.35, 0.5, 0.6) end)
    row:SetScript("OnLeave", function(self)
        local idx = self.rowIndex or 1
        self:SetBackdropColor(idx % 2 == 0 and 0.1 or 0.2, idx % 2 == 0 and 0.1 or 0.2, idx % 2 == 0 and 0.1 or 0.2, idx % 2 == 0 and 0.4 or 0.2)
    end)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    row:SetScript("OnClick", function(self, btn)
        local t = GetTime()
        if btn == "MiddleButton" then
            local target = (self.avatarName ~= "" and self.avatarName) or self.characterName
            if target ~= "" then ChatFrame_OpenChat("/w " .. target .. " ") end
        elseif btn == "RightButton" then
            if (t - (self.lastRightClick or 0)) <= VEP_CONFIG.DOUBLE_CLICK_THRESHOLD then vep_mainframe:DeleteRow(self); self.lastRightClick = 0
            else self.lastRightClick = t end
        elseif btn == "LeftButton" then
            if (t - (self.lastClick or 0)) <= VEP_CONFIG.DOUBLE_CLICK_THRESHOLD then
                self.isDimmed = not self.isDimmed
                local a = self.isDimmed and 0.5 or 1.0
                for _, cell in ipairs(self.cells) do cell:SetAlpha(a) end
                if REP_SavedDB and REP_SavedDB.rows then
                    for _, s in ipairs(REP_SavedDB.rows) do if s.timestamp == self.timestamp then s.isDimmed = self.isDimmed; break end end
                end
                self.lastClick = 0
            else self.lastClick = t end
        end
    end)
    AttachDelayedTooltip(row, "Middle click to whisper || Double right-click to delete")

    local values, cOffset, rHeight = { timeStr, charName, avName, resText, emoteText }, 0, 22
    for i, col in ipairs(VEP_CONFIG.COLUMNS) do
        local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetPoint("TOPLEFT", row, "TOPLEFT", cOffset + 6, -4)
        cell:SetWidth(col.width - 10)
        cell:SetJustifyH("LEFT")
        cell:SetWordWrap(col.wrap or false)
        cell:SetAlpha(alpha)

        local val = values[i] or ""
        if C_ChatInfo and C_ChatInfo.ReplaceIconAndGroupExpressions then val = C_ChatInfo.ReplaceIconAndGroupExpressions(val) end
        cell:SetText(val)
        row.cells[i] = cell
        rHeight = math_max(rHeight, cell:GetStringHeight() + 8)
        cOffset = cOffset + col.width
    end

    row:SetSize(width, rHeight)
    table_insert(self.rows, row)

    if not skipSave and REP_SavedDB then
        REP_SavedDB.rows = REP_SavedDB.rows or {}
        table_insert(REP_SavedDB.rows, { timeString = timeStr, characterName = charName, avatarName = avName, emoteResult = resText, emoteText = emoteText, isDimmed = row.isDimmed, timestamp = row.timestamp })
    end
    self:SortAndRefreshRows()
end

-------------------------------------------------------------------------------
-- 7. Chat Parsing & Event Handling
-------------------------------------------------------------------------------
local function ResolvePlayerNames()
    local blizz = UnitName("player")
    local trp, trpFirst = nil, nil
    if C_AddOns and C_AddOns.IsAddOnLoaded("TotalRP3") and TRP3_API then
        local uID = TRP3_API.utils.str.getUnitID("player")
        if uID then
            trp = TRP3_API.register.getUnitRPName("player") or TRP3_API.chat.getFullnameForUnitUsingChatMethod(uID)
            if trp then trpFirst = ExtractFirstName(trp) end
        end
    end
    return blizz, trp, trpFirst
end

local function EvaluateMatchCriteria(cleanInner, rawMsg)
    if REP_SavedDB and REP_SavedDB.matchRaidMarkers and (rawMsg:find("[▼●◆▲★♦]") or rawMsg:find("{.-}") or rawMsg:find("|T.-|t") or rawMsg:lower():find("{%a+}")) then return true end
    if REP_SavedDB and REP_SavedDB.matchDigits and cleanInner:find("%d") then return true end
    for _, kw in ipairs(GetActiveKeywords()) do if cleanInner:find(EscapePattern(kw)) then return true end end
    return false
end

local function ResolveCharacterName(cleanSender, playerClean)
    if not (C_AddOns and C_AddOns.IsAddOnLoaded("TotalRP3") and TRP3_API) then return nil end
    if cleanSender == playerClean then
        local uID = TRP3_API.utils.str.getUnitID("player")
        if uID then return TRP3_API.register.getUnitRPName("player") or TRP3_API.chat.getFullnameForUnitUsingChatMethod(uID) end
    else
        local prefix, num = (IsInRaid() and "raid") or "party", (IsInRaid() and GetNumGroupMembers()) or GetNumSubgroupMembers()
        for i = 1, num do
            local uName, uRealm = UnitName(prefix .. i)
            if uName then
                local fullName = (uRealm and uRealm ~= "") and (uName .. "-" .. uRealm) or uName
                if Ambiguate(fullName, "none") == cleanSender then
                    local uID = TRP3_API.utils.str.getUnitID(prefix .. i)
                    if uID then return TRP3_API.register.getUnitRPName(prefix .. i) or TRP3_API.chat.getFullnameForUnitUsingChatMethod(uID) end
                    break
                end
            end
        end
        if TRP3_API.chat and TRP3_API.chat.getFullnameForUnitUsingChatMethod then return TRP3_API.chat.getFullnameForUnitUsingChatMethod(cleanSender) end
    end
    return nil
end

local chatFrame, authorBuffers, BUFFER_WINDOW = CreateFrame("Frame"), {}, 2.5

local function FlushAuthorBuffer(cleanSender)
    local buf = authorBuffers[cleanSender]
    if not buf or not buf.hasValidMatch then return end
    authorBuffers[cleanSender] = nil
    vep_mainframe:AddRow(buf.timeString, buf.characterName, buf.avatarName, table.concat(buf.results, " "), table.concat(buf.texts, " "))
end

chatFrame:SetScript("OnEvent", function(_, event, message, sender, ...)
    if event == "ADDON_LOADED" and message == addonName then
        local defStr = table.concat(VEP_CONFIG.KEYWORDS, ", ")
        REP_SavedDB = REP_SavedDB or { rows = {} }
        REP_SavedDB.rows = REP_SavedDB.rows or {}
        REP_SavedDB.lastReadyCheckTime = REP_SavedDB.lastReadyCheckTime or 0
        if REP_SavedDB.isVisible == nil then REP_SavedDB.isVisible = true end
        if REP_SavedDB.isSettingsVisible == nil then REP_SavedDB.isSettingsVisible = false end
        if REP_SavedDB.isMinimized == nil then REP_SavedDB.isMinimized = false end
        REP_SavedDB.savedWidth = REP_SavedDB.savedWidth or VEP_CONFIG.DEFAULT_WIDTH
        REP_SavedDB.savedHeight = REP_SavedDB.savedHeight or VEP_CONFIG.DEFAULT_HEIGHT
        if REP_SavedDB.readyCheckDim == nil then REP_SavedDB.readyCheckDim = false end
        if REP_SavedDB.disableInstanced == nil then REP_SavedDB.disableInstanced = false end
        if REP_SavedDB.matchRaidMarkers == nil then REP_SavedDB.matchRaidMarkers = true end
        if REP_SavedDB.matchDigits == nil then REP_SavedDB.matchDigits = true end
        if REP_SavedDB.matchMyName == nil then REP_SavedDB.matchMyName = true end
        if REP_SavedDB.keywordsText == nil then REP_SavedDB.keywordsText = defStr end
        REP_SavedDB.channels = REP_SavedDB.channels or { say = true, party = true, raid = true, emote = true, instance = true }
        REP_SavedDB.modes = REP_SavedDB.modes or { ungrouped = true, party = true, raid = true }
        REP_SavedDB.cleanup = REP_SavedDB.cleanup or { predates = true, dimmed = true }
        REP_SavedDB.sortRules = REP_SavedDB.sortRules or { { col = "character", asc = true }, { col = "time", asc = false } }

        cbSay:SetChecked(REP_SavedDB.channels.say)
        cbParty:SetChecked(REP_SavedDB.channels.party)
        cbRaid:SetChecked(REP_SavedDB.channels.raid)
        cbEmote:SetChecked(REP_SavedDB.channels.emote)
        cbInstance:SetChecked(REP_SavedDB.channels.instance)
        cbModeUngrouped:SetChecked(REP_SavedDB.modes.ungrouped)
        cbModeParty:SetChecked(REP_SavedDB.modes.party)
        cbModeRaid:SetChecked(REP_SavedDB.modes.raid)
        cbCleanPredates:SetChecked(REP_SavedDB.cleanup.predates)
        cbCleanDimmed:SetChecked(REP_SavedDB.cleanup.dimmed)
        cbReadyDim:SetChecked(REP_SavedDB.readyCheckDim)
        cbDisableInstanced:SetChecked(REP_SavedDB.disableInstanced)
        cbMatchMarkers:SetChecked(REP_SavedDB.matchRaidMarkers)
        cbMatchDigits:SetChecked(REP_SavedDB.matchDigits)
        cbMatchMyName:SetChecked(REP_SavedDB.matchMyName)
        keywordsEditBox:SetText(REP_SavedDB.keywordsText)

        vep_mainframe.lastReadyCheckTime = REP_SavedDB.lastReadyCheckTime
        ApplyMinimizedState(REP_SavedDB.isMinimized)
        UpdateHeaderVisuals()

        if REP_SavedDB.isVisible then vep_mainframe:Show() else vep_mainframe:Hide() end
        if REP_SavedDB.isSettingsVisible then settingsFrame:Show() else settingsFrame:Hide() end

        if REP_SavedDB.rows and #REP_SavedDB.rows > 0 then
            local saved = REP_SavedDB.rows
            REP_SavedDB.rows = {}
            for _, e in ipairs(saved) do vep_mainframe:AddRow(e.timeString, e.characterName, e.avatarName, e.emoteResult, e.emoteText, e.isDimmed, e.timestamp, false) end
        end
        return
    end

    if event == "READY_CHECK" then
        vep_mainframe.lastReadyCheckTime = GetTime()
        if REP_SavedDB then
            REP_SavedDB.lastReadyCheckTime = vep_mainframe.lastReadyCheckTime
            if REP_SavedDB.readyCheckDim and vep_mainframe.rows then
                for _, row in ipairs(vep_mainframe.rows) do
                    row.isDimmed = true
                    for _, c in ipairs(row.cells) do c:SetAlpha(0.5) end
                    for _, s in ipairs(REP_SavedDB.rows or {}) do if s.timestamp == row.timestamp then s.isDimmed = true end end
                end
            end
        end
        return
    end

    if type(sender) ~= "string" or sender == "" then return end
    if REP_SavedDB and REP_SavedDB.disableInstanced then
        local inInst, iType = IsInInstance()
        if inInst and (iType == "party" or iType == "raid" or iType == "scenario") then return end
    end

    local isSay, isParty, isRaid, isEmote, isInst = (event == "CHAT_MSG_SAY"), (event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER"), (event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" or event == "CHAT_MSG_RAID_WARNING"), (event == "CHAT_MSG_EMOTE"), (event == "CHAT_MSG_INSTANCE_CHAT" or event == "CHAT_MSG_INSTANCE_CHAT_LEADER")
    local ch = REP_SavedDB and REP_SavedDB.channels
    if ch then
        if isSay and not ch.say then return end
        if isParty and not ch.party then return end
        if isRaid and not ch.raid then return end
        if isEmote and not ch.emote then return end
        if isInst and not ch.instance then return end
    end

    local inGrp, inRd, modes = IsInGroup(), IsInRaid(), REP_SavedDB and REP_SavedDB.modes
    if not inGrp and modes and not modes.ungrouped then return end
    if inGrp and not inRd and modes and not modes.party then return end
    if inRd and modes and not modes.raid then return end

    local cleanSender, playerClean = Ambiguate(sender, "none"), Ambiguate(UnitName("player"), "none")
    local pattern, removePattern = "([%(%[][^%]%)]-[%]%)])", "[%(%[][^%]%)]-[%]%)]"
    local results, hasMatch = {}, false

    if REP_SavedDB and REP_SavedDB.matchMyName then
        local bName, tName, tFirst = ResolvePlayerNames()
        local lowerMsg = message:lower()
        if (bName and bName ~= "" and lowerMsg:find(EscapePattern(bName:lower()))) or (tName and tName ~= "" and lowerMsg:find(EscapePattern(tName:lower()))) or (tFirst and tFirst ~= "" and lowerMsg:find(EscapePattern(tFirst:lower()))) then
            hasMatch = true
        end
    end

    for match in message:gmatch(pattern) do
        local cleanInner = trim(match:sub(2, -2)):lower()
        if cleanInner ~= "" and cleanInner ~= "flavor" then
            table_insert(results, match)
            if EvaluateMatchCriteria(cleanInner, message) then hasMatch = true end
        end
    end

    local actionEmote = trim(message:gsub(removePattern, ""))
    if event == "CHAT_MSG_EMOTE" then actionEmote = trim(actionEmote:gsub("^" .. cleanSender .. "%s*", "")) end

    local avatarName, charName, timeStr = cleanSender, ResolveCharacterName(cleanSender, playerClean) or cleanSender, date("%H:%M:%S")

    if authorBuffers[cleanSender] then
        local buf = authorBuffers[cleanSender]
        if buf.timer then buf.timer:Cancel() end
        for _, r in ipairs(results) do table_insert(buf.results, r) end
        if actionEmote ~= "" then table_insert(buf.texts, actionEmote) end
        if hasMatch then buf.hasValidMatch = true end
        buf.characterName = charName
        buf.timer = C_Timer.NewTimer(BUFFER_WINDOW, function() FlushAuthorBuffer(cleanSender) end)
    else
        authorBuffers[cleanSender] = {
            timeString = timeStr, characterName = charName, avatarName = avatarName,
            results = results, texts = actionEmote ~= "" and { actionEmote } or {},
            hasValidMatch = hasMatch,
            timer = C_Timer.NewTimer(BUFFER_WINDOW, function() FlushAuthorBuffer(cleanSender) end)
        }
    end
end)

for _, e in ipairs(VEP_CONFIG.EVENTS) do chatFrame:RegisterEvent(e) end

-------------------------------------------------------------------------------
-- 8. Slash Command Integration
-------------------------------------------------------------------------------
SLASH_ROLEPLAYEVENTPARSER1 = "/rp-parse"
SlashCmdList["ROLEPLAYEVENTPARSER"] = function(msg)
    if trim(msg:lower()) == "reset" then
        if REP_SavedDB then
            REP_SavedDB.isMinimized, REP_SavedDB.savedWidth, REP_SavedDB.savedHeight, REP_SavedDB.isVisible, REP_SavedDB.sortRules = false, VEP_CONFIG.DEFAULT_WIDTH, VEP_CONFIG.DEFAULT_HEIGHT, true, { { col = "character", asc = true }, { col = "time", asc = false } }
        end
        ApplyMinimizedState(false)
        UpdateHeaderVisuals()
        RoleplayEventParserFrame:ClearAllPoints()
        RoleplayEventParserFrame:SetPoint("CENTER")
        RoleplayEventParserFrame:SetSize(VEP_CONFIG.DEFAULT_WIDTH, VEP_CONFIG.DEFAULT_HEIGHT)
        RoleplayEventParserFrame:Show()
        RoleplayEventParserFrame:UpdateLayoutWidths()
    else
        if vep_mainframe:IsShown() then vep_mainframe:Hide() else vep_mainframe:Show() end
    end
end