--!strict

local EventV1 = require("../contracts/event-v1")
local Identity = require("../contracts/internal/AdapterIdentity")

export type AdapterIdentity = Identity.AdapterIdentity
export type CaseSelection = Identity.CaseSelection
export type Requirement = Identity.Requirement
export type ResolvedSelection = Identity.ResolvedSelection

export type SupportedPreflight = {
	kind: "Supported",
	identity: AdapterIdentity,
	selection: ResolvedSelection,
}

export type PreflightResult =
	SupportedPreflight
	| {
		kind: "Unsupported",
		identity: AdapterIdentity,
		selection: ResolvedSelection,
		missing: { Requirement },
	}

export type LogicalValue = boolean | number | Vector3
export type LogicalPayload = { [string]: LogicalValue }

export type RecordDelivery = {
	kind: "Record",
	value: unknown?,
}

export type PositionalDelivery = {
	kind: "Positional",
	values: { [number]: unknown },
	count: number,
}

export type DeliveryEnvelope = RecordDelivery | PositionalDelivery

export type ClientToServerMetadata<TSender> = {
	kind: "ClientToServer",
	sender: TSender,
}

export type ServerToClientMetadata = {
	kind: "ServerToClient",
}

export type ServerDeliverySink<TSender> = (
	delivery: DeliveryEnvelope,
	metadata: ClientToServerMetadata<TSender>
) -> ()

export type ClientDeliverySink = (
	delivery: DeliveryEnvelope,
	metadata: ServerToClientMetadata
) -> ()

export type EnvelopeFactory = {
	record: (value: unknown) -> RecordDelivery,
	positional: (...unknown) -> PositionalDelivery,
}

export type SubmissionBoundary = "ContinueFrame" | "FlushBeforeReturn"

export type SideLifecycle = {
	setup: () -> (),
	ready: () -> boolean,
	teardown: () -> (),
}

export type ServerSide = SideLifecycle & {
	broadcast: ((payload: LogicalPayload, boundary: SubmissionBoundary) -> ())?,
}

export type ClientSide = SideLifecycle & {
	submit: ((payload: LogicalPayload, boundary: SubmissionBoundary) -> ())?,
}

export type ServerContext<TResource, TSender> = {
	resourceRoot: TResource,
	selection: ResolvedSelection,
	recipients: { TSender },
	envelopes: EnvelopeFactory,
	sink: ServerDeliverySink<TSender>,
}

export type ClientContext<TResource> = {
	resourceRoot: TResource,
	selection: ResolvedSelection,
	participantIndex: number,
	envelopes: EnvelopeFactory,
	sink: ClientDeliverySink,
}

export type AdapterFactory<TResource, TSender> = {
	constructServer: (context: ServerContext<TResource, TSender>) -> ServerSide,
	constructClient: (context: ClientContext<TResource>) -> ClientSide,
}

type LifecycleState =
	"Constructed"
	| "SettingUp"
	| "AwaitingReady"
	| "Ready"
	| "SetupFailed"
	| "ExecutionFailed"
	| "TearingDown"
	| "TornDown"

local supportedPreflights: { [any]: boolean } = setmetatable({}, { __mode = "k" })

local function fail(code: string)
	error(code, 0)
end

