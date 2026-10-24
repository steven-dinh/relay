--!strict

-- Read-only preflight for v2-v4 broadcast recovery. It never selects old slots
-- for comparison or authorizes an unattended Studio relaunch.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Study = require("./BroadcastStudy")
local Host = require("./HostRuntime")
local Manifest = require("./StudyInputManifest")
local Fingerprint = require("./MeasurementFingerprint")
local ExecutionReceipt = require("./StudyExecutionReceipt")
local ResultV2 = require("../contracts/result-v2")

local MAX_LEDGER_BYTES = 1_048_576
local MAX_LOG_BYTES = Study.PROCESS_OUTPUT_MAX_BYTES
local MAX_RECEIPT_BYTES = ExecutionReceipt.MAX_RECEIPT_BYTES
local MAX_LINEAGE_LENGTH = 8
local function fail(code: string): never
	error("BCAST_RECOVERY_E_" .. code, 0)
end

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_VALUES = {}
for index = 1, #BASE64 do BASE64_VALUES[string.sub(BASE64, index, index)] = index - 1 end

local function decodeBase64(encoded: string, maximum: number): string
	if #encoded % 4 ~= 0 or #encoded > 4 * math.ceil(maximum / 3) then fail("READ") end
	local padding = if string.sub(encoded, -2) == "==" then 2
		elseif string.sub(encoded, -1) == "=" then 1 else 0
	local length = #encoded / 4 * 3 - padding
	if length > maximum then fail("READ") end
	local output = buffer.create(length)
	local offset = 0
	for index = 1, #encoded, 4 do
		local a = BASE64_VALUES[string.sub(encoded, index, index)]
		local b = BASE64_VALUES[string.sub(encoded, index + 1, index + 1)]
		local c = BASE64_VALUES[string.sub(encoded, index + 2, index + 2)]
		local d = BASE64_VALUES[string.sub(encoded, index + 3, index + 3)]
		if a == nil or b == nil or (c == nil and index + 3 < #encoded)
			or (d == nil and index + 3 < #encoded) then fail("READ") end
		local word = bit32.lshift(a, 18) + bit32.lshift(b, 12)
			+ bit32.lshift(c or 0, 6) + (d or 0)
		if offset < length then buffer.writeu8(output, offset, bit32.band(bit32.rshift(word, 16), 255)); offset += 1 end
		if offset < length then buffer.writeu8(output, offset, bit32.band(bit32.rshift(word, 8), 255)); offset += 1 end
		if offset < length then buffer.writeu8(output, offset, bit32.band(word, 255)); offset += 1 end
	end
	return buffer.tostring(output)
end

local function readCapped(filename: string, maximum: number): string
	local root = process.env.SystemRoot
	if type(root) ~= "string" or #root == 0 then fail("READ") end
	local executable = string.gsub(root, "\\", "/") .. "/System32/WindowsPowerShell/v1.0/powershell.exe"
	local script = [[& { $ErrorActionPreference='Stop';$stream=[IO.File]::Open($env:RELAY_AUDIT_PATH,'Open','Read','ReadWrite');try{$limit=[int]$env:RELAY_AUDIT_LIMIT;$bytes=New-Object byte[] ($limit+1);$count=0;while($count -lt $bytes.Length){$next=$stream.Read($bytes,$count,$bytes.Length-$count);if($next -eq 0){break};$count+=$next};if($count -gt $limit){exit 2};[Console]::Out.Write([Convert]::ToBase64String($bytes,0,$count))}finally{$stream.Dispose()} }]]
	local result = process.exec(executable, { "-NoProfile", "-NonInteractive", "-Command", script },
		{ env = { RELAY_AUDIT_PATH = filename, RELAY_AUDIT_LIMIT = tostring(maximum) } })
	if result.ok ~= true or type(result.stdout) ~= "string" then fail("READ") end
	return decodeBase64(result.stdout, maximum)
end

local function path(value: any): string
	if type(value) ~= "string" or #value == 0 then fail("PATH") end
	local normalized = string.gsub(value, "\\", "/")
	if string.find(normalized, "[%z\r\n]") or string.find(normalized, "/%.%./")
		or string.sub(normalized, -3) == "/.." then fail("PATH") end
	return normalized
end

local function absolute(value: any, cwd: string): string
	local normalized = path(value)
	if string.match(normalized, "^%a:/") or string.sub(normalized, 1, 1) == "/" then return normalized end
	return path(string.gsub(path(cwd), "/+$", "") .. "/" .. normalized)
end

local function same(left: any, right: any): boolean
	local a, b = path(left), path(right)
	return if process.os == "windows" then string.lower(a) == string.lower(b) else a == b
end

local function canonicalKey(value: string, osName: string): string
	local normalized = path(value)
	local prefix = string.match(normalized, "^%a:/")
		or (if string.sub(normalized, 1, 2) == "//" then "//"
			elseif string.sub(normalized, 1, 1) == "/" then "/" else "")
	local parts = {}
	for part in string.gmatch(string.sub(normalized, #prefix + 1), "[^/]+") do
		if part == "." then continue end
		if part == ".." then fail("PATH") end
		table.insert(parts, part)
	end
	local result = prefix .. table.concat(parts, "/")
	return if osName == "windows" then string.lower(result) else result
end

local function sameSourceIdentity(left: any, right: any): boolean
	if left == nil or right == nil then return left == right end
	return type(left) == "table" and type(right) == "table"
		and same(left.root, right.root) and left.revision == right.revision
end

local function array(value: any, maximum: number, code: string): number
	if type(value) ~= "table" then fail(code) end
	local count = #value
	if count > maximum then fail(code) end
	local keys = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then fail(code) end
		keys += 1
	end
	if keys ~= count then fail(code) end
	return count
end

local function readBounded(read: any, size: any, filename: string, maximum: number, code: string): string
	local sizeOk, expectedSize = pcall(size, filename)
	if not sizeOk or type(expectedSize) ~= "number" or expectedSize < 0
		or expectedSize % 1 ~= 0 or expectedSize > maximum then fail(code) end
	local ok, body = pcall(read, filename, maximum)
	if not ok or type(body) ~= "string" or #body ~= expectedSize then fail(code) end
	return body
end

local function digest(body: string): string
	return "sha256:" .. serde.hash("sha256", body)
end

local function sameSummary(left: any, right: any): boolean
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	for id, summary in right do
		local ok = pcall(Study.summaryAgreement, left[id], summary)
		if not ok then return false end
	end
	for id in left do if right[id] == nil then return false end end
	return true
end

local function sameStrings(left: any, right: any): boolean
	if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
	for index, value in left do if value ~= right[index] then return false end end
	return true
end

local function validPin(pin: any): boolean
	return ExecutionReceipt.validatePin(pin)
		and type(pin.version) == "string" and #pin.version > 0 and #pin.version <= 64
end

local function audit(ledgerPath: string, dependencies: any?, expectedDigest: string?): any
	local deps = dependencies or {}
	local read = deps.readFile or readCapped
	local size = deps.fileSize or function(filename: string): number
		return Host.outputFileSize(filename, process.os, process.exec)
	end
	local hash = deps.hash or serde.hash
	local cwd = deps.cwd or process.cwd
	local osName = deps.os or process.os
	local visited = {}
	local function visit(selectedPath: string, expectedDigest: string?, depth: number): any
		if depth > MAX_LINEAGE_LENGTH then fail("LINEAGE_DEPTH") end
		local filename = absolute(selectedPath, cwd)
		local key = canonicalKey(filename, osName)
		if visited[key] then fail("RESTART_CYCLE") end
		visited[key] = true
	local directory = string.match(filename, "^(.*)/[^/]+$")
	if directory == nil then fail("PATH") end
	local body = readBounded(read, size, filename, MAX_LEDGER_BYTES, "LEDGER_READ")
	if expectedDigest ~= nil and digest(body) ~= expectedDigest then fail("RESTART_HASH") end
	local decoded, ledger = pcall(serde.decode, "json", body)
	if not decoded or type(ledger) ~= "table" or ledger.schema ~= "Relay.BroadcastStudyLedger"
		or (ledger.version ~= 2 and ledger.version ~= 3 and ledger.version ~= 4)
		or ledger.finishedUtc ~= nil then fail("LEDGER") end
	local version = ledger.version
	if version == 2 and (ledger.collectionId ~= nil or ledger.restartOf ~= nil) then fail("LEDGER") end
	if type(ledger.sources) ~= "table" or type(ledger.sources.baseline) ~= "table"
		or type(ledger.topology) ~= "table" or type(ledger.studio) ~= "table"
		or type(ledger.startedUtc) ~= "string" then fail("LEDGER") end
	local baseline, candidate = ledger.sources.baseline, ledger.sources.candidate
	if type(baseline.root) ~= "string" or type(baseline.revision) ~= "string"
		or (candidate ~= nil and (type(candidate) ~= "table" or type(candidate.root) ~= "string"
			or type(candidate.revision) ~= "string"))
		or type(ledger.studio.path) ~= "string" or type(ledger.studio.sha256) ~= "string"
		or ledger.topology.mode ~= "PersistentBenchmark" or ledger.topology.caseId ~= "state-broadcast-s2c"
		or (ledger.topology.recipients ~= 1 and ledger.topology.recipients ~= 4 and ledger.topology.recipients ~= 8)
	then fail("LEDGER") end
	local options = { os = osName, baseline = path(baseline.root),
		candidate = if candidate == nil then nil else path(candidate.root),
		studio = path(ledger.studio.path), recipients = ledger.topology.recipients }
	if not same(absolute(options.baseline, cwd), options.baseline)
		or (options.candidate ~= nil and (not same(absolute(options.candidate, cwd), options.candidate)
			or same(options.candidate, options.baseline))) then fail("SOURCE") end
	local expectedPlan = Study.plan(options)
	local manifest = ledger.inputManifest
	local verified, valid = pcall(Manifest.verify, manifest, hash)
	if not verified or valid ~= true or manifest.studioSha256 ~= ledger.studio.sha256
		or (manifest.candidate ~= nil) ~= (candidate ~= nil)
		or manifest.planSha256 ~= Fingerprint.digest({ bytes = serde.encode("json", expectedPlan) },
			hash, "RelayStudyPlan:1") then fail("INPUT") end
	local previous = nil
	if version == 3 or (version == 4 and ledger.restartOf ~= nil) then
		local restart = ledger.restartOf
		if type(ledger.collectionId) ~= "string" or ledger.collectionId ~= string.match(directory, "([^/]+)$")
			or type(restart) ~= "table" or type(restart.path) ~= "string"
			or type(restart.sha256) ~= "string" or type(restart.inputManifestSha256) ~= "string"
			or restart.inputManifestSha256 ~= manifest.sha256 then fail("RESTART") end
		local priorPathOk, priorPath = pcall(Study.restartLedgerPath, restart.path, baseline.root, options.os)
		if not priorPathOk then fail("RESTART_PATH") end
		if same(priorPath, filename) then fail("RESTART_CYCLE") end
		previous = visit(priorPath, restart.sha256, depth + 1)
		if previous.inputManifestSha256 ~= restart.inputManifestSha256
			or previous.inputManifestSha256 ~= manifest.sha256
			or not sameSourceIdentity(previous.sources.baseline, baseline)
			or not sameSourceIdentity(previous.sources.candidate, candidate)
			or previous.topology.recipients ~= ledger.topology.recipients then fail("RESTART") end
	elseif ledger.collectionId ~= nil or ledger.restartOf ~= nil then
		fail("RESTART")
	end
	local execution = ledger.execution
	local executionReady = false
	if version == 4 then
		local token = string.match(directory, "/broadcast%-study%-(%x+)$")
		if token == nil or #token ~= 16 or type(execution) ~= "table" or execution.version ~= 1
			or (execution.status ~= "Ready" and execution.status ~= "Preparing" and execution.status ~= "Failed")
		then fail("EXECUTION") end
		if execution.status == "Ready" then
			local baselineRootOk, expectedBaselineRoot = pcall(Study.copyDestination, baseline.root, token, "baseline")
			local baselineCopy = type(execution.copies) == "table" and execution.copies.baseline or nil
			local runner = execution.runner
			local candidateCopy = type(execution.copies) == "table" and execution.copies.candidate or nil
			local tools = execution.toolchains
			if not baselineRootOk or type(runner) ~= "table" or type(baselineCopy) ~= "table"
				or not same(runner.root, expectedBaselineRoot) or not same(baselineCopy.root, expectedBaselineRoot)
				or runner.files ~= manifest.baseline.files or baselineCopy.files ~= manifest.baseline.files
				or runner.sha256 ~= manifest.baseline.sha256 or baselineCopy.sha256 ~= manifest.baseline.sha256
				or type(tools) ~= "table" or type(tools.baseline) ~= "table"
				or not validPin(tools.baseline.lune) or not validPin(tools.baseline.rojo)
			then fail("EXECUTION") end
			if candidate ~= nil then
				local candidateRootOk, expectedCandidateRoot = pcall(Study.copyDestination, candidate.root, token, "candidate")
				if not candidateRootOk or type(candidateCopy) ~= "table" or type(tools.candidate) ~= "table"
					or not validPin(tools.candidate.lune) or not validPin(tools.candidate.rojo)
					or not same(candidateCopy.root, expectedCandidateRoot)
					or candidateCopy.files ~= manifest.candidate.files or candidateCopy.sha256 ~= manifest.candidate.sha256
				then fail("EXECUTION") end
			elseif candidateCopy ~= nil or tools.candidate ~= nil then fail("EXECUTION") end
			executionReady = true
		elseif execution.runner ~= nil or execution.copies == nil or next(execution.copies) ~= nil
			or execution.toolchains ~= nil or type(ledger.attempts) ~= "table" or #ledger.attempts > 0
		then fail("EXECUTION") end
	elseif execution ~= nil then
		-- v2/v3 records are legacy live-source runs; extra metadata cannot upgrade them.
		fail("EXECUTION")
	end
	local ordered = Study.schedule(options)
	if array(ledger.schedule, #ordered, "SCHEDULE") ~= #ordered then fail("SCHEDULE") end
	local count = array(ledger.attempts, #ordered, "ATTEMPTS")
	if deps.verifyCurrent ~= false and depth == 1 then
		local currentSource = deps.sourceIdentity or Study.sourceIdentity
		local execute = deps.execute or process.exec
		local baselineCurrent = currentSource(options.baseline, execute)
		local candidateCurrent = if options.candidate == nil then nil else currentSource(options.candidate, execute)
		if baselineCurrent.revision ~= baseline.revision
			or (candidate ~= nil and candidateCurrent.revision ~= candidate.revision) then fail("SOURCE_CHANGED") end
		local collect = deps.collectInputManifest or Manifest.collect
		local current, currentDetails = collect(options, expectedPlan, { fs = deps.fs, execute = execute, hash = hash,
			toolRoot = deps.toolRoot })
		local currentVerified, currentValid = pcall(Manifest.verify, current, hash)
		if not currentVerified or currentValid ~= true or current.sha256 ~= manifest.sha256 then fail("INPUT_CHANGED") end
		if version == 4 and executionReady then
			local function sameToolchain(left: any, right: any): boolean
				if type(left) ~= "table" or type(right) ~= "table" then return false end
				for _, name in { "lune", "rojo" } do
					local a, b = left[name], right[name]
					if not validPin(a) or not validPin(b) or a.path ~= b.path or a.sha256 ~= b.sha256
						or a.version ~= b.version then return false end
				end
				return true
			end
			if type(currentDetails) ~= "table" or type(currentDetails.tools) ~= "table"
				or not sameToolchain(currentDetails.tools.baseline, execution.toolchains.baseline)
				or (candidate ~= nil and not sameToolchain(currentDetails.tools.candidate, execution.toolchains.candidate))
			then fail("INPUT_CHANGED") end
		end
	end
	local seenRunIds, seenArchivePaths, commonKey = {}, {}, nil
	if previous ~= nil then
		for _, prior in previous.previousAttempts do
			for _, archive in prior.archives do seenRunIds[string.lower(archive.runId)] = true end
		end
	end
	local observed = {}
	local priorResults = { baseline = {}, candidate = {} }
	local function canonicalResults(values: { string }): { string }
		local result = table.clone(values)
		table.sort(result)
		return result
	end
	local function readReceipt(receiptPath: string, expectedSha: string, executionRoot: string): any
		local receiptSurface = {
			isFile = function(value: string): boolean local ok = pcall(size, value); return ok end,
			readFile = function(value: string): string return readBounded(read, size, value, MAX_RECEIPT_BYTES, "RECEIPT") end,
		}
		local ok, receipt = pcall(ExecutionReceipt.read, receiptPath, expectedSha, executionRoot, {
			fs = receiptSurface, fileSize = size, hash = hash,
		})
		if not ok then fail("RECEIPT") end
		return receipt
	end
	for index, expected in ordered do
		local scheduled = ledger.schedule[index]
		if type(scheduled) ~= "table" or scheduled.index ~= index then fail("SCHEDULE") end
		for key, value in expected do if scheduled[key] ~= value then fail("SCHEDULE") end end
		if index > count then continue end
		local attempt = ledger.attempts[index]
		if type(attempt) ~= "table" or attempt.index ~= index
			or attempt.inputManifestSha256 ~= manifest.sha256 or type(attempt.startedUtc) ~= "string"
			or (attempt.valid ~= true and attempt.valid ~= false) then fail("ATTEMPT") end
		for key, value in expected do if attempt[key] ~= value then fail("ATTEMPT") end end
		if attempt.valid == false and index ~= count then fail("ATTEMPT") end
		local rawCount = if attempt.rawResult == nil then 0 else array(attempt.rawResult, 32, "ARCHIVE")
		local receipt = nil
		if version == 4 then
			if attempt.executionReceiptPath ~= nil then
				if not executionReady then fail("RECEIPT") end
				local expectedRole = if expected.root == baseline.root then "baseline" else "candidate"
				local selectedCopy = execution.copies[expectedRole]
				local expectedReceipt = directory .. string.format("/execution-attempt-%03d.json", index)
				if selectedCopy == nil or type(attempt.executionRoot) ~= "string"
					or type(attempt.sourceCopySha256) ~= "string"
					or not same(attempt.executionRoot, selectedCopy.root)
					or attempt.sourceCopySha256 ~= selectedCopy.sha256
					or not same(attempt.executionReceiptPath, expectedReceipt)
					or type(attempt.executionReceiptSha256) ~= "string"
				then fail("RECEIPT") end
				receipt = readReceipt(expectedReceipt, attempt.executionReceiptSha256, attempt.executionRoot)
				if ExecutionReceipt.executionMode(receipt) ~= "PersistentBenchmark" then fail("RECEIPT") end
				local expectedSource = if expectedRole == "baseline" then baseline else candidate
				local expectedPins = execution.toolchains[expectedRole]
				if receipt.attempt.index ~= index or receipt.attempt.pass ~= expected.pass
					or receipt.attempt.order ~= expected.order or receipt.attempt.label ~= expected.label
					or receipt.attempt.adapterId ~= expected.adapterId
					or not same(receipt.baseline.root, baseline.root) or receipt.baseline.revision ~= baseline.revision
					or not same(receipt.attribution.root, expectedSource.root)
					or receipt.attribution.revision ~= expectedSource.revision
					or not same(receipt.runner.root, execution.runner.root)
					or receipt.runner.sha256 ~= execution.runner.sha256
					or receipt.source.role ~= expectedRole or not same(receipt.source.root, selectedCopy.root)
					or receipt.source.sha256 ~= selectedCopy.sha256
					or receipt.inputManifest.sha256 ~= manifest.sha256
					or receipt.inputManifest.baselineSha256 ~= manifest.baseline.sha256
					or receipt.inputManifest.candidateSha256 ~= (if manifest.candidate == nil then nil else manifest.candidate.sha256)
					or not same(receipt.studio.path, ledger.studio.path)
					or receipt.studio.sha256 ~= ledger.studio.sha256 or receipt.studio.size ~= ledger.studio.size
					or receipt.tools.lune.path ~= execution.toolchains.baseline.lune.path
					or receipt.tools.lune.sha256 ~= execution.toolchains.baseline.lune.sha256
					or receipt.tools.rojo.path ~= expectedPins.rojo.path
					or receipt.tools.rojo.sha256 ~= expectedPins.rojo.sha256
					or not sameStrings(receipt.runner.allowedResults, canonicalResults(priorResults.baseline))
					or not sameStrings(receipt.source.allowedResults, canonicalResults(priorResults[expectedRole]))
				then fail("RECEIPT") end
			elseif rawCount > 0 or attempt.exitCode ~= nil or attempt.executionRoot ~= nil
				or attempt.executionReceiptSha256 ~= nil or attempt.sourceCopySha256 ~= nil then
				fail("RECEIPT")
			end
		end
		if attempt.addedResults ~= nil then
			if type(attempt.addedResults) ~= "number" or attempt.addedResults % 1 ~= 0
				or attempt.addedResults ~= rawCount then fail("ARCHIVE_COUNT") end
		elseif rawCount > 0 then fail("ARCHIVE_COUNT") end
		local logsRequired = attempt.valid == true or attempt.exitCode ~= nil
			or attempt.addedResults ~= nil or rawCount > 0
		local logs = {}
		local stdoutBody = nil
		for _, name in { "stdout", "stderr" } do
			local expectedPath = directory .. string.format("/attempt-%03d.%s.log", index, name)
			local actualPath = attempt[name .. "Path"]
			if not same(actualPath, expectedPath) then fail("LOG") end
			local sizeOk, logSize = pcall(size, expectedPath)
			if sizeOk then
				if type(logSize) ~= "number" or attempt[name .. "Bytes"] ~= logSize then fail("LOG") end
				local log = readBounded(read, size, expectedPath, MAX_LOG_BYTES, "LOG")
				logs[name .. "Sha256"] = digest(log)
				if name == "stdout" then stdoutBody = log end
			elseif logsRequired or attempt[name .. "Bytes"] ~= nil then fail("LOG") end
		end
		local archives = {}
		for rawIndex = 1, rawCount do
			local raw = attempt.rawResult[rawIndex]
			if type(raw) ~= "table" or type(raw.sourcePath) ~= "string" or type(raw.path) ~= "string"
				or type(raw.size) ~= "number" or raw.size < 1 or raw.size > ResultV2.MAX_JSON_BYTES
				or type(raw.sha256) ~= "string" then fail("ARCHIVE") end
			local resultName = string.match(path(raw.sourcePath), "([^/]+)$")
			if resultName == nil then fail("ARCHIVE") end
			local resultRoot = if receipt == nil then expected.root else receipt.source.root
			local originalPrefix = resultRoot .. "/" .. Study.RESULT_DIRECTORY .. "/"
			local expectedArchive = directory .. "/raw/" .. string.format("attempt-%03d-%d-%s", index, rawIndex, resultName)
			if string.sub(path(raw.sourcePath), 1, #originalPrefix) ~= originalPrefix
				or not string.match(resultName, "^[0-9a-fA-F%-]+%.result%-v2%.json$")
				or not same(raw.path, expectedArchive) or seenArchivePaths[string.lower(path(raw.path))] then fail("ARCHIVE") end
			seenArchivePaths[string.lower(path(raw.path))] = true
			local archive = readBounded(read, size, expectedArchive, ResultV2.MAX_JSON_BYTES, "ARCHIVE_READ")
			if #archive ~= raw.size or digest(archive) ~= raw.sha256 then fail("ARCHIVE_HASH") end
			local jsonOk, result = pcall(serde.decode, "json", archive)
			if not jsonOk or type(result) ~= "table" or type(result.runId) ~= "string"
				or seenRunIds[string.lower(result.runId)] then fail("RAW_RESULT") end
			seenRunIds[string.lower(result.runId)] = true
			table.insert(archives, { path = expectedArchive, size = raw.size, sha256 = raw.sha256, runId = result.runId })
			if attempt.valid == true then
				local source = if expected.root == baseline.root then baseline else candidate
				local checked = Study.validateResult(result, { recipients = options.recipients, revision = source.revision },
					raw.sourcePath, expected, {}, commonKey)
				if commonKey == nil then commonKey = checked.compatibilityKey end
				if attempt.runId ~= checked.result.runId or attempt.resultPath ~= raw.sourcePath
					or attempt.resultSize ~= raw.size or attempt.resultSha256 ~= raw.sha256
					or attempt.sourceRevision ~= checked.source.revision
					or attempt.measurementFingerprint ~= checked.source.measurementFingerprint
					or attempt.contractFingerprint ~= checked.result.contract.fingerprint then fail("PROVENANCE") end
				if not sameSummary(attempt.summaries, checked.summaries) then fail("SUMMARY") end
			end
			if version == 4 and rawCount == 1 then
				table.insert(priorResults[if expected.root == baseline.root then "baseline" else "candidate"],
					string.sub(raw.sourcePath, #resultRoot + 2))
			end
		end
		if attempt.valid == true then
			if rawCount ~= 1 or attempt.failure ~= nil or attempt.exitCode ~= 0
				or attempt.stdoutTruncated ~= false or attempt.stderrTruncated ~= false
				or attempt.addedResults ~= 1 or type(attempt.finishedUtc) ~= "string" then fail("ATTEMPT") end
			local passOk, pass = pcall(Study.parsePassOutput, stdoutBody)
			if not passOk or pass.launchId ~= string.lower(attempt.runId)
				or not same(pass.path, attempt.resultPath) then fail("PASS") end
		elseif attempt.finishedUtc ~= nil
			and (type(attempt.finishedUtc) ~= "string" or type(attempt.failure) ~= "string") then fail("ATTEMPT") end
		table.insert(observed, { index = index, label = expected.label, ledger = filename,
			collectionId = ledger.collectionId,
			state = if attempt.valid then "RetainedValidButNotSelected" elseif attempt.finishedUtc == nil then "Interrupted"
				else "Rejected", failure = attempt.failure, archives = archives, logs = logs })
	end
	local allAttempts = {}
	if previous ~= nil then
		for _, prior in previous.previousAttempts do table.insert(allAttempts, prior) end
	end
	for _, current in observed do table.insert(allAttempts, current) end
	return { schema = "Relay.BroadcastRecoveryAudit", version = 1, ledger = filename,
		ledgerSha256 = digest(body), inputManifestSha256 = manifest.sha256,
		sources = { baseline = { root = baseline.root, revision = baseline.revision },
			candidate = if candidate == nil then nil else { root = candidate.root, revision = candidate.revision } },
		topology = ledger.topology,
		status = "FreshFullStudyRequired", selection = "none", previousAttempts = allAttempts,
		lineageLength = if previous == nil then 1 else previous.lineageLength + 1,
		scheduledSlots = #ordered, restartSlots = #ordered,
		ownership = "Unverified; inspect D05 lease and Studio process state before any new run" }
	end
	return visit(ledgerPath, expectedDigest, 1)
end

return table.freeze({ audit = audit, readCapped = readCapped, MAX_LINEAGE_LENGTH = MAX_LINEAGE_LENGTH })
