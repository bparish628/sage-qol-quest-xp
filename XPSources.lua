local ADDON_NAME = ...
local PREFIX = "|cffffd100Quest XP|r "

local SOURCES = {
	{ key = "kill", label = "Kills", color = { 0.85, 0.3, 0.25 } },
	{ key = "quest", label = "Quests", color = { 1, 0.82, 0 } },
	{ key = "explore", label = "Exploration", color = { 0.35, 0.8, 0.4 } },
	{ key = "other", label = "Other", color = { 0.6, 0.6, 0.6 } },
}
local ZONE_COLORS = {
	{ 0.35, 0.6, 0.9 },
	{ 0.65, 0.45, 0.85 },
	{ 0.3, 0.75, 0.7 },
	{ 0.9, 0.55, 0.3 },
	{ 0.8, 0.4, 0.6 },
}
local OTHER_ZONES_COLOR = { 0.5, 0.5, 0.5 }
-- XP and the event naming its source arrive in either order, so both wait this long to meet.
local SETTLE_SECONDS = 0.3
local BAR_CONTAINERS = { "MainStatusTrackingBarContainer", "SecondaryStatusTrackingBarContainer" }
local WINDOW = {
	width = 250, padding = 10, headerHeight = 32, headingHeight = 16, rowHeight = 15, sectionGap = 8,
	barHeight = 12, barGap = 6, segmentGap = 1, swatchSize = 9, valueWidth = 80, trackColor = { 1, 1, 1, 0.08 },
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
-- Computed from the layout, so segments size correctly before the window has been laid out.
local BAR_WIDTH = WINDOW.width - 2 * WINDOW.padding

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

local function Place(region, x, y)
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", window, "TOPLEFT", x, -y)
end

local function SourceEntries(bySource)
	local entries = {}
	for _, source in ipairs(SOURCES) do
		local xp = bySource[source.key]
		if xp then table.insert(entries, { label = source.label, color = source.color, xp = xp }) end
	end
	return entries
end

-- The top zones get their own colors; the rest share one so the bar still adds up to the level.
local function ZoneEntries(zones)
	local entries, restXP = {}, 0
	for i, entry in ipairs(zones) do
		if i <= #ZONE_COLORS then
			table.insert(entries, { label = entry.zone, color = ZONE_COLORS[i], xp = entry.xp })
		else
			restXP = restXP + entry.xp
		end
	end
	if restXP > 0 then
		table.insert(entries, { label = "Other zones", color = OTHER_ZONES_COLOR, xp = restXP })
	end
	return entries
end

local function CreateSection()
	local section = { segments = {}, rows = {} }
	section.heading = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	section.track = window:CreateTexture(nil, "ARTWORK")
	section.track:SetColorTexture(unpack(WINDOW.trackColor))
	section.track:SetSize(BAR_WIDTH, WINDOW.barHeight)
	return section
end

local function GetLegendRow(section, index)
	local row = section.rows[index]
	if not row then
		row = {
			swatch = window:CreateTexture(nil, "OVERLAY"),
			label = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
			value = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
		}
		row.swatch:SetSize(WINDOW.swatchSize, WINDOW.swatchSize)
		row.label:SetWidth(BAR_WIDTH - WINDOW.swatchSize - WINDOW.valueWidth - 10)
		row.label:SetJustifyH("LEFT")
		row.label:SetWordWrap(false)
		row.value:SetWidth(WINDOW.valueWidth)
		row.value:SetJustifyH("RIGHT")
		section.rows[index] = row
	end
	return row
end

local function HideFrom(list, first, hide)
	for index = first, #list do hide(list[index]) end
end

local function HideLegendRow(row)
	row.swatch:Hide()
	row.label:Hide()
	row.value:Hide()
end

local function HideSection(section)
	section.heading:Hide()
	section.track:Hide()
	HideFrom(section.segments, 1, function(segment) segment:Hide() end)
	HideFrom(section.rows, 1, HideLegendRow)
end

-- Draws a heading, a bar split by each entry's share of total, and a legend. Returns the y below it.
local function LayoutSection(section, title, entries, total, y)
	section.heading:SetText(title)
	Place(section.heading, WINDOW.padding, y)
	section.heading:Show()
	y = y + WINDOW.headingHeight

	Place(section.track, WINDOW.padding, y)
	section.track:Show()
	local x = WINDOW.padding
	for index, entry in ipairs(entries) do
		local segment = section.segments[index]
		if not segment then
			segment = window:CreateTexture(nil, "OVERLAY")
			section.segments[index] = segment
		end
		local width = math.max(entry.xp / total * BAR_WIDTH - WINDOW.segmentGap, 1)
		segment:SetColorTexture(entry.color[1], entry.color[2], entry.color[3], 0.9)
		segment:SetSize(width, WINDOW.barHeight)
		Place(segment, x, y)
		segment:Show()
		x = x + width + WINDOW.segmentGap
	end
	HideFrom(section.segments, #entries + 1, function(segment) segment:Hide() end)
	y = y + WINDOW.barHeight + WINDOW.barGap

	for index, entry in ipairs(entries) do
		local row = GetLegendRow(section, index)
		row.swatch:SetColorTexture(entry.color[1], entry.color[2], entry.color[3], 0.9)
		Place(row.swatch, WINDOW.padding, y + 2)
		row.label:SetText(entry.label)
		Place(row.label, WINDOW.padding + WINDOW.swatchSize + 5, y)
		row.value:SetFormattedText("%s  %d%%", BreakUpLargeNumbers(entry.xp), Percent(entry.xp, total))
		Place(row.value, WINDOW.width - WINDOW.padding - WINDOW.valueWidth, y)
		row.swatch:Show()
		row.label:Show()
		row.value:Show()
		y = y + WINDOW.rowHeight
	end
	HideFrom(section.rows, #entries + 1, HideLegendRow)
	return y
end

local function RefreshWindow()
	if not (window and window:IsShown()) then return end
	local level = ShownLevel()
	window.title:SetFormattedText("Level %d XP", level)
	window.prev:SetEnabled(StepLevel(-1) ~= nil)
	window.next:SetEnabled(window.level ~= nil)

	local bySource, zones, total = LevelTotals(level)
	window.empty:SetShown(total <= 0)
	if total <= 0 then
		HideSection(window.sources)
		HideSection(window.zones)
		window:SetHeight(WINDOW.headerHeight + WINDOW.rowHeight + WINDOW.padding)
		return
	end
	local y = LayoutSection(window.sources, "Sources", SourceEntries(bySource), total, WINDOW.headerHeight)
	y = LayoutSection(window.zones, "Zones", ZoneEntries(zones), total, y + WINDOW.sectionGap)
	window:SetHeight(y + WINDOW.padding)
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
	window.sources = CreateSection()
	window.zones = CreateSection()
	window.empty = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	window.empty:SetText("No XP recorded yet")
	window.empty:SetPoint("TOPLEFT", WINDOW.padding, -WINDOW.headerHeight)

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
