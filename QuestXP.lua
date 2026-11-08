local FILL = {
	atlas = "UI-HUD-ExperienceBar-Fill-Experience",
	r = 1, g = 0.55, b = 0.15,
	alpha = 0.6,
	edgeWidth = 2,
}

local BAR_CONTAINERS = { "MainStatusTrackingBarContainer", "SecondaryStatusTrackingBarContainer" }

local overlays = {}
local hooked = {}
local completedQuests = {}
local pendingXP = 0

local function ReadCompletedQuests()
	local quests, total = {}, 0
	for logIndex = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(logIndex)
		if info and not info.isHeader and not info.isHidden then
			local questID = info.questID
			local xp = GetQuestLogRewardXP(questID) or 0
			if xp > 0 and (C_QuestLog.ReadyForTurnIn(questID) or C_QuestLog.IsComplete(questID)) then
				table.insert(quests, { title = info.title, xp = xp })
				total = total + xp
			end
		end
	end
	table.sort(quests, function(a, b) return a.xp > b.xp end)
	return quests, total
end

local function IsOverlayDisabled(bar)
	return pendingXP <= 0
		or GameRulesUtil.IsPlayerAtEffectiveMaxLevel()
		or IsXPUserDisabled()
		or bar:IsCapped()
end

local function GetOverlay(bar)
	local overlay = overlays[bar]
	if not overlay then
		local statusBar = bar.StatusBar
		-- The StatusBar child draws over its parent, so the fill lives on the StatusBar,
		-- above its Background (BACKGROUND 0-1) and below the XP fill (BORDER).
		local fill = statusBar:CreateTexture(nil, "BACKGROUND", nil, 2)
		fill:SetAtlas(FILL.atlas)
		fill:SetDesaturated(true)
		fill:SetVertexColor(FILL.r, FILL.g, FILL.b)
		fill:SetAlpha(FILL.alpha)
		fill:SetPoint("BOTTOMLEFT", statusBar)
		fill:SetPoint("TOPLEFT", statusBar)

		local edge = statusBar:CreateTexture(nil, "ARTWORK")
		edge:SetColorTexture(FILL.r, FILL.g, FILL.b, 1)
		edge:SetWidth(FILL.edgeWidth)
		edge:SetPoint("TOPRIGHT", fill)
		edge:SetPoint("BOTTOMRIGHT", fill)

		overlay = { fill = fill, edge = edge }
		overlays[bar] = overlay
	end
	return overlay
end

local function HideOverlay(bar)
	local overlay = overlays[bar]
	if overlay then
		overlay.fill:Hide()
		overlay.edge:Hide()
	end
end

local function ApplyOverlay(bar)
	local maxXP = UnitXPMax("player")
	if IsOverlayDisabled(bar) or maxXP <= 0 then
		HideOverlay(bar)
		return
	end
	local ratio = Clamp((UnitXP("player") + pendingXP) / maxXP, 0, 1)
	local overlay = GetOverlay(bar)
	-- SetAtlas resets tex coords, so the crop is set after it and again on every resize.
	overlay.fill:SetWidth(math.max(ratio * bar.StatusBar:GetWidth(), 0.001))
	overlay.fill:SetTexCoord(0, ratio, 0, 1)
	overlay.fill:Show()
	overlay.edge:SetShown(ratio < 1)
end

local function ShowTooltipLines(bar)
	if IsOverlayDisabled(bar) then return end
	if not GameTooltip:IsShown() then
		GameTooltip:SetOwner(bar, "ANCHOR_CURSOR")
	else
		GameTooltip_AddBlankLineToTooltip(GameTooltip)
	end
	local maxXP = UnitXPMax("player")
	GameTooltip:AddLine("Completed quests", FILL.r, FILL.g, FILL.b)
	for _, quest in ipairs(completedQuests) do
		GameTooltip:AddDoubleLine(quest.title, BreakUpLargeNumbers(quest.xp), 1, 1, 1, 1, 1, 1)
	end
	GameTooltip:AddDoubleLine("Total", string.format("+%s XP (%d%% of level)",
		BreakUpLargeNumbers(pendingXP), math.floor(pendingXP / maxXP * 100)),
		FILL.r, FILL.g, FILL.b, FILL.r, FILL.g, FILL.b)
	if UnitXP("player") + pendingXP >= maxXP then
		GameTooltip:AddLine("Enough to level up", FILL.r, FILL.g, FILL.b)
	end
	GameTooltip:Show()
end

local function HookBar(bar)
	if hooked[bar] then return end
	hooked[bar] = true
	hooksecurefunc(bar, "Update", ApplyOverlay)
	bar:HookScript("OnSizeChanged", ApplyOverlay)
	bar:HookScript("OnEnter", ShowTooltipLines)
end

local function ForEachExperienceBar(callback)
	local barIndex = StatusTrackingBarInfo and StatusTrackingBarInfo.BarsEnum.Experience
	if not barIndex then return end
	for _, containerName in ipairs(BAR_CONTAINERS) do
		local container = _G[containerName]
		local bar = container and container.bars and container.bars[barIndex]
		if bar then callback(bar) end
	end
end

local function Refresh()
	completedQuests, pendingXP = ReadCompletedQuests()
	ForEachExperienceBar(function(bar)
		HookBar(bar)
		ApplyOverlay(bar)
	end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterUnitEvent("UNIT_QUEST_LOG_CHANGED", "player")
frame:SetScript("OnEvent", Refresh)
