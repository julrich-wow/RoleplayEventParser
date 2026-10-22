-- Initialize addon variables and viewer frame.
local addonName, addonTable = ...
local frameName = "RoleplayEventParserFrame"

-------------------------------------------------------------------------------
-- 0. Configuration & Local Performance Caches
-------------------------------------------------------------------------------
local GetTime = GetTime
local date = date
local UnitName = UnitName
local Ambiguate = Ambiguate
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local IsInInstance = IsInInstance
local GetNumGroupMembers = GetNumGroupMembers
local GetNumSubgroupMembers = GetNumSubgroupMembers
local string_lower = string.lower
local string_find = string.find
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort
local math_max = math.max
local IsShiftKeyDown = IsShiftKeyDown

local VEP_CONFIG = {
    DEFAULT_WIDTH = 750,
    DEFAULT_HEIGHT = 400,
    MIN_WIDTH = 740,
    MIN_HEIGHT = 200,
    MAX_WIDTH = 1400,
    MAX_HEIGHT = 1000,
    DOUBLE_CLICK_THRESHOLD = 0.3,
    TOOLTIP_DELAY = 1.0,
    
    COLUMNS = {
        { name = "Time",         width = 75,  wrap = false, key = "time" },
        { name = "Character",    width = 145, wrap = true,  key = "character" },
        { name = "Avatar Name",  width = 135, wrap = true,  key = "avatar" },
        { name = "Emote Result", width = 140, wrap = true,  key = "marker" },
        { name = "Emote Text",   width = 220, wrap = true,  key = "text" }
    },
    
    KEYWORDS = { "damage", "safe", "guarding", "intercepting", "hitpoints", "hit points", "hit-points", "heal" },
    
    EVENTS = {
        "ADDON_LOADED",
        "CHAT_MSG_SAY",
        "CHAT_MSG_PARTY",
        "CHAT_MSG_PARTY_LEADER",
        "CHAT_MSG_RAID",
        "CHAT_MSG_RAID_LEADER",
        "CHAT_MSG_RAID_WARNING",
        "CHAT_MSG_EMOTE",
        "CHAT_MSG_INSTANCE_CHAT",
        "CHAT_MSG_INSTANCE_CHAT_LEADER",
        "READY_CHECK"
    }
}

-------------------------------------------------------------------------------
-- 1. Helper & Utility Functions
-------------------------------------------------------------------------------
local function trim(s)
    return s and s:gsub("^%s*(.-)%s*$", "%1") or ""
end

local function EscapePattern(s)
    return s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

local function ExtractFirstName(fullName)
    if not fullName or fullName == "" then return nil end
    local clean = fullName:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
    clean = trim(clean)
    return clean:match("^(%S+)")
end

