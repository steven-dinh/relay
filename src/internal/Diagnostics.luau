local COUNTER_LIMIT = 4_294_967_295

local SESSION_COUNTERS = table.freeze({
    "received",
    "ineligible",
    "perPlayerRate",
    "aggregateRate",
    "perPlayerBytes",
    "aggregateBytes",
    "endpointRate",
    "invalidEndpoint",
    "wrongChannel",
    "noListener",
    "busy",
    "invalidPayload",
    "stale",
    "dispatched",
    "handlerErrors",
    "sendHandoffs",
    "broadcastHandoffs",
    "transportFailures",
    "transportLosses",
    "outboundByteRejected",
    "outboundBytesCharged",
})

local EVENT_COUNTERS = table.freeze({
    "noListener",
    "busy",
    "invalidPayload",
    "stale",
    "endpointRate",
    "dispatched",
    "handlerErrors",
    "sendHandoffs",
    "broadcastHandoffs",
    "transportFailures",
})

local TRAFFIC_COUNTERS = table.freeze({
    "submittedRecords",
    "submittedBytes",
    "sentPackets",
    "sentRecords",
    "sentBytes",
    "sentRecipientBytes",
    "receivedPackets",
    "receivedBytes",
    "validatedRecords",
    "validatedBytes",
    "unmeasuredPackets",
})

local TRAFFIC_COUNTER_SET = table.freeze({
    submittedRecords = true,
    submittedBytes = true,
    sentPackets = true,
    sentRecords = true,
    sentBytes = true,
    sentRecipientBytes = true,
    receivedPackets = true,
    receivedBytes = true,
    validatedRecords = true,
    validatedBytes = true,
    unmeasuredPackets = true,
})

local REPORT_CAPACITY = 16
local REFERENCE_BYTES = 8
local REPORT_REASONS = table.freeze({
    PerPlayerRateLimited = true,
    AggregateRateLimited = true,
    EndpointRateLimited = true,
    PerPlayerByteLimited = true,
    AggregateByteLimited = true,
    InvalidEndpoint = true,
    WrongChannel = true,
    Ineligible = true,
    NoListener = true,
    Busy = true,
    InvalidPayload = true,
    Stale = true,
    TransportFailure = true,
    TransportLoss = true,
    HandlerError = true,
    QueueFull = true,
    QueueLimit = true,
    QueueBusy = true,
    OutboundRateLimited = true,
    QueueClosed = true,
})

local function zeroCounters(names)
    local counters = {}
    for _, name in names do
        counters[name] = 0
    end
    return counters
end

local function copyCounters(source, names)
    local copy = {}
    for _, name in names do
        copy[name] = source[name]
    end
    return table.freeze(copy)
end

local function copyTraffic(traffic)
    local channels = {}
    for channel, row in traffic.channels do
        channels[channel] = copyCounters(row, TRAFFIC_COUNTERS)
    end
    table.freeze(channels)

    local endpoints = {}
    for id, row in traffic.endpoints do
        local endpointChannels = {}
        for channel, counters in row.channels do
            endpointChannels[channel] = copyCounters(counters, TRAFFIC_COUNTERS)
        end
        endpoints[id] = table.freeze({
            id = row.id,
            name = row.name,
            kind = row.kind,
            channels = table.freeze(endpointChannels),
        })
    end
    table.freeze(endpoints)

    return table.freeze({ channels = channels, endpoints = endpoints })
end

local function copyReports(reports)
    local entries = table.create(reports.size)
    local first = if reports.size == REPORT_CAPACITY then reports.next else 1
    for offset = 0, reports.size - 1 do
        local index = (first + offset - 1) % REPORT_CAPACITY + 1
        local entry = reports.entries[index]
        entries[offset + 1] = table.freeze({
            reason = entry.reason,
            endpointId = entry.endpointId,
            channel = entry.channel,
            count = entry.count,
            sequence = entry.sequence,
        })
    end

    return table.freeze({
        capacity = REPORT_CAPACITY,
        total = reports.total,
        entries = table.freeze(entries),
    })
