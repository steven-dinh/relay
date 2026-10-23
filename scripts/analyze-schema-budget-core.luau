local function diagnostic(code, path, message)
	return { severity = "error", code = code, path = path, message = message }
end

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function sortedDiagnostics(diagnostics)
	table.sort(diagnostics, function(left, right)
		if left.path == right.path then
			if left.code == right.code then return left.message < right.message end
			return left.code < right.code
		end
		return left.path < right.path
	end)
end

local function checkKeys(value, allowed, path, diagnostics)
	for key in value do
		if allowed[key] ~= true then
			table.insert(diagnostics, diagnostic("UnexpectedWorkloadField", path .. "." .. tostring(key),
				"field is not supported"))
		end
	end
end

local function validateRate(value, path, diagnostics)
	if not finite(value) or value < 0 then
		table.insert(diagnostics, diagnostic("InvalidRate", path, "must be a finite non-negative number"))
		return false
	end
	return true
end

local function validateRecipients(value, path, expected, diagnostics)
	if not finite(value) or value < 0 or value % 1 ~= 0 or (expected ~= nil and value ~= expected) then
		local reason = if expected ~= nil then "must be the integer 1" else "must be a non-negative integer"
		table.insert(diagnostics, diagnostic("InvalidRecipients", path, reason))
		return false
	end
	return true
end

local function validateWorkload(report, workload, diagnostics)
	if not plain(workload) then
		table.insert(diagnostics, diagnostic("InvalidWorkload", "workload", "must return a plain table"))
		return nil
	end
	checkKeys(workload, { events = true, requests = true }, "workload", diagnostics)

	local assumptions = {}
	for _, kind in { "events", "requests" } do
		local configured = workload[kind]
		if not plain(configured) then
			table.insert(diagnostics, diagnostic("InvalidWorkloadTable", "workload." .. kind,
				"must be a plain table keyed by exact endpoint name"))
			continue
		end
		local inspected = report[kind]
		for name, endpoint in inspected do
			local path = "workload." .. kind .. "." .. name
			local assumption = configured[name]
			if assumption == nil then
				table.insert(diagnostics, diagnostic("MissingEndpointAssumption", path,
					"every inspected endpoint requires an explicit workload assumption, including zero frequency"))
				continue
			elseif not plain(assumption) then
				table.insert(diagnostics, diagnostic("InvalidEndpointAssumption", path, "must be a plain table"))
				continue
			end

			local allowed = if kind == "events"
				then { sendsPerSecond = true, recipients = true, path = true }
				else { callsPerSecond = true, recipients = true }
			checkKeys(assumption, allowed, path, diagnostics)
			local rateKey = if kind == "events" then "sendsPerSecond" else "callsPerSecond"
			local rateValid = validateRate(assumption[rateKey], path .. "." .. rateKey, diagnostics)
			local recipientsValid = validateRecipients(assumption.recipients, path .. ".recipients",
				if kind == "requests" or endpoint.direction == "ClientToServer" then 1 else nil, diagnostics)
			local selectedPath = assumption.path
			local pathValid = true
			if kind == "events" and selectedPath ~= "Immediate" and selectedPath ~= "QueuedSingleRecord" then
				table.insert(diagnostics, diagnostic("InvalidPath", path .. ".path",
					"must be Immediate or QueuedSingleRecord"))
				pathValid = false
			end
			if kind == "events" and selectedPath == "QueuedSingleRecord" and endpoint.queuedBytes == nil then
				table.insert(diagnostics, diagnostic("QueuedPathUnavailable", path .. ".path",
					"the inspector does not report queued bytes for this event"))
				pathValid = false
			end
			if rateValid and recipientsValid and pathValid then
				assumptions[kind .. "." .. name] = {
					kind = kind,
					name = name,
					endpoint = endpoint,
					rate = assumption[rateKey],
					recipients = assumption.recipients,
					path = selectedPath,
				}
			end
		end
		for name in configured do
			if type(name) ~= "string" or inspected[name] == nil then
				table.insert(diagnostics, diagnostic("UnexpectedEndpointAssumption",
					"workload." .. kind .. "." .. tostring(name),
					"endpoint name is not present in the inspected schema"))
			end
		end
	end
	return assumptions
end

local function unknownRange()
	return { minimum = "Unknown", maximum = "Unknown" }
end

local function readRange(value)
	if type(value) ~= "table" or value.representation ~= "RelayBuffer"
		or not finite(value.minimum) or not finite(value.maximum)
		or value.minimum < 0 or value.maximum < value.minimum then
		return unknownRange()
	end
	return { minimum = value.minimum, maximum = value.maximum }
