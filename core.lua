local addonName, ns = ...

-- if we're on the developer version the addon behaves slightly different
ns.DEBUG_MODE = not not (GetAddOnMetadata(addonName, "Version") or ""):find("@project-version@", nil, true)

-- micro-optimization for more speed
local unpack = unpack
local sort = table.sort
local wipe = table.wipe
local floor = math.floor
local min = math.min
local max = math.max
local lshift = bit.lshift
local rshift = bit.rshift
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local PAYLOAD_BITS = 13
local PAYLOAD_MASK = lshift(1, PAYLOAD_BITS) - 1
local LOOKUP_MAX_SIZE = floor(2^18-1)

-- default config
local addonConfig
do
	addonConfig = {
		enableUnitTooltips = true,
		enableLFGTooltips = true,
		enableFriendsTooltips = true,
		enableLFGDropdown = true,
		enableWhoTooltips = true,
		enableWhoMessages = true,
		enableGuildTooltips = true,
		enableKeystoneTooltips = true,
		showMainsScore = true,
		showDropDownCopyURL = true,
		showSimpleScoreColors = false,
		showScoreInCombat = true,
		disableScoreColors = false,
		alwaysExtendTooltip = false,
		enableClientEnhancements = true,
		showClientGuildBest = true,
		displayWeeklyGuildBest = false,
		showRaiderIOProfile = true,
		enableProfileModifier = true,
		inverseProfileModifier = false,
		positionProfileAuto = true,
		lockProfile = false,
		profilePoint = { point = nil, x = 0, y = 0 },
	}

	ns.addonConfig = addonConfig
end

-- session
local uiHooks = {}
local profileCache = {}
local profileCacheTooltip = {}
local configParentFrame
local configButtonFrame
local configHeaderFrame
local configScrollFrame
local configSliderFrame
local configFrame
local dataProviderQueue = {}
local dataProvider

-- player
local PLAYER_FACTION
local PLAYER_REGION

-- db outdated
local IS_DB_OUTDATED = {}
local OUTDATED_DAYS = {}
local OUTDATED_HOURS = {}

-- constants
local CONST_REALM_SLUGS = ns.realmSlugs
local CONST_REGION_IDS = ns.regionIDs
local CONST_SCORE_TIER = ns.scoreTiers
local CONST_SCORE_TIER_SIMPLE = ns.scoreTiersSimple
local CONST_DUNGEONS = ns.dungeons
local CONST_AVERAGE_SCORE = ns.scoreLevelStats
local L = ns.L

-- data provider data types
local CONST_PROVIDER_DATA_MYTHICPLUS = 1
local CONST_PROVIDER_DATA_RAIDING = 2
local CONST_PROVIDER_DATA_LIST = { CONST_PROVIDER_DATA_MYTHICPLUS, CONST_PROVIDER_DATA_RAIDING }
local CONST_PROVIDER_INTERFACE = { MYTHICPLUS = CONST_PROVIDER_DATA_MYTHICPLUS, RAIDING = CONST_PROVIDER_DATA_RAIDING }

-- output flags used to shape the table returned by the data provider
local ProfileOutput = {
	INVALID_FLAG = 0,
	INCLUDE_LOWBIES = 1,
	MOD_KEY_DOWN = 2,
	MOD_KEY_DOWN_STICKY = 4,
	MYTHICPLUS = 8,
	RAIDING = 16,
	TOOLTIP = 32,
	ADD_PADDING = 64,
	ADD_NAME = 128,
	ADD_BEST_RUN = 256,
	ADD_LFD = 512,
	FOCUS_DUNGEON = 1024,
	FOCUS_KEYSTONE = 2048,
}

-- default no-tooltip and default tooltip flags used as baseline in several places
ProfileOutput.DATA = bor(ProfileOutput.MYTHICPLUS, ProfileOutput.RAIDING)
ProfileOutput.DEFAULT = bor(ProfileOutput.DATA, ProfileOutput.TOOLTIP)

-- dynamic tooltip flags for specific uses
local TooltipProfileOutput = {
	DEFAULT = ProfileOutput.DEFAULT,
	PADDING = bor(ProfileOutput.DEFAULT, ProfileOutput.ADD_PADDING),
	NAME = bor(ProfileOutput.DEFAULT, ProfileOutput.ADD_NAME),
}

-- setup outdated struct
do
	for i = 1, #CONST_PROVIDER_DATA_LIST do
		local dataType = CONST_PROVIDER_DATA_LIST[i]
		IS_DB_OUTDATED[dataType] = {}
		OUTDATED_DAYS[dataType] = {}
		OUTDATED_HOURS[dataType] = {}
	end
end

-- enum dungeons
-- the for-loop serves two purposes: localize the shortName, and populate the enums
local ENUM_DUNGEONS = {}
local KEYSTONE_INST_TO_DUNGEONID = {}
local DUNGEON_INSTANCEMAPID_TO_DUNGEONID = {}
local LFD_ACTIVITYID_TO_DUNGEONID = {}
for i = 1, #CONST_DUNGEONS do
	local dungeon = CONST_DUNGEONS[i]
	dungeon.index = i

	ENUM_DUNGEONS[dungeon.shortName] = i
	KEYSTONE_INST_TO_DUNGEONID[dungeon.keystone_instance] = i
	DUNGEON_INSTANCEMAPID_TO_DUNGEONID[dungeon.instance_map_id] = i

	for _, activity_id in ipairs(dungeon.lfd_activity_ids) do
		LFD_ACTIVITYID_TO_DUNGEONID[activity_id] = i
	end

	dungeon.shortNameLocale = L["DUNGEON_SHORT_NAME_" .. dungeon.shortName] or dungeon.shortName
end

-- defined constants
local MAX_LEVEL = MAX_PLAYER_LEVEL_TABLE[LE_EXPANSION_BATTLE_FOR_AZEROTH]
local OUTDATED_SECONDS = 86400 * 3 -- number of seconds before we start warning about outdated data
local NUM_FIELDS_PER_CHARACTER = 3 -- number of fields in the database lookup table for each character
local FACTION
local REGIONS
local REGIONS_RESET_TIME
local KEYSTONE_AFFIX_SCHEDULE
local KEYSTONE_LEVEL_TO_BASE_SCORE
do
	FACTION = {
		["Alliance"] = 1,
		["Horde"] = 2,
	}

	REGIONS = {
		"us",
		"kr",
		"eu",
		"tw",
		"cn"
	}

	REGIONS_RESET_TIME = {
		1135695600,
		1135810800,
		1135753200,
		1135810800,
		1135810800,
	}

	KEYSTONE_AFFIX_SCHEDULE = {
		9, -- Fortified
		10, -- Tyrannical
		-- {  6,  4,  9 },
		-- {  7,  2, 10 },
		-- {  5,  3,  9 },
		-- {  8, 12, 10 },
		-- {  7, 13,  9 },
		-- { 11, 14, 10 },
		-- {  6,  3,  9 },
		-- {  5, 13, 10 },
		-- {  7, 12,  9 },
		-- {  8,  4, 10 },
		-- { 11,  2,  9 },
		-- {  5, 14, 10 },
	}

	KEYSTONE_LEVEL_TO_BASE_SCORE = {
		[2] = 20,
		[3] = 30,
		[4] = 40,
		[5] = 50,
		[6] = 60,
		[7] = 70,
		[8] = 80,
		[9] = 90,
		[10] = 100,
		[11] = 110,
		[12] = 121,
		[13] = 133,
		[14] = 146,
		[15] = 161,
		[16] = 177,
		[17] = 195,
		[18] = 214,
		[19] = 236,
		[20] = 259,
		[21] = 285,
		[22] = 314,
		[23] = 345,
		[24] = 380,
		[25] = 418,
		[26] = 459,
		[27] = 505,
		[28] = 556,
		[29] = 612,
		[30] = 673,
	}
end

-- easter
local EGG = {
	["eu"] = {
		["Ravencrest"] = {
			["Voidzone"] = "Raider.IO AddOn Author",
		},
		["Sargeras"] = {
			["Isak"] = "Raider.IO Contributor"
		}
	},
	["us"] = {
		["Skullcrusher"] = {
			["Aspyrox"] = "Raider.IO Creator",
			["Ulsoga"] = "Raider.IO Creator",
			["Dynrai"] = "Raider.IO Contributor",
			["Divyn"] = "Raider.IO Contributor",
			["Pepsiblue"] = "#millennialthings",
		},
		["Thrall"] = {
			["Firstclass"] = "Author of mythicpl.us"
		}
	},
}

-- create the addon core frame
local addon = CreateFrame("Frame")

-- dynamic tooltip flags for specific uses (replaces the flags with functions that when called also combines the modifier logic)
do
	for k, v in pairs(TooltipProfileOutput) do
		TooltipProfileOutput[k] = function(forceMod) return bor(v, (forceMod or addon:IsModifierKeyDown()) and ProfileOutput.MOD_KEY_DOWN or 0) end
	end
end

-- utility functions
local RoundNumber
local CompareDungeon
local GetDungeonWithData
local GetTimezoneOffset
local GetRegion
local GetKeystoneLevel
local GetLFDStatus
local GetInstanceStatus
local GetRealmSlug
local GetNameAndRealm
local GetFaction
local IsUnitMaxLevel
local GetWeeklyAffix
local GetAverageScore
local GetStarsForUpgrades
local GetGuildFullName
local GetFormattedScore
local GetFormattedRunCount
do
	-- bracket can be 10, 100, 0.1, 0.01, and so on
	function RoundNumber(v, bracket)
		bracket = bracket or 1
		return floor(v/bracket + ((v >= 0 and 1) or -1 )* 0.5) * bracket
	end

	-- Find the dungeon in CONST_DUNGEONS corresponding to the data in argument
	function GetDungeonWithData(dataName, dataValue)
		for i = 1, #CONST_DUNGEONS do
			if CONST_DUNGEONS[i][dataName] == dataValue then
				return CONST_DUNGEONS[i]
			end
		end
	end

	-- Compare two dungeon first by the keyLevel, then by their short name
	function CompareDungeon(a, b)
		if not a then
			return false
		end

		if not b then
			return true
		end

		if a.keyLevel > b.keyLevel then
			return true
		elseif a.keyLevel < b.keyLevel then
			return false
		end

		if a.fractionalTime > b.fractionalTime then
			return false
		elseif a.fractionalTime < b.fractionalTime then
			return true
		end

		if a.shortName > b.shortName then
			return false
		elseif a.shortName < b.shortName then
			return true
		end

		return false
	end

	-- get timezone offset between local and UTC+0 time
	function GetTimezoneOffset(ts)
		local u = date("!*t", ts)
		local l = date("*t", ts)
		l.isdst = false
		return difftime(time(l), time(u))
	end

	-- gets the current region name and index
	function GetRegion()
		-- use the player GUID to find the serverID and check the map for the region we are playing on
		local guid = UnitGUID("player")
		local server
		if guid then
			server = tonumber(strmatch(guid, "^Player%-(%d+)") or 0) or 0
			local i = CONST_REGION_IDS[server]
			if i then
				return REGIONS[i], i
			end
		end
		-- alert the user to report this to the devs
		DEFAULT_CHAT_FRAME:AddMessage(format(L.UNKNOWN_SERVER_FOUND, addonName, guid or "N/A", GetNormalizedRealmName() or "N/A"), 1, 1, 0)
		-- fallback logic that might be wrong, but better than nothing...
		local i = GetCurrentRegion()
		return REGIONS[i], i
	end

	-- the kind of strings we might want to interpret as keystone levels in title and descriptions
	local KEYSTONE_LEVEL_PATTERNS = { "(%d+)%+", "%+%s*(%d+)", "(%d+)%s*%+", "(%d+)" }

	-- attempts to extract the keystone level from the provided strings
	function GetKeystoneLevel(raw)
		if type(raw) ~= "string" then
			return
		end
		local level
		for _, pattern in ipairs(KEYSTONE_LEVEL_PATTERNS) do
			level = raw:match(pattern)
			if level then
				level = tonumber(level)
				if level and level < 32 then
					break
				end
			end
		end
		if not level or level < 2 then
			return
		end
		return level
	end

	-- returns the LFD status (returns the info based on what we are hosting a group for, or what we queued up for)
	function GetLFDStatus()
		-- hosting a keystone group
		local _, activityID, _, _, name, comment = C_LFGList.GetActiveEntryInfo()
		local temp = {}
		if activityID then
			local index = LFD_ACTIVITYID_TO_DUNGEONID[activityID]
			if index then
				temp.dungeon = CONST_DUNGEONS[index]
				temp.level = 0 or GetKeystoneLevel(name) or GetKeystoneLevel(comment) or 0
				return true, temp
			end
		end
		-- applying for a keystone group
		local applications = C_LFGList.GetApplications()
		local j = 1
		for i = 1, #applications do
			local resultID = applications[i]
			local _, activityID, name, comment, _, _, _, _, _, _, _, isDelisted = C_LFGList.GetSearchResultInfo(resultID)
			if activityID and not isDelisted then
				local _, appStatus, pendingStatus = C_LFGList.GetApplicationInfo(resultID)
				if not pendingStatus and (appStatus == "applied" or appStatus == "invited") then
					local index = LFD_ACTIVITYID_TO_DUNGEONID[activityID]
					if index then
						temp[j] = { dungeon = CONST_DUNGEONS[index], level = 0 or GetKeystoneLevel(name) or GetKeystoneLevel(comment) or 0, resultID = resultID }
						j = j + 1
					end
				end
			end
		end
		return j - 1, temp
	end

	-- detect what instance we are in
	function GetInstanceStatus()
		local _, instanceType, _, _, _, _, _, instanceMapID = GetInstanceInfo()
		if instanceType ~= "party" then
			return
		end
		local index = DUNGEON_INSTANCEMAPID_TO_DUNGEONID[instanceMapID]
		if not index then
			return
		end
		return CONST_DUNGEONS[index]
	end

	-- retrieves the url slug for a given realm name
	function GetRealmSlug(realm)
		return CONST_REALM_SLUGS[realm] or realm
	end

	-- returns the name, realm and possibly unit
	function GetNameAndRealm(arg1, arg2)
		local name, realm, unit
		if UnitExists(arg1) then
			unit = arg1
			if UnitIsPlayer(arg1) then
				name, realm = UnitName(arg1)
				realm = realm and realm ~= "" and realm or GetNormalizedRealmName()
			end
		elseif type(arg1) == "string" and arg1 ~= "" then
			if arg1:find("-", nil, true) then
				name, realm = ("-"):split(arg1)
			else
				name = arg1 -- assume this is the name
			end
			if not realm or realm == "" then
				if type(arg2) == "string" and arg2 ~= "" then
					realm = arg2
				else
					realm = GetNormalizedRealmName() -- assume they are on our realm
				end
			end
		end
		return name, realm, unit
	end

	-- returns 1 or 2 if the unit is Alliance or Horde, nil if neutral
	function GetFaction(unit)
		if UnitExists(unit) and UnitIsPlayer(unit) then
			local faction = UnitFactionGroup(unit)
			if faction then
				return FACTION[faction]
			end
		end
	end

	-- returns true if we know the unit is max level or if we don't know (unit is invalid) we return using fallback value
	function IsUnitMaxLevel(unit, fallback)
		if UnitExists(unit) and UnitIsPlayer(unit) then
			local level = UnitLevel(unit)
			if level then
				return level >= MAX_LEVEL
			end
		end
		return fallback
	end

	-- returns affix ID based on the week
	function GetWeeklyAffix(weekOffset)
		local timestamp = (time() - GetTimezoneOffset()) + 604800 * (weekOffset or 0)
		local timestampWeeklyReset = REGIONS_RESET_TIME[PLAYER_REGION]
		local diff = difftime(timestamp, timestampWeeklyReset)
		local index = floor(diff / 604800) % #KEYSTONE_AFFIX_SCHEDULE + 1
		return KEYSTONE_AFFIX_SCHEDULE[index]
	end

	function GetAverageScore(level)
		if CONST_AVERAGE_SCORE and CONST_AVERAGE_SCORE[level] then
			return CONST_AVERAGE_SCORE[level]
		end
		return nil
	end

	function GetStarsForUpgrades(upgrades, skipPadding)
		local stars = ""
		for q = 1, 3 do
			if 3 - q < upgrades then
				stars = stars .. "+"
			elseif not skipPadding then
				stars = stars .. " "
			end
		end
		if upgrades > 0 then
			return "|cffffcf40" .. stars .. "|r"
		else
			return stars
		end
	end

	function GetGuildFullName(unit)
		local guildName, _, _, guildRealm = GetGuildInfo(unit)

		if not guildName then
			return nil
		end

		if not guildRealm then
			_, guildRealm = GetNameAndRealm(unit)
		end

		return guildName.."-"..guildRealm
	end

	-- returns score formatted for current or prev season
	function GetFormattedScore(score, isPrevious)
		if isPrevious then
			return score .. " " .. L.PREV_SEASON_SUFFIX
		end
		return score
	end

	-- we only use 8 bits for a run, so decide a cap that we won't show beyond
	function GetFormattedRunCount(count)
		if count > 250 then
			return "250+"
		else
			return count
		end
	end