local function AttachDelayedTooltip(button, tooltipText, delay)
    button:SetScript("OnEnter", function(self)
        if self.tooltipTimer then self.tooltipTimer:Cancel() end
        self.tooltipTimer = C_Timer.NewTimer(delay or VEP_CONFIG.TOOLTIP_DELAY, function()
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tooltipText, nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
    end)

    button:SetScript("OnLeave", function(self)
        if self.tooltipTimer then
            self.tooltipTimer:Cancel()
            self.tooltipTimer = nil
        end
        GameTooltip:Hide()
    end)
end

local cachedKeywordsList = {}
local function GetActiveKeywords()
    local str = REP_SavedDB and REP_SavedDB.keywordsText
    if not str or str == "" then return VEP_CONFIG.KEYWORDS end

    table.wipe(cachedKeywordsList)
    for word in str:gmatch("[^,%s]+") do
        table_insert(cachedKeywordsList, word:lower())
    end

    return (#cachedKeywordsList > 0) and cachedKeywordsList or VEP_CONFIG.KEYWORDS
end

-------------------------------------------------------------------------------
-- Raid Marker Extraction & Multi-Sort Logic
-------------------------------------------------------------------------------
local MARKER_WEIGHTS = {
    -- Star (1)
    ["{star}"] = 1, ["{rt1}"] = 1, ["{yellow}"] = 1, ["★"] = 1,
    -- Circle (2)
    ["{circle}"] = 2, ["{rt2}"] = 2, ["{orange}"] = 2, ["●"] = 2,
    -- Diamond (3)
    ["{diamond}"] = 3, ["{rt3}"] = 3, ["{purple}"] = 3, ["◆"] = 3,
    -- Triangle (4)
    ["{triangle}"] = 4, ["{rt4}"] = 4, ["{green}"] = 4, ["▼"] = 4,
    -- Moon (5)
    ["{moon}"] = 5, ["{rt5}"] = 5, ["{silver}"] = 5, ["{white}"] = 5, ["♦"] = 5,
    -- Square (6)
    ["{square}"] = 6, ["{rt6}"] = 6, ["{blue}"] = 6, ["■"] = 6, ["⬛"] = 6,
    -- Cross (7)
    ["{cross}"] = 7, ["{rt7}"] = 7, ["{x}"] = 7, ["{red}"] = 7, ["✖"] = 7, ["✕"] = 7, ["X"] = 7,
    -- Skull (8)
    ["{skull}"] = 8, ["{rt8}"] = 8, ["☠"] = 8, ["▲"] = 8
}

local function GetFirstRaidMarkerWeight(text)
    if not text or text == "" then return 99 end

    local lower = text:lower()
    local earliestPos = nil
    local earliestWeight = 99

    -- 1. Check for texture paths embedded from ReplaceIconAndGroupExpressions
    local texIndex = lower:match("raidtargetingicon_(%d)")
    if texIndex then
        local weight = tonumber(texIndex)
        local pos = lower:find("raidtargetingicon_")
        if pos then
            earliestPos = pos
            earliestWeight = weight
        end
    end

    -- 2. Check for token strings or symbols
    for token, weight in pairs(MARKER_WEIGHTS) do
        local pos = lower:find(token, 1, true)
        if pos and (not earliestPos or pos < earliestPos) then
            earliestPos = pos
            earliestWeight = weight
        end
    end

    return earliestWeight
end

local function GetRowValueByKey(row, colKey)
    if colKey == "time" then
        return row.timestamp or 0
    elseif colKey == "character" then
        return (row.characterName or ""):lower()
    elseif colKey == "avatar" then
        return (row.avatarName or ""):lower()
    elseif colKey == "marker" then
        -- Check both raw result and full text to capture markers accurately regardless of column placement
        return GetFirstRaidMarkerWeight((row.emoteResult or "") .. " " .. (row.emoteText or ""))
    elseif colKey == "text" then
        return (row.emoteText or ""):lower()
    end
    return 0
end

-------------------------------------------------------------------------------
-- 2. Main Frame & Confirm Dialog Construction
-------------------------------------------------------------------------------
local vep_mainframe = CreateFrame("Frame", frameName, UIParent, "BasicFrameTemplateWithInset")
vep_mainframe:SetSize(VEP_CONFIG.DEFAULT_WIDTH, VEP_CONFIG.DEFAULT_HEIGHT)
vep_mainframe:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
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
vep_mainframe.title:ClearAllPoints()
if vep_mainframe.TitleBg then
    vep_mainframe.title:SetPoint("LEFT", vep_mainframe.TitleBg, "LEFT", 10, 1)
else
    vep_mainframe.title:SetPoint("TOPLEFT", vep_mainframe, "TOPLEFT", 10, -6)
end

local addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version") or GetAddOnMetadata(addonName, "Version")
local baseTitleText = addonVersion or ""
vep_mainframe.title:SetText(baseTitleText)

-- Dynamic Visibility Tracking Hooks
vep_mainframe:HookScript("OnShow", function()
    if REP_SavedDB then
        REP_SavedDB.isVisible = true
    end
end)

vep_mainframe:HookScript("OnHide", function()
    if REP_SavedDB then
        REP_SavedDB.isVisible = false
    end
end)

-- Confirmation Dialog
local confirmFrame = CreateFrame("Frame", nil, vep_mainframe, "BasicFrameTemplateWithInset")
confirmFrame:SetSize(300, 110)
confirmFrame:SetPoint("CENTER", vep_mainframe, "CENTER", 0, 0)
confirmFrame:SetFrameLevel(vep_mainframe:GetFrameLevel() + 20)
confirmFrame:Hide()

if confirmFrame.TitleBg then confirmFrame.TitleBg:SetHeight(24) end

confirmFrame.title = confirmFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
if confirmFrame.TitleBg then
    confirmFrame.title:SetPoint("LEFT", confirmFrame.TitleBg, "LEFT", 8, 0)
else
    confirmFrame.title:SetPoint("TOPLEFT", confirmFrame, "TOPLEFT", 8, -6)
end
confirmFrame.title:SetText("Confirm Action")

local confirmText = confirmFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
confirmText:SetPoint("TOP", confirmFrame, "TOP", 0, -32)

local yesButton = CreateFrame("Button", nil, confirmFrame, "UIPanelButtonTemplate")
yesButton:SetSize(80, 22)
yesButton:SetPoint("BOTTOMLEFT", confirmFrame, "BOTTOMLEFT", 45, 12)
yesButton:SetText("Yes")
yesButton:SetScript("OnClick", function()
    if confirmFrame.onConfirm then confirmFrame.onConfirm() end
    confirmFrame:Hide()
end)

local noButton = CreateFrame("Button", nil, confirmFrame, "UIPanelButtonTemplate")
noButton:SetSize(80, 22)
noButton:SetPoint("BOTTOMRIGHT", confirmFrame, "BOTTOMRIGHT", -45, 12)
noButton:SetText("No")
noButton:SetScript("OnClick", function() confirmFrame:Hide() end)

local function ShowConfirmDialog(promptText, onConfirmCallback)
    confirmText:SetText(promptText)
    confirmFrame.onConfirm = onConfirmCallback
    confirmFrame:Show()
end

-------------------------------------------------------------------------------
-- 3. Header, Controls & Scroll Setup
-------------------------------------------------------------------------------
local resetButton = CreateFrame("Button", nil, vep_mainframe, "UIPanelButtonTemplate")
resetButton:SetSize(50, 20)
resetButton:SetPoint("BOTTOMLEFT", vep_mainframe, "BOTTOMLEFT", 12, 8)
resetButton:SetText("Reset")
resetButton.lastClickTime = 0
AttachDelayedTooltip(resetButton, "Deletes all entries.")

resetButton:RegisterForClicks("LeftButtonUp")
resetButton:SetScript("OnClick", function(self)
    GameTooltip:Hide()
    if self.tooltipTimer then self.tooltipTimer:Cancel() end

    local currentTime = GetTime()
    if (currentTime - (self.lastClickTime or 0)) <= VEP_CONFIG.DOUBLE_CLICK_THRESHOLD then
        vep_mainframe:ClearLog()
        confirmFrame:Hide()
        self.lastClickTime = 0
    else
        self.lastClickTime = currentTime
        ShowConfirmDialog("Clear all entries from the log?", function() vep_mainframe:ClearLog() end)
    end
end)

local cleanUpButton = CreateFrame("Button", nil, vep_mainframe, "UIPanelButtonTemplate")
cleanUpButton:SetSize(100, 20)
cleanUpButton:SetPoint("LEFT", resetButton, "RIGHT", 6, 0)
cleanUpButton:SetText("Clean Up Logs")
cleanUpButton.lastClickTime = 0
AttachDelayedTooltip(cleanUpButton, "Deletes entries based on your settings (dimmed and/or pre-ready check).")

cleanUpButton:RegisterForClicks("LeftButtonUp")
cleanUpButton:SetScript("OnClick", function(self)
    GameTooltip:Hide()
    if self.tooltipTimer then self.tooltipTimer:Cancel() end

    local currentTime = GetTime()
    if (currentTime - (self.lastClickTime or 0)) <= VEP_CONFIG.DOUBLE_CLICK_THRESHOLD then
        vep_mainframe:CleanUpLog()
        confirmFrame:Hide()
        self.lastClickTime = 0
    else
        self.lastClickTime = currentTime
        ShowConfirmDialog("Clean up log entries according to rules?", function() vep_mainframe:CleanUpLog() end)
    end
end)

vep_mainframe.innerElements = { resetButton, cleanUpButton }

local headerFrame = CreateFrame("Frame", nil, vep_mainframe)
headerFrame:SetPoint("TOPLEFT", vep_mainframe, "TOPLEFT", 12, -32)
headerFrame:SetPoint("TOPRIGHT", vep_mainframe, "TOPRIGHT", -32, -32)
headerFrame:SetHeight(22)

local headerButtons = {}
local currentOffsetX = 0

local function UpdateHeaderVisuals()
    local sortRules = (REP_SavedDB and REP_SavedDB.sortRules) or { { col = "time", asc = false } }
    
    for i, col in ipairs(VEP_CONFIG.COLUMNS) do
        local headerBtn = headerButtons[i]
        if headerBtn then
            local ruleIndex, ruleFound = nil, nil
            for idx, rule in ipairs(sortRules) do
                if rule.col == col.key then
                    ruleIndex = idx
                    ruleFound = rule
                    break
                end
            end

            local baseName = col.name
            if ruleFound then
                local sign = ruleFound.asc and "+" or "-"
                local indicator = "[" .. sign .. ruleIndex .. "]"
                headerBtn.text:SetText(baseName .. " " .. indicator)
                headerBtn.text:SetTextColor(1, 0.82, 0)
            else
                headerBtn.text:SetText(baseName)
                headerBtn.text:SetTextColor(0.9, 0.9, 0.9)
            end
        end
    end
end

for i, col in ipairs(VEP_CONFIG.COLUMNS) do
    local header = CreateFrame("Button", nil, headerFrame, "BackdropTemplate")
    header:SetSize(col.width, 22)
    header:SetPoint("LEFT", headerFrame, "LEFT", currentOffsetX, 0)
    header:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    header:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
    header:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    local text = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", header, "LEFT", 6, 0)
    text:SetText(col.name)
    header.text = text
    header.columnKey = col.key

    AttachDelayedTooltip(header, "Left-Click: Set Primary Sort || Shift-Click: Add Secondary Sort || Right-Click: Reset Sort")

    header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    header:SetScript("OnClick", function(self, button)
        REP_SavedDB = REP_SavedDB or {}
        REP_SavedDB.sortRules = REP_SavedDB.sortRules or { { col = "time", asc = false } }
        local rules = REP_SavedDB.sortRules

        if button == "RightButton" then
            REP_SavedDB.sortRules = { { col = "time", asc = false } }
        else
            local isShift = IsShiftKeyDown()
            local targetKey = self.columnKey
            local existingIndex = nil

            for idx, rule in ipairs(rules) do
                if rule.col == targetKey then
                    existingIndex = idx
                    break
                end
            end

            if isShift then
                if existingIndex then
                    rules[existingIndex].asc = not rules[existingIndex].asc
                else
                    table_insert(rules, { col = targetKey, asc = true })
                end
            else
                if existingIndex == 1 then
                    rules[1].asc = not rules[1].asc
                else
                    local newAsc = existingIndex and rules[existingIndex].asc or true
                    REP_SavedDB.sortRules = { { col = targetKey, asc = newAsc } }
                end
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
scrollFrame:SetPoint("BOTTOMRIGHT", vep_mainframe, "BOTTOMRIGHT", -32, 36)

local contentFrame = CreateFrame("Frame", nil, scrollFrame)
contentFrame:SetSize(700, 1)
scrollFrame:SetScrollChild(contentFrame)

local resizeBackdrop = CreateFrame("Frame", nil, vep_mainframe, "BackdropTemplate")
resizeBackdrop:SetSize(24, 24)
resizeBackdrop:SetPoint("BOTTOMRIGHT", vep_mainframe, "BOTTOMRIGHT", -3, 3)
resizeBackdrop:SetFrameLevel(vep_mainframe:GetFrameLevel() + 10)
resizeBackdrop:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
resizeBackdrop:SetBackdropColor(0.1, 0.1, 0.1, 0.85)
resizeBackdrop:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)

local resizeButton = CreateFrame("Button", nil, resizeBackdrop)
resizeButton:SetSize(16, 16)
resizeButton:SetPoint("CENTER", resizeBackdrop, "CENTER", 0, 0)
resizeButton:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeButton:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeButton:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

resizeButton:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then vep_mainframe:StartSizing("BOTTOMRIGHT") end
end)
resizeButton:SetScript("OnMouseUp", function() vep_mainframe:StopMovingOrSizing() end)

-------------------------------------------------------------------------------
-- 4. Compact Settings Window Integration
-------------------------------------------------------------------------------
local settingsFrame = CreateFrame("Frame", "RoleplayEventParserSettingsFrame", UIParent, "BasicFrameTemplateWithInset")
settingsFrame:SetSize(410, 420)
settingsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
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
settingsFrame.title:ClearAllPoints()
if settingsFrame.TitleBg then
    settingsFrame.title:SetPoint("LEFT", settingsFrame.TitleBg, "LEFT", 10, 1)
else
    settingsFrame.title:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 10, -6)
