local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local Verification = require("../scripts/Verification")

-- Independent oracle: literal expected commands, not the production mapping.
local tests = {
	{ label = "state queue", path = "tests/state-queue.luau" },
	{ label = "types", path = "tests/public-types.luau" },
	{ label = "state session", path = "tests/state-session.luau" },
	{ label = "definition", path = "tests/definition.luau" },
}
local function expect(changes, full, paths)
	local result = Verification.plan(tests, changes)
	assert(result.full == full, "unexpected full fallback")
	assert(#result.tests == #paths, "unexpected selected count")
	for index, path in paths do assert(result.tests[index].path == path, `unexpected check {index}`) end
	assert(#result.reasons > 0, "selection must explain itself")
end
expect({ { status = "M", path = "src/internal/StateQueue.luau" } }, false,
	{ "tests/state-queue.luau", "tests/state-session.luau" })
expect({ { status = "A", path = "tests/types/fixture with spaces.luau" } }, false, { "tests/public-types.luau" })
expect({ { status = "M", path = "tests/definition.luau" }, { status = "M", path = "tests/definition.luau" } }, false,
	{ "tests/definition.luau" })
local all = { "tests/state-queue.luau", "tests/public-types.luau", "tests/state-session.luau", "tests/definition.luau" }
for _, status in { "D", "R100", "C100", "T", "U", "?" } do
	expect({ { status = status, path = "tests/definition.luau" } }, true, all)
end
expect({}, true, all)
expect({ { status = "M", path = "README.md" } }, true, all)
expect({ { status = "M", path = "tests/new-check.luau" } }, true, all)
expect({ { status = "M", path = "src/internal/RpcFrame.luau" } }, true, all) -- missing registered targets
expect({ { status = "M", path = "tests/definition.luau" }, { status = "A", path = "unknown.luau" } }, true, all)
local changed = Verification.parseChanges("M\0tests/definition.luau\0D\0old name.luau\0A\0new name.luau\0", "new\nfile.luau\0")
assert(#changed == 4 and changed[2].status == "D" and changed[2].path == "old name.luau")
assert(changed[4].status == "A" and changed[4].path == "new\nfile.luau", "NUL paths must retain newlines")
expect(changed, true, all)
assert(not pcall(Verification.parseChanges, "M\0unterminated", ""), "truncated Git output accepted")
assert(not pcall(Verification.parseChanges, "M\0", ""), "unpaired Git output accepted")

-- Real atomic reservations and ownership: same owner, distinct paths; cleanup
-- cannot remove a neighbor or a report, and repeating it is harmless.
local left, right = Verification.workspace("regression"), Verification.workspace("regression")
assert(left.root ~= right.root, "workspaces collide")
fs.writeFile(left.artifacts .. "/Relay.rbxm", "left")
fs.writeFile(right.artifacts .. "/Relay.rbxm", "right")
fs.writeFile(left.root .. "/report.json", "retained")
left.cleanup(); left.cleanup()
assert(not fs.isDir(left.artifacts) and fs.readFile(left.root .. "/report.json") == "retained")
assert(fs.readFile(right.artifacts .. "/Relay.rbxm") == "right", "cleanup crossed owners")
right.cleanup()
-- These two roots were created above and are entirely owned by this test.
fs.removeDir(left.root); fs.removeDir(right.root)

local runner = fs.readFile("scripts/verify-foundation.luau")
local function exercise(args, childOk, changedSource)
	local report, reserved, cleaned, exited, calls = nil, false, false, nil, {}
	local identityCalls = 0
	local fakeVerification = {
		plan = Verification.plan,
		changes = function() return { { status = "M", path = "tests/definition.luau" } } end,
		sourceIdentity = function()
			identityCalls += 1
			return { revision = "abc", dirty = true, fingerprint = if changedSource and identityCalls > 1 then "changed" else "same" }
		end,
		workspace = function()
			reserved = true
			return { root = ".tmp/test-owned", artifacts = ".tmp/test-owned/artifacts", cleanup = function() cleaned = true end }
		end,
	}
	local fakeProcess = {
		cwd = ".", args = args,
		exec = function(program, arguments)
			table.insert(calls, { program = program, arguments = arguments })
			return { ok = childOk, code = if childOk then 0 else 9, stdout = "", stderr = "fixture failure" }
		end,
		exit = function(code) exited = code; error("test exit", 0) end,
	}
	local fakeFs = { writeFile = function(path, bytes)
		assert(path == ".tmp/test-owned/report.json"); report = serde.decode("json", bytes)
	end }
	local chunk = luau.load(runner, { environment = {
		print = function() end,
		require = function(path)
			if path == "@lune/fs" then return fakeFs
			elseif path == "@lune/process" then return fakeProcess
			elseif path == "@lune/serde" then return serde
			elseif path == "./Verification" then return fakeVerification end
			error(`unexpected require {path}`)
		end,
	}, injectGlobals = true })
	local ok = pcall(chunk)
	return { report = report, reserved = reserved, cleaned = cleaned, exited = exited, calls = calls, ok = ok }
end
local dry = exercise({ "--first", "--dry-run" }, true)
assert(dry.ok and not dry.reserved and #dry.calls == 0 and dry.report == nil, "dry run executed work")
local focused = exercise({ "--first" }, true)
assert(focused.ok and focused.cleaned and focused.report.mode == "advisory-first")
assert(#focused.calls == 1 and focused.calls[1].program == "lune")
assert(table.concat(focused.calls[1].arguments, " ") == "run tests/definition.luau", "wrong first command")
assert(focused.report.stages[1].status == "passed")
for index = 2, #focused.report.stages do assert(focused.report.stages[index].status == "skipped") end
local failed = exercise({}, false)
assert(not failed.ok and failed.exited == 1 and not failed.cleaned and failed.report.mode == "full")
assert(failed.report.stages[1].status == "failed" and string.find(failed.report.failure, "fixture failure", 1, true))
for index = 2, #failed.report.stages do assert(failed.report.stages[index].status == "blocked") end
local changedDuringRun = exercise({ "--first" }, true, true)
assert(changedDuringRun.exited == 1 and not changedDuringRun.report.sourceStable and not changedDuringRun.cleaned)
assert(not exercise({ "--unknown" }, true).ok, "unknown CLI flag accepted")

print("PASS verification selection, dry run, failure evidence, source drift and output ownership")
