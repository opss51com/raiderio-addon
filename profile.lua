local addonName, ns = ...

-- constants
local L = ns.L

-- profile tooltip
local ProfileTooltip = CreateFrame("GameTooltip", addonName .. "ProfileTooltip", UIParent, "GameTooltipTemplate")

-- force can either be "player", "target" or not defined
-- if force == player then always display player's profile
-- if force == target then always display the active player tooltip
-- if force is not defined, then the display depends on the modifier and the configuration

local function ProfileTooltip_Update(force)
	if false then return end -- DEBUG: NYI

	--[=[

	if not profileTooltip or not profileTooltip:GetOwner() then
		return
	end

	local arg1, forceNoPadding, forceAddName, forceFaction, focusOnDungeonIndex, focusOnKeystoneLevel = tooltipArgs[1], tooltipArgs[2], tooltipArgs[3], tooltipArgs[4], tooltipArgs[5], tooltipArgs[6]

	-- force player
	if force == "player" then
		arg1 = "player"
	end

	-- force target
	if force ~= "target" then
		if not arg1 then
			arg1 = "player"
		end

		if not ns.addonConfig.enableProfileModifier then
			arg1 = "player"
		else
			if (not ns.addonConfig.inverseProfileModifier and not addon:IsModifierKeyDown(true)) or (ns.addonConfig.inverseProfileModifier and addon:IsModifierKeyDown(true)) then
				arg1 = "player"
			end
		end
	end

	local profile = GetScore(arg1, nil, forceFaction)

	-- sanity check that the profile exists
	if not profile then
		return
	end

	profileTooltip:ClearLines()

	if arg1 == "player" then
		profileTooltip:AddLine(L.MY_PROFILE_TITLE, 1, 0.85, 0, false)
	else
		profileTooltip:AddLine(L.PLAYER_PROFILE_TITLE, 1, 0.85, 0, false)
	end

	profileTooltip:AddDoubleLine(profile.name, GetFormattedScore(profile.allScore, profile.isPrevAllScore), 1, 1, 1, GetScoreColor(profile.allScore))

	AddLegionScore(profileTooltip, profile)

	if profile.mainScore > profile.allScore then
		profileTooltip:AddDoubleLine(L.MAINS_SCORE, profile.mainScore, 1, 1, 1, GetScoreColor(profile.mainScore))
	end

	profileTooltip:AddLine(" ")
	profileTooltip:AddLine(L.PROFILE_BEST_RUNS, 1, 0.85, 0, false)

	local dungeons = {}
	for dungeonIndex, keyLevel in ipairs(profile.dungeons) do
		table.insert(dungeons, {
			index = dungeonIndex,
			shortName = CONST_DUNGEONS[dungeonIndex].shortNameLocale,
			keyLevel = keyLevel,
			upgrades = profile.dungeonUpgrades[dungeonIndex] or 0,
			fractionalTime = profile.dungeonTimes[dungeonIndex] or 0
		})
	end

	table.sort(dungeons, CompareDungeon)

	for i, dungeon in ipairs(dungeons) do
		local colorDungeonName = COLOR_WHITE
		local colorDungeonLevel = COLOR_WHITE

		local keyLevel = dungeon.keyLevel
		if keyLevel ~= 0 then
			if profile.isEnhanced then
				if dungeon.upgrades == 0 then
					colorDungeonLevel = COLOR_GREY
				end
				keyLevel = GetStarsForUpgrades(dungeon.upgrades) .. keyLevel
			else
				keyLevel = "+" .. keyLevel
			end
		else
			keyLevel = "-"
			colorDungeonLevel = COLOR_GREY
		end

		if focusOnDungeonIndex and focusOnDungeonIndex == dungeon.index then
--				TODO: Add color depending if it's an upgrade or a downgrade
--				if focusOnKeystoneLevel then
--					if dungeon.keyLevel < focusOnKeystoneLevel  then
--						-- green
--						colorDungeonName = { r = 0.12, g = 1, b = 0 }
--						colorDungeonLevel = { r = 0.12, g = 1, b = 0 }
--					elseif dungeon.keyLevel > focusOnKeystoneLevel then
--						-- purple
--						colorDungeonName = { r = 0.78, g = 0, b = 1 }
--						colorDungeonLevel = { r = 0.78, g = 0, b = 1 }
--					else
--						-- blue
--						colorDungeonName = { r = 0, g = 0.51, b = 1 }
--						colorDungeonLevel = { r = 0, g = 0.51, b = 1 }
--					end
--				else
				colorDungeonName = COLOR_GREEN
				colorDungeonLevel = COLOR_GREEN
--				end
		end

		profileTooltip:AddDoubleLine(dungeon.shortName, keyLevel, colorDungeonName.r, colorDungeonName.g, colorDungeonName.b, colorDungeonLevel.r, colorDungeonLevel.g, colorDungeonLevel.b)
	end

	if OUTDATED_DAYS[CONST_PROVIDER_DATA_MYTHICPLUS] and OUTDATED_DAYS[CONST_PROVIDER_DATA_MYTHICPLUS][profile.faction] > 1 then
		profileTooltip:AddLine(" ")
		profileTooltip:AddLine(format(L.OUTDATED_DATABASE, OUTDATED_DAYS[CONST_PROVIDER_DATA_MYTHICPLUS][profile.faction]), 0.8, 0.8, 0.8, false)
	elseif OUTDATED_HOURS[CONST_PROVIDER_DATA_MYTHICPLUS] and OUTDATED_HOURS[CONST_PROVIDER_DATA_MYTHICPLUS][profile.faction] > 12 then
		profileTooltip:AddLine(" ")
		profileTooltip:AddLine(format(L.OUTDATED_DATABASE_HOURS, OUTDATED_HOURS[CONST_PROVIDER_DATA_MYTHICPLUS][profile.faction]), 0.8, 0.8, 0.8, false)
	end

	profileTooltip:Show()
	--]=]