end
settingsFrame.title:SetText(baseTitleText .. " - Settings")

settingsFrame:HookScript("OnShow", function()
    if REP_SavedDB then REP_SavedDB.isSettingsVisible = true end
end)

settingsFrame:HookScript("OnHide", function()
    if REP_SavedDB then REP_SavedDB.isSettingsVisible = false end
end)

local function CreateSettingsCheckbox(parent, labelText, xOffset, yOffset, targetTable, targetKey)
    local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, yOffset)
    cb.text = cb.Text or _G[cb:GetName() .. "Text"]
    if cb.text then
        cb.text:SetText(labelText)
        cb.text:SetFontObject("GameFontHighlightSmall")
    end
    cb:SetScript("OnClick", function(self)
        if REP_SavedDB then
            if targetTable then
                REP_SavedDB[targetTable] = REP_SavedDB[targetTable] or {}
                REP_SavedDB[targetTable][targetKey] = self:GetChecked()
            else
                REP_SavedDB[targetKey] = self:GetChecked()
            end
        end
    end)
    return cb
end

local function AddSettingsHeader(parent, text, xOffset, yOffset)
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, yOffset)
    header:SetText(text)
    return header
end

-- Two-Column Section: Channels (Col 1) & Group Modes (Col 2)
AddSettingsHeader(settingsFrame, "Channels to Capture", 16, -36)
local cbSay = CreateSettingsCheckbox(settingsFrame, "Say (/say)", 18, -54, "channels", "say")
local cbParty = CreateSettingsCheckbox(settingsFrame, "Party (/party)", 18, -74, "channels", "party")
local cbRaid = CreateSettingsCheckbox(settingsFrame, "Raid / Raid Warning", 18, -94, "channels", "raid")
local cbEmote = CreateSettingsCheckbox(settingsFrame, "Emote (/emote)", 18, -114, "channels", "emote")
local cbInstance = CreateSettingsCheckbox(settingsFrame, "Instance Chat", 18, -134, "channels", "instance")

