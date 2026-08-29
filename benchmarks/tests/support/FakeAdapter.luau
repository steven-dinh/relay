--!strict

type Direction = "ClientToServer" | "ServerToClient"

type DeliveryClaim = {
	direction: Direction,
	submitIndex: number,
	receiverIndex: number,
}

local MAX_SAFE_INTEGER = 9_007_199_254_740_991
local MAX_ACTIONS = 32
local MAX_SUBMISSIONS = 2_000
local MAX_CLIENTS = 8
local MAX_DELAY_FRAMES = 120
local MAX_PENDING = 16_384

local DELIVERY_KINDS = {
	Drop = true,
	Duplicate = true,
	Corrupt = true,
	ReorderNext = true,
	Delay = true,
	Unexpected = true,
	StaleAfterTeardown = true,
}

local function fail(code: string): never
	error(code, 0)
end

local function isSafeInteger(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
		and math.abs(value) <= MAX_SAFE_INTEGER
end

local function isExactRecord(value: unknown, keys: { [string]: boolean }, keyCount: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end

	local observed = 0
	for key in next, value do
		observed += 1
		if type(key) ~= "string" or rawget(keys, key) ~= true then
			return false
		end
	end

	return observed == keyCount
end

local function denseLength(value: unknown, maximum: number): number?
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil
	end

	local count = 0
	local maximumIndex = 0
	for key in next, value do
		if not isSafeInteger(key) or key < 1 or key > maximum then
			return nil
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
	end

	if count ~= maximumIndex then
		return nil
	end
	for index = 1, count do
		if rawget(value, index) == nil then
			return nil
		end
	end

	return count
end

local function validDirection(value: unknown): boolean
	return value == "ClientToServer" or value == "ServerToClient"
end

local function validReceiver(direction: Direction, receiverIndex: unknown): boolean
	if not isSafeInteger(receiverIndex) then
		return false
	end
	if direction == "ClientToServer" then
		return receiverIndex == 0
	end
	return receiverIndex >= 1 and receiverIndex <= MAX_CLIENTS
end

local function copyDeliveryTarget(candidate: unknown): any
	if not isExactRecord(candidate, {
		direction = true,
		submitIndex = true,
		receiverIndex = true,
	}, 3) then
		fail("FAKE_E_SCRIPT")
	end

	local direction = rawget(candidate :: any, "direction")
	local submitIndex = rawget(candidate :: any, "submitIndex")
	local receiverIndex = rawget(candidate :: any, "receiverIndex")
	if not validDirection(direction)
		or not isSafeInteger(submitIndex)
		or submitIndex < 1
		or submitIndex > MAX_SUBMISSIONS
		or not validReceiver(direction :: Direction, receiverIndex)
	then
		fail("FAKE_E_SCRIPT")
	end

	local copied = {
		direction = direction,
		submitIndex = submitIndex,
		receiverIndex = receiverIndex,
	}
	table.freeze(copied)
	return copied
end

local function copyAction(candidate: unknown): any
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
		fail("FAKE_E_SCRIPT")
	end

	local kind = rawget(candidate, "kind")
	if type(kind) ~= "string" then
		fail("FAKE_E_SCRIPT")
	end

	if rawget(DELIVERY_KINDS, kind) == true then
		local expected = { kind = true, target = true }
		local expectedCount = 2
		if kind == "Delay" then
			expected.frames = true
			expectedCount = 3
		end
		if not isExactRecord(candidate, expected, expectedCount) then
			fail("FAKE_E_SCRIPT")
		end

		local copied: any = {
			kind = kind,
			target = copyDeliveryTarget(rawget(candidate, "target")),
		}
		if kind == "Delay" then
			local frames = rawget(candidate, "frames")
			if not isSafeInteger(frames) or frames < 1 or frames > MAX_DELAY_FRAMES then
				fail("FAKE_E_SCRIPT")
			end
			copied.frames = frames
		end
		table.freeze(copied)
		return copied
	elseif kind == "FailSubmit" then
		if not isExactRecord(candidate, {
			kind = true,
			direction = true,
			submitIndex = true,
		}, 3) then
			fail("FAKE_E_SCRIPT")
		end
		local direction = rawget(candidate, "direction")
		local submitIndex = rawget(candidate, "submitIndex")
		if not validDirection(direction)
			or not isSafeInteger(submitIndex)
			or submitIndex < 1
			or submitIndex > MAX_SUBMISSIONS
		then
			fail("FAKE_E_SCRIPT")
		end
		local copied = {
			kind = kind,
			direction = direction,
			submitIndex = submitIndex,
		}
		table.freeze(copied)
		return copied
	elseif kind == "FailSetup" or kind == "FailTeardown" then
		if not isExactRecord(candidate, {
			kind = true,
			side = true,
			participantIndex = true,
		}, 3) then
			fail("FAKE_E_SCRIPT")
		end
		local side = rawget(candidate, "side")
		local participantIndex = rawget(candidate, "participantIndex")
		if side ~= "Server" and side ~= "Client" then
			fail("FAKE_E_SCRIPT")
		end
		if not isSafeInteger(participantIndex)
			or (side == "Server" and participantIndex ~= 0)
			or (side == "Client" and (participantIndex < 1 or participantIndex > MAX_CLIENTS))
		then
			fail("FAKE_E_SCRIPT")
		end
		local copied = {
			kind = kind,
			side = side,
			participantIndex = participantIndex,
		}
		table.freeze(copied)
		return copied
	end

	fail("FAKE_E_SCRIPT")
end

local function deliveryClaims(action: any): { DeliveryClaim }
	local claims: { DeliveryClaim } = {}
	if rawget(DELIVERY_KINDS, action.kind) == true then
		local target = action.target
		table.insert(claims, {
			direction = target.direction,
			submitIndex = target.submitIndex,
			receiverIndex = target.receiverIndex,
		})
		if action.kind == "ReorderNext" and target.submitIndex < MAX_SUBMISSIONS then
			table.insert(claims, {
				direction = target.direction,
				submitIndex = target.submitIndex + 1,
				receiverIndex = target.receiverIndex,
			})
		end
	elseif action.kind == "FailSubmit" then
		if action.direction == "ClientToServer" then
			table.insert(claims, {
				direction = action.direction,
				submitIndex = action.submitIndex,
				receiverIndex = 0,
			})
		else
			for receiverIndex = 1, MAX_CLIENTS do
				table.insert(claims, {
					direction = action.direction,
					submitIndex = action.submitIndex,
					receiverIndex = receiverIndex,
				})
			end
		end
	end
	return claims
end

local function actionsOverlap(left: any, right: any): boolean
	local leftClaims = deliveryClaims(left)
	local rightClaims = deliveryClaims(right)
	for _, leftClaim in leftClaims do
		for _, rightClaim in rightClaims do
			if leftClaim.direction == rightClaim.direction
				and leftClaim.submitIndex == rightClaim.submitIndex
				and leftClaim.receiverIndex == rightClaim.receiverIndex
			then
				return true
			end
		end
	end

	if (left.kind == "FailSetup" or left.kind == "FailTeardown") and left.kind == right.kind then
		return left.side == right.side and left.participantIndex == right.participantIndex
	end
	return false
end

local function copyScript(candidate: unknown): { any }
	local length = denseLength(candidate, MAX_ACTIONS)
	if length == nil then
		fail("FAKE_E_SCRIPT")
	end

	local copied: { any } = table.create(length)
	for index = 1, length do
		copied[index] = copyAction(rawget(candidate :: any, index))
		for priorIndex = 1, index - 1 do
			if actionsOverlap(copied[priorIndex], copied[index]) then
				fail("FAKE_E_SCRIPT")
			end
		end
	end
	table.freeze(copied)
	return copied
end

local function clonePayload(payload: any): any
	local copied: any = {}
	for key, value in next, payload do
		rawset(copied, key, value)
	end
	return copied
end

local function selectionSignature(selection: any): string
	if selection.kind == "SeparateProbe" then
		return `P:{selection.probeId}:{selection.clientCount}:{selection.payloadId}`
	end
	return `W:{selection.workloadId}:{selection.recipientCount}:{selection.payloadId}:{selection.direction}:{selection.audience}`
end

local function serverHasOperation(selection: any): boolean
	return selection.kind == "SeparateProbe" or selection.direction == "ServerToClient"
end

local function clientHasOperation(selection: any): boolean
	return selection.kind == "SeparateProbe" or selection.direction == "ClientToServer"
end

local function selectedClientCount(selection: any): number
	if selection.kind == "SeparateProbe" then
		return selection.clientCount
	end
	return selection.recipientCount
end

local function newTestRig(schedulerCandidate: unknown): (any, any)
	if not isExactRecord(schedulerCandidate, {
		currentFrame = true,
		connectPostSimulation = true,
	}, 2) then
		fail("FAKE_E_SCHEDULER")
	end

	local scheduler: any = schedulerCandidate
	if type(rawget(scheduler, "currentFrame")) ~= "function"
		or type(rawget(scheduler, "connectPostSimulation")) ~= "function"
	then
		fail("FAKE_E_SCHEDULER")
	end

	local currentFrameFunction = rawget(scheduler, "currentFrame")
	local connectFunction = rawget(scheduler, "connectPostSimulation")
	local function readFrame(): number
		local frameCall = table.pack(pcall(currentFrameFunction))
		if frameCall[1] ~= true or frameCall.n ~= 2 or not isSafeInteger(frameCall[2]) or frameCall[2] < 0 then
			fail("FAKE_E_SCHEDULER")
		end
		return frameCall[2]
	end

	local observedFrame = readFrame()
	if observedFrame ~= 0 then
		fail("FAKE_E_SCHEDULER")
	end

	local generation = 1
	local insertionOrdinal = 0
	local submissionIndexes: { [Direction]: number } = {
		ClientToServer = 0,
		ServerToClient = 0,
	}
	local routeOrdinals: { [string]: number } = {}
	local routeDueFrames: { [string]: number } = {}
	local heap: { any } = {}
	local scheduledCount = 0
	local heldCount = 0
	local retainedCount = 0
	local unarmedRetained: { any } = {}
	local heldByRoute: { [string]: any } = {}
	local heldRecords: { [any]: boolean } = {}
	local serverEndpoint: any = nil
	local clientEndpoints: { [number]: any } = {}
	local sides: { any } = {}
	local setupStarted = false
	local boundSelection: any = nil
	local boundSignature: string? = nil
	local faultActions: { any } = table.freeze({})
	local faultStates: { string } = {}
	local scriptLoaded = false

	local function pendingTotal(): number
		return scheduledCount + heldCount + retainedCount
	end

	local function requireCapacity(additional: number)
		if pendingTotal() + additional > MAX_PENDING then
			fail("FAKE_E_LIMIT")
		end
	end

	local function recordBefore(left: any, right: any): boolean
		return left.dueFrame < right.dueFrame
			or (left.dueFrame == right.dueFrame and left.insertionOrdinal < right.insertionOrdinal)
	end

	local function heapPush(record: any)
		table.insert(heap, record)
		local index = #heap
		while index > 1 do
			local parent = math.floor(index / 2)
			if not recordBefore(heap[index], heap[parent]) then
				break
			end
			heap[index], heap[parent] = heap[parent], heap[index]
			index = parent
		end
	end

	local function heapPop(): any
		local first = heap[1]
		local last = table.remove(heap)
		if #heap > 0 then
			heap[1] = last
			local index = 1
			while true do
				local left = index * 2
				if left > #heap then
					break
				end
				local right = left + 1
				local smallest = left
				if right <= #heap and recordBefore(heap[right], heap[left]) then
					smallest = right
				end
				if not recordBefore(heap[smallest], heap[index]) then
					break
				end
				heap[index], heap[smallest] = heap[smallest], heap[index]
				index = smallest
			end
		end
		return first
	end

	local function rebuildHeap()
		for index = math.floor(#heap / 2), 1, -1 do
			local cursor = index
			while true do
				local left = cursor * 2
				if left > #heap then
					break
				end
				local right = left + 1
				local smallest = left
				if right <= #heap and recordBefore(heap[right], heap[left]) then
					smallest = right
				end
				if not recordBefore(heap[smallest], heap[cursor]) then
					break
				end
				heap[cursor], heap[smallest] = heap[smallest], heap[cursor]
				cursor = smallest
			end
		end
	end

	local function operationFrame(): number
		local frame = readFrame()
		if frame ~= observedFrame then
			fail("FAKE_E_SCHEDULER")
		end
		return frame
	end

	local function routeKey(direction: Direction, receiverIndex: number): string
		if direction == "ClientToServer" then
			return "C:0"
		end
		return `S:{receiverIndex}`
	end

	local function matchesEndpoint(record: any, endpoint: any): boolean
		return record.sourceEndpoint == endpoint or record.destinationEndpoint == endpoint
	end

	local function cancelHeld(held: any)
		if held == nil or heldRecords[held] ~= true then
			return
		end
		heldRecords[held] = nil
		if heldByRoute[held.record.routeKey] == held then
			heldByRoute[held.record.routeKey] = nil
		end
		heldCount -= 1
	end

	local function cancelOrdinaryForEndpoint(endpoint: any)
		local retainedHeap: { any } = {}
		for _, record in heap do
			if record.pendingKind == "Scheduled" and matchesEndpoint(record, endpoint) then
				scheduledCount -= 1
				cancelHeld(record.releaseHeld)
			else
				table.insert(retainedHeap, record)
			end
		end
		heap = retainedHeap
		rebuildHeap()

		for held in next, heldRecords do
			if matchesEndpoint(held.record, endpoint) then
				cancelHeld(held)
			end
		end
	end

	local function armRetainedForEndpoint(endpoint: any)
		local frame: number? = nil
		local remaining: { any } = {}
		for _, record in unarmedRetained do
			if record.destinationEndpoint == endpoint then
				if frame == nil then
					frame = operationFrame()
					if frame >= MAX_SAFE_INTEGER then
						fail("FAKE_E_SCHEDULER")
					end
				end
				record.dueFrame = frame + 1
				record.destinationEndpoint = nil
				heapPush(record)
			else
				table.insert(remaining, record)
			end
		end
		unarmedRetained = remaining
	end

	local function currentDestination(record: any): any
		if record.direction == "ClientToServer" then
			return serverEndpoint
		end
		return clientEndpoints[record.receiverIndex]
	end

	local function currentSource(record: any): any
		if record.direction == "ClientToServer" then
			return clientEndpoints[record.senderIndex]
		end
		return serverEndpoint
	end

	local dispatchOrdinary: (any) -> ()
	local function releaseHeld(record: any)
		local held = record.releaseHeld
		if held == nil or heldRecords[held] ~= true then
			return
		end
		cancelHeld(held)
		faultStates[held.actionIndex] = "Consumed"
		dispatchOrdinary(held.record)
	end

	dispatchOrdinary = function(record: any)
		if record.generation == generation
			and currentSource(record) == record.sourceEndpoint
			and currentDestination(record) == record.destinationEndpoint
			and record.sourceEndpoint.ready
			and record.destinationEndpoint.ready
		then
			record.sink(record.delivery, record.metadata)
		end
		releaseHeld(record)
	end

	local function drain(frame: number)
		while #heap > 0 and heap[1].dueFrame <= frame do
			local record = heapPop()
			if record.pendingKind == "Scheduled" then
				scheduledCount -= 1
				dispatchOrdinary(record)
			else
				retainedCount -= 1
				record.sink(record.delivery, record.metadata)
			end
		end
	end

	local function postSimulationCallback()
		local nextFrame = readFrame()
		if observedFrame >= MAX_SAFE_INTEGER or nextFrame ~= observedFrame + 1 then
			fail("FAKE_E_SCHEDULER")
		end
		observedFrame = nextFrame
		drain(nextFrame)
	end

	local function validateScriptForSelection(actions: { any }, selection: any)
		local clientCount = selectedClientCount(selection)
		for _, action in actions do
			if selection.kind == "SeparateProbe" and action.kind == "ReorderNext" then
				fail("FAKE_E_SCRIPT")
			end

			local direction: Direction? = nil
			if rawget(DELIVERY_KINDS, action.kind) == true then
				direction = action.target.direction
				if direction == "ServerToClient" and action.target.receiverIndex > clientCount then
					fail("FAKE_E_SCRIPT")
				end
			elseif action.kind == "FailSubmit" then
				direction = action.direction
			elseif (action.kind == "FailSetup" or action.kind == "FailTeardown")
				and action.side == "Client"
				and action.participantIndex > clientCount
			then
				fail("FAKE_E_SCRIPT")
			end

			if direction ~= nil
				and selection.kind == "Workload"
				and direction ~= selection.direction
			then
				fail("FAKE_E_SCRIPT")
			end
		end
	end

	local function bindSelection(selection: any)
		local signature = selectionSignature(selection)
		if boundSignature == nil then
			validateScriptForSelection(faultActions, selection)
			boundSelection = selection
			boundSignature = signature
		elseif boundSignature ~= signature then
			fail("FAKE_E_STATE")
		end
	end

	local function findDeliveryAction(
		direction: Direction,
		submitIndex: number,
		receiverIndex: number
	): (number?, any?)
		for index, action in faultActions do
			if faultStates[index] == "Pending" and rawget(DELIVERY_KINDS, action.kind) == true then
				local target = action.target
				if target.direction == direction
					and target.submitIndex == submitIndex
					and target.receiverIndex == receiverIndex
				then
					return index, action
				end
			end
		end
		return nil, nil
	end

	local function consumeLifecycle(kind: string, side: string, participantIndex: number): boolean
		for index, action in faultActions do
			if faultStates[index] == "Pending"
				and action.kind == kind
				and action.side == side
				and action.participantIndex == participantIndex
			then
				faultStates[index] = "Consumed"
				return true
			end
		end
		return false
	end

	local function consumeSubmitFailure(direction: Direction, submitIndex: number): boolean
		for index, action in faultActions do
			if faultStates[index] == "Pending"
				and action.kind == "FailSubmit"
				and action.direction == direction
				and action.submitIndex == submitIndex
			then
				faultStates[index] = "Consumed"
				return true
			end
		end
		return false
	end

	local function hasSubmitFailure(direction: Direction, submitIndex: number): boolean
		for index, action in faultActions do
			if faultStates[index] == "Pending"
				and action.kind == "FailSubmit"
				and action.direction == direction
				and action.submitIndex == submitIndex
			then
				return true
			end
		end
		return false
	end

	local function nextSubmission(direction: Direction): number
		local submitIndex = submissionIndexes[direction] + 1
		if submitIndex > MAX_SUBMISSIONS then
			fail("FAKE_E_LIMIT")
		end
		if consumeSubmitFailure(direction, submitIndex) then
			fail("FAKE_E_SUBMIT")
		end
		submissionIndexes[direction] = submitIndex
		return submitIndex
	end

	local function estimatePendingAddition(
		direction: Direction,
		submitIndex: number,
		receiverIndex: number,
		frame: number
	): number
		local _, action = findDeliveryAction(direction, submitIndex, receiverIndex)
		local route = routeKey(direction, receiverIndex)
		local dueFrame = frame
		if action ~= nil and action.kind == "Delay" then
			if frame > MAX_SAFE_INTEGER - action.frames then
				fail("FAKE_E_SCHEDULER")
			end
			dueFrame += action.frames
		end
		dueFrame = math.max(dueFrame, routeDueFrames[route] or frame)

		if action ~= nil and action.kind == "Drop" then
			return 0
		elseif action ~= nil and action.kind == "ReorderNext" then
			return 1
		end

		local addition = if dueFrame > frame then 1 else 0
		if action ~= nil and (action.kind == "Duplicate" or action.kind == "Unexpected") and dueFrame > frame then
			addition += 1
		elseif action ~= nil and action.kind == "StaleAfterTeardown" then
			addition += 1
		end
		return addition
	end

	local function requireLogicalCapacity(
		direction: Direction,
		submitIndex: number,
		receiverCount: number,
		frame: number
	)
		local addition = 0
		if direction == "ClientToServer" then
			addition = estimatePendingAddition(direction, submitIndex, 0, frame)
		else
			for receiverIndex = 1, receiverCount do
				addition += estimatePendingAddition(direction, submitIndex, receiverIndex, frame)
			end
		end
		requireCapacity(addition)
	end

	local function senderToken(sourceEndpoint: any): any
		return sourceEndpoint.participantIndex
	end

	local function makeDeliveryRecord(
		direction: Direction,
		submitIndex: number,
		receiverIndex: number,
		route: string,
		routeOrdinal: number,
		dueFrame: number,
		payload: any,
		transform: string,
		sourceEndpoint: any,
		destinationEndpoint: any
	): any
		local copiedPayload = clonePayload(payload)
		if transform == "Corrupt" then
			if sourceEndpoint.selection.payloadId == "tiny" then
				rawset(copiedPayload, "enabled", not rawget(copiedPayload, "enabled"))
			else
				local health = rawget(copiedPayload, "health")
				rawset(copiedPayload, "health", (health + 1) % 101)
			end
		elseif transform == "Unexpected" and sourceEndpoint.selection.kind ~= "SeparateProbe" then
			rawset(copiedPayload, "sequence", -1)
		end

		insertionOrdinal += 1
		local metadata: any
		local senderIndex = 0
		if direction == "ClientToServer" then
			senderIndex = sourceEndpoint.participantIndex
			metadata = {
				kind = "ClientToServer",
				sender = senderToken(sourceEndpoint),
			}
		else
			metadata = { kind = "ServerToClient" }
		end
		table.freeze(metadata)

		return {
			generation = generation,
			direction = direction,
			submitIndex = submitIndex,
			receiverIndex = receiverIndex,
			senderIndex = senderIndex,
			dueFrame = dueFrame,
			routeKey = route,
			routeOrdinal = routeOrdinal,
			insertionOrdinal = insertionOrdinal,
			sourceEndpoint = sourceEndpoint,
			destinationEndpoint = destinationEndpoint,
			sink = destinationEndpoint.sink,
			delivery = sourceEndpoint.envelopes.record(copiedPayload),
			metadata = metadata,
		}
	end

	local function scheduleOrDispatch(record: any, frame: number)
		if record.dueFrame <= frame then
			dispatchOrdinary(record)
		else
			requireCapacity(1)
			record.pendingKind = "Scheduled"
			scheduledCount += 1
			heapPush(record)
		end
	end

	local function retainStale(record: any)
		requireCapacity(1)
		record.pendingKind = "Stale"
		record.dueFrame = nil
		record.sourceEndpoint = nil
		retainedCount += 1
		table.insert(unarmedRetained, record)
	end

	local function acceptDelivery(
		direction: Direction,
		submitIndex: number,
		receiverIndex: number,
		payload: any,
		sourceEndpoint: any,
		destinationEndpoint: any,
		frame: number
	)
		local route = routeKey(direction, receiverIndex)
		local routeOrdinal = (routeOrdinals[route] or 0) + 1
		routeOrdinals[route] = routeOrdinal

		local actionIndex, action = findDeliveryAction(direction, submitIndex, receiverIndex)
		local dueFrame = frame
		if action ~= nil and action.kind == "Delay" then
			if frame > MAX_SAFE_INTEGER - action.frames then
				fail("FAKE_E_SCHEDULER")
			end
			dueFrame += action.frames
		end
		dueFrame = math.max(dueFrame, routeDueFrames[route] or frame)
		routeDueFrames[route] = dueFrame

		local transform = if action ~= nil and action.kind == "Corrupt" then "Corrupt" else "Normal"
		local normalRecord = makeDeliveryRecord(
			direction,
			submitIndex,
			receiverIndex,
			route,
			routeOrdinal,
			dueFrame,
			payload,
			transform,
			sourceEndpoint,
			destinationEndpoint
		)

		if action ~= nil and action.kind == "Drop" then
			faultStates[actionIndex :: number] = "Consumed"
			return
		end

		local held = heldByRoute[route]
		if held ~= nil then
			heldByRoute[route] = nil
			faultStates[held.actionIndex] = "Consumed"
		end

		if action ~= nil and action.kind == "ReorderNext" then
			if held ~= nil then
				fail("FAKE_E_SCRIPT")
			end
			requireCapacity(1)
			faultStates[actionIndex :: number] = "Holding"
			local newHeld = {
				record = normalRecord,
				actionIndex = actionIndex,
			}
			heldByRoute[route] = newHeld
			heldRecords[newHeld] = true
			heldCount += 1
			return
		end

		local records = { normalRecord }
		if action ~= nil and (action.kind == "Duplicate" or action.kind == "Unexpected") then
			table.insert(records, makeDeliveryRecord(
				direction,
				submitIndex,
				receiverIndex,
				route,
				routeOrdinal,
				dueFrame,
				payload,
				action.kind,
				sourceEndpoint,
				destinationEndpoint
			))
		elseif action ~= nil and action.kind == "StaleAfterTeardown" then
			local stale = makeDeliveryRecord(
				direction,
				submitIndex,
				receiverIndex,
				route,
				routeOrdinal,
				dueFrame,
				payload,
				"Normal",
				sourceEndpoint,
				destinationEndpoint
			)
			retainStale(stale)
		end

		if action ~= nil then
			faultStates[actionIndex :: number] = "Consumed"
		end
		if held ~= nil then
			records[#records].releaseHeld = held
		end
		for _, record in records do
			scheduleOrDispatch(record, frame)
		end
	end

	local function setupSide(sideRecord: any)
		if sideRecord.generation ~= generation or sideRecord.setupStarted or sideRecord.tornDown then
			fail("FAKE_E_STATE")
		end
		sideRecord.setupStarted = true
		setupStarted = true
		if consumeLifecycle("FailSetup", sideRecord.side, sideRecord.participantIndex) then
			fail("FAKE_E_SETUP")
		end

		local endpoint = {
			generation = generation,
			participantIndex = sideRecord.participantIndex,
			ready = false,
			selection = sideRecord.context.selection,
			recipients = if sideRecord.side == "Server" then sideRecord.context.recipients else nil,
			envelopes = sideRecord.context.envelopes,
			sink = sideRecord.context.sink,
		}
		if sideRecord.side == "Server" then
			if serverEndpoint ~= nil then
				fail("FAKE_E_STATE")
			end
			serverEndpoint = endpoint
		else
			if clientEndpoints[sideRecord.participantIndex] ~= nil then
				fail("FAKE_E_STATE")
			end
			clientEndpoints[sideRecord.participantIndex] = endpoint
		end
		sideRecord.endpoint = endpoint
	end

	local function readySide(sideRecord: any): boolean
		local endpoint = sideRecord.endpoint
		if sideRecord.tornDown or endpoint == nil then
			return false
		end
		endpoint.ready = true
		sideRecord.ready = true
		return true
	end

	local function teardownSide(sideRecord: any)
		if sideRecord.tornDown then
			return
		end
		sideRecord.tornDown = true
		local endpoint = sideRecord.endpoint
		if endpoint ~= nil then
			endpoint.ready = false
			if sideRecord.side == "Server" then
				if serverEndpoint == endpoint then
					serverEndpoint = nil
				end
			else
				if clientEndpoints[sideRecord.participantIndex] == endpoint then
					clientEndpoints[sideRecord.participantIndex] = nil
				end
			end
			cancelOrdinaryForEndpoint(endpoint)
			armRetainedForEndpoint(endpoint)
		end
		sideRecord.endpoint = nil
		sideRecord.ready = false
		sideRecord.context = nil

		if consumeLifecycle("FailTeardown", sideRecord.side, sideRecord.participantIndex) then
			fail("FAKE_E_TEARDOWN")
		end
	end

	local function makeSideRecord(side: string, participantIndex: number, context: any): any
		local sideRecord = {
			generation = generation,
			side = side,
			participantIndex = participantIndex,
			context = context,
			setupStarted = false,
			ready = false,
			tornDown = false,
			endpoint = nil,
		}
		table.insert(sides, sideRecord)
		return sideRecord
	end

	local function submit(sideRecord: any, payload: any)
		local sourceEndpoint = sideRecord.endpoint
		local destinationEndpoint = serverEndpoint
		if not sideRecord.ready
			or sourceEndpoint == nil
			or destinationEndpoint == nil
			or not destinationEndpoint.ready
		then
			fail("FAKE_E_STATE")
		end
		local frame = operationFrame()
		local submitIndexCandidate = submissionIndexes.ClientToServer + 1
		if submitIndexCandidate > MAX_SUBMISSIONS
			or hasSubmitFailure("ClientToServer", submitIndexCandidate)
		then
			nextSubmission("ClientToServer")
		end
		requireLogicalCapacity("ClientToServer", submitIndexCandidate, 1, frame)
		local submitIndex = nextSubmission("ClientToServer")
		acceptDelivery(
			"ClientToServer",
			submitIndex,
			0,
			payload,
			sourceEndpoint,
			destinationEndpoint,
			frame
		)
	end

	local function broadcast(sideRecord: any, payload: any)
		local sourceEndpoint = sideRecord.endpoint
		if not sideRecord.ready or sourceEndpoint == nil then
			fail("FAKE_E_STATE")
		end
		local clientCount = selectedClientCount(sideRecord.context.selection)
		for receiverIndex = 1, clientCount do
			if clientEndpoints[receiverIndex] == nil or not clientEndpoints[receiverIndex].ready then
				fail("FAKE_E_STATE")
			end
		end

		local frame = operationFrame()
		local submitIndexCandidate = submissionIndexes.ServerToClient + 1
		if submitIndexCandidate > MAX_SUBMISSIONS
			or hasSubmitFailure("ServerToClient", submitIndexCandidate)
		then
			nextSubmission("ServerToClient")
		end
		requireLogicalCapacity("ServerToClient", submitIndexCandidate, clientCount, frame)
		local submitIndex = nextSubmission("ServerToClient")
		for receiverIndex = 1, clientCount do
			acceptDelivery(
				"ServerToClient",
				submitIndex,
				receiverIndex,
				payload,
				sourceEndpoint,
				clientEndpoints[receiverIndex],
				frame
			)
		end
	end

	local adapter: any = {}
	adapter.constructServer = function(context: any): any
		bindSelection(context.selection)
		local sideRecord = makeSideRecord("Server", 0, context)
		local side: any = {
			setup = function()
				setupSide(sideRecord)
			end,
			ready = function(): boolean
				return readySide(sideRecord)
			end,
			teardown = function()
				teardownSide(sideRecord)
			end,
		}
		if serverHasOperation(context.selection) then
			side.broadcast = function(payload: any, _boundary: any)
				broadcast(sideRecord, payload)
			end
		end
		table.freeze(side)
		return side
	end
	adapter.constructClient = function(context: any): any
		bindSelection(context.selection)
		local sideRecord = makeSideRecord("Client", context.participantIndex, context)
		local side: any = {
			setup = function()
				setupSide(sideRecord)
			end,
			ready = function(): boolean
				return readySide(sideRecord)
			end,
			teardown = function()
				teardownSide(sideRecord)
			end,
		}
		if clientHasOperation(context.selection) then
			side.submit = function(payload: any, _boundary: any)
				submit(sideRecord, payload)
			end
		end
		table.freeze(side)
		return side
	end
	table.freeze(adapter)

	local control: any = {}
	control.loadFaultScript = function(self: any, actionsCandidate: unknown)
		if self ~= control or setupStarted or scriptLoaded then
			fail("FAKE_E_STATE")
		end
		local copied = copyScript(actionsCandidate)
		if boundSelection ~= nil then
			validateScriptForSelection(copied, boundSelection)
		end
		faultActions = copied
		faultStates = table.create(#copied, "Pending")
		scriptLoaded = true
	end
	control.pending = function(self: any): any
		if self ~= control then
			fail("FAKE_E_STATE")
		end
		local snapshot = {
			generation = generation,
			scheduled = scheduledCount,
			heldReorder = heldCount,
			retainedStale = retainedCount,
		}
		table.freeze(snapshot)
		return snapshot
	end
	control.assertConsumed = function(self: any)
		if self ~= control then
			fail("FAKE_E_STATE")
		end
		for _, state in faultStates do
			if state ~= "Consumed" then
				fail("FAKE_E_SCRIPT")
			end
		end
		if heldCount ~= 0 then
			fail("FAKE_E_SCRIPT")
		end
	end
	control.reset = function(self: any)
		if self ~= control then
			fail("FAKE_E_STATE")
		end
		for _, sideRecord in sides do
			if not sideRecord.tornDown then
				fail("FAKE_E_STATE")
			end
		end
		for _, state in faultStates do
			if state ~= "Consumed" then
				fail("FAKE_E_SCRIPT")
			end
		end
		if scheduledCount ~= 0 or heldCount ~= 0 or #unarmedRetained ~= 0 then
			fail("FAKE_E_STATE")
		end
		if generation >= MAX_SAFE_INTEGER then
			fail("FAKE_E_LIMIT")
		end

		generation += 1
		submissionIndexes = {
			ClientToServer = 0,
			ServerToClient = 0,
		}
		routeOrdinals = {}
		routeDueFrames = {}
		heldByRoute = {}
		heldRecords = {}
		serverEndpoint = nil
		clientEndpoints = {}
		sides = {}
		setupStarted = false
		boundSelection = nil
		boundSignature = nil
		faultActions = table.freeze({})
		faultStates = {}
		scriptLoaded = false
	end
	table.freeze(control)

	local connected = pcall(connectFunction, postSimulationCallback)
	if not connected then
		fail("FAKE_E_SCHEDULER")
	end

	return adapter, control
end

local FakeAdapter = {
	newTestRig = newTestRig,
}
table.freeze(FakeAdapter)

return FakeAdapter
