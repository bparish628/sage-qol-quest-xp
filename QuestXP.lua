local FILL = {
	atlas = "UI-HUD-ExperienceBar-Fill-Experience",
	r = 1, g = 0.55, b = 0.15,
	alpha = 0.6,
}

local BAR_CONTAINERS = { "MainStatusTrackingBarContainer", "SecondaryStatusTrackingBarContainer" }

local overlays = {}
local hooked = {}
local pendingXP = 0

local function GetPendingQuestXP()
	local total = 0
	for logIndex = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(logIndex)
		if info and not info.isHeader and not info.isHidden then
			local questID = info.questID
			if C_QuestLog.ReadyForTurnIn(questID) or C_QuestLog.IsComplete(questID) then
				total = total + (GetQuestLogRewardXP(questID) or 0)
			end
		end
	end
	return total
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
		-- The StatusBar child draws over its parent, so the fill lives on the StatusBar,
		-- above its Background (BACKGROUND 0-1) and below the XP fill (BORDER).
		overlay = bar.StatusBar:CreateTexture(nil, "BACKGROUND", nil, 2)
		overlay:SetAtlas(FILL.atlas)
		overlay:SetDesaturated(true)
		overlay:SetVertexColor(FILL.r, FILL.g, FILL.b)
		overlay:SetAlpha(FILL.alpha)
		overlay:SetPoint("BOTTOMLEFT", bar.StatusBar)
		overlay:SetPoint("TOPLEFT", bar.StatusBar)
		overlays[bar] = overlay
	end
	return overlay
end

local function ApplyOverlay(bar)
	if IsOverlayDisabled(bar) then
		if overlays[bar] then overlays[bar]:Hide() end
		return
	end
	local maxXP = UnitXPMax("player")
	if maxXP <= 0 then
		if overlays[bar] then overlays[bar]:Hide() end
		return
	end
	local ratio = Clamp((UnitXP("player") + pendingXP) / maxXP, 0, 1)
	local overlay = GetOverlay(bar)
	-- SetAtlas resets tex coords, so the crop is set after it and again on every resize.
	overlay:SetWidth(math.max(ratio * bar.StatusBar:GetWidth(), 0.001))
	overlay:SetTexCoord(0, ratio, 0, 1)
	overlay:Show()
end

local function ShowTooltipLines(bar)
	if pendingXP <= 0 or IsOverlayDisabled(bar) then return end
	if not GameTooltip:IsShown() then
		GameTooltip:SetOwner(bar, "ANCHOR_CURSOR")
	end
	GameTooltip:AddLine(string.format("Completed quests: +%s XP", BreakUpLargeNumbers(pendingXP)), FILL.r, FILL.g, FILL.b)
	if UnitXP("player") + pendingXP >= UnitXPMax("player") then
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
	pendingXP = GetPendingQuestXP()
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