AddSettingsHeader(settingsFrame, "Parse Text When", 215, -36)
local cbModeUngrouped = CreateSettingsCheckbox(settingsFrame, "Ungrouped", 217, -54, "modes", "ungrouped")
local cbModeParty = CreateSettingsCheckbox(settingsFrame, "In a party", 217, -74, "modes", "party")
local cbModeRaid = CreateSettingsCheckbox(settingsFrame, "In a raid", 217, -94, "modes", "raid")

-- General & Clean Up Sections
AddSettingsHeader(settingsFrame, "General Options & Matching Rules", 16, -164)
local cbMatchRaidMarkers = CreateSettingsCheckbox(settingsFrame, "Match raid markers", 18, -182, nil, "matchRaidMarkers")
AttachDelayedTooltip(cbMatchRaidMarkers, "Match events where the emote result includes a raid marker", VEP_CONFIG.TOOLTIP_DELAY)

local cbMatchDigits = CreateSettingsCheckbox(settingsFrame, "Match digits", 217, -182, nil, "matchDigits")
AttachDelayedTooltip(cbMatchDigits, "Match events where the emote result includes a digit", VEP_CONFIG.TOOLTIP_DELAY)

local cbMatchMyName = CreateSettingsCheckbox(settingsFrame, "Match my name", 18, -202, nil, "matchMyName")
AttachDelayedTooltip(cbMatchMyName, "Match events that include your avatar or TRP3 name.", VEP_CONFIG.TOOLTIP_DELAY)

local cbDisableInstanced = CreateSettingsCheckbox(settingsFrame, "Disable in instanced content", 217, -202, nil, "disableInstanced")
AttachDelayedTooltip(cbDisableInstanced, "Disable matching in instances.", VEP_CONFIG.TOOLTIP_DELAY)

AddSettingsHeader(settingsFrame, "Log Clean Up Behavior", 16, -230)
local cbCleanPredates = CreateSettingsCheckbox(settingsFrame, "Delete entries before last ready check", 18, -248, "cleanup", "predates")
local cbCleanDimmed = CreateSettingsCheckbox(settingsFrame, "Delete dimmed log entries", 18, -268, "cleanup", "dimmed")
local cbReadyDim = CreateSettingsCheckbox(settingsFrame, "Auto-dim old entries on ready check", 18, -288, nil, "readyCheckDim")

-- Keywords Direct Config
AddSettingsHeader(settingsFrame, "Keywords", 16, -318)

local keywordsEditBox = CreateFrame("EditBox", nil, settingsFrame, "InputBoxTemplate")
keywordsEditBox:SetSize(255, 20)
keywordsEditBox:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 22, -338)
keywordsEditBox:SetAutoFocus(false)
keywordsEditBox:SetScript("OnTextChanged", function(self, userInput)
    if userInput and REP_SavedDB then
        REP_SavedDB.keywordsText = self:GetText()
    end
end)
keywordsEditBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
keywordsEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local resetKeywordsBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
resetKeywordsBtn:SetSize(105, 20)
resetKeywordsBtn:SetPoint("LEFT", keywordsEditBox, "RIGHT", 10, 0)
resetKeywordsBtn:SetText("Reset Keywords")
AttachDelayedTooltip(resetKeywordsBtn, "Reset keywords list to defaults.")

resetKeywordsBtn:SetScript("OnClick", function()
    ShowConfirmDialog("Reset keywords to default values?", function()
        local defaultKeywordsStr = table.concat(VEP_CONFIG.KEYWORDS, ", ")
        if REP_SavedDB then REP_SavedDB.keywordsText = defaultKeywordsStr end
        keywordsEditBox:SetText(defaultKeywordsStr)
    end)
end)

local settingsButton = CreateFrame("Button", nil, vep_mainframe, "UIPanelButtonTemplate")
settingsButton:SetSize(65, 20)
settingsButton:SetPoint("LEFT", cleanUpButton, "RIGHT", 6, 0)
settingsButton:SetText("Settings")
AttachDelayedTooltip(settingsButton, "Configure addon settings.")
settingsButton:SetScript("OnClick", function()
    if settingsFrame:IsShown() then
        settingsFrame:Hide()
    else
        settingsFrame:Show()
    end
end)

table_insert(vep_mainframe.innerElements, settingsButton)
table_insert(vep_mainframe.innerElements, headerFrame)
table_insert(vep_mainframe.innerElements, scrollFrame)
table_insert(vep_mainframe.innerElements, resizeBackdrop)

-------------------------------------------------------------------------------
-- 5. Minimize Controller
-------------------------------------------------------------------------------
local isMinimized = false
local savedWidth = VEP_CONFIG.DEFAULT_WIDTH
local savedHeight = VEP_CONFIG.DEFAULT_HEIGHT

local minimizeButton = CreateFrame("Button", nil, vep_mainframe, "UIPanelButtonTemplate")
minimizeButton:SetSize(20, 20)

local closeBtn = vep_mainframe.CloseButton or vep_mainframe.closeButton
if closeBtn then
    minimizeButton:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
else
    minimizeButton:SetPoint("TOPRIGHT", vep_mainframe, "TOPRIGHT", -26, -5)
end

minimizeButton:SetText("_")

