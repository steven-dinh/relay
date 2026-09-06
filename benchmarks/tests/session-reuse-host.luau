-- Focused pilot framing/validation proof; does not start Studio.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local Host = require("../host/HostRuntime")
local EventV1 = require("../contracts/event-v1")

for _, name in { "Bootstrap.luau", "run-session-reuse.luau", "PersistentSession.luau",
	"DeliveryObserver.luau", "Server.server.luau", "Client.client.luau" } do
	luau.compile(fs.readFile("benchmarks/pilot/" .. name))
end
local source = fs.readFile("benchmarks/pilot/run-session-reuse.luau")
source = string.gsub(source, "main%(process%.args%)%s*$", "return { parseArgs = parseArgs, validate = validate, collect = collect, finite = finite }")
local api = luau.load(source, { environment = { require = function(path)
	if path == "../host/HostRuntime" then return Host end
	if path == "../contracts/event-v1" then return EventV1 end
	return require(path)
end }, injectGlobals = true })()

local launchId = "11111111-1111-4111-8111-111111111111"
local capability = string.rep("a", 64)
local workload
for _, candidate in EventV1.workloads do
	if candidate.id == "state-burst-c2s" then workload = candidate; break end
end
local expected = (workload.warmupFrames + workload.measuredFrames) * workload.messagesPerFrame
local function valid()
	local windows = {}
	for index = 1, 30 do
		windows[index] = { index = index, expected = expected, received = expected,
			warmupQuietFrames = 60, measuredQuietFrames = 60, senderMeasuredSeconds = 1, senderCallSeconds = 0.1 }
	end
	return { kind = "RelaySessionReusePilot", version = 1, launchId = launchId, adapterId = "quicknet",
		studioVersion = "test", status = "Passed", caseId = "state-burst-c2s", recipientCount = 1,
		lifecycle = "PersistentSession", rankingEligible = false, sharedClockProof = "NotRun",
		setupSeconds = 1, sessionSeconds = 90, serverSetups = 1, clientSetups = 1, windows = windows }
end
local function rejected(callback)
	assert(not pcall(callback), "invalid pilot accepted")
end
local function validate(value)
	return api.validate(serde.encode("json", value), launchId, "quicknet")
end
assert(validate(valid()).status == "Passed")
local function frames(body)
	local lines = {}
	local count = math.ceil(#body / 1024)
	for index = 1, count do
		local encoded = string.gsub(string.sub(body, (index - 1) * 1024 + 1, index * 1024), ".", function(character)
			return string.format("%02x", string.byte(character))
		end)
		lines[index] = `RELAY_SESSION_PILOT_1 {capability} {launchId} {index} {count} {encoded}`
	end
	return lines
end
local lines = frames(serde.encode("json", valid()))
assert(#lines > 1)
local function collect(values, token)
	return api.collect(table.concat(values, "\n"), token or capability, launchId, "quicknet")
end
assert(#collect(lines).windows == 30)
rejected(function() collect(lines, string.rep("b", 64)) end)
local missing = table.clone(lines)
table.remove(missing)
rejected(function() collect(missing) end)
local reordered = table.clone(lines)
reordered[1], reordered[2] = reordered[2], reordered[1]
rejected(function() collect(reordered) end)
rejected(function() api.collect(table.concat(lines, "\n"), capability, "wrong-launch", "quicknet") end)
for _, mutate in {
	function(value) value.status = "Failed" end,
	function(value) value.launchId = "wrong" end,
	function(value) table.remove(value.windows) end,
	function(value) value.windows[1].measuredQuietFrames = 59 end,
	function(value) value.windows[1].warmupQuietFrames = 59 end,
	function(value) value.windows[1].received -= 1 end,
	function(value) value.windows[1].senderCallSeconds = 2 end,
	function(value) value.setupSeconds = 91 end,
	function(value) value.windows[1].senderMeasuredSeconds = -1 end,
} do
	local value = valid()
	mutate(value)
	rejected(function() validate(value) end)
end
assert(not api.finite(0 / 0) and not api.finite(math.huge) and not api.finite(-1))
assert(api.finite(0) and api.finite(1))
local studio, adapterId = api.parseArgs({ "--studio", "C:/Studio.exe", "--adapter", "zap" })
assert(studio == "C:/Studio.exe" and adapterId == "zap")
for _, args in { {}, { "--studio", "relative.exe", "--adapter", "zap" },
	{ "--studio", "C:/Studio.exe", "--adapter", "other" },
	{ "--studio", "C:/Studio.exe", "--studio", "C:/Studio.exe" } } do
	rejected(function() api.parseArgs(args) end)
end
print("PASS session-reuse-host: pilot scripts compile; bounded framing, result validation, and CLI rejection")
