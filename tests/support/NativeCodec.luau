local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Quantized = require("../../src/internal/Quantized")
local BitPacking = require("../../src/internal/BitPacking")
local LengthBounds = require("../../src/internal/LengthBounds")
local NumericFormats = require("../../src/internal/NumericFormats")

local nativeEnvironment = {}
for name, value in roblox do nativeEnvironment[name] = value end
nativeEnvironment.Enum = roblox.Enum
local World = roblox.Instance.new("DataModel")

local NativeCodec = luau.load(fs.readFile("src/internal/NativeCodec.luau"), {
	environment = nativeEnvironment,
	injectGlobals = true,
})()

local InstanceRefs = luau.load(fs.readFile("src/internal/InstanceRefs.luau"), {
	environment = { game = World },
	injectGlobals = true,
})()

local compactEnvironment = table.clone(nativeEnvironment)
compactEnvironment.require = function(path)
	assert(path == "./Quantized")
	return Quantized
end
local CompactValues = luau.load(fs.readFile("src/internal/CompactValues.luau"), {
	environment = compactEnvironment,
	injectGlobals = true,
})()

local CompositeCodec = luau.load(fs.readFile("src/internal/CompositeCodec.luau"), {
	environment = {
		require = function(path)
			if path == "./NativeCodec" then return NativeCodec end
			if path == "./InstanceRefs" then return InstanceRefs end
			if path == "./Quantized" then return Quantized end
			if path == "./CompactValues" then return CompactValues end
			if path == "./BitPacking" then return BitPacking end
			if path == "./LengthBounds" then return LengthBounds end
			if path == "./NumericFormats" then return NumericFormats end
			assert(false, `unexpected composite codec dependency: {path}`)
		end,
	},
	injectGlobals = true,
})()

local function loadFrame()
	return luau.load(fs.readFile("src/internal/Frame.luau"), {
		environment = {
			Vector2 = roblox.Vector2,
			Vector3 = roblox.Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			require = function(path)
				assert(path == "./CompositeCodec", `unexpected frame dependency: {path}`)
				return CompositeCodec
			end,
		},
		injectGlobals = true,
	})()
end

return table.freeze({ NativeCodec = NativeCodec, InstanceRefs = InstanceRefs, World = World,
	CompactValues = CompactValues, CompositeCodec = CompositeCodec, loadFrame = loadFrame })
