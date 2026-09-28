--!strict

-- Offline evidence only. Never installs a codec or changes the benchmark runner.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Result = require("../contracts/result-v2")
local Study = require("./BroadcastStudy")
local Gate = require("./SerializerGate")

local M = {}
local MAX_BYTES = 128 * 1024 * 1024

local function artifactBytes(path: string): (any, string)
	local bytes = fs.readFile(path)
	assert(#bytes <= MAX_BYTES, "artifact exceeds 128 MiB")
	return { path = path, sha256 = "sha256:" .. serde.hash("sha256", bytes), size = #bytes }, bytes
end

function M.artifact(path: string): any
	local record = artifactBytes(path)
	return record
end

local function verified(root: string, reference: any): (string, string)
	assert(type(reference) == "table" and type(reference.path) == "string", "missing artifact reference")
	local path = reference.path
	if not string.match(path, "^%a:[/\\]") and string.sub(path, 1, 1) ~= "/" then path = root .. "/" .. path end
	local actual, bytes = artifactBytes(path)
	assert(actual.sha256 == reference.sha256 and actual.size == reference.size, "artifact hash/size mismatch: " .. path)
	return path, bytes
end

M.verified = verified

local function json(root: string, reference: any): any
	local _, bytes = verified(root, reference)
	assert(reference.size <= Result.MAX_JSON_BYTES, "JSON evidence too large")
	return serde.decode("json", bytes)
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function denseArray(value: any, expectedCount: number?, message: string): number
	assert(type(value) == "table", message)
	local count, maximum = 0, 0
	for key in value do
		assert(type(key) == "number" and key % 1 == 0 and key >= 1, message)
		count += 1
		maximum = math.max(maximum, key)
	end
	local length = expectedCount or count
	assert(count == length and maximum == length, message)
	for index = 1, length do assert(rawget(value, index) ~= nil, message) end
	return length
end

local function samples(result: any, id: string): { number }
	for _, metric in result.measurements do
		if metric.metadata.id == id then
			assert(metric.state == "Available", "unavailable measurement: " .. id)
			local values = {}
			for _, group in metric.rawSamples do
				for _, value in group.values do table.insert(values, value) end
			end
			return values
		end
	end
	error("missing measurement: " .. id, 0)
end

-- tshark outputs one row per captured frame. A frame is counted once even if
-- the protocol viewer also exposes nested packets/items. Both directions at a
-- single capture point include ACK/retransmission cost without adding Tx+Rx.
function M.wireTotals(tsv: string, windows: any, streams: any?): any
	local windowCount = denseArray(windows, nil, "invalid wire windows")
	assert(windowCount > 0 and windowCount <= 30, "invalid wire windows")
	local totals = table.create(windowCount, 0)
	local seenStreams = {}
	local previousFinish = -math.huge
	for index = 1, windowCount do
		local window = windows[index]
		seenStreams[index] = {}
		assert(finite(window.startUnix) and finite(window.finishUnix)
			and window.startUnix < window.finishUnix and window.startUnix >= previousFinish, "overlapping/invalid wire windows")
		assert(finite(window.delivered) and window.delivered > 0 and window.delivered % 1 == 0, "invalid wire denominator")
		previousFinish = window.finishUnix
	end
	local previousFrame, previousTime = 0, -math.huge
	local interface, encapsulation
	local packetCount = 0
	for line in string.gmatch(tsv, "[^\r\n]+") do
		local fields = string.split(line, "\t")
		assert(#fields == 7, "incomplete packet fields")
		local frame, timestamp, length, captured = tonumber(fields[1]), tonumber(fields[2]), tonumber(fields[3]), tonumber(fields[4])
		assert(finite(frame) and frame > previousFrame and frame % 1 == 0, "duplicate/unordered capture frame")
		assert(finite(timestamp) and timestamp >= previousTime, "invalid/unordered capture timestamp")
		assert(finite(length) and length > 0 and length % 1 == 0 and length == captured, "truncated/invalid captured frame")
		assert(fields[5] ~= "" and fields[6] ~= "", "missing capture interface/encapsulation")
		local stream = tonumber(fields[7])
		assert(finite(stream) and stream >= 0 and stream % 1 == 0 and (streams == nil or streams[stream]), "unqualified UDP connection")
		interface, encapsulation = interface or fields[5], encapsulation or fields[6]
		assert(interface == fields[5] and encapsulation == fields[6], "mixed interfaces/encapsulations can double count traffic")
		previousFrame, previousTime = frame, timestamp
		for index = 1, windowCount do
			local window = windows[index]
			if timestamp >= window.startUnix and timestamp < window.finishUnix then
				totals[index] += length
				seenStreams[index][stream] = true
				packetCount += 1
				break
			end
		end
	end
	local bytes, deliveries = 0, 0
	for index = 1, windowCount do
		local total = totals[index]
		assert(total > 0, "wire window has no captured traffic")
		if streams then
			for stream in streams do assert(seenStreams[index][stream], "capture window misses a recipient connection") end
		end
		bytes += total
		deliveries += windows[index].delivered
	end
	return { bytes = bytes, deliveries = deliveries, packets = packetCount,
		bytesPerDelivery = bytes / deliveries, interface = interface, encapsulation = encapsulation }
end

local function cost(root: string, receipt: any, result: any, side: string): any
	assert(receipt.runId == result.runId and receipt.adapterFingerprint == result.benchmark.source.adapterFingerprint
		and receipt.measurementFingerprint == result.benchmark.source.measurementFingerprint, side .. " evidence belongs to different code/run")
	local isSender = side == "sender"
	assert(receipt.scope == (if isSender then "send-through-engine-serialization" else "engine-deserialization-through-dispatch")
		and receipt.unit == (if isSender then "microsecondsPerSubmissionWindowMean" else "microsecondsPerDeliveryWindowMean"),
		side .. " evidence must include engine work, with window means labeled")
	verified(root, receipt.rawProfile)
	verified(root, receipt.accountingReview)
	local recipients = if isSender or result.case.workloadId == "state-burst-c2s" then 1 else result.case.recipientCount
	denseArray(receipt.participants, recipients, "missing receiver participant")
	local values = {}
	local counts = samples(result, if isSender then "submitted" else "correct")
	for index = 1, recipients do
		local participant = receipt.participants[index]
		assert(participant.index == index, "receiver windows/identity mismatch")
		denseArray(participant.windows, result.case.completedRepetitions, "receiver windows/identity mismatch")
		for windowIndex = 1, result.case.completedRepetitions do
			local window = participant.windows[windowIndex]
			local correct = counts[windowIndex] / recipients
			assert(window.messages == correct, "cost denominator differs from verified message count")
			assert(finite(window.totalMicroseconds) and window.totalMicroseconds > 0, "invalid receiver cost")
			table.insert(values, window.totalMicroseconds / window.messages)
		end
	end
	return Gate.summary(values)
end

local function network(root: string, receipt: any, result: any, tshark: string?): any
	assert(receipt.runId == result.runId and receipt.adapterFingerprint == result.benchmark.source.adapterFingerprint
		and receipt.measurementFingerprint == result.benchmark.source.measurementFingerprint,
		"network evidence belongs to different code/run")
	assert(receipt.scope == "isolated-connection-bidirectional" and receipt.layer == "captured-frame"
		and receipt.droppedPackets == 0 and receipt.captureComplete == true, "unqualified capture accounting")
	local connectionCount = if result.case.workloadId == "state-broadcast-s2c" then result.case.recipientCount else 1
	denseArray(receipt.connections, connectionCount, "missing recipient connections")
	local streams, filters = {}, {}
	for index = 1, connectionCount do
		local connection = receipt.connections[index]
		local stream = connection.udpStream
		assert(connection.participantIndex == index and finite(stream) and stream >= 0
			and stream <= 65535 and stream % 1 == 0 and not streams[stream], "invalid/duplicate recipient connection")
		streams[stream] = true
		table.insert(filters, `udp.stream == {stream}`)
	end
	local correct = samples(result, "correct")
	denseArray(receipt.windows, #correct, "capture does not cover every measured window")
	for index = 1, #correct do
		local window = receipt.windows[index]
		assert(window.delivered == correct[index], "wire denominator differs from delivery proof")
	end
	assert(tshark ~= nil, "packet capture requires --tshark <absolute executable>")
	assert(M.artifact(tshark).sha256 == receipt.decoderSha256, "packet decoder changed")
	verified(root, receipt.boundaryEvidence)
	verified(root, receipt.accountingReview)
	local capture = verified(root, receipt.capture)
	local decoded = process.exec(tshark, { "-n", "-r", capture, "-Y", table.concat(filters, " or "),
		"-T", "fields", "-E", "separator=/t", "-E", "occurrence=f",
		"-e", "frame.number", "-e", "frame.time_epoch", "-e", "frame.len", "-e", "frame.cap_len",
		"-e", "frame.interface_id", "-e", "frame.encap_type", "-e", "udp.stream" })
	assert(decoded.ok and #decoded.stdout <= 16 * 1024 * 1024, "packet decoding failed/too large")
	verified(root, receipt.capture)
	assert(M.artifact(tshark).sha256 == receipt.decoderSha256, "packet decoder changed during extraction")
	local totals = M.wireTotals(decoded.stdout, receipt.windows, streams)
	assert(totals.deliveries == result.counts.correct, "capture misses delivered messages")
	return totals
end

function M.load(root: string, entry: any, planHash: string, tshark: string?): any
	local row: any = { caseId = entry.caseId, pass = entry.pass, role = entry.role, metrics = {}, issues = {} }
	local ok, message = pcall(function()
		local result = Result.validate(json(root, entry.result))
		local session = entry.session
		assert(type(session) == "table" and session.planSha256 == planHash
			and finite(session.startedUnix) and finite(session.finishedUnix)
			and session.startedUnix < session.finishedUnix, "missing predeclared session receipt")
		verified(root, session.hostLog)
		verified(root, session.environmentReview)
		row.startedUnix, row.finishedUnix = session.startedUnix, session.finishedUnix
		assert(result.status == "Valid" and result.benchmark.source.dirty == false, "invalid/dirty canonical result")
		assert(result.case.scheduledRepetitions == 30 and result.case.startedRepetitions == 30
			and result.case.completedRepetitions == 30, "gate requires 30 complete windows per session")
		assert(result.adapter.id == "relay-reliable" and result.adapter.lane == "EquivalentSemantics"
			and result.adapter.semantics.broadcastMode == "NativeBroadcast", "incompatible Relay semantics")
		assert((result.case.workloadId or result.case.probeId) == entry.caseId, "wrong workload/probe")
		assert(result.environment.execution.clientCount == (if entry.caseId == "state-broadcast-s2c" then 8 else 1),
			"gate requires eight broadcast recipients, one C2S/RTT client")
		local source = result.benchmark.source
		row.runId, row.revision = result.runId, source.revision
		row.adapterFingerprint, row.measurementFingerprint = source.adapterFingerprint, source.measurementFingerprint
		row.compatibilityKey = Study.compatibilityKey(result)
		local latency = Gate.summary(samples(result, if entry.caseId == "tiny-round-trip" then "roundTripLatency" else "drainDuration"))
		row.metrics.latencyP95Ms, row.metrics.latencyP99Ms = latency.p95, latency.p99
		if entry.caseId == "tiny-round-trip" then return end
		row.delivered = result.counts.correct
		local sender = Gate.summary(samples(result, "submitCallDuration"))
		row.publicCall = sender -- Synchronous API cost, separate from whole sender work.
		local completion = samples(result, "completionDuration")
		local elapsed = 0
		for _, milliseconds in completion do elapsed += milliseconds / 1000 end
		row.metrics.deliveredPerSecond = result.counts.correct / elapsed
		local receipt = json(root, entry.supplement)
		assert(receipt.schema == "Relay.SerializerSupplement" and receipt.version == 1 and receipt.planSha256 == planHash,
			"supplement does not bind this predeclared plan")
		local senderCost = cost(root, receipt.sender, result, "sender")
		row.metrics.senderMedianUs, row.metrics.senderP95Us = senderCost.median, senderCost.p95
		local receiverCost = cost(root, receipt.receiver, result, "receiver")
		row.metrics.receiverMedianUs, row.metrics.receiverP95Us = receiverCost.median, receiverCost.p95
		local traffic = network(root, receipt.network, result, tshark)
		for index = 1, result.case.completedRepetitions do
			local window = receipt.network.windows[index]
			assert(window.startUnix >= session.startedUnix and window.finishUnix <= session.finishedUnix,
				"capture window falls outside its session")
		end
		row.network = traffic
		row.metrics.wireBytesPerDelivery = traffic.bytesPerDelivery
		row.compatibilityKey ..= "|" .. receipt.network.decoderSha256 .. "|" .. traffic.encapsulation
	end)
	if not ok then table.insert(row.issues, tostring(message)) end
	return row
end

return table.freeze(M)