end

local function copyBucket(rate)
    return table.freeze({
        capacity = rate.capacity,
        refillPerSecond = rate.refillPerSecond,
    })
end

local function copyRate(inboundRate)
    if inboundRate == nil then
        return nil
    end

    local endpoints
    if inboundRate.endpoints ~= nil then
        endpoints = {}
        for id, rate in inboundRate.endpoints do
            endpoints[id] = copyBucket(rate)
        end
        table.freeze(endpoints)
    end

    local bytes
    if inboundRate.bytes ~= nil then
        bytes = table.freeze({
            perPlayer = copyBucket(inboundRate.bytes.perPlayer),
            aggregate = copyBucket(inboundRate.bytes.aggregate),
        })
    end

    local fairness
    if inboundRate.fairness ~= nil then
        fairness = table.freeze({
            maxPeers = inboundRate.fairness.maxPeers,
            reserve = copyBucket(inboundRate.fairness.reserve),
        })
    end

    return table.freeze({
        perPlayer = copyBucket(inboundRate.perPlayer),
        aggregate = copyBucket(inboundRate.aggregate),
        endpoints = endpoints,
        bytes = bytes,
        fairness = fairness,
    })
end

local function copyHandlerLimits(handlerLimits)
    return table.freeze(table.clone(handlerLimits))
end

local function create(events, side, inboundRate, handlerLimits, outboundBytes, requests, options)
    local eventCounters, countersById = {}, {}
    for name, event in events do
        local row = zeroCounters(EVENT_COUNTERS)
        eventCounters[name] = row
        countersById[event.id] = row
    end

    local traffic
    if options ~= nil and options.traffic == true then
        local channels = {
            Reliable = zeroCounters(TRAFFIC_COUNTERS),
            Unreliable = zeroCounters(TRAFFIC_COUNTERS),
        }
        local endpoints, trafficById = {}, {}

        local function addEndpoints(declared, kind)
            if declared == nil then return end
            for name, endpoint in declared do
                local row = {
                    id = endpoint.id,
                    name = name,
                    kind = kind,
                    channels = {
                        Reliable = zeroCounters(TRAFFIC_COUNTERS),
                        Unreliable = zeroCounters(TRAFFIC_COUNTERS),
                    },
                }
                endpoints[endpoint.id] = row
                trafficById[endpoint.id] = row
            end
        end

        addEndpoints(events, "Event")
        addEndpoints(requests, "Request")
        traffic = { channels = channels, endpoints = endpoints, byId = trafficById }
    end

    local reports
    if options ~= nil and options.reports == true then
        local entries = table.create(REPORT_CAPACITY)
        for index = 1, REPORT_CAPACITY do
            entries[index] = { reason = nil, endpointId = nil, channel = nil, count = 0, sequence = 0 }
        end
        reports = { total = 0, size = 0, next = 1, sequence = 0, entries = entries }
    end

    return {
        side = side,
        counters = zeroCounters(SESSION_COUNTERS),
        events = eventCounters,
        byId = countersById,
        inboundRate = copyRate(inboundRate),
        outboundBytes = if outboundBytes == nil then nil else copyBucket(outboundBytes),
        handlerLimits = copyHandlerLimits(handlerLimits),
        traffic = traffic,
        reports = reports,
    }
end

local function increment(counters, name)
    local value = counters[name]
    if value < COUNTER_LIMIT then
        counters[name] = value + 1
    end
end

local function add(counters, name, amount)
    local value = counters[name]
    if amount >= COUNTER_LIMIT - value then
        counters[name] = COUNTER_LIMIT
    else
        counters[name] = value + amount
    end
end