local function ApplyMinimizedState(minimized)
    isMinimized = minimized
    confirmFrame:Hide()

    if isMinimized then
        if not REP_SavedDB.savedWidth or REP_SavedDB.savedWidth < VEP_CONFIG.MIN_WIDTH then
            savedWidth = vep_mainframe:GetWidth()
            savedHeight = vep_mainframe:GetHeight()
            if REP_SavedDB then
                REP_SavedDB.savedWidth = savedWidth
                REP_SavedDB.savedHeight = savedHeight
            end
        else
            savedWidth = REP_SavedDB.savedWidth
            savedHeight = REP_SavedDB.savedHeight
        end

        vep_mainframe:SetResizable(false)
        vep_mainframe:SetSize(200, 28)

        for _, el in ipairs(vep_mainframe.innerElements) do el:Hide() end

        if vep_mainframe.Bg then vep_mainframe.Bg:Hide() end
        if vep_mainframe.NineSlice then vep_mainframe.NineSlice:Hide() end
        if vep_mainframe.Inset then vep_mainframe.Inset:Hide() end
        if vep_mainframe.TopTileStreaks then vep_mainframe.TopTileStreaks:Hide() end

        minimizeButton:SetText("+")
    else
        local targetWidth = (REP_SavedDB and REP_SavedDB.savedWidth) or savedWidth or VEP_CONFIG.DEFAULT_WIDTH
        local targetHeight = (REP_SavedDB and REP_SavedDB.savedHeight) or savedHeight or VEP_CONFIG.DEFAULT_HEIGHT

        vep_mainframe:SetSize(targetWidth, targetHeight)
        vep_mainframe:SetResizable(true)

        for _, el in ipairs(vep_mainframe.innerElements) do el:Show() end

        if vep_mainframe.Bg then vep_mainframe.Bg:Show() end
        if vep_mainframe.NineSlice then vep_mainframe.NineSlice:Show() end
        if vep_mainframe.Inset then vep_mainframe.Inset:Show() end
        if vep_mainframe.TopTileStreaks then vep_mainframe.TopTileStreaks:Show() end

        minimizeButton:SetText("_")
        vep_mainframe:UpdateLayoutWidths()
    end

    if REP_SavedDB then
        REP_SavedDB.isMinimized = isMinimized
    end
end

minimizeButton:SetScript("OnClick", function()
    ApplyMinimizedState(not isMinimized)
end)

vep_mainframe:SetSize(VEP_CONFIG.DEFAULT_WIDTH, VEP_CONFIG.DEFAULT_HEIGHT)
vep_mainframe:Hide()

-------------------------------------------------------------------------------
-- 6. Dynamic Layout Manager & Row Processing
-------------------------------------------------------------------------------
vep_mainframe.rows = {}
vep_mainframe.lastReadyCheckTime = 0

function vep_mainframe:DeleteRow(row)
    if not row then return end

    for i = #self.rows, 1, -1 do
        if self.rows[i] == row then
            table_remove(self.rows, i)
            break
        end
    end

    if REP_SavedDB and REP_SavedDB.rows then
        for i = #REP_SavedDB.rows, 1, -1 do
            if REP_SavedDB.rows[i].timestamp == row.timestamp then
                table_remove(REP_SavedDB.rows, i)
                break
            end
        end
    end

    row:Hide()
    row:SetParent(nil)
    self:SortAndRefreshRows()
end

function vep_mainframe:UpdateLayoutWidths()
    if isMinimized then return end

    local availableWidth = math_max(scrollFrame:GetWidth() - 5, 700)
    local fixedWidths = VEP_CONFIG.COLUMNS[1].width + VEP_CONFIG.COLUMNS[2].width + VEP_CONFIG.COLUMNS[3].width + VEP_CONFIG.COLUMNS[4].width
    local dynamicTextWidth = math_max(availableWidth - fixedWidths, 120)

    VEP_CONFIG.COLUMNS[5].width = dynamicTextWidth
    contentFrame:SetWidth(availableWidth)

    local offsetX = 0
    for i, col in ipairs(VEP_CONFIG.COLUMNS) do
        if headerButtons[i] then
            headerButtons[i]:SetWidth(col.width)
            headerButtons[i]:SetPoint("LEFT", headerFrame, "LEFT", offsetX, 0)
        end
        offsetX = offsetX + col.width
    end

    if self.rows then
        for _, row in ipairs(self.rows) do
            row:SetWidth(availableWidth)
            local rowHeight = 22
            if row.cells then
                local cellOffsetX = 0
                for i, col in ipairs(VEP_CONFIG.COLUMNS) do
                    if row.cells[i] then
                        row.cells[i]:SetWidth(col.width - 10)
                        row.cells[i]:SetPoint("TOPLEFT", row, "TOPLEFT", cellOffsetX + 6, -4)
                        local textHeight = row.cells[i]:GetStringHeight() + 8
                        if textHeight > rowHeight then rowHeight = textHeight end
                    end
                    cellOffsetX = cellOffsetX + col.width
                end
            end
            row:SetHeight(rowHeight)
        end
        self:SortAndRefreshRows()
    end
end

vep_mainframe:SetScript("OnSizeChanged", function(self) vep_mainframe:UpdateLayoutWidths() end)

function vep_mainframe:ClearLog()
    if self.rows then
        for _, row in ipairs(self.rows) do
            row:Hide()
            row:SetParent(nil)
        end
    end
    self.rows = {}
    if REP_SavedDB then REP_SavedDB.rows = {} end
    contentFrame:SetHeight(1)
end

function vep_mainframe:CleanUpLog()
    if not self.rows then return end

    local keptRows = {}
    local keptSavedRows = {}
    local hasReadyCheck = (self.lastReadyCheckTime and self.lastReadyCheckTime > 0)
    
    local deletePredates = REP_SavedDB and REP_SavedDB.cleanup and REP_SavedDB.cleanup.predates
    local deleteDimmed = REP_SavedDB and REP_SavedDB.cleanup and REP_SavedDB.cleanup.dimmed

    for _, row in ipairs(self.rows) do
        local isDimmed = row.isDimmed
        local predatesReadyCheck = hasReadyCheck and (row.timestamp and row.timestamp < self.lastReadyCheckTime)

        local shouldDelete = (deletePredates and predatesReadyCheck) or (deleteDimmed and isDimmed)

        if shouldDelete then
            row:Hide()
            row:SetParent(nil)
        else
            table_insert(keptRows, row)
            if REP_SavedDB and REP_SavedDB.rows then
                for _, savedData in ipairs(REP_SavedDB.rows) do
                    if savedData.timestamp == row.timestamp then
                        table_insert(keptSavedRows, savedData)
                        break
                    end
                end
            end
        end
    end

    self.rows = keptRows
    if REP_SavedDB then REP_SavedDB.rows = keptSavedRows end
    vep_mainframe:SortAndRefreshRows()
