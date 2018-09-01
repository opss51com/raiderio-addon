-- TODO: inverse modifier behavior
-- TODO: non-auto positioning behavior
-- TODO: unlocked positioning behavior

local addonName, ns = ...

-- constants
local L = ns.L

-- colors
local COLOR_WHITE = { r = 1, g = 1, b = 1 }
local COLOR_GREY = { r = 0.62, g = 0.62, b = 0.62 }
local COLOR_GREEN = { r = 0, g = 1, b = 0 }

-- fallback frame
local FALLBACK_FRAME = _G.PVEFrame
local FALLBACK_FRAME_STRATA = "BACKGROUND"

-- profile tooltip
local ProfileTooltip
do
	ProfileTooltip = CreateFrame("GameTooltip", addonName .. "ProfileTooltip", FALLBACK_FRAME, "GameTooltipTemplate")
	ProfileTooltip:RegisterForDrag("LeftButton")
	ProfileTooltip:SetScript("OnDragStop", function()
		ProfileTooltip:StopMovingOrSizing()
		local point, _, _, x, y = ProfileTooltip:GetPoint()
		local p = ns.addonConfig.profilePoint or {}
		p.point, p.x, p.y = point, x, y
		ns.addonConfig.profilePoint = p
	end)
end

local IsFallbackShown
local HookFrame
local SetAnchor
local UpdateProfile
local SetDrag
do
	local hooks = {}
	local query = {}
	local hasQuery = false

	local function IsFrame(widget)
		return type(widget) == "table" and type(widget.GetObjectType) == "function"
	end

	local function HookHideTooltip()
		if IsFallbackShown() then
			ProfileTooltip.ShowProfile("player", nil, ns.PLAYER_FACTION, FALLBACK_FRAME, FALLBACK_FRAME_STRATA)
		else
			ProfileTooltip.HideProfile(true)
		end
	end

	local function PopulateProfile(unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, lfdActivityID, keystoneLevel)
		if ns.addonConfig.enableProfileModifier then
			if (ns.addonConfig.inverseProfileModifier and not ns.addon:IsModifierKeyDown(true)) or (not ns.addonConfig.inverseProfileModifier and ns.addon:IsModifierKeyDown(true)) then
				unitOrNameOrNameAndRealm, realmOrNil = "player"
			end
		end
		local output, hasProfile = ns.GetPlayerProfile(bit.bor(ns.ProfileOutput.MYTHICPLUS, ns.ProfileOutput.TOOLTIP), unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, true, lfdActivityID, keystoneLevel)
		if not hasProfile then return end
		local profile = output.profile
		if not profile then return end
		local isPlayer = unitOrNameOrNameAndRealm == "player"
		-- the focused dungeon based on LFD activityID
		local dungeon
		if lfdActivityID then
			local dungeonID = ns.LFD_ACTIVITYID_TO_DUNGEONID[lfdActivityID]
			if dungeonID then
				dungeon = ns.CONST_DUNGEONS[dungeonID]
			end
		end
		local focusOnDungeonIndex = dungeon and dungeon.index or nil
		-- make a list over the dungeons the profile has done
		local dungeons = {}
		for dungeonIndex, keyLevel in ipairs(profile.dungeons) do
			local d = ns.CONST_DUNGEONS[dungeonIndex]
			dungeons[dungeonIndex] = {
				index = dungeonIndex,
				dungeon = d,
				shortName = d.shortNameLocale,
				keyLevel = keyLevel,
				upgrades = profile.dungeonUpgrades[dungeonIndex] or 0,
				fractionalTime = profile.dungeonTimes[dungeonIndex] or 0,
			}
		end
		table.sort(dungeons, ns.CompareDungeon)
		-- add the tooltip header and regular tooltip lines
		ProfileTooltip:AddLine(L[isPlayer and "MY_PROFILE_TITLE" or "PLAYER_PROFILE_TITLE"], 1, 0.85, 0, false)
		for i = 1, output.length do
			local line = output[i]
			if type(line) == "table" then
				ProfileTooltip:AddDoubleLine(line[1], line[2], line[3], line[4], line[5], line[6], line[7], line[8], line[9], line[10])
			else
				ProfileTooltip:AddLine(line)
			end
		end
		-- add the dungeons list of the best runs
		ProfileTooltip:AddLine(" ")
		ProfileTooltip:AddLine(L.PROFILE_BEST_RUNS, 1, 0.85, 0, false)
		for i, dungeon in ipairs(dungeons) do
			local colorDungeonName = COLOR_WHITE
			local colorDungeonLevel = COLOR_WHITE
			local keyLevel = dungeon.keyLevel
			if keyLevel ~= 0 then
				if profile.isEnhanced then
					if dungeon.upgrades == 0 then
						colorDungeonLevel = COLOR_GREY
					end
					keyLevel = ns.GetStarsForUpgrades(dungeon.upgrades) .. keyLevel
				else
					keyLevel = "+" .. keyLevel
				end
			else
				keyLevel = "-"
				colorDungeonLevel = COLOR_GREY
			end
			if focusOnDungeonIndex == dungeon.index then
				colorDungeonName = COLOR_GREEN
				colorDungeonLevel = COLOR_GREEN
			end
			ProfileTooltip:AddDoubleLine(dungeon.shortName, keyLevel, colorDungeonName.r, colorDungeonName.g, colorDungeonName.b, colorDungeonLevel.r, colorDungeonLevel.g, colorDungeonLevel.b)
		end
		-- TODO: this working right?
		if ns.OUTDATED_DAYS[ns.CONST_PROVIDER_DATA_MYTHICPLUS] and ns.OUTDATED_DAYS[ns.CONST_PROVIDER_DATA_MYTHICPLUS][profile.faction] > 1 then
			ProfileTooltip:AddLine(" ")
			ProfileTooltip:AddLine(format(L.OUTDATED_DATABASE, ns.OUTDATED_DAYS[ns.CONST_PROVIDER_DATA_MYTHICPLUS][profile.faction]), 0.8, 0.8, 0.8, false)
		elseif ns.OUTDATED_HOURS[ns.CONST_PROVIDER_DATA_MYTHICPLUS] and ns.OUTDATED_HOURS[ns.CONST_PROVIDER_DATA_MYTHICPLUS][profile.faction] > 12 then
			ProfileTooltip:AddLine(" ")
			ProfileTooltip:AddLine(format(L.OUTDATED_DATABASE_HOURS, ns.OUTDATED_HOURS[ns.CONST_PROVIDER_DATA_MYTHICPLUS][profile.faction]), 0.8, 0.8, 0.8, false)
		end
		ProfileTooltip:Show()
		return true
	end

	local function SaveQuery(unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, lfdActivityID, keystoneLevel)
		query[1], query[2], query[3], query[4], query[5] = unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, lfdActivityID, keystoneLevel
		hasQuery = true
	end

	local function ClearQuery()
		query[1], query[2], query[3], query[4], query[5] = nil
		hasQuery = false
	end

	local function GetQuery()
		return query[1], query[2], query[3], query[4], query[5]
	end

	function IsFallbackShown()
		return FALLBACK_FRAME:IsShown()
	end

	function HookFrame(frame)
		if not IsFrame(frame) then return end
		if hooks[frame] then return end
		hooks[frame] = 1
		frame:HookScript("OnHide", HookHideTooltip)
	end

	function SetAnchor(anchorFrame, frameStrata)
		anchorFrame = IsFrame(anchorFrame) and anchorFrame or FALLBACK_FRAME
		ProfileTooltip:SetOwner(anchorFrame, "ANCHOR_NONE")
		ProfileTooltip:ClearAllPoints()
		local userPlaced = ns.addonConfig.profilePoint
		if userPlaced and userPlaced.point then
			ProfileTooltip:SetPoint(userPlaced.point, UIParent, userPlaced.point, userPlaced.x, userPlaced.y)
		elseif anchorFrame then
			ProfileTooltip:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", 0, 0)
		end
		ProfileTooltip:SetFrameStrata(frameStrata or "MEDIUM")
	end

	function UpdateProfile(unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, lfdActivityID, keystoneLevel)
		if unitOrNameOrNameAndRealm == true then
			unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, lfdActivityID, keystoneLevel = GetQuery()
		end
		ProfileTooltip:ClearLines()
		if PopulateProfile(unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, lfdActivityID, keystoneLevel) then
			SaveQuery(unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, lfdActivityID, keystoneLevel)
			ProfileTooltip:Show()
		else
			ClearQuery()
			ProfileTooltip:Hide()
		end
	end

	function SetDrag(canDrag)
		ProfileTooltip:EnableMouse(canDrag)
		ProfileTooltip:SetMovable(canDrag)
	end
