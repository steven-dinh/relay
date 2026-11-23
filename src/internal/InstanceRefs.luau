local FORMAT = 4
local HEADER_BYTES = 4
local MAXIMUM_REFERENCES = 16
local REFERENCE_BYTES = 8
local CLASSES = table.freeze({
	Instance = true,
	BasePart = true,
	Part = true,
	MeshPart = true,
	Model = true,
	Humanoid = true,
	Tool = true,
	Attachment = true,
	Player = true,
	Folder = true,
	GuiObject = true,
	Sound = true,
	Animation = true,
	Animator = true,
})

local DATA_MODEL = game

local function isNativeInstance(value)
	return typeof(value) == "Instance"
end

local function isInteger(value)
	return type(value) == "number" and value % 1 == 0
end

local function validSidecars(sidecars, expectedCount)
	if sidecars == nil then return expectedCount == 0 end
	if type(sidecars) ~= "table" or getmetatable(sidecars) ~= nil then return false end
	local count = rawget(sidecars, "n")
	if not isInteger(count) or count < 0 or count > MAXIMUM_REFERENCES or count ~= expectedCount then return false end
	local observed = 0
	for key, value in sidecars do
		if key == "n" then
			if value ~= count then return false end
		elseif not isInteger(key) or key < 1 or key > count or typeof(value) ~= "Instance" then
			return false
		else
			observed += 1
		end
	end
	return observed == count
end

local function isDescendantOf(value, ancestor)
	local ok, descendant = pcall(value.IsDescendantOf, value, ancestor)
	return ok and descendant == true
end

local function isLiveRoot(value)
	if not isNativeInstance(value) then return false end
	return value == DATA_MODEL or isDescendantOf(value, DATA_MODEL)
end

local function isScoped(value, context)
	if not isNativeInstance(value) or value == DATA_MODEL then return false end
	if context == nil or context.server ~= true then return isDescendantOf(value, DATA_MODEL) end
	local root = context.root
	return (value == root or isDescendantOf(value, root)) and isLiveRoot(root)
end

local function valid(value, className, context)
	if not CLASSES[className] or not isScoped(value, context) then return false end
	local ok, matches = pcall(value.IsA, value, className)
	return ok and matches == true
end

local function scopeArguments(context, ...)
	local argumentCount = select("#", ...)
	local referenceCount = argumentCount - 1
	if argumentCount < 1 or referenceCount > MAXIMUM_REFERENCES then return false end
	local frame = ...
	if typeof(frame) ~= "buffer" then return false end
	for index = 1, referenceCount do
		if not isScoped(select(index + 1, ...), context) then return false end
	end
	return true
end

return table.freeze({
	FORMAT = FORMAT,
	HEADER_BYTES = HEADER_BYTES,
	MAXIMUM_REFERENCES = MAXIMUM_REFERENCES,
	REFERENCE_BYTES = REFERENCE_BYTES,
	CLASSES = CLASSES,
	validSidecars = validSidecars,
	isLiveRoot = isLiveRoot,
	valid = valid,
	scopeArguments = scopeArguments,
})
