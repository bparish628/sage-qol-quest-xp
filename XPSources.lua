local ADDON_NAME = ...
local PREFIX = "|cffffd100Quest XP|r "

local SOURCES = {
	{ key = "kill", label = "Kills", color = { 0.85, 0.3, 0.25 } },
	{ key = "quest", label = "Quests", color = { 1, 0.82, 0 } },
	{ key = "explore", label = "Exploration", color = { 0.35, 0.8, 0.4 } },
	{ key = "other", label = "Other", color = { 0.6, 0.6, 0.6 } },
}
local ZONE_COLOR = { 0.35, 0.6, 0.9 }
-- XP and the event naming its source arrive in either order, so both wait this long to meet.
local SETTLE_SECONDS = 0.3
local BAR_CONTAINERS = { "MainStatusTrackingBarContainer", "SecondaryStatusTrackingBarContainer" }
local WINDOW = {
	width = 280, padding = 10, rowHeight = 16, headerHeight = 32, maxZones = 5,
	labelWidth = 92, valueWidth = 70, barHeight = 8, trackColor = { 1, 1, 1, 0.08 },
}

-- SageQoL_QuestXPDB.levels[level][zone][sourceKey] = xp
local db
local last = {}
-- segments: XP gained since the last flush, already split at level boundaries.
-- questXP, sawKill, sawExplore: what named the source of that XP.
local pending = { segments = {}, questXP = 0 }
local flushScheduled = false
local logUntil = 0
local hooked = {}
local settingsCategory
local window
-- Fixed by the layout, so bars size correctly before the window has been laid out.
local BAR_WIDTH = WINDOW.width - 2 * WINDOW.padding - WINDOW.labelWidth - WINDOW.valueWidth - 8

local function Log(text)
	if GetTime() < logUntil then print(PREFIX .. text) end
end

local function Snapshot()
	last.level, last.xp, last.max = UnitLevel("player"), UnitXP("player"), UnitXPMax("player")
end

local function Record(level, zone, source, xp)
	if xp <= 0 then return end
	db.levels[level] = db.levels[level] or {}
	local zones = db.levels[level]
	zones[zone] = zones[zone] or {}
	zones[zone][source] = (zones[zone][source] or 0) + xp
end

local function LevelTotals(level)
	local bySource, byZone, total = {}, {}, 0
	for zone, sources in pairs(db.levels[level] or {}) do
		for source, xp in pairs(sources) do
			bySource[source] = (bySource[source] or 0) + xp
			byZone[zone] = (byZone[zone] or 0) + xp
			total = total + xp
		end
	end
	local zones = {}
	for zone, xp in pairs(byZone) do table.insert(zones, { zone = zone, xp = xp }) end
	table.sort(zones, function(a, b) return a.xp > b.xp end)
	return bySource, zones, total
end

local function Percent(part, total)
	return math.floor(part / total * 100 + 0.5)
end

local function RecordedLevels()
	local levels = {}
	for level in pairs(db.levels) do table.insert(levels, level) end
	table.sort(levels)
	return levels
end

-- window.level is nil while the window follows the current level.
local function ShownLevel()
	return window.level or UnitLevel("player")
end

-- The nearest recorded past level before (direction -1) or after (+1) the shown one.
-- Stepping forward past the last one returns to the current level.
local function StepLevel(direction)
	local shown, current = ShownLevel(), UnitLevel("player")
	local target
	for _, level in ipairs(RecordedLevels()) do
		if level < current then
			if direction < 0 and level < shown and (not target or level > target) then target = level end
			if direction > 0 and level > shown and (not target or level < target) then target = level end
		end
	end
	return target
end

local function GetRow(index)
	local row = window.rows[index]
	if not row then
		row = CreateFrame("Frame", nil, window)
		row:SetHeight(WINDOW.rowHeight)
		row:SetPoint("TOPLEFT", WINDOW.padding, -(WINDOW.headerHeight + (index - 1) * WINDOW.rowHeight))
		row:SetPoint("RIGHT", -WINDOW.padding, 0)
		row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.label:SetPoint("LEFT")
		row.label:SetWidth(WINDOW.labelWidth)
		row.label:SetJustifyH("LEFT")
		row.label:SetWordWrap(false)
		row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.value:SetPoint("RIGHT")
		row.value:SetWidth(WINDOW.valueWidth)
		row.value:SetJustifyH("RIGHT")
		row.track = row:CreateTexture(nil, "ARTWORK")
		row.track:SetColorTexture(unpack(WINDOW.trackColor))
		row.track:SetHeight(WINDOW.barHeight)
		row.track:SetPoint("LEFT", WINDOW.labelWidth + 4, 0)
		row.track:SetPoint("RIGHT", -(WINDOW.valueWidth + 4), 0)
		row.fill = row:CreateTexture(nil, "OVERLAY")
		row.fill:SetHeight(WINDOW.barHeight)
		row.fill:SetPoint("LEFT", row.track)
		window.rows[index] = row
	end
	return row
end