end

function ProfileTooltip.SaveConfig()
	if ns.addonConfig.positionProfileAuto then
		local p = ns.addonConfig.profilePoint or {}
		p.point, p.x, p.y = nil
		ns.addonConfig.profilePoint = p
		if IsFallbackShown() then
			SetAnchor(FALLBACK_FRAME, FALLBACK_FRAME_STRATA)
		end
	end
	SetDrag(not ns.addonConfig.positionProfileAuto and not ns.addonConfig.lockProfile)
end

function ProfileTooltip.ToggleLock()
	if ns.addonConfig.positionProfileAuto then
		DEFAULT_CHAT_FRAME:AddMessage(L.WARNING_LOCK_POSITION_FRAME_AUTO, 1, 1, 0)
		return
	end
	if ns.addonConfig.lockProfile then
		DEFAULT_CHAT_FRAME:AddMessage(L.UNLOCKING_PROFILE_FRAME, 1, 1, 0)
	else
		DEFAULT_CHAT_FRAME:AddMessage(L.LOCKING_PROFILE_FRAME, 1, 1, 0)
	end
	ns.addonConfig.lockProfile = not ns.addonConfig.lockProfile
	SetDrag(not ns.addonConfig.lockProfile)
end

function ProfileTooltip.ShowProfile(unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, anchorFrame, frameStrata, lfdActivityID, keystoneLevel)
	if anchorFrame then
		HookFrame(anchorFrame)
	end
	if ns.addonConfig.positionProfileAuto then
		SetAnchor(anchorFrame, frameStrata)
	end
	UpdateProfile(unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, lfdActivityID, keystoneLevel)
end

function ProfileTooltip.HideProfile(useFallback)
	if useFallback == true and IsFallbackShown() then
		SetAnchor(FALLBACK_FRAME, FALLBACK_FRAME_STRATA)
		ProfileTooltip.UpdateTooltip()
	else
		ProfileTooltip:Hide()
	end
end

function ProfileTooltip.UpdateTooltip()
	if ProfileTooltip:IsShown() then
		UpdateProfile(true)
	end
end

ns.PROFILE_UI = ProfileTooltip
