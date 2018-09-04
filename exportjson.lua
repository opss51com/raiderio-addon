local addonName, ns = ...

-- TODO: placement? button look, icon, shape? Prat like copy popup?
-- export button
local ExportButton
do
	ExportButton = CreateFrame("Frame", addonName .. "ExportButton", UIParent)
end

local TableToJSON
local UpdateCopyDialog
do
	local function IsArray(o)
		if not o[1] then
			return false
		end
		local i
		for k = 1, #o do
			local v = o[k]
			if type(k) ~= "number" then
				return false
			end
			if i and i ~= k - 1 then
				return false
			end
			i = k
		end
		return true
	end

	local function IsMap(o)
		return not not (not IsArray(o) and next(o))
	end

	local function WrapValue(o)
		local t = type(o)
		local s = ""
		if t == "nil" then
			s = "null"
		elseif t == "number" then
			s = o
		elseif t == "boolean" then
			s = o and "true" or "false"
		elseif t == "table" then
			s = TableToJSON(o)
		else
			s = "\"" .. tostring(o) .. "\""
		end
		return s
	end

	function TableToJSON(o)
		if type(o) == "table" then
			local s = ""
			if IsMap(o) then
				s = s .. "{"
				for k, v in pairs(o) do
					s = s .. "\"" .. tostring(k) .. "\":" .. WrapValue(v) .. ","
				end
				if s:sub(-1) == "," then
					s = s:sub(1, -2)
				end
				s = s .. "}"
			else
				s = s .. "["
				for i = 1, #o do
					local v = o[i]
					s = s .. WrapValue(v) .. ","
				end
				if s:sub(-1) == "," then
					s = s:sub(1, -2)
				end
				s = s .. "]"
			end
			return s
		end
		return o
	end

	function UpdateCopyDialog()
		-- TODO: when the group changes or when the queue changes we would probably want to update the dialog EditBox with new JSON + autoselect it to be copied
	end
end

function ExportButton.OpenCopyDialog()
	-- TODO: shows the copy dialog that contains the EditBox with the JSON
	-- TODO: register events to trigger UpdateCopyDialog
end

function ExportButton.CloseCopyDialog()
	-- TODO: closes the copy dialog
	-- TODO: unregister events
end

ns.EXPORT_JSON = ExportButton