local function addTraffic(diagnostics, endpointId, channel, name, amount)
    local traffic = diagnostics.traffic
    if traffic == nil or TRAFFIC_COUNTER_SET[name] ~= true
        or (channel ~= "Reliable" and channel ~= "Unreliable")
        or type(amount) ~= "number" or amount < 0 or amount % 1 ~= 0 then
        return
    end

    local channelCounters = traffic.channels[channel]
    local endpoint
    if endpointId ~= nil then
        endpoint = traffic.byId[endpointId]
    end

    add(channelCounters, name, amount)
    if endpoint ~= nil then
        add(endpoint.channels[channel], name, amount)
    end
end

local function recordSubmitted(diagnostics, endpointId, channel, bytes)
	if diagnostics == nil or diagnostics.traffic == nil then return end
	addTraffic(diagnostics, endpointId, channel, "submittedRecords", 1)
	if bytes ~= nil then addTraffic(diagnostics, endpointId, channel, "submittedBytes", bytes) end
end

local function recordValidated(diagnostics, endpointId, channel, bytes)
	if diagnostics == nil or diagnostics.traffic == nil then return end
	addTraffic(diagnostics, endpointId, channel, "validatedRecords", 1)
	if bytes ~= nil then addTraffic(diagnostics, endpointId, channel, "validatedBytes", bytes) end
end

local function observeEndpoint(diagnostics, endpointId, channel, bytes)
	local traffic = if diagnostics == nil then nil else diagnostics.traffic
	local endpoint = if traffic == nil then nil else traffic.byId[endpointId]
	if endpoint == nil or (channel ~= "Reliable" and channel ~= "Unreliable") then return end
	local counters = endpoint.channels[channel]
	add(counters, "receivedPackets", 1)
	if bytes == nil then
		add(counters, "unmeasuredPackets", 1)
	else
		add(counters, "receivedBytes", bytes)
	end
end

local function rowBody(row)
	if typeof(row) == "buffer" then return row end
	return row.body
end

local function rowEndpointId(row, body)
	local endpointId = if typeof(row) == "table" then row.endpointId else nil
	return if type(endpointId) == "number" then endpointId else buffer.readu16(body, 1)
end

local function rowUnits(row, body)
	local units = if typeof(row) == "table" then row.units else nil
	if type(units) == "number" then return units end
	local referenceCount = if buffer.readu8(body, 0) == 4 then buffer.readu8(body, 3) else 0
	return buffer.len(body) + referenceCount * REFERENCE_BYTES
end

local function recordSentPacket(diagnostics, channel, packet, references, rows, rowCount, handoffs, recipients)
	local traffic = diagnostics.traffic
	if traffic == nil or rowCount <= 0 or handoffs <= 0 then return end
	local referenceCount = if references == nil then 0 else references.n
	local packetBytes = buffer.len(packet) + referenceCount * REFERENCE_BYTES
	addTraffic(diagnostics, nil, channel, "sentPackets", handoffs)
	addTraffic(diagnostics, nil, channel, "sentRecords", handoffs * rowCount)
	addTraffic(diagnostics, nil, channel, "sentBytes", handoffs * packetBytes)
	addTraffic(diagnostics, nil, channel, "sentRecipientBytes", recipients * packetBytes)

	for index = 1, rowCount do
		local row = rows[index]
		local body = rowBody(row)
		local endpointId = rowEndpointId(row, body)
		local endpoint = traffic.byId[endpointId]
		if endpoint ~= nil then
			local first = true
			for previous = 1, index - 1 do
				local previousRow = rows[previous]
				local previousId = rowEndpointId(previousRow, rowBody(previousRow))
				if previousId == endpointId then first = false; break end
			end
			local counters = endpoint.channels[channel]
			local bytes = rowUnits(row, body)
			if first then add(counters, "sentPackets", handoffs) end
			add(counters, "sentRecords", handoffs)
			add(counters, "sentBytes", handoffs * bytes)
			add(counters, "sentRecipientBytes", recipients * bytes)
		end
	end
end

