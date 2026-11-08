local ADDON_NAME = ...
local PREFIX = "|cffffd100Quest XP|r "

local SOURCES = {
	{ key = "kill", label = "Kills" },
	{ key = "quest", label = "Quests" },
	{ key = "explore", label = "Exploration" },
	{ key = "other", label = "Other" },
}
local MAX_TOOLTIP_ZONES = 4
-- XP and the event naming its source arrive in either order, so both wait this long to meet.
local SETTLE_SECONDS = 0.3
local BAR_CONTAINERS = { "MainStatusTrackingBarContainer", "SecondaryStatusTrackingBarContainer" }

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

local function ShowTooltipLines(bar)
	if not db.settings.showTooltip then return end
	local bySource, zones, total = LevelTotals(UnitLevel("player"))
	if total <= 0 then return end
	if GameTooltip:IsShown() then
		GameTooltip_AddBlankLineToTooltip(GameTooltip)
	else
		GameTooltip:SetOwner(bar, "ANCHOR_CURSOR")
	end
	GameTooltip:AddLine("XP this level", NORMAL_FONT_COLOR:GetRGB())
	for _, source in ipairs(SOURCES) do
		local xp = bySource[source.key]
		if xp then
			GameTooltip:AddDoubleLine(source.label, string.format("%s (%d%%)", BreakUpLargeNumbers(xp), Percent(xp, total)), 1, 1, 1, 1, 1, 1)
		end
	end
	for i = 1, math.min(#zones, MAX_TOOLTIP_ZONES) do
		local entry = zones[i]
		GameTooltip:AddDoubleLine(entry.zone, string.format("%d%%", Percent(entry.xp, total)), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
	end
	GameTooltip:Show()
end

local function HookExperienceBars()
	local barIndex = StatusTrackingBarInfo and StatusTrackingBarInfo.BarsEnum.Experience
	if not barIndex then return end
	for _, containerName in ipairs(BAR_CONTAINERS) do
		local container = _G[containerName]
		local bar = container and container.bars and container.bars[barIndex]
		if bar and not hooked[bar] then
			hooked[bar] = true
			bar:HookScript("OnEnter", ShowTooltipLines)
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
	local levels = {}
	for level in pairs(db.levels) do table.insert(levels, level) end
	table.sort(levels)
	if #levels == 0 then
		print(PREFIX .. "No XP recorded yet. Tracking starts when the addon is first loaded.")
	end
	for _, level in ipairs(levels) do print(PREFIX .. FormatLevel(level)) end
end

local function RegisterSettings()
	local category = Settings.RegisterVerticalLayoutCategory("Sage QoL: Quest XP")
	settingsCategory = category
	local setting = Settings.RegisterAddOnSetting(category, "SageQoL_QuestXP_ShowSources", "showTooltip",
		db.settings, type(true), "Show XP sources in XP bar tooltip", true)
	Settings.CreateCheckbox(category, setting, "Lists this level's XP by source and zone when you hover the XP bar.")
	Settings.RegisterAddOnCategory(category)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_XP_UPDATE")
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
		if db.settings.showTooltip == nil then db.settings.showTooltip = true end
		RegisterSettings()
	elseif event == "PLAYER_ENTERING_WORLD" then
		Snapshot()
		HookExperienceBars()
	elseif event == "PLAYER_XP_UPDATE" then
		OnXPUpdate()
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
		print(PREFIX .. "History cleared.")
	elseif msg:match("^%s*config") then
		Settings.OpenToCategory(settingsCategory:GetID())
	else
		PrintHistory()
	end
end