end

function vep_mainframe:SortAndRefreshRows()
    local sortRules = (REP_SavedDB and REP_SavedDB.sortRules) or { { col = "time", asc = false } }

    table_sort(self.rows, function(a, b)
        for _, rule in ipairs(sortRules) do
            local valA = GetRowValueByKey(a, rule.col)
            local valB = GetRowValueByKey(b, rule.col)

            if valA ~= valB then
                if rule.asc then
                    return valA < valB
                else
                    return valA > valB
                end
            end
        end
        return false
    end)

    local currentOffsetY = 0
    for index, row in ipairs(self.rows) do
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, -currentOffsetY)
        row.rowIndex = index
        
        if index % 2 == 0 then
            row:SetBackdropColor(0.1, 0.1, 0.1, 0.4)
        else
            row:SetBackdropColor(0.2, 0.2, 0.2, 0.2)
        end
        currentOffsetY = currentOffsetY + row:GetHeight()
    end
    contentFrame:SetHeight(math_max(currentOffsetY, 1))
end

local function OnRowClick(row, button)
    local currentTime = GetTime()

    if button == "MiddleButton" then
        local targetName = (row.avatarName ~= "" and row.avatarName) or row.characterName
        if targetName and targetName ~= "" then
            ChatFrame_OpenChat("/w " .. targetName .. " ")
        end
        return
    end

    if button == "RightButton" then
        if (currentTime - (row.lastRightClickTime or 0)) <= VEP_CONFIG.DOUBLE_CLICK_THRESHOLD then
            vep_mainframe:DeleteRow(row)
            row.lastRightClickTime = 0
        else
            row.lastRightClickTime = currentTime
        end
        return
    end

    if button == "LeftButton" then
        if (currentTime - (row.lastClickTime or 0)) <= VEP_CONFIG.DOUBLE_CLICK_THRESHOLD then
            row.isDimmed = not row.isDimmed
            local targetAlpha = row.isDimmed and 0.5 or 1.0
            for _, cell in ipairs(row.cells) do cell:SetAlpha(targetAlpha) end
            
            if REP_SavedDB and REP_SavedDB.rows then
                for _, savedData in ipairs(REP_SavedDB.rows) do
                    if savedData.timestamp == row.timestamp then
                        savedData.isDimmed = row.isDimmed
                        break
                    end
                end
            end

            row.lastClickTime = 0
        else
            row.lastClickTime = currentTime
        end
    end
end

function vep_mainframe:AddRow(timeString, characterName, avatarName, emoteResult, emoteText, isDimmed, timestamp)
    local rowWidth = contentFrame:GetWidth()
    local rowHeight = 22
    
    local row = CreateFrame("Button", nil, contentFrame, "BackdropTemplate")
    row.characterName = characterName or ""
    row.avatarName = avatarName or ""
    row.timeString = timeString or ""
    row.timestamp = timestamp or GetTime()
    row.emoteResult = emoteResult or ""
    row.emoteText = emoteText or ""
    row.cells = {}
    row.isDimmed = isDimmed or false
    row.lastClickTime = 0
    row.lastRightClickTime = 0

    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })

    local initialAlpha = row.isDimmed and 0.5 or 1.0

    row:SetScript("OnEnter", function(self) self:SetBackdropColor(0.25, 0.35, 0.5, 0.6) end)
    row:SetScript("OnLeave", function(self)
        if (self.rowIndex or 1) % 2 == 0 then
            self:SetBackdropColor(0.1, 0.1, 0.1, 0.4)
        else
            self:SetBackdropColor(0.2, 0.2, 0.2, 0.2)
        end
    end)

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    row:SetScript("OnClick", OnRowClick)

    AttachDelayedTooltip(row, "Middle click to whisper || Double right-click to delete")

    local values = { timeString, characterName, avatarName, emoteResult, emoteText }
    local currentOffsetX = 0

    for i, col in ipairs(VEP_CONFIG.COLUMNS) do
        local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetPoint("TOPLEFT", row, "TOPLEFT", currentOffsetX + 6, -4)
        cell:SetWidth(col.width - 10)
        cell:SetJustifyH("LEFT")
        cell:SetWordWrap(col.wrap or false)
        cell:SetAlpha(initialAlpha)

        local rawValue = values[i] or ""
        if C_ChatInfo and C_ChatInfo.ReplaceIconAndGroupExpressions then
            rawValue = C_ChatInfo.ReplaceIconAndGroupExpressions(rawValue)
        end
        
        cell:SetText(rawValue)
        row.cells[i] = cell
        
        local textHeight = cell:GetStringHeight() + 8
        if textHeight > rowHeight then rowHeight = textHeight end
        currentOffsetX = currentOffsetX + col.width
    end

    row:SetSize(rowWidth, rowHeight)
    table_insert(self.rows, row)

    if not timestamp and REP_SavedDB and REP_SavedDB.rows then
        table_insert(REP_SavedDB.rows, {
            timeString = timeString,
            characterName = characterName,
            avatarName = avatarName,
            emoteResult = emoteResult,
            emoteText = emoteText,
            isDimmed = row.isDimmed,
            timestamp = row.timestamp
        })
    end

    vep_mainframe:SortAndRefreshRows()
end

-------------------------------------------------------------------------------
-- 7. Chat Parsing & Event Handler
-------------------------------------------------------------------------------
local function ResolvePlayerNames()
    local blizzName = UnitName("player")
    local trpName = nil
    local trpFirstName = nil

    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("TotalRP3") and TRP3_API then
        local unitID = TRP3_API.utils.str.getUnitID("player")
        if unitID then
            trpName = TRP3_API.register.getUnitRPName("player") or TRP3_API.chat.getFullnameForUnitUsingChatMethod(unitID)
            if trpName then
                trpFirstName = ExtractFirstName(trpName)
            end
        end
    end

    return blizzName, trpName, trpFirstName
end