end

local function plusRange(left, right, path, diagnostics)
	if left.minimum == "Unknown" or right.minimum == "Unknown" then return unknownRange() end
	local minimum, maximum = left.minimum + right.minimum, left.maximum + right.maximum
	if not finite(minimum) or not finite(maximum) then
		table.insert(diagnostics, diagnostic("NumericOverflow", path, "byte range arithmetic is not finite"))
		return nil
	end
	return { minimum = minimum, maximum = maximum }
end

local function scaleRange(value, rate, recipients, path, diagnostics)
	if rate == 0 or recipients == 0 then return { minimum = 0, maximum = 0 } end
	if value.minimum == "Unknown" or value.maximum == "Unknown" then return unknownRange() end
	local minimum = (value.minimum * rate) * recipients
	local maximum = (value.maximum * rate) * recipients
	if not finite(minimum) or not finite(maximum) then
		table.insert(diagnostics, diagnostic("NumericOverflow", path, "bytes per second arithmetic is not finite"))
		return nil
	end
	return { minimum = minimum, maximum = maximum }
end

local function eventRanges(assumption)
	local endpoint = assumption.endpoint
	if assumption.path == "QueuedSingleRecord" then
		local queued = endpoint.queuedBytes
		return readRange({
			representation = "RelayBuffer",
			minimum = queued.bodyMinimum,
			maximum = queued.bodyMaximum,
		}), readRange({
			representation = "RelayBuffer",
			minimum = queued.singleRecordMinimum,
			maximum = queued.singleRecordMaximum,
		})
	end
	local inspected = readRange(endpoint.bytes)
	return inspected, inspected
end

local function rpcRanges(endpoint, envelopeBytes, path, diagnostics)
	local requestPayload = readRange(endpoint.request and endpoint.request.bytes)
	local responsePayload = readRange(endpoint.response and endpoint.response.bytes)
	local payload = plusRange(requestPayload, responsePayload, path .. ".payloadBytes", diagnostics)
	if payload == nil then return nil end
	if not finite(envelopeBytes) or envelopeBytes < 0 then return payload, unknownRange(), requestPayload, responsePayload end

	local requestBuffer = plusRange(requestPayload,
		{ minimum = envelopeBytes, maximum = envelopeBytes }, path .. ".requestBufferBytes", diagnostics)
	local responseBuffer = plusRange(responsePayload,
		{ minimum = envelopeBytes, maximum = envelopeBytes }, path .. ".responseBufferBytes", diagnostics)
	if requestBuffer == nil or responseBuffer == nil then return nil end
	local buffer = plusRange(requestBuffer, responseBuffer, path .. ".relayBufferBytes", diagnostics)
	return payload, buffer, requestPayload, responsePayload, requestBuffer, responseBuffer
end

