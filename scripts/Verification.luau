-- Private workflow helpers, outside the Wally package. Selection is advisory:
-- these are first checks to try, not a dependency graph or a release proof.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Fingerprint = require("../benchmarks/host/MeasurementFingerprint")

local FIRST_CHECKS = {
	["src/internal/PacedBatcher.luau"] = { "tests/paced-batcher.luau", "tests/batch-session.luau" },
	["src/internal/Streams.luau"] = { "tests/streams.luau", "tests/ordered-unreliable.luau" },
	["src/internal/StateQueue.luau"] = { "tests/state-queue.luau", "tests/state-session.luau" },
	["src/internal/Batch.luau"] = { "tests/batch-queue.luau", "tests/batch-session.luau" },
	["src/internal/BatchFrame.luau"] = { "tests/batch-frame.luau", "tests/batch-session.luau" },
	["src/internal/ReadinessFrame.luau"] = { "tests/readiness-frame.luau", "tests/readiness-session.luau" },
	["src/internal/RpcFrame.luau"] = { "tests/rpc-frame.luau", "tests/rpc-session.luau" },
	["src/internal/TokenBucket.luau"] = { "tests/token-bucket.luau", "tests/server-session.luau" },
	["src/internal/Diagnostics.luau"] = { "tests/diagnostics.luau" },
	["benchmarks/reporting/ResultReporter.luau"] = { "benchmarks/tests/result-reporter.luau", "benchmarks/tests/persistent-reporter.luau" },
}

local function command(program, arguments)
	local result = process.exec(program, arguments, { cwd = process.cwd, stdio = "default" })
	assert(result.ok, `{program} failed ({result.code})\n{result.stdout}\n{result.stderr}`)
	return result.stdout
end

local function nulFields(bytes)
	local fields = {}
	local cursor = 1
	while cursor <= #bytes do
		local ending = string.find(bytes, "\0", cursor, true)
		assert(ending, "unterminated Git NUL field")
		table.insert(fields, string.sub(bytes, cursor, ending - 1))
		cursor = ending + 1
	end
	return fields
end

local function parseChanges(diff, untracked)
	local fields = nulFields(diff)
	assert(#fields % 2 == 0, "invalid Git name-status pairs")
	local changes = {}
	for index = 1, #fields, 2 do
		-- --no-renames deliberately represents a rename as delete + add.
		table.insert(changes, { status = fields[index], path = fields[index + 1] })
	end
	for _, path in nulFields(untracked) do table.insert(changes, { status = "A", path = path }) end
	return changes
end

local function changes()
	return parseChanges(command("git", { "diff", "--name-status", "--no-renames", "-z", "HEAD", "--" }),
		command("git", { "ls-files", "--others", "--exclude-standard", "-z" }))
end

local function plan(tests, changed)
	local selected, registered, reasons = {}, {}, {}
	for _, test in tests do registered[test.path] = true end
	local full = #changed == 0
	if full then table.insert(reasons, "no changes: full verification") end
	for _, change in changed do
		local mapped = FIRST_CHECKS[change.path]
		if registered[change.path] then mapped = { change.path }
		elseif string.sub(change.path, 1, 12) == "tests/types/" then mapped = { "tests/public-types.luau" } end
		if (change.status ~= "M" and change.status ~= "A") or mapped == nil then
			full = true
			table.insert(reasons, `{change.status} {change.path}: full fallback (unknown mapping or non-add/modify status)`)
		else
			table.insert(reasons, `{change.status} {change.path}: {table.concat(mapped, ", ")}`)
			for _, path in mapped do
				if not registered[path] then full = true; table.insert(reasons, `unregistered check {path}: full fallback`) end
				selected[path] = true
			end
		end
	end
	local checks = {}
	for _, test in tests do if full or selected[test.path] then table.insert(checks, test) end end
	return { full = full, tests = checks, reasons = reasons }
end

local function sourceIdentity()
	local revision = string.match(command("git", { "rev-parse", "HEAD" }), "^%x+")
	local status = command("git", { "status", "--porcelain=v1", "--untracked-files=all" })
	local entries = { ["@revision"] = revision, ["@status"] = status }
	for _, path in nulFields(command("git", { "ls-files", "--cached", "--others", "--exclude-standard", "-z" })) do
		entries[path] = if fs.isFile(path) then fs.readFile(path) else "<missing>"
	end
	return { revision = revision, dirty = #status > 0,
		fingerprint = Fingerprint.digest(entries, serde.hash, "RelayVerificationSource:1") }
end

local function workspace(kind)
	assert(kind == "foundation" or kind == "public-types" or kind == "regression", "invalid verification owner")
	fs.writeDir(".tmp/verification")
	local token = string.sub(serde.hash("sha256", `{os.time()}:{os.clock()}:{tostring({})}`), 1, 24)
	local root = `.tmp/verification/{kind}-{token}`
	-- Reserve atomically: never reuse another invocation's directory.
	if process.os == "windows" then
		command("powershell.exe", { "-NoProfile", "-NonInteractive", "-Command",
			`New-Item -ItemType Directory -Path '{root}' -ErrorAction Stop | Out-Null` })
	else
		command("mkdir", { root })
	end
	local artifacts = root .. "/artifacts"
	fs.writeDir(artifacts)
	local cleaned = false
	return {
		root = root,
		artifacts = artifacts,
		cleanup = function()
			-- Only this closure's reserved artifacts. Reports and failures remain.
			if not cleaned then fs.removeDir(artifacts); cleaned = true end
		end,
	}
end

return table.freeze({ plan = plan, changes = changes, parseChanges = parseChanges,
	sourceIdentity = sourceIdentity, workspace = workspace })