-- Each line is a bar row ({ label, value, fraction, color }) or a heading ({ label, heading = true }).
local function WindowLines(level)
	local bySource, zones, total = LevelTotals(level)
	if total <= 0 then
		return { { label = "No XP recorded yet", heading = true } }
	end
	local lines = {}
	for _, source in ipairs(SOURCES) do
		local xp = bySource[source.key]
		if xp then
			table.insert(lines, { label = source.label, color = source.color, fraction = xp / total,
				value = string.format("%s  %d%%", BreakUpLargeNumbers(xp), Percent(xp, total)) })
		end
	end
	table.insert(lines, { label = "Zones", heading = true })
	for i = 1, math.min(#zones, WINDOW.maxZones) do
		local entry = zones[i]
		table.insert(lines, { label = entry.zone, color = ZONE_COLOR, fraction = entry.xp / total,
			value = string.format("%d%%", Percent(entry.xp, total)) })
	end
	return lines
end

local function RefreshWindow()
	if not (window and window:IsShown()) then return end
	local level = ShownLevel()
	window.title:SetFormattedText("Level %d XP", level)
	window.prev:SetEnabled(StepLevel(-1) ~= nil)
	window.next:SetEnabled(window.level ~= nil)

	local lines = WindowLines(level)
	for index, line in ipairs(lines) do
		local row = GetRow(index)
		row.label:SetText(line.label)
		row.label:SetFontObject(line.heading and "GameFontNormalSmall" or "GameFontHighlightSmall")
		row.value:SetText(line.value or "")
		row.track:SetShown(not line.heading)
		row.fill:SetShown(not line.heading)
		if not line.heading then
			row.fill:SetColorTexture(line.color[1], line.color[2], line.color[3], 0.9)
			-- A zero width would drop the texture's anchor, so the smallest bar is a sliver.
			row.fill:SetWidth(math.max(line.fraction * BAR_WIDTH, 1))
		end
		row:Show()
	end
	for index = #lines + 1, #window.rows do
		window.rows[index]:Hide()
	end
	window:SetHeight(WINDOW.headerHeight + #lines * WINDOW.rowHeight + WINDOW.padding)
end

local function CreateArrow(text, direction)
	local button = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	button:SetSize(22, 18)
	button:SetText(text)
	button:SetScript("OnClick", function()
		window.level = StepLevel(direction)
		RefreshWindow()
	end)
	return button
end

local function CreateWindow()
	window = CreateFrame("Frame", "SageQoLXPSourcesWindow", UIParent, "TooltipBackdropTemplate")
	window:SetWidth(WINDOW.width)
	window:SetFrameStrata("MEDIUM")
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", function()
		window:StopMovingOrSizing()
		local point, _, relativePoint, x, y = window:GetPoint()
		db.settings.position = { point, relativePoint, x, y }
	end)
	local position = db.settings.position
	if position then
		window:SetPoint(position[1], UIParent, position[2], position[3], position[4])
	else
		window:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
	end
	window.rows = {}

	window.prev = CreateArrow("<", -1)
	window.prev:SetPoint("TOPLEFT", WINDOW.padding - 2, -7)
	window.next = CreateArrow(">", 1)
	window.next:SetPoint("LEFT", window.prev, "RIGHT", 2, 0)
	window.title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	window.title:SetPoint("LEFT", window.next, "RIGHT", 6, 0)

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetSize(24, 24)
	close:SetPoint("TOPRIGHT", 1, 1)
	close:SetScript("OnClick", function() window.setting:SetValue(false) end)

	window:SetScript("OnShow", RefreshWindow)
	window:Hide()
end

local function SetWindowShown(shown)
	if shown and not window:IsShown() then window.level = nil end
	window:SetShown(shown)
end

local function ToggleWindow()
	window.setting:SetValue(not window:IsShown())
end

local function Flush()
	flushScheduled = false
	-- A source event whose XP hasn't landed yet gets one more wait before it is dropped.
	if #pending.segments == 0 and not pending.waited then
		pending.waited = true
		flushScheduled = true
		C_Timer.After(SETTLE_SECONDS, Flush)
		return
	end
	local quest = pending.questXP
	local rest = (pending.sawKill and "kill") or (pending.sawExplore and "explore") or "other"
	for _, segment in ipairs(pending.segments) do
		local questPart = math.min(quest, segment.xp)
		quest = quest - questPart
		Record(segment.level, segment.zone, "quest", questPart)
		Record(segment.level, segment.zone, rest, segment.xp - questPart)
		Log(string.format("level %d, %s: %d quest, %d %s", segment.level, segment.zone, questPart, segment.xp - questPart, rest))
	end
	pending = { segments = {}, questXP = 0 }
	RefreshWindow()
end

local function ScheduleFlush()
	if flushScheduled then return end
	flushScheduled = true
	C_Timer.After(SETTLE_SECONDS, Flush)
end

local function AddSegment(level, xp)
	if xp <= 0 then return end
	table.insert(pending.segments, { level = level, xp = xp, zone = GetRealZoneText() or UNKNOWN })
end

local function OnXPUpdate()
	if not last.level then return Snapshot() end
	-- UnitLevel can lag the level-up, so a drop in XP also counts as one.
	local level, xp = math.max(UnitLevel("player"), last.level), UnitXP("player")
	if level > last.level or xp < last.xp then
		AddSegment(last.level, last.max - last.xp)
		AddSegment(last.level + 1, xp)
		level = math.max(level, last.level + 1)
	else
		AddSegment(level, xp - last.xp)
	end
	Snapshot()
	last.level = level
	ScheduleFlush()
end

local function ExplorePattern()
	if not ERR_ZONE_EXPLORED_XP then return nil end
	local pattern = ERR_ZONE_EXPLORED_XP:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
	pattern = pattern:gsub("%%s", ".+"):gsub("%%d", "%%d+")
	return "^" .. pattern .. "$"
end

local function IsExploreMessage(text)
	local pattern = ExplorePattern()
	return pattern and not (issecretvalue and issecretvalue(text)) and text:match(pattern) ~= nil
end

local function HookExperienceBars()
	local barIndex = StatusTrackingBarInfo and StatusTrackingBarInfo.BarsEnum.Experience
	if not barIndex then return end
	for _, containerName in ipairs(BAR_CONTAINERS) do
		local container = _G[containerName]
		local bar = container and container.bars and container.bars[barIndex]
		if bar and not hooked[bar] then
			hooked[bar] = true
			bar:HookScript("OnMouseUp", function(_, button)
				if button == "LeftButton" then ToggleWindow() end
			end)
		end
	end
end

local function FormatLevel(level)
	local bySource, zones, total = LevelTotals(level)
	local parts = {}
	for _, source in ipairs(SOURCES) do
		local xp = bySource[source.key]
		if xp then table.insert(parts, string.format("%s %d%%", source.label, Percent(xp, total))) end
	end
	local zoneParts = {}
	for _, entry in ipairs(zones) do
		table.insert(zoneParts, string.format("%s %d%%", entry.zone, Percent(entry.xp, total)))
	end
	return string.format("Level %d: %s XP. %s. |cffaaaaaa%s|r", level, BreakUpLargeNumbers(total),
		table.concat(parts, ", "), table.concat(zoneParts, ", "))
end

local function PrintHistory()
	local levels = RecordedLevels()
	if #levels == 0 then
		print(PREFIX .. "No XP recorded yet. Tracking starts when the addon is first loaded.")
	end
	for _, level in ipairs(levels) do print(PREFIX .. FormatLevel(level)) end
end

local function RegisterSettings()
	local category = Settings.RegisterVerticalLayoutCategory("Sage QoL: Quest XP")
	settingsCategory = category
	local setting = Settings.RegisterAddOnSetting(category, "SageQoL_QuestXP_ShowSources", "showWindow",
		db.settings, type(false), "Show XP sources window", false)
	setting:SetValueChangedCallback(function(_, shown) SetWindowShown(shown) end)
	Settings.CreateCheckbox(category, setting,
		"A small movable window with each level's XP by source and zone. Clicking the XP bar also toggles it.")
	Settings.RegisterAddOnCategory(category)
	window.setting = setting
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("UI_INFO_MESSAGE")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON_NAME then return end
		SageQoL_QuestXPDB = SageQoL_QuestXPDB or {}
		db = SageQoL_QuestXPDB
		db.levels = db.levels or {}
		db.settings = db.settings or {}
		CreateWindow()
		RegisterSettings()
	elseif event == "PLAYER_ENTERING_WORLD" then
		Snapshot()
		HookExperienceBars()
		SetWindowShown(db.settings.showWindow)
	elseif event == "PLAYER_XP_UPDATE" then
		OnXPUpdate()
	elseif event == "PLAYER_LEVEL_UP" then
		RefreshWindow()
	elseif event == "QUEST_TURNED_IN" then
		local _, xpReward = ...
		pending.questXP = pending.questXP + (xpReward or 0)
		Log("quest turned in: " .. tostring(xpReward) .. " XP")
		ScheduleFlush()
	elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
		pending.sawKill = true
		Log("combat XP message")
		ScheduleFlush()
	else
		local text = event == "UI_INFO_MESSAGE" and select(2, ...) or ...
		if IsExploreMessage(text) then
			pending.sawExplore = true
			Log("exploration message")
			ScheduleFlush()
		end
	end
end)

SLASH_SAGEQOLQUESTXP1 = "/xpsources"
SlashCmdList.SAGEQOLQUESTXP = function(msg)
	msg = msg:lower()
	if msg:match("^%s*log") then
		logUntil = GetTime() + 60
		print(PREFIX .. "Logging XP events for 60 seconds.")
	elseif msg:match("^%s*reset") then
		db.levels = {}
		RefreshWindow()
		print(PREFIX .. "History cleared.")
	elseif msg:match("^%s*config") then
		Settings.OpenToCategory(settingsCategory:GetID())
	elseif msg:match("^%s*print") then
		PrintHistory()
	else
		ToggleWindow()
	end
end