end

local function ProfileTooltip_ShowNearFrame(frame, forceFrameStrata, force)
	if false then return end -- DEBUG: NYI

	--[=[
	if not ns.addonConfig.showRaiderIOProfile then
		return
	end

	profileTooltip:SetOwner(frame, "ANCHOR_NONE")
	profileTooltip:ClearAllPoints()
	profileTooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT")

	profileTooltip:SetFrameStrata(forceFrameStrata or frame:GetFrameStrata())

	ProfileTooltip_Update(force)
	--]=]
end

local function ProfileTooltip_OnDragStop(self)
	self:StopMovingOrSizing()
	local point, _, _, x, y = self:GetPoint()
	local p = ns.addonConfig.profilePoint or {}
	p.point, p.x, p.y = point, x, y
	ns.addonConfig.profilePoint = p
end

local function ProfileTooltip_SetFrameDraggability(draggable)
	ProfileTooltip:SetMovable(draggable)
	ProfileTooltip:EnableMouse(draggable)
	if draggable then
		ProfileTooltip:RegisterForDrag("LeftButton")
		ProfileTooltip:SetScript("OnDragStart", ProfileTooltip.StartMoving)
		ProfileTooltip:SetScript("OnDragStop", ProfileTooltip_OnDragStop)
	else
		ProfileTooltip:RegisterForDrag(nil)
		ProfileTooltip:SetScript("OnDragStart", nil)
		ProfileTooltip:SetScript("OnDragStop", nil)
	end
end

local function ProfileTooltip_OnHide(self)
	if PVEFrame:IsShown() then
		if ns.addonConfig.positionProfileAuto then
			ProfileTooltip_ShowNearFrame(PVEFrame, "BACKGROUND")
		else
			ProfileTooltip_Update()
		end
	else
		ProfileTooltip:Hide()
	end
end

ProfileTooltip:HookScript("OnHide",  ProfileTooltip_OnHide)

local HookFrame
do
	local hook = {}

	function HookFrame(frame)
		if type(frame) ~= "table" or type(frame.GetObjectType) ~= "function" then return end
		if hook[frame] then return end
		hook[frame] = 1
		frame:HookScript("OnHide", ProfileTooltip.HideProfile)
	end
end

function ProfileTooltip.SaveConfig()
	if ns.addonConfig.positionProfileAuto and PVEFrame:IsShown() then
		ProfileTooltip_ShowNearFrame(PVEFrame, "BACKGROUND")
	end
	ProfileTooltip_SetFrameDraggability(not ns.addonConfig.positionProfileAuto and not ns.addonConfig.lockProfile)
	if ns.addonConfig.positionProfileAuto then
		local p = ns.addonConfig.profilePoint or {}
		p.point, p.x, p.y = nil
		ns.addonConfig.profilePoint = p
	end
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
	ProfileTooltip_SetFrameDraggability(not ns.addonConfig.lockProfile)
end

function ProfileTooltip.ShowProfile(unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, anchorFrame, frameStrata)
	if anchorFrame then
		HookFrame(anchorFrame)
	end
	if ns.addonConfig.positionProfileAuto then
		ProfileTooltip_ShowNearFrame(anchorFrame, nil, "target")
	else
		ProfileTooltip_Update("target")
	end
end

function ProfileTooltip.HideProfile(anchorFrame)
	if ns.addonConfig.positionProfileAuto then
		ProfileTooltip_ShowNearFrame(anchorFrame)
	else
		ProfileTooltip_Update()
	end
end

ns.PROFILE_UI = ProfileTooltip

--[[
if not profileTooltip:IsShown() then
	ProfileTooltip_ShowNearFrame(PVEFrame, "BACKGROUND", "player")
	if not ns.addonConfig.positionProfileAuto then
		if ns.addonConfig.profilePoint.point ~= nil then
			profileTooltip:ClearAllPoints()
			profileTooltip:SetPoint(ns.addonConfig.profilePoint.point, nil, ns.addonConfig.profilePoint.point, ns.addonConfig.profilePoint.x, ns.addonConfig.profilePoint.y)
		end
		if not ns.addonConfig.lockProfile then
			ProfileTooltip_SetFrameDraggability(true)
		end
	end
end
--]]