local function recordSentSingle(diagnostics, endpointId, channel, packetBytes, endpointBytes, handoffs, recipients)
	if diagnostics == nil or diagnostics.traffic == nil or handoffs <= 0 then return end
	addTraffic(diagnostics, nil, channel, "sentPackets", handoffs)
	addTraffic(diagnostics, nil, channel, "sentRecords", handoffs)
	if packetBytes ~= nil then
		addTraffic(diagnostics, nil, channel, "sentBytes", handoffs * packetBytes)
		if recipients ~= nil then
			addTraffic(diagnostics, nil, channel, "sentRecipientBytes", recipients * packetBytes)
		end
	end
	local endpoint = diagnostics.traffic.byId[endpointId]
	if endpoint == nil then return end
	local counters = endpoint.channels[channel]
	add(counters, "sentPackets", handoffs)
	add(counters, "sentRecords", handoffs)
	if endpointBytes ~= nil then
		add(counters, "sentBytes", handoffs * endpointBytes)
		if recipients ~= nil then
			add(counters, "sentRecipientBytes", recipients * endpointBytes)
		end
	end
end

local function recordReceivedRows(diagnostics, channel, rows)
	local traffic = if diagnostics == nil then nil else diagnostics.traffic
	if traffic == nil then return end
	for index, row in rows do
		local endpoint = traffic.byId[row.event.id]
		if endpoint ~= nil then
			local first = true
			for previous = 1, index - 1 do
				if rows[previous].event.id == row.event.id then first = false; break end
			end
			if first then add(endpoint.channels[channel], "receivedPackets", 1) end
			add(endpoint.channels[channel], "receivedBytes", row.length + row.referenceCount * REFERENCE_BYTES)
		end
	end
end

local function report(diagnostics, reason, endpointId, channel)
    local reports = diagnostics.reports
    if reports == nil or REPORT_REASONS[reason] ~= true
        or (channel ~= nil and channel ~= "Reliable" and channel ~= "Unreliable")
        or (endpointId ~= nil and (type(endpointId) ~= "number" or endpointId % 1 ~= 0
            or endpointId < 1 or endpointId > 65_535)) then
        return
    end

    add(reports, "total", 1)
    for _, entry in reports.entries do
        if entry.reason == reason and entry.endpointId == endpointId and entry.channel == channel then
            add(entry, "count", 1)
            return
        end
    end

    local entry = reports.entries[reports.next]
    add(reports, "sequence", 1)
    entry.reason = reason
    entry.endpointId = endpointId
    entry.channel = channel
    entry.count = 1
    entry.sequence = reports.sequence
    if reports.size < REPORT_CAPACITY then
        reports.size += 1
    end
    reports.next = reports.next % REPORT_CAPACITY + 1
end

local function snapshot(diagnostics, state, inFlight)
    local events = {}
    for name, row in diagnostics.events do
        events[name] = copyCounters(row, EVENT_COUNTERS)
    end

    local result = {
        side = diagnostics.side,
        state = state,
        counterLimit = COUNTER_LIMIT,
        inFlight = inFlight,
        inboundRate = diagnostics.inboundRate,
        outboundBytes = diagnostics.outboundBytes,
        handlerLimits = diagnostics.handlerLimits,
        counters = copyCounters(diagnostics.counters, SESSION_COUNTERS),
        events = table.freeze(events),
    }
    if diagnostics.traffic ~= nil then
        result.traffic = copyTraffic(diagnostics.traffic)
    end
    if diagnostics.reports ~= nil then
        result.reports = copyReports(diagnostics.reports)
    end
    return table.freeze(result)
end

return table.freeze({
    create = create,
    increment = increment,
    add = add,
    addTraffic = addTraffic,
    recordSubmitted = recordSubmitted,
    recordValidated = recordValidated,
	observeEndpoint = observeEndpoint,
    recordSentPacket = recordSentPacket,
    recordSentSingle = recordSentSingle,
    recordReceivedRows = recordReceivedRows,
    report = report,
    snapshot = snapshot,
})