end

-- addon functions
local Init
local InitConfig
do
	-- update local reference to the correct savedvariable table
	local function UpdateGlobalConfigVar()
		if type(_G.RaiderIO_Config) ~= "table" then
			_G.RaiderIO_Config = addonConfig
		else
			local defaults = addonConfig
			addonConfig = setmetatable(_G.RaiderIO_Config, {
				__index = function(_, key)
					return defaults[key]
				end
			})
			-- update the namespace reference
			ns.addonConfig = addonConfig
		end
	end

	-- addon config is loaded so we update the local reference and register for future events
	function Init()
		-- update local reference to the correct savedvariable table
		UpdateGlobalConfigVar()

		-- wait for the login event, or run the associated code right away
		if not IsLoggedIn() then
			addon:RegisterEvent("PLAYER_LOGIN")
		else
			addon:PLAYER_LOGIN()
		end

		-- create the config frame
		InitConfig()

		-- purge cache after zoning
		addon:RegisterEvent("PLAYER_ENTERING_WORLD")

		-- detect toggling of the modifier keys (additional events to try self-correct if we locked the mod key by using ALT-TAB)
		addon:RegisterEvent("MODIFIER_STATE_CHANGED")
	end

	-- addon config is loaded so we can build the config frame
	function InitConfig()
		_G.StaticPopupDialogs["RAIDERIO_RELOADUI_CONFIRM"] = {
			text = L.CHANGES_REQUIRES_UI_RELOAD,
			button1 = L.RELOAD_NOW,
			button2 = L.RELOAD_LATER,
			hasEditBox = false,
			preferredIndex = 3,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			OnShow = nil,
			OnHide = nil,
			OnAccept = ReloadUI,
			OnCancel = nil
		}

		configParentFrame = CreateFrame("Frame", addonName .. "ConfigParentFrame", UIParent)
		configParentFrame:SetSize(400, 600)
		configParentFrame:SetPoint("CENTER")

		configHeaderFrame = CreateFrame("Frame", nil, configParentFrame)
		configHeaderFrame:SetPoint("TOPLEFT", 00, -30)
		configHeaderFrame:SetPoint("TOPRIGHT", 00, 30)
		configHeaderFrame:SetHeight(40)

		configScrollFrame = CreateFrame("ScrollFrame", nil, configParentFrame)
		configScrollFrame:SetPoint("TOPLEFT", configHeaderFrame, "BOTTOMLEFT")
		configScrollFrame:SetPoint("TOPRIGHT", configHeaderFrame, "BOTTOMRIGHT")
		configScrollFrame:SetHeight(475)
		configScrollFrame:EnableMouseWheel(true)
		configScrollFrame:SetClampedToScreen(true);
		configScrollFrame:SetClipsChildren(true);
		configScrollFrame:HookScript("OnMouseWheel", function(self, delta)
			local currentValue = configSliderFrame:GetValue()
			local changes = -delta * 20
			configSliderFrame:SetValue(currentValue + changes)
		end)

		configButtonFrame = CreateFrame("Frame", nil, configParentFrame)
		configButtonFrame:SetPoint("TOPLEFT", configScrollFrame, "BOTTOMLEFT", 0, -10)
		configButtonFrame:SetPoint("TOPRIGHT", configScrollFrame, "BOTTOMRIGHT")
		configButtonFrame:SetHeight(50)

		configParentFrame.scrollframe = configScrollFrame

		configSliderFrame = CreateFrame("Slider", nil, configScrollFrame, "UIPanelScrollBarTemplate")
		configSliderFrame:SetPoint("TOPLEFT", configScrollFrame, "TOPRIGHT", -35, -18)
		configSliderFrame:SetPoint("BOTTOMLEFT", configScrollFrame, "BOTTOMRIGHT", -35, 18)
		configSliderFrame:SetMinMaxValues(1, 1)
		configSliderFrame:SetValueStep(1)
		configSliderFrame.scrollStep = 1
		configSliderFrame:SetValue(0)
		configSliderFrame:SetWidth(16)
		configSliderFrame:SetScript("OnValueChanged",
			function (self, value)
				self:GetParent():SetVerticalScroll(value)
			end)

		configParentFrame.scrollbar = configSliderFrame

		configFrame = CreateFrame("Frame", addonName .. "ConfigFrame", configScrollFrame)
		configFrame:SetSize(400, 600) -- resized to proper value below
		configScrollFrame.content = configFrame
		configScrollFrame:SetScrollChild(configFrame)
		configParentFrame:Hide()

		local config

		local function WidgetHelp_OnEnter(self)
			if self.tooltip then
				GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT", 0, 0)
				GameTooltip:AddLine(self.tooltip, 1, 1, 1, true)
				GameTooltip:Show()
			end
		end

		local function WidgetButton_OnEnter(self)
			self:SetBackdropColor(0.3, 0.3, 0.3, 1)
			self:SetBackdropBorderColor(1, 1, 1, 1)
		end

		local function WidgetButton_OnLeave(self)
			self:SetBackdropColor(0, 0, 0, 1)
			self:SetBackdropBorderColor(1, 1, 1, 0.3)
		end

		local function Close_OnClick()
			configParentFrame:SetShown(not configParentFrame:IsShown())
		end

		local function Save_OnClick()
			Close_OnClick()
			local reload
			for i = 1, #config.modules do
				local f = config.modules[i]
				local checked1 = f.checkButton:GetChecked()
				local checked2 = f.checkButton2:GetChecked()
				local loaded1 = IsAddOnLoaded(f.addon1)
				local loaded2 = IsAddOnLoaded(f.addon2)
				if checked1 then
					if not loaded1 then
						reload = 1
						EnableAddOn(f.addon1)
					end
				elseif loaded1 then
					reload = 1
					DisableAddOn(f.addon1)
				end
				if checked2 then
					if not loaded2 then
						reload = 1
						EnableAddOn(f.addon2)
					end
				elseif loaded2 then
					reload = 1
					DisableAddOn(f.addon2)
				end
			end
			for i = 1, #config.options do
				local f = config.options[i]
				local checked = f.checkButton:GetChecked()
				local enabled = addonConfig[f.cvar]
				addonConfig[f.cvar] = not not checked
				if ((not enabled and checked) or (enabled and not checked)) then
					if f.needReload then
						reload = 1
					end
					if f.callback then
						f.callback()
					end
				end
			end
			if reload then
				StaticPopup_Show("RAIDERIO_RELOADUI_CONFIRM")
			end
			ns.PROFILE_UI.SaveConfig()
		end

		config = {
			modules = {},
			options = {},
			backdrop = {
				bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
				insets = { left = 4, right = 4, top = 4, bottom = 4 }
			}
		}

		function config.Update(self)
			for i = 1, #self.modules do
				local f = self.modules[i]
				f.checkButton:SetChecked(IsAddOnLoaded(f.addon1))
				f.checkButton2:SetChecked(IsAddOnLoaded(f.addon2))
			end
			for i = 1, #self.options do
				local f = self.options[i]
				f.checkButton:SetChecked(addonConfig[f.cvar] ~= false)
			end
		end

		function config.CreateWidget(self, widgetType, height, parentFrame)
			local widget = CreateFrame(widgetType, nil, parentFrame or configFrame)

			if self.lastWidget then
				widget:SetPoint("TOPLEFT", self.lastWidget, "BOTTOMLEFT", 0, -24)
				widget:SetPoint("BOTTOMRIGHT", self.lastWidget, "BOTTOMRIGHT", 0, -4)
			else
				widget:SetPoint("TOPLEFT", parentFrame or configFrame, "TOPLEFT", 16, 0)
				widget:SetPoint("BOTTOMRIGHT", parentFrame or configFrame, "TOPRIGHT", -40, -16)
			end

			widget.bg = widget:CreateTexture()
			widget.bg:SetAllPoints()
			widget.bg:SetColorTexture(0, 0, 0, 0.5)

			widget.text = widget:CreateFontString(nil, nil, "GameFontNormal")
			widget.text:SetPoint("LEFT", 8, 0)
			widget.text:SetPoint("RIGHT", -8, 0)
			widget.text:SetJustifyH("LEFT")

			widget.checkButton = CreateFrame("CheckButton", "$parentCheckButton1", widget, "UICheckButtonTemplate")
			widget.checkButton:Hide()
			widget.checkButton:SetPoint("RIGHT", -4, 0)
			widget.checkButton:SetScale(0.7)

			widget.checkButton2 = CreateFrame("CheckButton", "$parentCheckButton2", widget, "UICheckButtonTemplate")
			widget.checkButton2:Hide()
			widget.checkButton2:SetPoint("RIGHT", widget.checkButton, "LEFT", -4, 0)
			widget.checkButton2:SetScale(0.7)

			widget.help = CreateFrame("Frame", nil, widget)
			widget.help:Hide()
			widget.help:SetPoint("LEFT", widget.checkButton, "LEFT", -20, 0)
			widget.help:SetSize(16, 16)
			widget.help:SetScale(0.9)
			widget.help.icon = widget.help:CreateTexture()
			widget.help.icon:SetAllPoints()
			widget.help.icon:SetTexture("Interface\\GossipFrame\\DailyActiveQuestIcon")

			widget.help:SetScript("OnEnter", WidgetHelp_OnEnter)
			widget.help:SetScript("OnLeave", GameTooltip_Hide)

			if widgetType == "Button" then
				widget.bg:Hide()
				widget.text:SetTextColor(1, 1, 1)
				widget:SetBackdrop(self.backdrop)
				widget:SetBackdropColor(0, 0, 0, 1)
				widget:SetBackdropBorderColor(1, 1, 1, 0.3)
				widget:SetScript("OnEnter", WidgetButton_OnEnter)
				widget:SetScript("OnLeave", WidgetButton_OnLeave)
			end

			if not parentFrame then
				self.lastWidget = widget
			end
			return widget
		end

		function config.CreatePadding(self)
			local frame = self:CreateWidget("Frame")
			local _, lastWidget = frame:GetPoint(1)
			frame:ClearAllPoints()
			frame:SetPoint("TOPLEFT", lastWidget, "BOTTOMLEFT", 0, -14)
			frame:SetPoint("BOTTOMRIGHT", lastWidget, "BOTTOMRIGHT", 0, -4)
			frame.bg:Hide()
			return frame
		end

		function config.CreateHeadline(self, text, parentFrame)
			local frame = self:CreateWidget("Frame", nil, parentFrame)
			frame.bg:Hide()
			frame.text:SetText(text)
			return frame
		end

		function config.CreateModuleToggle(self, name, addon1, addon2)
			local frame = self:CreateWidget("Frame")
			frame.text:SetText(name)
			frame.addon2 = addon1
			frame.addon1 = addon2
			frame.checkButton:Show()
			frame.checkButton2:Show()
			self.modules[#self.modules + 1] = frame
			return frame
		end

		function config.CreateOptionToggle(self, label, description, cvar, config)
			local frame = self:CreateWidget("Frame")
			frame.text:SetText(label)
			frame.tooltip = description
			frame.cvar = cvar
			frame.needReload = (config and config.needReload) or false
			frame.callback = (config and config.callback) or nil
			frame.help.tooltip = description
			frame.help:Show()
			frame.checkButton:Show()
			self.options[#self.options + 1] = frame
			return frame
		end

		-- customize the look and feel
		do
			local function ConfigFrame_OnShow(self)
				if not InCombatLockdown() then
					if InterfaceOptionsFrame:IsShown() then
						InterfaceOptionsFrame_Show()
					end
					HideUIPanel(GameMenuFrame)
				end
				config:Update()
			end

			local function ConfigFrame_OnDragStart(self)
				self:StartMoving()
			end

			local function ConfigFrame_OnDragStop(self)
				self:StopMovingOrSizing()
			end

			local function ConfigFrame_OnEvent(self, event)
				if event == "PLAYER_REGEN_ENABLED" then
					if self.combatHidden then
						self.combatHidden = nil
						self:Show()
					end
				elseif event == "PLAYER_REGEN_DISABLED" then
					if self:IsShown() then
						self.combatHidden = true
						self:Hide()
					end
				end
			end

			configParentFrame:SetFrameStrata("DIALOG")
			configParentFrame:SetFrameLevel(255)

			configParentFrame:EnableMouse(true)
			configParentFrame:SetClampedToScreen(true)
			configParentFrame:SetDontSavePosition(true)
			configParentFrame:SetMovable(true)
			configParentFrame:RegisterForDrag("LeftButton")

			configParentFrame:SetBackdrop(config.backdrop)
			configParentFrame:SetBackdropColor(0, 0, 0, 0.8)
			configParentFrame:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)

			configParentFrame:SetScript("OnShow", ConfigFrame_OnShow)
			configParentFrame:SetScript("OnDragStart", ConfigFrame_OnDragStart)
			configParentFrame:SetScript("OnDragStop", ConfigFrame_OnDragStop)
			configParentFrame:SetScript("OnEvent", ConfigFrame_OnEvent)

			configParentFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
			configParentFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

			-- add widgets
			local header = config:CreateHeadline(L.RAIDERIO_MYTHIC_OPTIONS .. "\nVersion: " .. tostring(GetAddOnMetadata(addonName, "Version")), configHeaderFrame)
			header.text:SetFont(header.text:GetFont(), 16, "OUTLINE")

			config:CreateHeadline(L.MYTHIC_PLUS_SCORES)
			config:CreateOptionToggle(L.SHOW_ON_PLAYER_UNITS, L.SHOW_ON_PLAYER_UNITS_DESC, "enableUnitTooltips")
			config:CreateOptionToggle(L.SHOW_IN_LFD, L.SHOW_IN_LFD_DESC, "enableLFGTooltips")
			config:CreateOptionToggle(L.SHOW_IN_FRIENDS, L.SHOW_IN_FRIENDS_DESC, "enableFriendsTooltips")
			config:CreateOptionToggle(L.SHOW_ON_GUILD_ROSTER, L.SHOW_ON_GUILD_ROSTER_DESC, "enableGuildTooltips")
			config:CreateOptionToggle(L.SHOW_IN_WHO_UI, L.SHOW_IN_WHO_UI_DESC, "enableWhoTooltips")
			config:CreateOptionToggle(L.SHOW_IN_SLASH_WHO_RESULTS, L.SHOW_IN_SLASH_WHO_RESULTS_DESC, "enableWhoMessages")

			config:CreatePadding()
			config:CreateHeadline(L.TOOLTIP_CUSTOMIZATION)
			config:CreateOptionToggle(L.SHOW_MAINS_SCORE, L.SHOW_MAINS_SCORE_DESC, "showMainsScore")
			config:CreateOptionToggle(L.ENABLE_SIMPLE_SCORE_COLORS, L.ENABLE_SIMPLE_SCORE_COLORS_DESC, "showSimpleScoreColors")
			config:CreateOptionToggle(L.ENABLE_NO_SCORE_COLORS, L.ENABLE_NO_SCORE_COLORS_DESC, "disableScoreColors")
			config:CreateOptionToggle(L.ALWAYS_SHOW_EXTENDED_INFO, L.ALWAYS_SHOW_EXTENDED_INFO_DESC, "alwaysExtendTooltip")
			config:CreateOptionToggle(L.SHOW_SCORE_IN_COMBAT, L.SHOW_SCORE_IN_COMBAT_DESC, "showScoreInCombat")
			config:CreateOptionToggle(L.SHOW_KEYSTONE_INFO, L.SHOW_KEYSTONE_INFO_DESC, "enableKeystoneTooltips")
			config:CreateOptionToggle(L.SHOW_AVERAGE_PLAYER_SCORE_INFO, L.SHOW_AVERAGE_PLAYER_SCORE_INFO_DESC, "showAverageScore")

			config:CreatePadding()
			config:CreateHeadline(L.TOOLTIP_PROFILE)
			config:CreateOptionToggle(L.SHOW_RAIDERIO_PROFILE, L.SHOW_RAIDERIO_PROFILE_DESC, "showRaiderIOProfile", {["needReload"] = true})
			config:CreateOptionToggle(L.SHOW_LEADER_PROFILE, L.SHOW_LEADER_PROFILE_DESC, "enableProfileModifier")
			config:CreateOptionToggle(L.INVERSE_PROFILE_MODIFIER, L.INVERSE_PROFILE_MODIFIER_DESC, "inverseProfileModifier")
			config:CreateOptionToggle(L.ENABLE_AUTO_FRAME_POSITION, L.ENABLE_AUTO_FRAME_POSITION_DESC, "positionProfileAuto")
			config:CreateOptionToggle(L.ENABLE_LOCK_PROFILE_FRAME, L.ENABLE_LOCK_PROFILE_FRAME_DESC, "lockProfile")

			config:CreatePadding()
			config:CreateHeadline(L.RAIDERIO_CLIENT_CUSTOMIZATION)
			config:CreateOptionToggle(L.ENABLE_RAIDERIO_CLIENT_ENHANCEMENTS, L.ENABLE_RAIDERIO_CLIENT_ENHANCEMENTS_DESC, "enableClientEnhancements", {["needReload"] = true})
			config:CreateOptionToggle(L.SHOW_CLIENT_GUILD_BEST, L.SHOW_CLIENT_GUILD_BEST_DESC, "showClientGuildBest", {["needReload"] = true})

			config:CreatePadding()
			config:CreateHeadline(L.COPY_RAIDERIO_PROFILE_URL)
			config:CreateOptionToggle(L.ALLOW_ON_PLAYER_UNITS, L.ALLOW_ON_PLAYER_UNITS_DESC, "showDropDownCopyURL")
			config:CreateOptionToggle(L.ALLOW_IN_LFD, L.ALLOW_IN_LFD_DESC, "enableLFGDropdown")

			config:CreatePadding()
			config:CreateHeadline(L.MYTHIC_PLUS_DB_MODULES)
			local module1 = config:CreateModuleToggle(L.MODULE_AMERICAS, "RaiderIO_DB_US_A", "RaiderIO_DB_US_H")
			config:CreateModuleToggle(L.MODULE_EUROPE, "RaiderIO_DB_EU_A", "RaiderIO_DB_EU_H")
			config:CreateModuleToggle(L.MODULE_KOREA, "RaiderIO_DB_KR_A", "RaiderIO_DB_KR_H")
			config:CreateModuleToggle(L.MODULE_TAIWAN, "RaiderIO_DB_TW_A", "RaiderIO_DB_TW_H")

			config:CreatePadding()
			config:CreateHeadline(L.RAIDING_DB_MODULES)
			local module1 = config:CreateModuleToggle(L.MODULE_AMERICAS, "RaiderIO_DB_US_A_R", "RaiderIO_DB_US_H_R")
			config:CreateModuleToggle(L.MODULE_EUROPE, "RaiderIO_DB_EU_A_R", "RaiderIO_DB_EU_H_R")
			config:CreateModuleToggle(L.MODULE_KOREA, "RaiderIO_DB_KR_A_R", "RaiderIO_DB_KR_H_R")
			config:CreateModuleToggle(L.MODULE_TAIWAN, "RaiderIO_DB_TW_A_R", "RaiderIO_DB_TW_H_R")

			-- add save button and cancel buttons
			local buttons = config:CreateWidget("Frame", 4, configButtonFrame)
			buttons:ClearAllPoints()
			buttons:SetPoint("TOPLEFT", configButtonFrame, "TOPLEFT", 16, 0)
			buttons:SetPoint("BOTTOMRIGHT", configButtonFrame, "TOPRIGHT", -16, -10)
			buttons:Hide()
			local save = config:CreateWidget("Button", 4, configButtonFrame)
			local cancel = config:CreateWidget("Button", 4, configButtonFrame)
			save:ClearAllPoints()
			save:SetPoint("LEFT", buttons, "LEFT", 0, -12)
			save:SetSize(96, 28)
			save.text:SetText(SAVE)
			save.text:SetJustifyH("CENTER")
			save:SetScript("OnClick", Save_OnClick)
			cancel:ClearAllPoints()
			cancel:SetPoint("RIGHT", buttons, "RIGHT", 0, -12)
			cancel:SetSize(96, 28)
			cancel.text:SetText(CANCEL)
			cancel.text:SetJustifyH("CENTER")
			cancel:SetScript("OnClick", Close_OnClick)

			-- adjust frame height dynamically
			local children = {configFrame:GetChildren()}
			local height = 50
			for i = 1, #children do
				height = height + children[i]:GetHeight() + 2
			end

			configSliderFrame:SetMinMaxValues(1, height - 440)
			configFrame:SetHeight(height)

			-- adjust frame width dynamically (add padding based on the largest option label string)
			local maxWidth = 0
			for i = 1, #config.options do
				local option = config.options[i]
				if option.text and option.text:GetObjectType() == "FontString" then
					maxWidth = max(maxWidth, option.text:GetStringWidth())
				end
			end
			configFrame:SetWidth(160 + maxWidth)
			configParentFrame:SetWidth(160 + maxWidth)

			-- add faction headers over the first module
			local af = config:CreateHeadline("|TInterface\\Icons\\inv_bannerpvp_02:0:0:0:0:16:16:4:12:4:12|t")
			af:ClearAllPoints()
			af:SetPoint("BOTTOM", module1.checkButton2, "TOP", 2, -5)
			af:SetSize(32, 32)
			local hf = config:CreateHeadline("|TInterface\\Icons\\inv_bannerpvp_01:0:0:0:0:16:16:4:12:4:12|t")
			hf:ClearAllPoints()
			hf:SetPoint("BOTTOM", module1.checkButton, "TOP", 2, -5)
			hf:SetSize(32, 32)
		end

		-- add the category and a shortcut button in the interface panel options
		do
			local function Button_OnClick()
				if not InCombatLockdown() then
					configParentFrame:SetShown(not configParentFrame:IsShown())
				end
			end

			local panel = CreateFrame("Frame", configFrame:GetName() .. "Panel", InterfaceOptionsFramePanelContainer)
			panel.name = addonName
			panel:Hide()

			local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
			button:SetText(L.OPEN_CONFIG)
			button:SetWidth(button:GetTextWidth() + 18)
			button:SetPoint("TOPLEFT", 16, -16)
			button:SetScript("OnClick", Button_OnClick)

			InterfaceOptions_AddCategory(panel, true)
		end

		-- create slash command to toggle the config frame
		do
			_G["SLASH_" .. addonName .. "1"] = "/raiderio"
			_G["SLASH_" .. addonName .. "2"] = "/rio"

			local function handler(text)
				if type(text) == "string" then

					-- if the keyword "lock" is present in the command we toggle lock behavior on profile frame
					if text:find("[Ll][Oo][Cc][Kk]") then
						ns.PROFILE_UI.ToggleLock()
						return
					end

					-- if the keyword "search" is present in the command we show the query dialog
					local searchQuery = text:match("[Ss][Ee][Aa][Rr][Cc][Hh]%s*(.-)$")
					if searchQuery then
						if not ns.SEARCH_UI and ns.SEARCH_INIT then
							ns.SEARCH_INIT()
						end
						if ns.SEARCH_UI then
							if strlenutf8(searchQuery) > 0 then
								ns.SEARCH_UI:Show()
								ns.SEARCH_UI:Search(searchQuery)
							else
								ns.SEARCH_UI:SetShown(not ns.SEARCH_UI:IsShown())
							end
						end
						-- we do not wish to show the config dialog at this time
						return
					end

				end

				-- resume regular routine
				if not InCombatLockdown() then
					configParentFrame:SetShown(not configParentFrame:IsShown())
				end
			end

			SlashCmdList[addonName] = handler
		end
	end
end

-- provider
local AddProvider
local GetScoreColor
local GetPlayerProfile
do
	-- unpack the payload
	local function UnpackPayload(data)
		-- 4294967296 == (1 << 32). Meaning, shift to get the hi-word.
		-- WoW lua bit operators seem to only work on the lo-word (?)
		local hiword = data / 4294967296
		return
			band(data, PAYLOAD_MASK),
			band(rshift(data, PAYLOAD_BITS), PAYLOAD_MASK),
			band(hiword, PAYLOAD_MASK),
			band(rshift(hiword, PAYLOAD_BITS), PAYLOAD_MASK)
	end

	-- search for the index of a name in the given sorted list
	local function BinarySearchForName(list, name, startIndex, endIndex)
		local minIndex = startIndex
		local maxIndex = endIndex
		local mid, current

		while minIndex <= maxIndex do
			mid = floor((maxIndex + minIndex) / 2)
			current = list[mid]
			if current == name then
				return mid
			elseif current < name then
				minIndex = mid + 1
			else
				maxIndex = mid - 1
			end
		end
	end

	local function Split64BitNumber(dword)
		-- 0x100000000 == (1 << 32). Meaning, shift to get the hi-word.
		-- WoW lua bit operators seem to only work on the lo-word (?)
		local lo = band(dword, 0xfffffffff)
		return lo, (dword - lo) / 0x100000000
	end

	-- read given number of bits from the chosen offset with max of 52 bits
	-- assumed that lo contains 32 bits and hi contains 20 bits
	local function ReadBits(lo, hi, offset, bits)
		if offset < 32 and (offset + bits) > 32 then
			-- reading across boundary
			local mask = lshift(1, (offset + bits) - 32) - 1
			local p1 = rshift(lo, offset)
			local p2 = lshift(band(hi, mask), 32 - offset)
			return p1 + p2
		else
			local mask = lshift(1, bits) - 1
			if offset < 32 then
				-- standard read from loword
				return band(rshift(lo, offset), mask)
			else
				-- standard read from hiword
				return band(rshift(hi, offset - 32), mask)
			end
		end
	end

	local function UnpackCharacterData(data1, data2, data3)
		local results = {}
		local lo, hi
		local offset

		--
		-- Field 1
		--
		lo, hi = Split64BitNumber(data1)
		offset = 0

		results.allScore = ReadBits(lo, hi, offset, PAYLOAD_BITS)
		offset = offset + PAYLOAD_BITS

		results.healScore = ReadBits(lo, hi, offset, PAYLOAD_BITS)
		offset = offset + PAYLOAD_BITS

		results.tankScore = ReadBits(lo, hi, offset, PAYLOAD_BITS)
		offset = offset + PAYLOAD_BITS

		results.mainScore = ReadBits(lo, hi, offset, PAYLOAD_BITS)
		offset = offset + PAYLOAD_BITS

		results.isPrevAllScore = not (ReadBits(lo, hi, offset, 1) == 0)
		offset = offset + 1

		--
		-- Field 2
		--
		lo, hi = Split64BitNumber(data2)

		offset = 0
		results.dpsScore = ReadBits(lo, hi, offset, PAYLOAD_BITS)
		offset = offset + PAYLOAD_BITS

		local dungeonIndex = 1
		results.dungeons = {}
		for i = 1, 8 do
			results.dungeons[dungeonIndex] = ReadBits(lo, hi, offset, 5)
			dungeonIndex = dungeonIndex + 1
			offset = offset + 5
		end

		--
		-- Field 3
		--
		lo, hi = Split64BitNumber(data3)

		offset = 0
		while dungeonIndex <= #ns.dungeons do
			results.dungeons[dungeonIndex] = ReadBits(lo, hi, offset, 5)
			dungeonIndex = dungeonIndex + 1
			offset = offset + 5
		end

		local maxDungeonLevel = 0
		local maxDungeonIndex = -1	-- we may not have a max dungeon if user was brought in because of +10/+15 achievement
		for i = 1, #results.dungeons do
			if results.dungeons[i] > maxDungeonLevel then
				maxDungeonLevel = results.dungeons[i]
				maxDungeonIndex = i
			end
		end

		results.maxDungeonLevel = maxDungeonLevel
		results.maxDungeonIndex = maxDungeonIndex

		results.keystoneTenPlus = ReadBits(lo, hi, offset, 8)
		offset = offset + 8

		results.keystoneFifteenPlus = ReadBits(lo, hi, offset, 8)
		offset = offset + 8

		return results
	end

	-- caches the profile table and returns one using keys
	local function CacheProviderData(dataProviderGroup, name, realm, faction, index, data1, data2, data3)
		local cache = profileCache[index]

		-- prefer to re-use cached profiles
		if cache then
			return cache
		end

		-- unpack the payloads into these tables
		local payload = UnpackCharacterData(data1, data2, data3)

		-- TODO: can we make this table read-only? raw methods will bypass metatable restrictions we try to enforce
		-- build this custom table in order to avoid users tainting the provider database
		cache = {
			-- provider information
			region = dataProviderGroup.region,
			date = dataProviderGroup.date,
			season = dataProviderGroup.season,
			prevSeason = dataProviderGroup.prevSeason,
			-- basic information about the character
			name = name,
			realm = realm,
			faction = faction,
			-- current and last season overall score
			allScore = payload.allScore,
			isPrevAllScore = payload.isPrevAllScore,
			mainScore = payload.mainScore,
			-- extract the scores per role
			dpsScore = payload.dpsScore,
			healScore = payload.healScore,
			tankScore = payload.tankScore,
			-- dungeons they have completed
			dungeons = payload.dungeons,
			-- best dungeon completed (or highest 10/15 achievement)
			maxDungeon = CONST_DUNGEONS[payload.maxDungeonIndex],
			maxDungeonLevel = payload.maxDungeonLevel,
			maxDungeonIndex = payload.maxDungeonIndex,
			maxDungeonName = CONST_DUNGEONS[payload.maxDungeonIndex] and CONST_DUNGEONS[payload.maxDungeonIndex].shortName or "",
			maxDungeonNameLocale = CONST_DUNGEONS[payload.maxDungeonIndex] and CONST_DUNGEONS[payload.maxDungeonIndex].shortNameLocale or "",
			keystoneTenPlus = payload.keystoneTenPlus,
			keystoneFifteenPlus = payload.keystoneFifteenPlus,
		}

		-- client related data populates these fields
		do

			-- has been enhanced with client data
			cache.isEnhanced = false

			-- number of keystone upgrades per dungeon
			cache.dungeonUpgrades = {}
			cache.dungeonTimes = {}
			cache.maxDungeonUpgrades = 0

			-- purge pre-bfa data until bfa season starts (but keep it if we're debugging so we can play with the UI)
			if not ns.DEBUG_MODE then
				cache.legionScore = RoundNumber(cache.allScore, 10)
				cache.legionMainScore = RoundNumber(cache.mainScore, 10)
				cache.allScore = 0
				cache.isPrevAllScore = false
				cache.mainScore = 0
				cache.dpsScore = 0
				cache.healScore = 0
				cache.tankScore = 0
				cache.maxDungeonLevel = 0
				cache.maxDungeonName = ""
				cache.maxDungeonNameLocale = ""
				cache.keystoneTenPlus = 0
				cache.keystoneFifteenPlus = 0
				for i = 1, #cache.dungeons do cache.dungeons[i] = 0 end
			end

			-- if character exists in the clientCharacters list then override some data with higher precision
			-- TODO: only do this if the clientCharacters data isn't too old compared to regular addon date?
			if ns.CLIENT_CHARACTERS and addonConfig.enableClientEnhancements then
				local nameAndRealm = name .. "-" .. realm
				local clientData = ns.CLIENT_CHARACTERS[nameAndRealm]

				if clientData then
					local keystoneData = clientData.mythic_keystone
					cache.isEnhanced = true
					cache.allScore = keystoneData.all.score

					local maxDungeonIndex = 0
					local maxDungeonTime = 999
					local maxDungeonLevel = 0
					local maxDungeonUpgrades = 0

					for i = 1, #keystoneData.all.runs do
						local run = keystoneData.all.runs[i]
						cache.dungeons[i] = run.level
						cache.dungeonUpgrades[i] = run.upgrades
						cache.dungeonTimes[i] = run.fraction

						if run.level > maxDungeonLevel or (run.level == maxDungeonLevel and run.fraction < maxDungeonTime) then
							maxDungeonLevel = run.level
							maxDungeonTime = run.fraction
							maxDungeonUpgrades = run.upgrades
							maxDungeonIndex = i
						end
					end

					if maxDungeonIndex > 0 then
						cache.maxDungeon = CONST_DUNGEONS[maxDungeonIndex]
						cache.maxDungeonIndex = maxDungeonIndex
						cache.maxDungeonLevel = maxDungeonLevel
						cache.maxDungeonName = CONST_DUNGEONS[maxDungeonIndex] and CONST_DUNGEONS[maxDungeonIndex].shortName or ""
						cache.maxDungeonNameLocale = CONST_DUNGEONS[maxDungeonIndex] and CONST_DUNGEONS[maxDungeonIndex].shortNameLocale or ""
						cache.maxDungeonUpgrades = maxDungeonUpgrades
					end
				end
			end

		end

		-- append additional role information
		cache.isTank, cache.isHealer, cache.isDPS = cache.tankScore > 0, cache.healScore > 0, cache.dpsScore > 0
		cache.numRoles = (cache.tankScore > 0 and 1 or 0) + (cache.healScore > 0 and 1 or 0) + (cache.dpsScore > 0 and 1 or 0)

		-- store it in the profile cache
		profileCache[index] = cache

		-- return the freshly generated table
		return cache
	end

	-- returns the profile of a given character, faction is optional but recommended for quicker lookups
	local function GetProviderData(dataType, name, realm, faction)
		-- shorthand for data provider group table
		local dataProviderGroup = dataProvider[dataType]
		-- if the provider isn't loaded we don't try and search for the data
		if not dataProviderGroup then return end
		-- figure out what faction tables we want to iterate
		local a, b = 1, 2
		if faction == 1 or faction == 2 then
			a, b = faction, faction
		end
		-- iterate through the data
		local db, lu, r, d, base, bucketID, bucket
		for i = a, b do
			db, lu = dataProviderGroup["db" .. i], dataProviderGroup["lookup" .. i]
			-- sanity check that the data exists and is loaded, because it might not be for the requested faction
			if db and lu then
				r = db[realm]
				if r then
					d = BinarySearchForName(r, name, 2, #r)
					if d then
						-- `r[1]` = offset for this realm's characters in lookup table
						-- `d` = index of found character in realm list. note: this is offset by one because of r[1]
						-- `bucketID` is the index in the lookup table that contains that characters data
						base = r[1] + (d - 1) * NUM_FIELDS_PER_CHARACTER - (NUM_FIELDS_PER_CHARACTER - 1)
						bucketID = floor(base / LOOKUP_MAX_SIZE)
						bucket = lu[bucketID + 1]
						base = base - bucketID * LOOKUP_MAX_SIZE
						return CacheProviderData(dataProviderGroup, name, realm, i, i .. "-" .. bucketID .. "-" .. base, bucket[base], bucket[base + 1], bucket[base + 2])
					end
				end
			end
		end
	end

	function AddProvider(data)
		-- make sure the object is what we expect it to be like
		assert(type(data) == "table" and type(data.name) == "string" and type(data.data) == "number" and type(data.region) == "string" and type(data.faction) == "number", "Raider.IO has been requested to load a database that isn't supported.")
		-- queue it for later inspection
		dataProviderQueue[#dataProviderQueue + 1] = data
	end

	-- returns score color using item colors
	function GetScoreColor(score)
		if score == 0 or addonConfig.disableScoreColors then
			return 1, 1, 1
		end
		local r, g, b = 0.62, 0.62, 0.62
		if type(score) == "number" then
			if not addonConfig.showSimpleScoreColors then
				for i = 1, #CONST_SCORE_TIER do
					local tier = CONST_SCORE_TIER[i]
					if score >= tier.score then
						local color = tier.color
						r, g, b = color[1], color[2], color[3]
						break
					end
				end
			else
				local qualityColor = 0
				for i = 1, #CONST_SCORE_TIER_SIMPLE do
					local tier = CONST_SCORE_TIER_SIMPLE[i]
					if score >= tier.score then
						qualityColor = tier.quality
						break
					end
				end
				r, g, b = GetItemQualityColor(qualityColor)
			end
		end
		return r, g, b
	end

	local function SortScoresByRole(a, b)
		return a[2] > b[2]
	end

	-- reads the profile and formats the output using the provided output flags
	local function ShapeProfileData(dataType, profile, outputFlag, ...)
		local output = { dataType = dataType, profile = profile, outputFlag = outputFlag, length = 0 }
		local addTooltip = band(outputFlag, ProfileOutput.TOOLTIP) == ProfileOutput.TOOLTIP

		if addTooltip then
			local i = 1

			local isModKeyDown = band(outputFlag, ProfileOutput.MOD_KEY_DOWN) == ProfileOutput.MOD_KEY_DOWN
			local isModKeyDownSticky = band(outputFlag, ProfileOutput.MOD_KEY_DOWN_STICKY) == ProfileOutput.MOD_KEY_DOWN_STICKY
			local addPadding = band(outputFlag, ProfileOutput.ADD_PADDING) == ProfileOutput.ADD_PADDING
			local addName = band(outputFlag, ProfileOutput.ADD_NAME) == ProfileOutput.ADD_NAME
			local addBestRun = band(outputFlag, ProfileOutput.ADD_BEST_RUN) == ProfileOutput.ADD_BEST_RUN
			local addLFD = band(outputFlag, ProfileOutput.ADD_LFD) == ProfileOutput.ADD_LFD
			local focusDungeon = band(outputFlag, ProfileOutput.FOCUS_DUNGEON) == ProfileOutput.FOCUS_DUNGEON
			local focusKeystone = band(outputFlag, ProfileOutput.FOCUS_KEYSTONE) == ProfileOutput.FOCUS_KEYSTONE

			if addPadding then
				output[i] = " "
				i = i + 1
			end

			if addName then
				output[i] = format("%s (%s)", profile.name, profile.realm)
				i = i + 1
			end

			if dataType == CONST_PROVIDER_DATA_MYTHICPLUS then

				if profile.legionScore and profile.legionScore > 0 and (not profile.legionMainScore or profile.legionMainScore <= profile.legionScore) then
					output[i] = {L.LEGION_SCORE, GetFormattedScore(profile.legionScore), 1, 1, 1, 1, 1, 1}
					i = i + 1
				elseif profile.legionMainScore and (not profile.legionScore or profile.legionMainScore > profile.legionScore) then
					output[i] = {L.LEGION_MAIN_SCORE, GetFormattedScore(profile.legionMainScore), 1, 1, 1, 1, 1, 1}
					i = i + 1
				elseif profile.allScore >= 0 then
					output[i] = {L.RAIDERIO_MP_SCORE, GetFormattedScore(profile.allScore, profile.isPrevAllScore), 1, 0.85, 0, GetScoreColor(profile.allScore)}
					i = i + 1
				else
					output[i] = {L.RAIDERIO_MP_SCORE, L.UNKNOWN_SCORE, 1, 0.85, 0, 1, 1, 1}
					i = i + 1
				end

				if isModKeyDown or isModKeyDownSticky then
					local scores = {}
					local j = 1
					if profile.tankScore then
						scores[j] = {L.TANK_SCORE, profile.tankScore}
						j = j + 1
					end
					if profile.healScore then
						scores[j] = {L.HEALER_SCORE, profile.healScore}
						j = j + 1
					end
					if profile.dpsScore then
						scores[j] = {L.DPS_SCORE, profile.dpsScore}
						j = j + 1
					end
					table.sort(scores, SortScoresByRole)
					for k = 1, j - 1 do
						if scores[k][2] > 0 then
							output[i] = {scores[k][1], scores[k][2], 1, 1, 1, GetScoreColor(scores[k][2])}
							i = i + 1
						end
					end
				end

				if addBestRun or addLFD or focusDungeon then
					local best = { dungeon = nil, level = 0, text = nil }

					if addLFD then
						local hasArgs, dungeonIndex = ...
						if hasArgs == true then
							best.dungeon = CONST_DUNGEONS[dungeonIndex] or best.dungeon
						end
					end

					if focusDungeon then
						local hasArgs, dungeonIndex = ...
						if hasArgs == true then
							best.dungeon = CONST_DUNGEONS[dungeonIndex] or best.dungeon
						end
					end

					if not best.dungeon then
						local numSigned, status = GetLFDStatus()
						if numSigned then
							if numSigned == true then
								best.dungeon = status.dungeon
							elseif numSigned > 0 then
								local highestDungeon
								for j = 1, numSigned do
									local d = status[j]
									if not highestDungeon or d.level > highestDungeon.level then
										highestDungeon = d
									end
								end
								best.dungeon = highestDungeon
							end
						end
						if not best.dungeon then
							best.dungeon = GetInstanceStatus()
						end
					end

					if best.dungeon then
						best.level = profile.dungeons[best.dungeon.index]
					end

					if profile.keystoneFifteenPlus > 0 then
						if profile.maxDungeonLevel < 15 then
							best.text = L.KEYSTONE_COMPLETED_15
						end
					elseif profile.keystoneTenPlus > 0 then
						if profile.maxDungeonLevel < 10 then
							best.text = L.KEYSTONE_COMPLETED_10
						end
					end

					if best.dungeon and best.dungeon == profile.maxDungeon then
						output[i] = {L.BEST_RUN, "+" .. best.level .. " " .. best.dungeon.shortNameLocale, 0, 1, 0, GetScoreColor(profile.allScore)}
						i = i + 1
					elseif best.dungeon and best.level > 0 then
						output[i] = {L.BEST_RUN, "+" .. best.level .. " " .. best.dungeon.shortNameLocale, 1, 1, 1, GetScoreColor(profile.allScore)}
						i = i + 1
					elseif best.text then
						output[i] = {L.BEST_RUN, best.text, 1, 1, 1, GetScoreColor(profile.allScore)}
						i = i + 1
					end

					if profile.keystoneFifteenPlus > 0 then
						output[i] = {L.TIMED_15_RUNS, GetFormattedRunCount(profile.keystoneFifteenPlus), 1, 1, 1, GetScoreColor(profile.allScore)}
						i = i + 1
					end
					if profile.keystoneTenPlus > 0 and (profile.keystoneFifteenPlus == 0 or addon:IsModifierKeyDown()) then
						output[i] = {L.TIMED_10_RUNS, GetFormattedRunCount(profile.keystoneTenPlus), 1, 1, 1, GetScoreColor(profile.allScore)}
						i = i + 1
					end
				end

				if focusKeystone then
					local hasArgs, arg1, arg2 = ...
					if hasArgs == true then
						output[i] = "focusKeystone arg1 = " .. tostring(arg1)
						i = i + 1
						output[i] = "focusKeystone arg2 = " .. tostring(arg2)
						i = i + 1
					end
				end

				if addonConfig.showMainsScore and profile.mainScore > profile.allScore then
					output[i] = {L.MAINS_SCORE, profile.mainScore, 1, 1, 1, GetScoreColor(profile.mainScore)}
					i = i + 1
				end

			end

			if dataType == CONST_PROVIDER_DATA_RAIDING then
				-- TODO
			end

			local j = 1

			if IS_DB_OUTDATED[dataType][profile.faction] then
				output[i] = {format(L.OUTDATED_DATABASE, OUTDATED_DAYS[dataType][profile.faction]), "", 1, 1, 1, 1, 1, 1, false}
				i = i + 1
				j = j + 1
			end

			local t = EGG[profile.region]
			if t then
				t = t[profile.realm]
				if t then
					t = t[profile.name]
					if t then
						output[i] = {t, "", 0.9, 0.8, 0.5, 1, 1, 1, false}
						i = i + 1
						j = j + 1
					end
				end
			end

			output.length = i - j

		end

		return output
	end

	-- retrieves the complete player profile from all providers
	function GetPlayerProfile(outputFlag, ...)
		if not dataProvider then
			return
		end
		-- must be a number 0 or larger
		if type(outputFlag) ~= "number" or outputFlag < 1 then
			outputFlag = ProfileOutput.DATA
		end
		-- read the first args and figure out the request
		local arg1, arg2, arg3, arg4, arg5 = ...
		local targ1, targ2, targ3 = type(arg1), type(arg2), type(arg3)
		local passThroughAt, passThroughArg1, passThroughArg2, passThroughArg1Table
		local queryName, queryRealm, queryFaction
		if targ1 == "string" and targ2 == "string" and targ3 == "number" then
			passThroughAt, passThroughArg1, passThroughArg2 = 4, arg4, arg5
			queryName, queryRealm, queryFaction = arg1, arg2, arg3
		elseif targ1 == "string" and arg2 == nil and targ3 == "number" then
			passThroughAt, passThroughArg1, passThroughArg2 = 4, arg4, arg5
			queryName, queryRealm, queryFaction = arg1, arg2, arg3
		elseif targ1 == "string" and targ2 == "string" then
			passThroughAt, passThroughArg1, passThroughArg2 = 3, arg3, arg4
			queryName, queryRealm, queryFaction = arg1, arg2, nil
		elseif targ1 == "string" and targ2 == "number" then
			passThroughAt, passThroughArg1, passThroughArg2 = 3, arg3, arg4
			queryName, queryRealm, queryFaction = arg1, nil, arg2
		else
			passThroughAt, passThroughArg1, passThroughArg2 = 2, arg2, arg3
			queryName, queryRealm, queryFaction = arg1, nil, nil
		end
		-- is the pass args an object? if so we pass it directly
		if type(passThroughArg1) == "table" and passThroughArg2 == nil then
			passThroughArg1Table = passThroughArg1
		end
		-- lookup name, realm and potentially unit identifier
		local name, realm, unit = GetNameAndRealm(queryName, queryRealm)
		if name and realm then
			-- what modules are we looking into?
			local reqMythicPlus = band(outputFlag, ProfileOutput.MYTHICPLUS) == ProfileOutput.MYTHICPLUS
			local reqRaiding = band(outputFlag, ProfileOutput.RAIDING) == ProfileOutput.RAIDING
			-- profile GUID for this particular request
			local profileGUID = realm .. "-" .. name .. "-" .. outputFlag
			-- return cached table if it exists, and if we are capable of caching this particular tooltip
			local canCacheProfile = band(outputFlag, ProfileOutput.ADD_LFD) ~= ProfileOutput.ADD_LFD and band(outputFlag, ProfileOutput.FOCUS_DUNGEON) ~= ProfileOutput.FOCUS_DUNGEON and band(outputFlag, ProfileOutput.FOCUS_KEYSTONE) ~= ProfileOutput.FOCUS_KEYSTONE and true or false
			if canCacheProfile then
				local cachedProfile = profileCacheTooltip[profileGUID]
				if cachedProfile then
					return cachedProfile, true, true, reqMythicPlus and reqRaiding
				end
			end
			-- unless the flag to specifically ignore the level check, do make sure we only query max level players
			if not IsUnitMaxLevel(unit, true) and band(outputFlag, ProfileOutput.INCLUDE_LOWBIES) ~= ProfileOutput.INCLUDE_LOWBIES then
				return
			end
			-- establish faction for the lookups
			local faction = type(queryFaction) == "number" and queryFaction or GetFaction(unit)
			-- retrive data from the various data types
			local profile = {}
			local hasData = false
			for i = 1, #CONST_PROVIDER_DATA_LIST do
				local dataType = CONST_PROVIDER_DATA_LIST[i]
				if (dataType == CONST_PROVIDER_DATA_MYTHICPLUS and reqMythicPlus) or (dataType == CONST_PROVIDER_DATA_RAIDING and reqRaiding) then
					local data = GetProviderData(dataType, name, realm, faction)
					if data then
						hasData = true
						if passThroughArg1Table then
							profile[dataType] = ShapeProfileData(dataType, data, outputFlag, passThroughArg1Table)
						else
							profile[dataType] = ShapeProfileData(dataType, data, outputFlag, select(passThroughAt, ...))
						end
					end
				end
			end
			-- if we only requested specific mythic+ or raiding data we only return that specific table
			if reqMythicPlus and not reqRaiding then
				profile = profile[CONST_PROVIDER_DATA_MYTHICPLUS]
			elseif not reqMythicPlus and reqRaiding then
				profile = profile[CONST_PROVIDER_DATA_RAIDING]
			end
			-- cache profile before returning, if we are allowed to cache this particular tooltip
			if canCacheProfile then
				profileCacheTooltip[profileGUID] = profile
			end
			return profile, hasData, canCacheProfile, reqMythicPlus and reqRaiding
		end
	end
end

-- tooltips
local ShowTooltip
local UpdateTooltips
do
	-- tooltip related hooks and storage
	local tooltipArgs = {}
	local tooltipHooks = { Wipe = function(tooltip) table.wipe(tooltipArgs[tooltip]) end }

	-- draws the tooltip based on the returned profile data from the data providers
	local function AppendTooltipLines(tooltip, profile, multipleProviders)
		local added
		if multipleProviders then
			local count = #profile
			-- iterate the data returned from the modules
			for i = 1, count do
				local output = profile[i]
				-- iterate everything if this is the last module output, otherwise limit ourselves to the defined length
				for j = 1, i == count and #output or output.length do
					-- the line can be a table, thus a double line, or a left aligned line
					local line = output[j]
					if type(line) == "table" then
						tooltip:AddDoubleLine(line[1], line[2], line[3], line[4], line[5], line[6], line[7], line[8], line[9], line[10])
					else
						tooltip:AddLine(line)
					end
					-- we know the tooltip was build successfully
					added = true
				end
			end
		else
			-- only one provider so we have only one table to iterate
			for i = 1, #profile do
				-- the line can be a table, thus a double line, or a left aligned line
				local line = profile[i]
				if type(line) == "table" then
					tooltip:AddDoubleLine(line[1], line[2], line[3], line[4], line[5], line[6], line[7], line[8], line[9], line[10])
				else
					tooltip:AddLine(line)
				end
				-- we know the tooltip was build successfully
				added = true
			end
		end
		return added
	end

	-- shows data on the provided tooltip widget for the particular player
	function ShowTooltip(tooltip, outputFlag, unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, arg1, ...)
		-- setup tooltip hook
		if not tooltipHooks[tooltip] then
			tooltipHooks[tooltip] = true
			tooltip:HookScript("OnTooltipCleared", tooltipHooks.Wipe)
			tooltip:HookScript("OnHide", tooltipHooks.Wipe)
			-- setup the re-usable table for this tooltips args cache for future updates
			tooltipArgs[tooltip] = {}
		end
		-- get the player profile
		local profile, hasProfile, isCached, multipleProviders = GetPlayerProfile(outputFlag, unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, arg1, ...)
		-- sanity check
		if hasProfile and AppendTooltipLines(tooltip, profile, multipleProviders) then
			-- store tooltip args for refresh purposes
			local tooltipCache = tooltipArgs[tooltip]
			if isCached then
				tooltipCache[1], tooltipCache[2], tooltipCache[3], tooltipCache[4], tooltipCache[5], tooltipCache[6], tooltipCache[7], tooltipCache[8] = true, tooltip, outputFlag, unitOrNameOrNameAndRealm, realmOrNil, factionOrNil
			else
				tooltipCache[1], tooltipCache[2], tooltipCache[3], tooltipCache[4], tooltipCache[5], tooltipCache[6], tooltipCache[7], tooltipCache[8] = false, {tooltip, outputFlag, unitOrNameOrNameAndRealm, realmOrNil, factionOrNil, arg1, ...}
			end
			-- resize tooltip to fit the new contents
			tooltip:Show()
			return true
		end
		return false
	end

	-- updates the visible tooltip
	local function UpdateTooltip(tooltipCache)
		-- unpack the args
		local arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8 = tooltipCache[1], tooltipCache[2], tooltipCache[3], tooltipCache[4], tooltipCache[5], tooltipCache[6], tooltipCache[7], tooltipCache[8]
		local tooltip
		if arg1 == true then
			tooltip = arg2
		elseif arg1 == false then
			tooltip = arg2[1]
		end
		-- sanity check
		if not tooltip or not tooltip:GetOwner() then return end
		-- units only need to SetUnit to re-draw the tooltip properly
		local _, unit = tooltip:GetUnit()
		if unit then
			tooltip:SetUnit(unit)
			return
		end
		-- gather tooltip information
		local o1, o2, o3, o4 = tooltip:GetOwner()
		local p1, p2, p3, p4, p5 = tooltip:GetPoint(1)
		local a1, a2, a3 = tooltip:GetAnchorType()
		-- try to run the OnEnter handler to simulate the user hovering over and triggering the tooltip
		if o1 then
			local oe = o1:GetScript("OnEnter")
			if oe then
				tooltip:Hide()
				oe(o1)
				return
			end
		end
		-- if nothing else worked, attempt to hide, then show the tooltip again in the same place
		tooltip:Hide()
		if o1 then
			o2 = a1
			if p4 then
				o3 = p4
			end
			if p5 then
				o4 = p5
			end
			tooltip:SetOwner(o1, o2, o3, o4)
		end
		if p1 then
			tooltip:SetPoint(p1, p2, p3, p4, p5)
		end
		if not o1 and a1 then
			tooltip:SetAnchorType(a1, a2, a3)
		end
		-- we need to handle the modifier bit or we'll just re-draw the same one if we've toggled the modifier
		local modBit, modBitIsArg
		if arg1 == true then
			modBit, modBitIsArg = arg3, true
		elseif arg1 == false then
			modBit, modBitIsArg = arg2[3], false
		end
		if modBit then
			if band(modBit, ProfileOutput.MOD_KEY_DOWN) == ProfileOutput.MOD_KEY_DOWN then
				if not addon:IsModifierKeyDown() then
					modBit = bxor(modBit, ProfileOutput.MOD_KEY_DOWN)
				end
			elseif addon:IsModifierKeyDown() then
				modBit = bor(modBit, ProfileOutput.MOD_KEY_DOWN)
			end
			if modBitIsArg then
				arg3 = modBit
			else
				arg2[3] = modBit
			end
		end
		-- finalize by calling the show tooltip API with the same arguments as earlier
		if arg1 == true then
			ShowTooltip(arg2, arg3, arg4, arg5, arg6, arg7, arg8)
		elseif arg1 == false then
			ShowTooltip(unpack(arg2))
		end
	end

	function UpdateTooltips()
		for tooltip, tooltipCache in pairs(tooltipArgs) do
			if tooltip:IsShown() then
				UpdateTooltip(tooltipCache)
			end
		end
	end
end

-- addon events
do
	-- apply hooks to interface elements
	local function ApplyHooks()
		-- iterate backwards, removing hooks as they complete
		for i = #uiHooks, 1, -1 do
			local func = uiHooks[i]
			-- if the function returns true our hook succeeded, we then remove it from the table
			if func() then
				table.remove(uiHooks, i)
			end
		end
	end

	-- an addon has loaded, is it ours? is it some LOD addon we can hook?
	function addon:ADDON_LOADED(event, name)
		-- the addon savedvariables are loaded and we can initialize the addon
		if name == addonName then
			Init()
		end

		-- apply hooks to interface elements
		ApplyHooks()
	end

	local function IsProviderOutdated(provider)
		local year, month, day, hours, minutes, seconds = provider.date:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+).*Z$")
		-- parse the ISO timestamp to unix time
		local ts = time({ year = year, month = month, day = day, hour = hours, min = minutes, sec = seconds })
		-- calculate the timezone offset between the user and UTC+0
		local offset = GetTimezoneOffset(ts)
		-- find elapsed seconds since database update and account for the timezone offset
		local diff = time() - ts - offset
		-- figure out of the DB is outdated or not by comparing to our threshold
		local isOutdated = diff >= OUTDATED_SECONDS
		local outdatedHours = floor(diff/ 3600 + 0.5)
		local outdatedDays = floor(diff / 86400 + 0.5)
		return isOutdated, outdatedHours, outdatedDays
	end

	-- we have logged in and character data is available
	function addon:PLAYER_LOGIN()
		-- store our faction for later use
		PLAYER_FACTION = GetFaction("player")
		PLAYER_REGION = GetRegion()

		-- share the faction and region with the other modules
		ns.PLAYER_FACTION = PLAYER_FACTION
		ns.PLAYER_REGION = PLAYER_REGION

		-- we can now create the empty table that contains all providers and provider groups
		dataProvider = {}

		-- for notification purposes after we're done iterating the provider queue
		local isAnyProviderDesynced
		local isAnyProviderOutdated

		-- pick the data provider that suits the players region
		for i = #dataProviderQueue, 1, -1 do
			local data = dataProviderQueue[i]
			local dataType = data.data

			-- is this provider relevant?
			if data.region == PLAYER_REGION then
				local dataProviderGroup = dataProvider[dataType]

				-- is the provider up to date?
				local isOutdated, outdatedHours, outdatedDays = IsProviderOutdated(data)
				IS_DB_OUTDATED[dataType][data.faction] = isOutdated
				OUTDATED_HOURS[dataType][data.faction] = outdatedHours
				OUTDATED_DAYS[dataType][data.faction] = outdatedDays

				-- update the outdated counter with the largest count
				if isOutdated then
					isAnyProviderOutdated = isAnyProviderOutdated and max(isAnyProviderOutdated, outdatedDays) or outdatedDays
				end

				-- append provider to the group
				if dataProviderGroup then
					if dataProviderGroup.faction == data.faction and dataProviderGroup.date ~= data.date then
						isAnyProviderDesynced = true
					end
					if not dataProviderGroup.db1 then
						dataProviderGroup.db1 = data.db1
					end
					if not dataProviderGroup.db2 then
						dataProviderGroup.db2 = data.db2
					end
					if not dataProviderGroup.lookup1 then
						dataProviderGroup.lookup1 = data.lookup1
					end
					if not dataProviderGroup.lookup2 then
						dataProviderGroup.lookup2 = data.lookup2
					end

				else
					dataProviderGroup = data
					dataProvider[dataType] = dataProviderGroup
				end

			else
				-- disable the provider addon from loading in the future
				DisableAddOn(data.name)
				-- wipe the table to free up memory
				table.wipe(data)
			end

			-- remove reference from the queue
			dataProviderQueue[i] = nil
		end

		if isAnyProviderDesynced then
			DEFAULT_CHAT_FRAME:AddMessage(format(L.OUT_OF_SYNC_DATABASE_S, addonName), 1, 1, 0)
		elseif isAnyProviderOutdated then
			DEFAULT_CHAT_FRAME:AddMessage(format(L.OUTDATED_DATABASE_S, addonName, isAnyProviderOutdated), 1, 1, 0)
		end

		-- hide the provider functions from the public API
		_G.RaiderIO.AddProvider = nil

		-- search.lua needs this for querying
		ns.dataProvider = dataProvider
	end

	-- we enter the world (after a loading screen, int/out of instances)
	function addon:PLAYER_ENTERING_WORLD()
		-- we wipe the cached profiles in between loading screens, this seems like a good way get rid of memory use over time
		table.wipe(profileCache)
		table.wipe(profileCacheTooltip)
		-- store the character we're logged on (used by the client to queue an update, once we log out from the game of course)
		_G.RaiderIO_LastCharacter = format("%s-%s", GetNameAndRealm("player"))
	end

	-- modifier key is toggled, update the tooltip if needed
	function addon:MODIFIER_STATE_CHANGED(skipUpdatingTooltip)
		-- if we always draw the full tooltip then this part of the code shouldn't be running at all
		if addonConfig.alwaysExtendTooltip and not addonConfig.enableProfileModifier then
			return
		end
		-- check if the mod state has changed, and only then run the update function
		local m = IsModifierKeyDown()
		local l = addon.modKey
		addon.modKey = m
		if m ~= l and skipUpdatingTooltip ~= true then
			UpdateTooltips()
			ns.PROFILE_UI.UpdateTooltip()
		end
	end

	function addon:IsModifierKeyDown(skipConfig)
		if skipConfig then
			return IsModifierKeyDown()
		end
		return addonConfig.alwaysExtendTooltip or IsModifierKeyDown()
	end
end

-- ui hooks
do
	-- extract character name and realm from BNet friend
	local function GetNameAndRealmForBNetFriend(bnetIDAccount)
		local index = BNGetFriendIndex(bnetIDAccount)
		if index then
			local numGameAccounts = BNGetNumFriendGameAccounts(index)
			for i = 1, numGameAccounts do
				local _, characterName, client, realmName, _, faction, _, _, _, _, level = BNGetFriendGameAccountInfo(index, i)
				if client == BNET_CLIENT_WOW then
					if realmName then
						characterName = characterName .. "-" .. realmName:gsub("%s+", "")
					end
					return characterName, FACTION[faction], tonumber(level)
				end
			end
		end
	end

	-- copy profile link from dropdown menu
	local function CopyURLForNameAndRealm(...)
		local name, realm = GetNameAndRealm(...)
		local realmSlug = GetRealmSlug(realm)
		local url = format("https://raider.io/characters/%s/%s/%s", PLAYER_REGION, realmSlug, name)
		if IsModifiedClick("CHATLINK") then
			local editBox = ChatFrame_OpenChat(url, DEFAULT_CHAT_FRAME)
			editBox:HighlightText()
		else
			StaticPopup_Show("RAIDERIO_COPY_URL", format("%s (%s)", name, realm), url)
		end
	end

	_G.StaticPopupDialogs["RAIDERIO_COPY_URL"] = {
		text = "%s",
		button2 = CLOSE,
		hasEditBox = true,
		hasWideEditBox = true,
		editBoxWidth = 350,
		preferredIndex = 3,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		OnShow = function(self)
			self:SetWidth(420)
			local editBox = _G[self:GetName() .. "WideEditBox"] or _G[self:GetName() .. "EditBox"]
			editBox:SetText(self.text.text_arg2)
			editBox:SetFocus()
			editBox:HighlightText(false)
			local button = _G[self:GetName() .. "Button2"]
			button:ClearAllPoints()
			button:SetWidth(200)
			button:SetPoint("CENTER", editBox, "CENTER", 0, -30)
		end,
		EditBoxOnEscapePressed = function(self)
			self:GetParent():Hide()
		end,
		OnHide = nil,
		OnAccept = nil,
		OnCancel = nil
	}

	-- GameTooltip
	uiHooks[#uiHooks + 1] = function()
		local function OnTooltipSetUnit(self)
			if not addonConfig.enableUnitTooltips then
				return
			end
			if not addonConfig.showScoreInCombat and InCombatLockdown() then
				return
			end
			-- TODO: summoning portals don't always trigger OnTooltipSetUnit properly, leaving the unit tooltip on the portal object
			local _, unit = self:GetUnit()
			ShowTooltip(self, TooltipProfileOutput.PADDING(), unit, nil, GetFaction(unit))
		end
		GameTooltip:HookScript("OnTooltipSetUnit", OnTooltipSetUnit)
		return 1
	end

	-- LFG
	uiHooks[#uiHooks + 1] = function()
		if _G.LFGListApplicationViewerScrollFrameButton1 then
			local hooked = {}
			local OnEnter, OnLeave
			-- application queue
			function OnEnter(self)
				if not addonConfig.enableLFGTooltips then
					return
				end
				if self.applicantID and self.Members then
					for i = 1, #self.Members do
						local b = self.Members[i]
						if not hooked[b] then
							hooked[b] = 1
							b:HookScript("OnEnter", OnEnter)
							b:HookScript("OnLeave", OnLeave)
						end
					end
				elseif self.memberIdx then
					local fullName = C_LFGList.GetApplicantMemberInfo(self:GetParent().applicantID, self.memberIdx)
					if fullName then
						local hasOwner = GameTooltip:GetOwner()
						if not hasOwner then
							GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT", 0, 0)
						end
						local _, activityID, _, title, description = C_LFGList.GetActiveEntryInfo()
						local keystoneLevel = GetKeystoneLevel(title) or GetKeystoneLevel(description) or 0
						ShowTooltip(GameTooltip, bor(TooltipProfileOutput.PADDING(), ProfileOutput.ADD_LFD), fullName, nil, PLAYER_FACTION, true, LFD_ACTIVITYID_TO_DUNGEONID[activityID], keystoneLevel)
						ns.PROFILE_UI.ShowProfile(fullName, nil, PLAYER_FACTION, GameTooltip, nil, LFD_ACTIVITYID_TO_DUNGEONID[activityID], keystoneLevel)
					end
				end
			end
			function OnLeave(self)
				if self.applicantID or self.memberIdx then
					GameTooltip:Hide()
				end
			end
			-- search results
			local function SetSearchEntryTooltip(tooltip, resultID, autoAcceptOption)
				local _, activityID, title, description, _, _, _, _, _, _, _, _, leaderName = C_LFGList.GetSearchResultInfo(resultID)
				if leaderName then
					local keystoneLevel = GetKeystoneLevel(title) or GetKeystoneLevel(description) or 0
					-- Update game tooltip with player info
					ShowTooltip(tooltip, bor(TooltipProfileOutput.PADDING(), ProfileOutput.ADD_LFD), leaderName, nil, PLAYER_FACTION, true, LFD_ACTIVITYID_TO_DUNGEONID[activityID], keystoneLevel)
					ns.PROFILE_UI.ShowProfile(leaderName, nil, PLAYER_FACTION, tooltip, nil, LFD_ACTIVITYID_TO_DUNGEONID[activityID], keystoneLevel)
				end
			end
			hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", SetSearchEntryTooltip)
			-- execute delayed hooks
			for i = 1, 14 do
				local b = _G["LFGListApplicationViewerScrollFrameButton" .. i]
				b:HookScript("OnEnter", OnEnter)
				b:HookScript("OnLeave", OnLeave)
			end
			-- UnempoweredCover blocking removal
			do
				local f = LFGListFrame.ApplicationViewer.UnempoweredCover
				f:EnableMouse(false)
				f:EnableMouseWheel(false)
				f:SetToplevel(false)
			end
			return 1
		end
	end

	-- WhoFrame
	uiHooks[#uiHooks + 1] = function()
		local function OnEnter(self)
			if not addonConfig.enableWhoTooltips then
				return
			end
			if self.whoIndex then
				local name, guild, level, race, class, zone, classFileName = GetWhoInfo(self.whoIndex)
				if name and level and level >= MAX_LEVEL then
					local hasOwner = GameTooltip:GetOwner()
					if not hasOwner then
						GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT", 0, 0)
					end
					if not ShowTooltip(GameTooltip, bor(TooltipProfileOutput.DEFAULT(), hasOwner and ProfileOutput.ADD_PADDING or 0), name, nil, PLAYER_FACTION) and not hasOwner then
						GameTooltip:Hide()
					end
				end
			end
		end
		local function OnLeave(self)
			if self.whoIndex then
				GameTooltip:Hide()
			end
		end
		for i = 1, 17 do
			local b = _G["WhoFrameButton" .. i]
			b:HookScript("OnEnter", OnEnter)
			b:HookScript("OnLeave", OnLeave)
		end
		return 1
	end

	-- FriendsFrame
	uiHooks[#uiHooks + 1] = function()
		local function OnEnter(self)
			if not addonConfig.enableFriendsTooltips then
				return
			end
			local fullName, faction, level
			if self.buttonType == FRIENDS_BUTTON_TYPE_BNET then
				local bnetIDAccount = BNGetFriendInfo(self.id)
				fullName, faction, level = GetNameAndRealmForBNetFriend(bnetIDAccount)
			elseif self.buttonType == FRIENDS_BUTTON_TYPE_WOW then
				fullName, level = GetFriendInfo(self.id)
				faction = PLAYER_FACTION
			end
			if fullName and level and level >= MAX_LEVEL then
				GameTooltip:SetOwner(FriendsTooltip, "ANCHOR_BOTTOMRIGHT", -FriendsTooltip:GetWidth(), -4)
				if not ShowTooltip(GameTooltip, TooltipProfileOutput.DEFAULT(), fullName, nil, faction) then
					GameTooltip:Hide()
				end
			else
				GameTooltip:Hide()
			end
		end
		local function FriendTooltip_Hide()
			if not addonConfig.enableFriendsTooltips then
				return
			end
			GameTooltip:Hide()
		end
		local buttons = FriendsFrameFriendsScrollFrame.buttons
		for i = 1, #buttons do
			local button = buttons[i]
			button:HookScript("OnEnter", OnEnter)
		end
		hooksecurefunc("FriendsFrameTooltip_Show", OnEnter)
		hooksecurefunc(FriendsTooltip, "Hide", FriendTooltip_Hide)
		return 1
	end

	-- Blizzard_GuildUI
	uiHooks[#uiHooks + 1] = function()
		if _G.GuildFrame then
			local function OnEnter(self)
				if not addonConfig.enableGuildTooltips then
					return
				end
				if self.guildIndex then
					local fullName, _, _, level = GetGuildRosterInfo(self.guildIndex)
					if fullName and level >= MAX_LEVEL then
						GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT", 0, 0)
						if not ShowTooltip(GameTooltip, TooltipProfileOutput.PADDING(), fullName, nil, PLAYER_FACTION) then
							GameTooltip:Hide()
						end
					end
				end
			end
			local function OnLeave(self)
				if self.guildIndex then
					GameTooltip:Hide()
				end
			end
			for i = 1, 16 do
				local b = _G["GuildRosterContainerButton" .. i]
				b:HookScript("OnEnter", OnEnter)
				b:HookScript("OnLeave", OnLeave)
			end
			return 1
		end
	end

	-- Blizzard_Communities
	uiHooks[#uiHooks + 1] = function()
		if _G.CommunitiesFrame then
			local function OnEnter(self)
				if not addonConfig.enableGuildTooltips then
					return
				end
				local info = self:GetMemberInfo()
				if not info or (info.clubType ~= Enum.ClubType.Guild and info.clubType ~= Enum.ClubType.Character) then
					return
				end
				if info.name and (info.level or MAX_LEVEL) >= MAX_LEVEL then
					local hasOwner = GameTooltip:GetOwner()
					if not hasOwner then
						GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT", 0, 0)
					end
					if not ShowTooltip(GameTooltip, bor(TooltipProfileOutput.DEFAULT(), hasOwner and ProfileOutput.ADD_PADDING or 0), info.name, nil, PLAYER_FACTION) and not hasOwner then
						GameTooltip:Hide()
					end
				end
			end
			local function OnLeave(self)
				GameTooltip:Hide()
			end
			for _, b in pairs(CommunitiesFrame.MemberList.ListScrollFrame.buttons) do
				b:HookScript("OnEnter", OnEnter)
				b:HookScript("OnLeave", OnLeave)
			end
			return 1
		end
	end

	-- ChatFrame (Who Results)
	uiHooks[#uiHooks + 1] = function()
		local function pattern(pattern)
			pattern = pattern:gsub("%%", "%%%%")
			pattern = pattern:gsub("%.", "%%%.")
			pattern = pattern:gsub("%?", "%%%?")
			pattern = pattern:gsub("%+", "%%%+")
			pattern = pattern:gsub("%-", "%%%-")
			pattern = pattern:gsub("%(", "%%%(")
			pattern = pattern:gsub("%)", "%%%)")
			pattern = pattern:gsub("%[", "%%%[")
			pattern = pattern:gsub("%]", "%%%]")
			pattern = pattern:gsub("%%%%s", "(.-)")
			pattern = pattern:gsub("%%%%d", "(%%d+)")
			pattern = pattern:gsub("%%%%%%[%d%.%,]+f", "([%%d%%.%%,]+)")
			return pattern
		end
		local function sortRoleScores(a, b)
			return a[2] > b[2]
		end
		local FORMAT_GUILD = "^" .. pattern(WHO_LIST_GUILD_FORMAT) .. "$"
		local FORMAT = "^" .. pattern(WHO_LIST_FORMAT) .. "$"
		local nameLink, name, level, race, class, guild, zone
		local repl, text, profile
		local function score(profile)
			text = ""

			if profile.allScore > 0 then
				text = text .. (L.RAIDERIO_MP_SCORE_COLON):gsub("%.", "|cffFFFFFF|r.") .. GetFormattedScore(profile.allScore, profile.isPrevAllScore) .. ". "
			end

			-- show the mains season score
			if addonConfig.showMainsScore and profile.mainScore > profile.allScore then
				text = text .. "(" .. L.MAINS_SCORE_COLON .. profile.mainScore .. "). "
			end

			-- show tank, healer and dps scores
			local scores = {}

			if profile.tankScore then
				scores[#scores + 1] = { L.TANK, profile.tankScore }
			end

			if profile.healScore then
				scores[#scores + 1] = { L.HEALER, profile.healScore }
			end

			if profile.dpsScore then
				scores[#scores + 1] = { L.DPS, profile.dpsScore }
			end

			sort(scores, sortRoleScores)

			for i = 1, #scores do
				if scores[i][2] > 0 then
					if i > 1 then
						text = text .. ", "
					end
					text = text .. scores[i][1] .. ": " .. scores[i][2]
				end
			end

			return text
		end
		local function filter(self, event, text, ...)
			if addonConfig.enableWhoMessages and event == "CHAT_MSG_SYSTEM" then
				nameLink, name, level, race, class, guild, zone = text:match(FORMAT_GUILD)
				if not zone then
					guild = nil
					nameLink, name, level, race, class, zone = text:match(FORMAT)
				end
				if level then
					level = tonumber(level) or 0
					if level >= MAX_LEVEL then
						if guild then
							repl = format(WHO_LIST_GUILD_FORMAT, nameLink, name, level, race, class, guild, zone)
						else
							repl = format(WHO_LIST_FORMAT, nameLink, name, level, race, class, zone)
						end
						profile = GetPlayerProfile(ProfileOutput.MYTHICPLUS, nameLink, nil, PLAYER_FACTION)
						if profile then
							repl = repl .. " - " .. score(profile.profile)
						end
						return false, repl, ...
					end
				end
			end
			return false
		end
		ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", filter)
		return 1
	end

	-- DropDownMenu (Units and LFD)
	uiHooks[#uiHooks + 1] = function()
		local function CanCopyURL(which, unit, name, bnetIDAccount)
			if UnitExists(unit) then
				return UnitIsPlayer(unit) and UnitLevel(unit) >= MAX_LEVEL,
					GetUnitName(unit, true) or name,
					"UNIT"
			elseif which and which:find("^BN_") then
				local charName, charFaction, charLevel
				if bnetIDAccount then
					charName, charFaction, charLevel = GetNameAndRealmForBNetFriend(bnetIDAccount)
				end
				return charName and charLevel and charLevel >= MAX_LEVEL,
					bnetIDAccount,
					"BN",
					charName,
					charFaction
			elseif name then
				return true,
					name,
					"NAME"
			end
			return false
		end
		local function ShowCopyURLPopup(kind, query, bnetChar, bnetFaction)
			CopyURLForNameAndRealm(bnetChar or query)
		end
		-- TODO: figure out the type of menus we don't really need to show our copy link button
		local supportedTypes = {
			-- SELF = 1, -- do we really need this? can always target self anywhere else and copy our own url
			PARTY = 1,
			PLAYER = 1,
			RAID_PLAYER = 1,
			RAID = 1,
			FRIEND = 1,
			BN_FRIEND = 1,
			GUILD = 1,
			GUILD_OFFLINE = 1,
			CHAT_ROSTER = 1,
			TARGET = 1,
			ARENAENEMY = 1,
			FOCUS = 1,
			WORLD_STATE_SCORE = 1,
			COMMUNITIES_WOW_MEMBER = 1,
			COMMUNITIES_GUILD_MEMBER = 1,
			SELF = 1
		}
		local OFFSET_BETWEEN = -5 -- default UI makes this offset look nice
		local reskinDropDownList
		do
			local addons = {
				{ -- Aurora
					name = "Aurora",
					func = function(list)
						local F = _G.Aurora[1]
						local menu = _G[list:GetName() .. "MenuBackdrop"]
						local backdrop = _G[list:GetName() .. "Backdrop"]
						if not backdrop.reskinned then
							F.CreateBD(menu)
							F.CreateBD(backdrop)
							backdrop.reskinned = true
						end
						OFFSET_BETWEEN = -1 -- need no gaps so the frames align with this addon
						return 1
					end
				},
			}
			local skinned = {}
			function reskinDropDownList(list)
				if skinned[list] then
					return skinned[list]
				end
				for i = 1, #addons do
					local addon = addons[i]
					if IsAddOnLoaded(addon.name) then
						skinned[list] = addon.func(list)
						break
					end
				end
			end
		end
		local custom
		do
			local function CopyOnClick()
				ShowCopyURLPopup(custom.kind, custom.query, custom.bnetChar, custom.bnetFaction)
			end
			local function UpdateCopyButton()
				local copy = custom.copy
				local copyName = copy:GetName()
				local text = _G[copyName .. "NormalText"]
				text:SetText(L.COPY_RAIDERIO_PROFILE_URL)
				text:Show()
				copy:SetScript("OnClick", CopyOnClick)
				copy:Show()
			end
			local function CustomOnEnter(self) -- UIDropDownMenuTemplates.xml#248
				UIDropDownMenu_StopCounting(self:GetParent()) -- TODO: this might taint and break like before, but let's try it and observe
			end
			local function CustomOnLeave(self) -- UIDropDownMenuTemplates.xml#251
				UIDropDownMenu_StartCounting(self:GetParent()) -- TODO: this might taint and break like before, but let's try it and observe
			end
			local function CustomOnShow(self) -- UIDropDownMenuTemplates.xml#257
				local p = self:GetParent() or self
				local w = p:GetWidth()
				local h = 32
				for i = 1, #self.buttons do
					local b = self.buttons[i]
					if b:IsShown() then
						b:SetWidth(w - 32) -- anchor offsets for left/right
						h = h + 16
					end
				end
				self:SetHeight(h)
			end
			local function CustomButtonOnEnter(self) -- UIDropDownMenuTemplates.xml#155
				_G[self:GetName() .. "Highlight"]:Show()
				CustomOnEnter(self:GetParent())
			end
			local function CustomButtonOnLeave(self) -- UIDropDownMenuTemplates.xml#178
				_G[self:GetName() .. "Highlight"]:Hide()
				CustomOnLeave(self:GetParent())
			end
			custom = CreateFrame("Button", addonName .. "CustomDropDownList", UIParent, "UIDropDownListTemplate")
			custom:Hide()
			-- attempt to reskin using popular frameworks
			-- skinType = nil : not skinned
			-- skinType = 1 : skinned, apply further visual modifications (the addon does a good job, but we need to iron out some issues)
			-- skinType = 2 : skinned, no need to apply further visual modifications (the addon handles it flawlessly)
			local skinType = reskinDropDownList(custom)
			-- cleanup and modify the default template
			do
				custom:SetScript("OnClick", nil)
				custom:SetScript("OnEnter", CustomOnEnter)
				custom:SetScript("OnLeave", CustomOnLeave)
				custom:SetScript("OnUpdate", nil)
				custom:SetScript("OnShow", CustomOnShow)
				custom:SetScript("OnHide", nil)
				_G[custom:GetName() .. "Backdrop"]:Hide()
				custom.buttons = {}
				for i = 1, UIDROPDOWNMENU_MAXBUTTONS do
					local b = _G[custom:GetName() .. "Button" .. i]
					if not b then
						break
					end
					custom.buttons[i] = b
					b:Hide()
					b:SetScript("OnClick", nil)
					b:SetScript("OnEnter", CustomButtonOnEnter)
					b:SetScript("OnLeave", CustomButtonOnLeave)
					b:SetScript("OnEnable", nil)
					b:SetScript("OnDisable", nil)
					b:SetPoint("TOPLEFT", custom, "TOPLEFT", 16, -16 * i)
					local t = _G[b:GetName() .. "NormalText"]
					t:ClearAllPoints()
					t:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
					t:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
					_G[b:GetName() .. "Check"]:SetAlpha(0)
					_G[b:GetName() .. "UnCheck"]:SetAlpha(0)
					_G[b:GetName() .. "Icon"]:SetAlpha(0)
					_G[b:GetName() .. "ColorSwatch"]:SetAlpha(0)
					_G[b:GetName() .. "ExpandArrow"]:SetAlpha(0)
					_G[b:GetName() .. "InvisibleButton"]:SetAlpha(0)
				end
				custom.copy = custom.buttons[1]
				UpdateCopyButton()
			end
		end
		local function ShowCustomDropDown(list, dropdown, name, unit, which, bnetIDAccount)
			local show, query, kind, bnetChar, bnetFaction = CanCopyURL(which, unit, name, bnetIDAccount)
			if not show then
				return custom:Hide()
			end
			-- assign data for use with the copy function
			custom.query = query
			custom.kind = kind
			custom.bnetChar = bnetChar
			custom.bnetFaction = bnetFaction
			-- set positioning under the active dropdown
			custom:SetParent(list)
			custom:SetFrameStrata(list:GetFrameStrata())
			custom:SetFrameLevel(list:GetFrameLevel() + 2)
			custom:ClearAllPoints()
			if list:GetBottom() >= 50 then
				custom:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, OFFSET_BETWEEN)
				custom:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", 0, OFFSET_BETWEEN)
			else
				custom:SetPoint("BOTTOMLEFT", list, "TOPLEFT", 0, OFFSET_BETWEEN)
				custom:SetPoint("BOTTOMRIGHT", list, "TOPRIGHT", 0, OFFSET_BETWEEN)
			end
			custom:Show()
		end
		local function HideCustomDropDown()
			custom:Hide()
		end
		local function OnShow(self)
			local dropdown = self.dropdown
			if not dropdown then
				return
			end
			if dropdown.Button == _G.LFGListFrameDropDownButton then -- LFD
				if addonConfig.enableLFGDropdown then
					ShowCustomDropDown(self, dropdown, dropdown.menuList[2].arg1)
				end
			elseif dropdown.which and supportedTypes[dropdown.which] then -- UnitPopup
				if addonConfig.showDropDownCopyURL then
					local dropdownFullName
					if dropdown.name then
						if dropdown.server and not dropdown.name:find("-") then
							dropdownFullName = dropdown.name .. "-" .. dropdown.server
						else
							dropdownFullName = dropdown.name
						end
					end
					ShowCustomDropDown(self, dropdown, dropdown.chatTarget or dropdownFullName, dropdown.unit, dropdown.which, dropdown.bnetIDAccount)
				end
			end
		end
		local function OnHide()
			HideCustomDropDown()
		end
		DropDownList1:HookScript("OnShow", OnShow)
		DropDownList1:HookScript("OnHide", OnHide)
		return 1
	end

	-- Keystone Info
	uiHooks[#uiHooks + 1] = function()
		local function OnSetItem(tooltip)
			if not addonConfig.enableKeystoneTooltips then
				return
			end
			local _, link = tooltip:GetItem()
			if type(link) ~= "string" then
				return
			end

			local patterns = {
				"keystone:%d+:(%d+):(%d+):(%d+):(%d+):(%d+)",
				"item:138019:.-:.-:.-:.-:.-:.-:.-:.-:.-:.-:.-:.-:(%d+):(%d+):(%d+):(%d+):(%d+)",
				"item:158923:.-:.-:.-:.-:.-:.-:.-:.-:.-:.-:.-:.-:(%d+):(%d+):(%d+):(%d+):(%d+)",
			};

			local inst, lvl, a1, a2, a3;
			for _, pattern in ipairs(patterns) do
				inst, lvl, a1, a2, a3 = link:match(pattern)

				if lvl and (tonumber(lvl) or 100) < 100 then
					break
				end
			end

			if not lvl then
				return
			end

			lvl = tonumber(lvl) or 0
			local baseScore = KEYSTONE_LEVEL_TO_BASE_SCORE[lvl]
			if not baseScore then
				return
			end
			tooltip:AddLine(" ")
			tooltip:AddDoubleLine(L.RAIDERIO_MP_BASE_SCORE, baseScore, 1, 0.85, 0, 1, 1, 1)

			-- AppendAveragePlayerScore(tooltip, lvl)

			inst = tonumber(inst)
			if inst then
				local index = KEYSTONE_INST_TO_DUNGEONID[inst]
				if index then
					local n = GetNumGroupMembers()
					if n <= 5 then -- let's show score only if we are in a 5 man group/raid
						for i = 0, n do
							local unit = i == 0 and "player" or "party" .. i
							local profile = GetPlayerProfile(ProfileOutput.MYTHICPLUS, unit)
							if profile then
								local level = profile.dungeons[index]
								if level > 0 then
									-- TODO: sort these by dungeon level, descending
									local dungeonName = CONST_DUNGEONS[index] and " " .. CONST_DUNGEONS[index].shortNameLocale or ""
									tooltip:AddDoubleLine(UnitName(unit), "+" .. level .. dungeonName, 1, 1, 1, 1, 1, 1)
								end
							end
						end
					end
				end
			end
			tooltip:Show()
		end
		GameTooltip:HookScript("OnTooltipSetItem", OnSetItem)
		ItemRefTooltip:HookScript("OnTooltipSetItem", OnSetItem)
		return 1
	end

	-- My Profile
	uiHooks[#uiHooks + 1] = function()
		if _G.PVEFrame then
			local function Show()
				if not addonConfig.showRaiderIOProfile then return end
				ns.PROFILE_UI.ShowProfile("player", nil, PLAYER_FACTION)
			end
			local function Hide()
				ns.PROFILE_UI.HideProfile()
			end
			PVEFrame:HookScript("OnShow", Show)
			PVEFrame:HookScript("OnHide", Hide)
			return 1
		end
	end

	-- Guild Weekly Best
	uiHooks[#uiHooks + 1] = function()
		if _G.ChallengesFrame and _G.PVEFrame then
			local function Show()
				if not ns.GUILD_BEST_DATA or not addonConfig.showClientGuildBest then return end
				GuildBestFrame:Show()
			end
			local function Hide()
				GuildBestFrame:Hide()
			end
			ChallengesFrame:HookScript("OnShow", Show)
			ChallengesFrame:HookScript("OnHide", Hide)
			PVEFrame:HookScript("OnHide", Hide)
			return 1
		end
	end
end

-- deprecated warnings
local WrapDeprecatedFunc
do
	local notified = {}

	local function Notify(funcName, newFuncName)
		if notified[funcName] then return end
		notified[funcName] = true
		DEFAULT_CHAT_FRAME:AddMessage(format(L[newFuncName and "API_DEPRECATED_WITH" or "API_DEPRECATED"], funcName, newFuncName), 1, 1, 0)
	end

	function WrapDeprecatedFunc(funcName, newFuncName)
		return function(...)
			Notify(funcName, newFuncName)
			local d = GetPlayerProfile(ProfileOutput.DATA, ...)
			if d then d = d[CONST_PROVIDER_DATA_MYTHICPLUS] end
			if d then d = d.profile end
			return d
		end
	end
end

-- private API
do
	ns.addon = addon
	ns.LFD_ACTIVITYID_TO_DUNGEONID = LFD_ACTIVITYID_TO_DUNGEONID
	ns.CONST_DUNGEONS = CONST_DUNGEONS
	ns.IS_DB_OUTDATED = IS_DB_OUTDATED
	ns.OUTDATED_DAYS = OUTDATED_DAYS
	ns.OUTDATED_HOURS = OUTDATED_HOURS
	ns.CompareDungeon = CompareDungeon
	ns.GetStarsForUpgrades = GetStarsForUpgrades
	ns.ProfileOutput = ProfileOutput
	ns.TooltipProfileOutput = TooltipProfileOutput
	ns.GetPlayerProfile = GetPlayerProfile
	ns.ShowTooltip = ShowTooltip
end

-- public API
_G.RaiderIO = {
	-- Calling GetPlayerProfile returns a table with the data requested for that unit or player by name and realm. Faction is optional and is either 0 = Either, 1 = Alliance, 2 = Horde.
	-- outputFlag is a bitwise combination of values from the ProfileOutput table, or by calling TooltipProfileOutput functions for complete presets for desired output.
	-- RaiderIO.GetPlayerProfile(outputFlag, unit)
	-- RaiderIO.GetPlayerProfile(outputFlag, "Name-Realm"[, 0|1|2])
	-- RaiderIO.GetPlayerProfile(outputFlag, "Name", "Realm"[, 0|1|2])
	ProfileOutput = ProfileOutput,
	TooltipProfileOutput = TooltipProfileOutput,
	DataProvider = CONST_PROVIDER_INTERFACE,
	GetPlayerProfile = GetPlayerProfile,
	-- Calling GetFaction requires a unit and returns you 1 if it's Alliance, 2 if Horde, otherwise nil.
	-- Calling GetScoreColor requires a Mythic+ score to be passed (a number value) and it returns r, g, b for that score.
	-- RaiderIO.GetScoreColor(1234)
	GetScoreColor = GetScoreColor,
	-- DEPRECATED since BfA season 1
	GetScore = WrapDeprecatedFunc("GetScore", "GetPlayerProfile"),
	GetProfile = WrapDeprecatedFunc("GetProfile", "GetPlayerProfile"),
}

-- PLEASE DO NOT USE (we need it public for the sake of the database modules)
_G.RaiderIO.AddProvider = AddProvider

-- register events and wait for the addon load event to fire
addon:SetScript("OnEvent", function(_, event, ...) addon[event](addon, event, ...) end)
addon:RegisterEvent("ADDON_LOADED")
