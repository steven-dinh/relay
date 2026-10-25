local fs = require("@lune/fs")
local process = require("@lune/process")
local Generator = require("../scripts/roblox-ts/Generator")
local spec = require("../scripts/roblox-ts/consumer/src/Spec")

local declaration = Generator.generate(spec)
assert(declaration == Generator.generate(spec), "declarations must be deterministic")
assert(not string.find(declaration, "%f[%w]any%f[%W]"), "contracts must not be erased with any")
for _, expected in { "ReadonlyMap<", "ReadonlyArray<", "Enum.Material.Plastic", "Enum.Material.Wood", "BasePart", "LuaTuple<" } do
	assert(string.find(declaration, expected, 1, true), `missing mapped shape: {expected}`)
end
assert(string.find(declaration, "export interface InboundFairness { readonly maxPeers: number; readonly reserve: EndpointRate }", 1, true))
assert(string.find(declaration, "readonly fairness?: InboundFairness", 1, true))
local server = assert(string.match(declaration, "export interface Server ([^\n]+)"))
local client = assert(string.match(declaration, "export interface Client ([^\n]+)"))
assert(string.find(server, 'ConnectWithContext(timeoutSeconds: number, handler: (this: void, player: Player, context: { readonly deadline: number; GetState(): "Open" | "DeadlineExceeded" | "Closed" }, arg0: number) => { readonly "owned": boolean; readonly "material": Enum.Material.Plastic | Enum.Material.Wood; readonly "note"?: string }): LuaTuple<[Connection | undefined, RelayError | undefined]>', 1, true))
assert(not string.find(client, "ConnectWithContext", 1, true))
assert(string.find(client, "RefreshReadiness(forceChallenge?: boolean): LuaTuple<[boolean, RelayError | undefined]>", 1, true))
assert(not string.find(server, "RefreshReadiness", 1, true))
assert(not pcall(Generator.generate, { name = "InvalidTS", version = 1, events = {
	Bad = { id = 1, direction = "ClientToServer", fields = { { name = "x", type = "unsupported" } } },
} }), "invalid Relay definitions must fail before emission")

-- Keep every scalar grammar branch covered without exceeding the descriptor cap.
for _, kind in { "u8", "i8", "u16", "i16", "u24", "i24", "u32", "i32", "f16", "f24", "f32", "f64",
	"Vector2F32", "Vector3F32", "CFrame" } do
	local result = Generator.generate({ name = "ScalarTS", version = 1, events = {
		Value = { id = 1, direction = "ClientToServer", fields = {
			{ name = "value", type = kind, minimum = 0, maximum = 1 },
		} },
	} })
	assert(type(result) == "string" and #result > 0, kind)
end

local directory = ".tmp/relay-additions/roblox-ts/checks"
fs.writeDir(directory)
local badSpec = directory .. "/invalid.luau"
local output = directory .. "/Network.d.ts"
fs.writeFile(badSpec, 'return { name = "InvalidTS", version = 1, events = {} }')
fs.writeFile(output, "preserve existing declarations")
local function run(arguments)
	local args = { "run", "scripts/roblox-ts/generate.luau" }
	for _, argument in arguments do table.insert(args, argument) end
	return process.exec("lune", args, { cwd = process.cwd, stdio = "default" })
end
assert(not run({ badSpec, output }).ok, "invalid schema CLI must exit nonzero")
assert(fs.readFile(output) == "preserve existing declarations", "failed generation must not clobber output")
assert(not run({}).ok, "missing CLI arguments must exit nonzero")
assert(not run({ "scripts/roblox-ts/consumer/src/Spec.luau", directory .. "/wrong.txt" }).ok,
	"output extension must be checked")
assert(run({ "scripts/roblox-ts/consumer/src/Spec.luau", output }).ok, "trusted shared schema CLI")
assert(fs.readFile(output) == declaration, "CLI and module must agree")
print("roblox-ts declarations: compiler grammar, deterministic output, invalid inputs and CLI checks passed")
