--!strict

-- Private, attempt-scoped provenance for verified-copy benchmark execution.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Fingerprint = require("./MeasurementFingerprint")
local SourceCopy = require("./StudySourceCopy")

local SCHEMA = "Relay.BroadcastStudyExecutionReceipt"
local VERSION = 1
local MAX_RECEIPT_BYTES = 4 * 1_048_576

local function fail(code: string): never
	error("BCAST_E_RECEIPT_" .. code, 0)
end

local function isDigest(value: any): boolean
	return type(value) == "string" and #value == 71 and string.match(value, "^sha256:[0-9a-f]+$") ~= nil
end

local function isRevision(value: any): boolean
	return type(value) == "string" and (#value == 40 or #value == 64)
		and string.match(value, "^[0-9a-f]+$") ~= nil
end

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in value do result[clone(key)] = clone(child) end
	return result
end

local normalizeAbsolute = SourceCopy.canonicalPath
local samePath = SourceCopy.samePath

local function externalAbsolute(value: any): boolean
	if type(value) ~= "string" or #value == 0 or #value > 512
		or string.find(value, "[%z\1-\31\127]") ~= nil then return false end
	local normalized = string.gsub(value, "\\", "/")
	if string.match(normalized, "^%a:/") == nil and string.match(normalized, "^//[^/]+/[^/]+") == nil then
		return false
	end
	for part in string.gmatch(normalized, "[^/]+") do
		if part == "." or part == ".." then return false end
	end
	return true
end

local function sameExternalPath(left: any, right: any): boolean
	if not externalAbsolute(left) or not externalAbsolute(right) then return false end
	local a, b = string.gsub(left, "\\", "/"), string.gsub(right, "\\", "/")
	return string.lower(a) == string.lower(b)
end

local function isUuid(value: string): boolean
	return string.match(value,
		"^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
			.. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
			.. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
			.. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
			.. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$"
	) ~= nil
end

local function validateInventory(inventory: any, hash: any): boolean
	return SourceCopy.validateInventory(inventory, hash)
end

local function validateResults(results: any): boolean
	if type(results) ~= "table" then return false end
	local seen, previous = {}, nil
	for _, value in results do
		if type(value) ~= "string" or string.sub(value, 1, #"benchmarks/results/local/") ~= "benchmarks/results/local/"
			or not string.match(value, "^[A-Za-z0-9_%.%-/]+%.result%-v2%.json$") then return false end
		local name = string.sub(value, #"benchmarks/results/local/" + 1, -#".result-v2.json" - 1)
		if not isUuid(name) or seen[string.lower(value)] or (previous ~= nil and previous >= value) then return false end
		seen[string.lower(value)] = true
		previous = value
	end
	return true
end

local function validatePin(pin: any): boolean
	return type(pin) == "table" and isDigest(pin.sha256) and externalAbsolute(pin.path)
end

local function payload(receipt: any): any
	local result = clone(receipt)
	result.sha256 = nil
	return result
end

local function executionMode(receipt: any): string
	return if receipt.executionMode == nil then "PersistentBenchmark" else receipt.executionMode
end

local verify

local function seal(value: any, hash: any): any
	local receipt = clone(value)
	receipt.schema = SCHEMA
	receipt.version = VERSION
	receipt.sha256 = Fingerprint.digest({ body = serde.encode("json", receipt) }, hash,
		"RelayStudyExecutionReceipt:1")
	local ok, valid = pcall(verify, receipt, hash)
	if not ok or valid ~= true then fail("SHAPE") end
	return receipt
end

verify = function(receipt: any, hash: any, expectedSha256: string?): boolean
	local digestFn = hash or serde.hash
	if type(receipt) ~= "table" or receipt.schema ~= SCHEMA or receipt.version ~= VERSION
		or not isDigest(receipt.sha256) or (expectedSha256 ~= nil and receipt.sha256 ~= expectedSha256)
	then return false end
	local computedOk, computed = pcall(function()
		return Fingerprint.digest({ body = serde.encode("json", payload(receipt)) }, digestFn,
			"RelayStudyExecutionReceipt:1")
	end)
	if not computedOk or computed ~= receipt.sha256 then return false end
	local baseline, attribution, runner, source = receipt.baseline, receipt.attribution, receipt.runner, receipt.source
	local manifest, attempt, tools, studio = receipt.inputManifest, receipt.attempt, receipt.tools, receipt.studio
	if type(baseline) ~= "table" or not isRevision(baseline.revision)
		or (receipt.executionMode ~= nil and receipt.executionMode ~= "PersistentBenchmark"
			and receipt.executionMode ~= "ControlProof")
		or type(attribution) ~= "table" or not isRevision(attribution.revision)
		or type(runner) ~= "table" or runner.role ~= "baseline"
		or type(source) ~= "table" or (source.role ~= "baseline" and source.role ~= "candidate")
		or type(manifest) ~= "table" or manifest.role ~= source.role or not isDigest(manifest.sha256)
		or type(attempt) ~= "table" or type(attempt.index) ~= "number" or attempt.index < 1
		or attempt.index % 1 ~= 0 or (attempt.pass ~= 1 and attempt.pass ~= 2)
		or (attempt.order ~= "forward" and attempt.order ~= "reverse")
		or type(attempt.adapterId) ~= "string" or #attempt.adapterId == 0 or #attempt.adapterId > 128
		or type(attempt.label) ~= "string" or #attempt.label == 0 or #attempt.label > 32
		or not validateInventory(runner, digestFn) or not validateInventory(source, digestFn)
		or not validateResults(runner.allowedResults) or not validateResults(source.allowedResults)
		or type(tools) ~= "table" or tools.lune == nil or tools.rojo == nil
		or not validatePin(tools.lune) or not validatePin(tools.rojo)
		or tools.lune.role ~= "baseline" or tools.rojo.role ~= source.role
		or type(studio) ~= "table" or not externalAbsolute(studio.path)
		or type(studio.size) ~= "number" or studio.size < 1
		or studio.size % 1 ~= 0 or not isDigest(studio.sha256)
	then return false end
	local rootChecks = { baseline.root, attribution.root, runner.sourceRoot, source.sourceRoot, runner.root, source.root }
	for _, value in rootChecks do
		if not pcall(normalizeAbsolute, value) then return false end
	end
	if not samePath(runner.sourceRoot, baseline.root) or runner.sourceRevision ~= baseline.revision then return false end
	if not samePath(source.sourceRoot, attribution.root) or source.sourceRevision ~= attribution.revision then return false end
	local hasRunner = false
	for _, entry in runner.entries do
		if entry.path == "benchmarks/host/run-event-v1.luau" then hasRunner = true; break end
	end
	if not hasRunner then return false end
	if runner.sha256 ~= manifest.baselineSha256
		or source.sha256 ~= (if source.role == "baseline" then manifest.baselineSha256 else manifest.candidateSha256)
		or (attempt.label == "candidate") ~= (source.role == "candidate")
		or (attempt.pass == 1 and attempt.order ~= "forward") or (attempt.pass == 2 and attempt.order ~= "reverse")
	then return false end
	if source.role == "baseline" and (not samePath(source.sourceRoot, baseline.root)
		or source.sourceRevision ~= baseline.revision or not samePath(source.root, runner.root)
		or source.sha256 ~= runner.sha256 or source.files ~= runner.files) then return false end
	if source.role == "candidate" and samePath(source.sourceRoot, baseline.root) then return false end
	return true
end

local function validateChild(receipt: any, cwd: string, adapterId: string, attemptIndex: number,
	studioPath: string, studioBytes: string, hash: any, actualMode: string): boolean
	if not verify(receipt, hash) or not samePath(receipt.source.root, cwd)
		or (actualMode ~= "PersistentBenchmark" and actualMode ~= "ControlProof")
		or executionMode(receipt) ~= actualMode
		or receipt.attempt.adapterId ~= adapterId or receipt.attempt.index ~= attemptIndex
		or not sameExternalPath(receipt.studio.path, studioPath) or type(studioBytes) ~= "string"
		or (receipt.attempt.label == "candidate") ~= (receipt.source.role == "candidate")
	then return false end
	local studioHash = hash("sha256", studioBytes)
	return type(studioHash) == "string" and receipt.studio.size == #studioBytes
		and receipt.studio.sha256 == "sha256:" .. string.lower(studioHash)
end

local function read(path: string, expectedSha256: string, cwd: string, dependencies: any?): any
	local deps = dependencies or {}
	local surface, hash = deps.fs or fs, deps.hash or serde.hash
	local normalizedPathOk, normalizedPath = pcall(normalizeAbsolute, path)
	local cwdOk, normalizedCwd = pcall(normalizeAbsolute, cwd)
	if not normalizedPathOk or not cwdOk or not isDigest(expectedSha256) or not surface.isFile(normalizedPath) then
		fail("READ")
	end
	local sizeFn = deps.fileSize or function(filename: string): number
		local metadata = fs.metadata(filename)
		if type(metadata) ~= "table" or metadata.exists ~= true or type(metadata.size) ~= "number" then fail("READ") end
		return metadata.size
	end
	local sizeOk, byteCount = pcall(sizeFn, normalizedPath)
	if not sizeOk or type(byteCount) ~= "number" or byteCount < 1 or byteCount > MAX_RECEIPT_BYTES then fail("READ") end
	local readOk, body = pcall(surface.readFile, normalizedPath)
	if not readOk or type(body) ~= "string" or #body ~= byteCount then fail("READ") end
	local decodeOk, receipt = pcall(serde.decode, "json", body)
	if not decodeOk or not verify(receipt, hash, expectedSha256) or not samePath(receipt.source.root, normalizedCwd) then
		fail("PROVENANCE")
	end
	local expectedName = string.format("execution-attempt-%03d.json", receipt.attempt.index)
	local expectedDirectory = string.match(normalizedPath, "^(.*)/[^/]+$")
	if expectedDirectory == nil or string.lower(string.match(normalizedPath, "([^/]+)$") or "") ~= expectedName
		or not samePath(normalizedPath, receipt.baseline.root .. "/.tmp/" ..
			(string.match(expectedDirectory, "([^/]+)$") or "") .. "/" .. expectedName)
		or string.match(expectedDirectory, "[/]broadcast%-study%-%x+$") == nil then fail("PROVENANCE") end
	return receipt
end

return table.freeze({
	SCHEMA = SCHEMA,
	VERSION = VERSION,
	MAX_RECEIPT_BYTES = MAX_RECEIPT_BYTES,
	executionMode = executionMode,
	isDigest = isDigest,
	validatePin = validatePin,
	validateInventory = validateInventory,
	seal = seal,
	verify = verify,
	validateChild = validateChild,
	read = read,
	samePath = samePath,
})