local function EvaluateMatchCriteria(cleanInner, rawMessage)
    -- 1. Check Raid Markers
    if REP_SavedDB and REP_SavedDB.matchRaidMarkers then
        if rawMessage:find("[▼●◆▲★♦]") or rawMessage:find("{.-}") or rawMessage:find("|T.-|t") or rawMessage:find("|t") or rawMessage:lower():find("{%a+}") then
            return true
        end
    end

    -- 2. Check Digits
    if REP_SavedDB and REP_SavedDB.matchDigits then
        if cleanInner:find("%d") then
            return true
        end
    end

    -- 3. Check Configured Keywords
    local activeKeywords = GetActiveKeywords()
    for _, keyword in ipairs(activeKeywords) do
        if cleanInner:find(EscapePattern(keyword)) then
            return true
        end
    end

    return false
end

local function ResolveCharacterName(cleanSender, playerClean)
    if not (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("TotalRP3") and TRP3_API) then
        return nil
    end

    if cleanSender == playerClean then
        local unitID = TRP3_API.utils.str.getUnitID("player")
        if unitID then
            return TRP3_API.register.getUnitRPName("player") or TRP3_API.chat.getFullnameForUnitUsingChatMethod(unitID)
        end
    else
        local prefix = (IsInRaid() and "raid") or "party"
        local numMembers = (IsInRaid() and GetNumGroupMembers()) or GetNumSubgroupMembers()
        for i = 1, numMembers do
            local unit = prefix .. i
            local uName, uRealm = UnitName(unit)
            if uName then
                local fullUnitName = (uRealm and uRealm ~= "") and (uName .. "-" .. uRealm) or uName
                if Ambiguate(fullUnitName, "none") == cleanSender then
                    local unitID = TRP3_API.utils.str.getUnitID(unit)
                    if unitID then
                        return TRP3_API.register.getUnitRPName(unit) or TRP3_API.chat.getFullnameForUnitUsingChatMethod(unitID)
                    end
                    break
                end
            end
        end
        
        if TRP3_API.chat and TRP3_API.chat.getFullnameForUnitUsingChatMethod then
            return TRP3_API.chat.getFullnameForUnitUsingChatMethod(cleanSender)
        end
    end
    return nil
end

local chatFrame = CreateFrame("Frame")
local authorBuffers = {}
local BUFFER_WINDOW = 2.5

local function FlushAuthorBuffer(cleanSender)
    local buf = authorBuffers[cleanSender]
    if not buf then return end
    authorBuffers[cleanSender] = nil

    if not buf.hasValidMatch then return end

    local vep_action_result = table.concat(buf.results, " ")
    local vep_action_emote = table.concat(buf.texts, " ")

    vep_mainframe:AddRow(buf.timeString, buf.characterName, buf.avatarName, vep_action_result, vep_action_emote)
end