local function analyze(report, workload, maximumBytesPerSecond)
	local diagnostics = {}
	if type(report) ~= "table" or type(report.events) ~= "table" or type(report.requests) ~= "table" then
		return nil, { diagnostic("InvalidInspection", "definition", "inspector output is incomplete") }
	end
	if maximumBytesPerSecond ~= nil and (not finite(maximumBytesPerSecond) or maximumBytesPerSecond < 0) then
		table.insert(diagnostics, diagnostic("InvalidBudget", "maximumBytesPerSecond",
			"must be a finite non-negative number"))
	end
	local assumptions = validateWorkload(report, workload, diagnostics)
	if #diagnostics > 0 then
		sortedDiagnostics(diagnostics)
		return nil, diagnostics
	end

	local rows, aggregatePayload, aggregateBuffer = {}, { minimum = 0, maximum = 0 }, { minimum = 0, maximum = 0 }
	for _, kind in { "events", "requests" } do
		for name, endpoint in report[kind] do
			local key = kind .. "." .. name
			local assumption = assumptions[key]
			local payload, relayBuffer, row = nil, nil, nil
			if kind == "events" then
				payload, relayBuffer = eventRanges(assumption)
				local payloadRate = scaleRange(payload, assumption.rate, assumption.recipients,
					key .. ".payloadBytesPerSecond", diagnostics)
				local bufferRate = scaleRange(relayBuffer, assumption.rate, assumption.recipients,
					key .. ".relayBufferBytesPerSecond", diagnostics)
				if payloadRate == nil or bufferRate == nil then
					sortedDiagnostics(diagnostics)
					return nil, diagnostics
				end
				row = {
					kind = "event",
					name = name,
					id = endpoint.id,
					direction = endpoint.direction,
					delivery = endpoint.delivery,
					representation = if assumption.path == "QueuedSingleRecord" then "RelayBuffer"
						else endpoint.bytes.representation,
					path = assumption.path,
					sendsPerSecond = assumption.rate,
					recipients = assumption.recipients,
					payloadBytes = payload,
					relayBufferBytes = relayBuffer,
					payloadBytesPerSecond = payloadRate,
					relayBufferBytesPerSecond = bufferRate,
					robloxEncodedBytes = "Unknown",
				}
				aggregatePayload = plusRange(aggregatePayload, payloadRate, "aggregate.payloadBytesPerSecond", diagnostics)
				aggregateBuffer = plusRange(aggregateBuffer, bufferRate, "aggregate.relayBufferBytesPerSecond", diagnostics)
			else
				local envelopeBytes = report.limits and report.limits.rpcEnvelopeBytes
				local requestPayload, responsePayload, requestBuffer, responseBuffer
				payload, relayBuffer, requestPayload, responsePayload, requestBuffer, responseBuffer =
					rpcRanges(endpoint, envelopeBytes, key, diagnostics)
				if payload == nil or relayBuffer == nil then
					sortedDiagnostics(diagnostics)
					return nil, diagnostics
				end
				local payloadRate = scaleRange(payload, assumption.rate, 1,
					key .. ".payloadBytesPerSecond", diagnostics)
				local bufferRate = scaleRange(relayBuffer, assumption.rate, 1,
					key .. ".relayBufferBytesPerSecond", diagnostics)
				if payloadRate == nil or bufferRate == nil then
					sortedDiagnostics(diagnostics)
					return nil, diagnostics
				end
				row = {
					kind = "request",
					direction = endpoint.direction,
					name = name,
					id = endpoint.id,
					callsPerSecond = assumption.rate,
					recipients = 1,
					requestPayloadBytes = requestPayload,
					responsePayloadBytes = responsePayload,
					requestRelayBufferBytes = requestBuffer,
					responseRelayBufferBytes = responseBuffer,
					payloadBytes = payload,
					relayBufferBytes = relayBuffer,
					payloadBytesPerSecond = payloadRate,
					relayBufferBytesPerSecond = bufferRate,
					rpcEnvelopeBytesAppliedPerLeg = envelopeBytes,
					robloxEncodedBytes = "Unknown",
				}
				aggregatePayload = plusRange(aggregatePayload, payloadRate, "aggregate.payloadBytesPerSecond", diagnostics)
				aggregateBuffer = plusRange(aggregateBuffer, bufferRate, "aggregate.relayBufferBytesPerSecond", diagnostics)
			end
			if aggregatePayload == nil or aggregateBuffer == nil then
				sortedDiagnostics(diagnostics)
				return nil, diagnostics
			end
			rows[key] = row
		end
	end

	local result = {
		mode = "boundedRelayBufferEstimate",
		units = "Relay buffer bytes; recipient-weighted bytes per second",
		endpoints = rows,
		aggregate = {
			payloadBytesPerSecond = aggregatePayload,
			relayBufferBytesPerSecond = aggregateBuffer,
			robloxEncodedBytes = "Unknown",
		},
		limitations = "NativeTuple sizes, Roblox-encoded bytes, and physical wire bytes are Unknown; compression and Instance-reference sidecar admission charges are excluded. Rates are explicit post-coalescing sends and successful RPC calls.",
	}
	if maximumBytesPerSecond ~= nil then
		local status = "passed"
		if aggregateBuffer.maximum == "Unknown" then
			status = "unknown"
			table.insert(diagnostics, diagnostic("BudgetUnknown", "maximumBytesPerSecond",
				"active endpoint size is Unknown, so the Relay buffer byte budget cannot be checked"))
		elseif aggregateBuffer.maximum > maximumBytesPerSecond then
			status = "exceeded"
			table.insert(diagnostics, diagnostic("BudgetExceeded", "maximumBytesPerSecond",
				"aggregate maximum Relay buffer bytes per second exceeds the inclusive budget"))
		end
		result.budget = {
			maximumRelayBufferBytesPerSecond = maximumBytesPerSecond,
			status = status,
		}
	end
	sortedDiagnostics(diagnostics)
	return result, diagnostics
end

return table.freeze({ analyze = analyze })
