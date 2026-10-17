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

local function isDescendantOf(value, ancestor)
	local ok, descendant = pcall(value.IsDescendantOf, value, ancestor)
	return ok and descendant == true
end

local function isLiveRoot(value)
	if not isNativeInstance(value) then return false end
	return value == DATA_MODEL or isDescendantOf(value, DATA_MODEL)
end

local function isScoped(value, context)
	if not isNativeInstance(value) or value == DATA_MODEL or not isDescendantOf(value, DATA_MODEL) then
		return false
	end
	if context == nil or context.server ~= true then return true end
	local root = context.root
	if not isLiveRoot(root) then return false end
	return value == root or isDescendantOf(value, root)
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
	isLiveRoot = isLiveRoot,
	valid = valid,
	scopeArguments = scopeArguments,
})