local function isStudioVersion(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 64
		and string.match(value, "^[A-Za-z0-9._%-]+$") ~= nil
end

local function requireSupported(candidate: unknown): SupportedPreflight
	if type(candidate) ~= "table" or rawget(supportedPreflights, candidate) ~= true then
		fail("ADAPTER_E_PREFLIGHT")
	end

	return candidate :: any
end

local function recordDelivery(value: unknown?): RecordDelivery
	local delivery: any
	if value == nil then
		delivery = { kind = "Record" }
	else
		delivery = { kind = "Record", value = value }
	end

	table.freeze(delivery)
	return delivery
end

local function selectedFieldCount(supported: SupportedPreflight): number
	local selection = supported.selection
	local payload = rawget(EventV1.payloads, selection.payloadId)
	return #payload.fields
end

local function positionalDelivery(supportedCandidate: SupportedPreflight, ...: unknown): PositionalDelivery
	local supported = requireSupported(supportedCandidate)
	local count = select("#", ...)
	local retainedCount = math.min(count, selectedFieldCount(supported) + 1)
	local values: { [number]: unknown } = table.create(retainedCount)

	for index = 1, retainedCount do
		local value = select(index, ...)
		if value ~= nil then
			values[index] = value
		end
	end

	table.freeze(values)
	local delivery: PositionalDelivery = {
		kind = "Positional",
		values = values,
		count = count,
	}
	table.freeze(delivery)
	return delivery
end

local function preflight(candidate: unknown, selection: CaseSelection, studioVersion: string): PreflightResult
	if not isStudioVersion(studioVersion) then
		fail("ADAPTER_E_CONTEXT")
	end

	local identityResult = Identity.check(candidate, "Canonical", studioVersion, "$.adapter")
	if identityResult.kind == "Invalid" then
		fail(`ADAPTER_E_IDENTITY_{identityResult.issue.code}:{identityResult.issue.path}`)
	end

	local selectionResult = Identity.resolveSelection(selection)
	if selectionResult.kind == "Invalid" then
		fail(`ADAPTER_E_CASE:{selectionResult.path}`)
	end

	local missing = Identity.missingRequirements(identityResult.value, selectionResult.value.requirements)
	if #missing > 0 then
		local unsupported = {
			kind = "Unsupported",
			identity = identityResult.value,
			selection = selectionResult.value,
			missing = missing,
		}
		table.freeze(unsupported)
		return unsupported :: any
	end

	local supported: SupportedPreflight = {
		kind = "Supported",
		identity = identityResult.value,
		selection = selectionResult.value,
	}
	table.freeze(supported)
	supportedPreflights[supported] = true
	return supported
end

local function exactRawFunctionRecord(value: unknown, expected: { [string]: boolean }, expectedCount: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end

	local count = 0
	for key in next, value do
		count += 1
		if type(key) ~= "string" or rawget(expected, key) ~= true or type(rawget(value, key)) ~= "function" then
			return false
		end
	end

	return count == expectedCount
end

local FACTORY_KEYS = {
	constructServer = true,
	constructClient = true,
}

local function requireFactory(factory: unknown): any
	if not exactRawFunctionRecord(factory, FACTORY_KEYS, 2) then
		fail("ADAPTER_E_FACTORY")
	end

	return factory
end

local function serverOperation(selection: ResolvedSelection): "broadcast"?
	if selection.kind == "SeparateProbe" or selection.direction == "ServerToClient" then
		return "broadcast"
	end

	return nil
end

local function clientOperation(selection: ResolvedSelection): "submit"?
	if selection.kind == "SeparateProbe" or selection.direction == "ClientToServer" then
		return "submit"
	end

	return nil
end

local function recipientCount(selection: ResolvedSelection): number
	if selection.kind == "SeparateProbe" then
		return selection.clientCount
	elseif selection.audience == "Broadcast" then
		return selection.recipientCount
	end

	return 0
end

local function participantCount(selection: ResolvedSelection): number
	if selection.kind == "SeparateProbe" then
		return selection.clientCount
	end

	return selection.recipientCount
end

local function copyRecipients(value: unknown, expectedCount: number): { any }
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		fail("ADAPTER_E_CONTEXT")
	end

	local seenCount = 0
	for key in next, value do
		seenCount += 1
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > expectedCount then
			fail("ADAPTER_E_CONTEXT")
		end
	end
	if seenCount ~= expectedCount then
		fail("ADAPTER_E_CONTEXT")
	end

	local copied = table.create(expectedCount)
	for index = 1, expectedCount do
		local token = rawget(value, index)
		if token == nil then
			fail("ADAPTER_E_CONTEXT")
		end
		for previousIndex = 1, index - 1 do
			if rawequal(token, copied[previousIndex]) then
				fail("ADAPTER_E_CONTEXT")
			end
		end
		copied[index] = token
	end

	table.freeze(copied)
	return copied
end

local function requireParticipantIndex(value: unknown, maximum: number): number
	if type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value > maximum then
		fail("ADAPTER_E_CONTEXT")
	end

	return value
end

local function makeEnvelopeFactory(supported: SupportedPreflight): EnvelopeFactory
	local factory: EnvelopeFactory = {
		record = recordDelivery,
		positional = function(...: unknown): PositionalDelivery
			return positionalDelivery(supported, ...)
		end,
	}
	table.freeze(factory)
	return factory
end

local function requireSide(value: unknown, operation: "submit" | "broadcast"?): any
	local expected = {
		setup = true,
		ready = true,
		teardown = true,
	}
	local count = 3
	if operation ~= nil then
		expected[operation] = true
		count += 1
	end

	if not exactRawFunctionRecord(value, expected, count) then
		fail("ADAPTER_E_FACTORY")
	end

	return value
end

local function wrapSide(adapterSide: any, operation: "submit" | "broadcast"?): any
	local state: LifecycleState = "Constructed"
	local adapterSetup = rawget(adapterSide, "setup")
	local adapterReady = rawget(adapterSide, "ready")
	local adapterTeardown = rawget(adapterSide, "teardown")
	local adapterOperation = if operation == nil then nil else rawget(adapterSide, operation)

	local function setup()
		if state ~= "Constructed" then
			fail("ADAPTER_E_STATE")
		end

		state = "SettingUp"
		local ok = pcall(adapterSetup)
		if not ok then
			state = "SetupFailed"
			fail("ADAPTER_E_SETUP")
		end
		state = "AwaitingReady"
	end

	local function ready(): boolean
		if state == "Ready" then
			return true
		elseif state ~= "AwaitingReady" then
			fail("ADAPTER_E_STATE")
		end

		local thread = coroutine.create(adapterReady)
		local results = table.pack(coroutine.resume(thread))
		if
			results[1] ~= true
			or coroutine.status(thread) ~= "dead"
			or results.n ~= 2
			or type(results[2]) ~= "boolean"
		then
			state = "SetupFailed"
			fail("ADAPTER_E_READY")
		end

		if results[2] then
			state = "Ready"
			return true
		end

		return false
	end

	local function teardown()
		if state == "TornDown" then
			return
		elseif
			state ~= "Constructed"
			and state ~= "AwaitingReady"
			and state ~= "Ready"
			and state ~= "SetupFailed"
			and state ~= "ExecutionFailed"
		then
			fail("ADAPTER_E_STATE")
		end

		state = "TearingDown"
		local ok = pcall(adapterTeardown)
		state = "TornDown"
		if not ok then
			fail("ADAPTER_E_TEARDOWN")
		end
	end

	local wrapped: any = {
		setup = setup,
		ready = ready,
		teardown = teardown,
	}

	if operation ~= nil then
		wrapped[operation] = function(payload: LogicalPayload, boundary: SubmissionBoundary)
			if state ~= "Ready" then
				fail("ADAPTER_E_STATE")
			end
			if boundary ~= "ContinueFrame" and boundary ~= "FlushBeforeReturn" then
				fail("ADAPTER_E_OPERATION")
			end

			local ok = pcall(adapterOperation, payload, boundary)
			if not ok then
				state = "ExecutionFailed"
				fail(if operation == "submit" then "ADAPTER_E_SUBMIT" else "ADAPTER_E_BROADCAST")
			end
		end
	end

	table.freeze(wrapped)
	return wrapped
end

local function constructServer<TResource, TSender>(
	supportedCandidate: SupportedPreflight,
	factoryCandidate: AdapterFactory<TResource, TSender>,
	resourceRoot: TResource,
	recipientsCandidate: { TSender },
	sink: ServerDeliverySink<TSender>
): ServerSide
	local supported = requireSupported(supportedCandidate)
	local factory = requireFactory(factoryCandidate)
	if resourceRoot == nil or type(sink) ~= "function" then
		fail("ADAPTER_E_CONTEXT")
	end

	local recipients = copyRecipients(recipientsCandidate, recipientCount(supported.selection))
	local context: ServerContext<TResource, TSender> = {
		resourceRoot = resourceRoot,
		selection = supported.selection,
		recipients = recipients,
		envelopes = makeEnvelopeFactory(supported),
		sink = sink,
	}
	table.freeze(context)

	local operation = serverOperation(supported.selection)
	local ok, adapterSide = pcall(rawget(factory, "constructServer"), context)
	if not ok then
		fail("ADAPTER_E_CONSTRUCT")
	end

	return wrapSide(requireSide(adapterSide, operation), operation)
end

local function constructClient<TResource, TSender>(
	supportedCandidate: SupportedPreflight,
	factoryCandidate: AdapterFactory<TResource, TSender>,
	resourceRoot: TResource,
	participantIndexCandidate: number,
	sink: ClientDeliverySink
): ClientSide
	local supported = requireSupported(supportedCandidate)
	local factory = requireFactory(factoryCandidate)
	if resourceRoot == nil or type(sink) ~= "function" then
		fail("ADAPTER_E_CONTEXT")
	end

	local participantIndex = requireParticipantIndex(
		participantIndexCandidate,
		participantCount(supported.selection)
	)
	local context: ClientContext<TResource> = {
		resourceRoot = resourceRoot,
		selection = supported.selection,
		participantIndex = participantIndex,
		envelopes = makeEnvelopeFactory(supported),
		sink = sink,
	}
	table.freeze(context)

	local operation = clientOperation(supported.selection)
	local ok, adapterSide = pcall(rawget(factory, "constructClient"), context)
	if not ok then
		fail("ADAPTER_E_CONSTRUCT")
	end

	return wrapSide(requireSide(adapterSide, operation), operation)
end

local AdapterContract = {
	preflight = preflight,
	constructServer = constructServer,
	constructClient = constructClient,
	recordDelivery = recordDelivery,
	positionalDelivery = positionalDelivery,
}

table.freeze(AdapterContract)

return AdapterContract