local function OnChatMessage(self, event, message, sender, ...)
    if event == "ADDON_LOADED" and message == addonName then
        local defaultKeywordsStr = table.concat(VEP_CONFIG.KEYWORDS, ", ")
        REP_SavedDB = REP_SavedDB or { 
            rows = {}, 
            lastReadyCheckTime = 0, 
            isVisible = true,
            isSettingsVisible = false,
            isMinimized = false,
            savedWidth = VEP_CONFIG.DEFAULT_WIDTH,
            savedHeight = VEP_CONFIG.DEFAULT_HEIGHT,
            readyCheckDim = false,
            disableInstanced = false,
            matchRaidMarkers = true,
            matchDigits = true,
            matchMyName = true,
            keywordsText = defaultKeywordsStr,
            channels = { say = true, party = true, raid = true, emote = true, instance = true },
            modes = { ungrouped = true, party = true, raid = true },
            cleanup = { predates = true, dimmed = true },
            sortRules = { { col = "time", asc = false } }
        }
        
        if REP_SavedDB.isVisible == nil then REP_SavedDB.isVisible = true end
        if REP_SavedDB.isSettingsVisible == nil then REP_SavedDB.isSettingsVisible = false end
        if REP_SavedDB.isMinimized == nil then REP_SavedDB.isMinimized = false end
        if REP_SavedDB.readyCheckDim == nil then REP_SavedDB.readyCheckDim = false end
        if REP_SavedDB.disableInstanced == nil then REP_SavedDB.disableInstanced = false end
        if REP_SavedDB.matchRaidMarkers == nil then REP_SavedDB.matchRaidMarkers = true end
        if REP_SavedDB.matchDigits == nil then REP_SavedDB.matchDigits = true end
        if REP_SavedDB.matchMyName == nil then REP_SavedDB.matchMyName = true end
        if REP_SavedDB.keywordsText == nil then REP_SavedDB.keywordsText = defaultKeywordsStr end
        REP_SavedDB.channels = REP_SavedDB.channels or { say = true, party = true, raid = true, emote = true, instance = true }
        REP_SavedDB.modes = REP_SavedDB.modes or { ungrouped = true, party = true, raid = true }
        REP_SavedDB.cleanup = REP_SavedDB.cleanup or { predates = true, dimmed = true }
        REP_SavedDB.sortRules = REP_SavedDB.sortRules or { { col = "time", asc = false } }

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
        cbMatchRaidMarkers:SetChecked(REP_SavedDB.matchRaidMarkers)
        cbMatchDigits:SetChecked(REP_SavedDB.matchDigits)
        cbMatchMyName:SetChecked(REP_SavedDB.matchMyName)
        keywordsEditBox:SetText(REP_SavedDB.keywordsText)

        vep_mainframe.lastReadyCheckTime = REP_SavedDB.lastReadyCheckTime or 0
        
        ApplyMinimizedState(REP_SavedDB.isMinimized)
        UpdateHeaderVisuals()

        if REP_SavedDB.isVisible then
            vep_mainframe:Show()
        else
            vep_mainframe:Hide()
        end

        if REP_SavedDB.isSettingsVisible then
            settingsFrame:Show()
        else
            settingsFrame:Hide()
        end
        
        if REP_SavedDB.rows then
            local savedEntries = REP_SavedDB.rows
            REP_SavedDB.rows = {}
            for _, entry in ipairs(savedEntries) do
                vep_mainframe:AddRow(entry.timeString, entry.characterName, entry.avatarName, entry.emoteResult, entry.emoteText, entry.isDimmed, entry.timestamp)
            end
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
                    for _, cell in ipairs(row.cells) do cell:SetAlpha(0.5) end
                    for _, savedData in ipairs(REP_SavedDB.rows or {}) do
                        if savedData.timestamp == row.timestamp then
                            savedData.isDimmed = true
                        end
                    end
                end
            end
        end
        return
    end

    if type(sender) ~= "string" or sender == "" then return end

    if REP_SavedDB and REP_SavedDB.disableInstanced then
        local inInstance, instanceType = IsInInstance()
        if inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario") then
            return
        end
    end

    local isSay = (event == "CHAT_MSG_SAY")
    local isParty = (event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER")
    local isRaid = (event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" or event == "CHAT_MSG_RAID_WARNING")
    local isEmote = (event == "CHAT_MSG_EMOTE")
    local isInstance = (event == "CHAT_MSG_INSTANCE_CHAT" or event == "CHAT_MSG_INSTANCE_CHAT_LEADER")

    local chConfig = REP_SavedDB and REP_SavedDB.channels
    if chConfig then
        if isSay and not chConfig.say then return end
        if isParty and not chConfig.party then return end
        if isRaid and not chConfig.raid then return end
        if isEmote and not chConfig.emote then return end
        if isInstance and not chConfig.instance then return end
    end

    local inGroup = IsInGroup()
    local inRaid = IsInRaid()
    local modes = REP_SavedDB and REP_SavedDB.modes

    if not inGroup and modes and not modes.ungrouped then return end
    if inGroup and not inRaid and modes and not modes.party then return end
    if inRaid and modes and not modes.raid then return end

    local cleanSender = Ambiguate(sender, "none")
    local playerClean = Ambiguate(UnitName("player"), "none")

    local pattern = "([%(%[][^%]%)]-[%]%)])"
    local removePattern = "[%(%[][^%]%)]-[%]%)]"

    local results = {}
    local hasMatchInThisLine = false

    -- Global Match Check: Match My Name (Blizzard name, full TRP name, or TRP first name) across full raw message
    if REP_SavedDB and REP_SavedDB.matchMyName then
        local blizzName, trpName, trpFirstName = ResolvePlayerNames()
        local lowerMsg = message:lower()
        
        if blizzName and blizzName ~= "" and lowerMsg:find(EscapePattern(blizzName:lower())) then
            hasMatchInThisLine = true
        elseif trpName and trpName ~= "" and lowerMsg:find(EscapePattern(trpName:lower())) then
            hasMatchInThisLine = true
        elseif trpFirstName and trpFirstName ~= "" and lowerMsg:find(EscapePattern(trpFirstName:lower())) then
            hasMatchInThisLine = true
        end
    end

    for match in message:gmatch(pattern) do
        local cleanInner = trim(match:sub(2, -2)):lower()
        if cleanInner ~= "" and cleanInner ~= "flavor" then
            table_insert(results, match)
            if EvaluateMatchCriteria(cleanInner, message) then
                hasMatchInThisLine = true
            end
        end
    end

    local vep_action_emote = trim(message:gsub(removePattern, ""))

    if event == "CHAT_MSG_EMOTE" then
        vep_action_emote = trim(vep_action_emote:gsub("^" .. cleanSender .. "%s*", ""))
    end

    local avatarName = cleanSender
    local characterName = ResolveCharacterName(cleanSender, playerClean) or cleanSender
    local timeString = date("%H:%M:%S")

    if authorBuffers[cleanSender] then
        local buf = authorBuffers[cleanSender]
        
        if buf.timer then buf.timer:Cancel() end
        
        for _, r in ipairs(results) do table_insert(buf.results, r) end
        if vep_action_emote ~= "" then table_insert(buf.texts, vep_action_emote) end
        
        if hasMatchInThisLine then buf.hasValidMatch = true end
        
        buf.characterName = characterName
        
        buf.timer = C_Timer.NewTimer(BUFFER_WINDOW, function()
            FlushAuthorBuffer(cleanSender)
        end)
    else
        local texts = {}
        if vep_action_emote ~= "" then table_insert(texts, vep_action_emote) end
        
        local timer = C_Timer.NewTimer(BUFFER_WINDOW, function()
            FlushAuthorMarker = function() end
            FlushAuthorBuffer(cleanSender)
        end)

        authorBuffers[cleanSender] = {
            timeString = timeString,
            characterName = characterName,
            avatarName = avatarName,
            results = results,
            texts = texts,
            hasValidMatch = hasMatchInThisLine,
            timer = timer
        }
    end
end

for _, eventName in ipairs(VEP_CONFIG.EVENTS) do
    chatFrame:RegisterEvent(eventName)
end
chatFrame:SetScript("OnEvent", OnChatMessage)

-------------------------------------------------------------------------------
-- 8. Slash Command Integration
-------------------------------------------------------------------------------
SLASH_ROLEPLAYEVENTPARSER1 = "/rp-parse"

local function HandleSlashCommand(msg)
    local command = trim(msg:lower())

    if command == "reset" then
        if REP_SavedDB then
            REP_SavedDB.isMinimized = false
            REP_SavedDB.savedWidth = VEP_CONFIG.DEFAULT_WIDTH
            REP_SavedDB.savedHeight = VEP_CONFIG.DEFAULT_HEIGHT
            REP_SavedDB.isVisible = true
            REP_SavedDB.sortRules = { { col = "time", asc = false } }
        end

        ApplyMinimizedState(false)
        UpdateHeaderVisuals()
        RoleplayEventParserFrame:ClearAllPoints()
        RoleplayEventParserFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        RoleplayEventParserFrame:SetSize(VEP_CONFIG.DEFAULT_WIDTH, VEP_CONFIG.DEFAULT_HEIGHT)
        RoleplayEventParserFrame:Show()
        RoleplayEventParserFrame:UpdateLayoutWidths()
    else
        if vep_mainframe:IsShown() then
            vep_mainframe:Hide()
        else
            vep_mainframe:Show()
        end
    end
end

SlashCmdList["ROLEPLAYEVENTPARSER"] = HandleSlashCommand