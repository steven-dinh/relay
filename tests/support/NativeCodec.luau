local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local nativeEnvironment = {}
for name, value in roblox do nativeEnvironment[name] = value end
nativeEnvironment.Enum = roblox.Enum

local NativeCodec = luau.load(fs.readFile("src/internal/NativeCodec.luau"), {
	environment = nativeEnvironment,
	injectGlobals = true,
})()

local CompositeCodec = luau.load(fs.readFile("src/internal/CompositeCodec.luau"), {
	environment = {
		require = function(path)
			assert(path == "./NativeCodec", `unexpected native codec dependency: {path}`)
			return NativeCodec
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

return table.freeze({ NativeCodec = NativeCodec, CompositeCodec = CompositeCodec, loadFrame = loadFrame })
