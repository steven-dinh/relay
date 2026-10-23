local LEGACY_WIRE_TAG = 1
local V2_WIRE_TAG = 7
local ENVELOPE_BYTES = 44
local MINIMUM_FRAME_BYTES = ENVELOPE_BYTES
local MAXIMUM_FRAME_BYTES = 8_192
local MAXIMUM_BODY_BYTES = MAXIMUM_FRAME_BYTES - ENVELOPE_BYTES
local MAXIMUM_REFERENCES = 16
local REFERENCE_BYTES = 8
local CODEC_VERSION = 1
local REFERENCE_FORMAT = 4

local function isInteger(value)
	return type(value) == "number" and value % 1 == 0
end

local function validGuid(value)
	if type(value) ~= "string" or #value ~= 36 then return false end
	for index = 1, 36 do
		local byte = string.byte(value, index)
		if index == 9 or index == 14 or index == 19 or index == 24 then
			if byte ~= 45 then return false end
		elseif not ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)) then
			return false
		end
	end
	return true
end

local function validKind(kind, version, allowBudgetFailure)
	if not isInteger(kind) then return false end
	if version == 1 then
		return kind >= 1 and kind <= 4 or kind == 5 and allowBudgetFailure == true
	end
	return kind >= 1 and kind <= 8
end

local function validIds(methodId, callId)
	return isInteger(methodId) and methodId >= 1 and methodId <= 65_535
		and isInteger(callId) and callId >= 1 and callId <= 4_294_967_295
end

local function peek(packet, serverSide, allowBudgetFailure, sidecarCount)
	if typeof(packet) ~= "buffer" or (serverSide ~= true and serverSide ~= false)
		or (allowBudgetFailure ~= nil and type(allowBudgetFailure) ~= "boolean")
		or (sidecarCount ~= nil and (not isInteger(sidecarCount) or sidecarCount < 0)) then
		return nil
	end
	local length = buffer.len(packet)
	if length < MINIMUM_FRAME_BYTES or length > MAXIMUM_FRAME_BYTES then return nil end
	local wireTag = buffer.readu8(packet, 0)
	local version = if wireTag == LEGACY_WIRE_TAG then 1 elseif wireTag == V2_WIRE_TAG then 2 else nil
	if version == nil then return nil end
	local kind = buffer.readu8(packet, 1)
	if not validKind(kind, version, allowBudgetFailure)
		or (version == 1 and ((serverSide and kind ~= 1) or (not serverSide and kind == 1))) then
		return nil
	end
	local methodId = buffer.readu16(packet, 2)
	local callId = buffer.readu32(packet, 4)
	if methodId == 0 or callId == 0 then return nil end

	local sessionGuid = buffer.readstring(packet, 8, 36)
	if not validGuid(sessionGuid) then return nil end

	local bodyBytes = length - ENVELOPE_BYTES
	local referenceCount = 0
	if kind >= 3 then
		if bodyBytes ~= 0 then return nil end
	else
		if bodyBytes < 3 then return nil end
		local format = buffer.readu8(packet, ENVELOPE_BYTES)
		if format == CODEC_VERSION then
			if buffer.readu16(packet, ENVELOPE_BYTES + 1) ~= methodId then return nil end
		elseif version == 2 and format == REFERENCE_FORMAT then
			if bodyBytes < 4 or buffer.readu16(packet, ENVELOPE_BYTES + 1) ~= methodId then return nil end
			referenceCount = buffer.readu8(packet, ENVELOPE_BYTES + 3)
			if referenceCount > MAXIMUM_REFERENCES then return nil end
		else
			return nil
		end
	end
	local suppliedReferences = sidecarCount or 0
	local admissionBytes = bodyBytes + referenceCount * REFERENCE_BYTES
	local referencesValid = suppliedReferences == referenceCount and suppliedReferences <= MAXIMUM_REFERENCES
		and (kind < 3 or suppliedReferences == 0)
		and ENVELOPE_BYTES + admissionBytes <= MAXIMUM_FRAME_BYTES

	local header = {
		kind = kind,
		methodId = methodId,
		callId = callId,
		sessionGuid = sessionGuid,
		bodyBytes = bodyBytes,
	}
	if version == 2 or not referencesValid then
		header.envelopeVersion = version
		header.referenceCount = referenceCount
		header.sidecarCount = suppliedReferences
		header.admissionBytes = admissionBytes
		header.referencesValid = referencesValid
	end
	return table.freeze(header)
end

local function readBody(packet, header, minimumBodyBytes, maximumBodyBytes, maximumAdmissionBytes,
	maximumReferences, sidecarCount)
	if typeof(packet) ~= "buffer" or type(header) ~= "table" then return nil end
	local length = buffer.len(packet)
	if length < MINIMUM_FRAME_BYTES or length > MAXIMUM_FRAME_BYTES then return nil end
	local version = header.envelopeVersion or 1
	local wireTag = if version == 1 then LEGACY_WIRE_TAG elseif version == 2 then V2_WIRE_TAG else nil
	local bodyBytes = header.bodyBytes
	local expectedReferences = header.referenceCount or 0
	local suppliedReferences = sidecarCount or header.sidecarCount or 0
	local maxReferences = maximumReferences or 0
	local maxAdmission = maximumAdmissionBytes or MAXIMUM_BODY_BYTES
	if wireTag == nil or buffer.readu8(packet, 0) ~= wireTag
		or not isInteger(bodyBytes) or bodyBytes < 3 or bodyBytes > MAXIMUM_BODY_BYTES
		or length ~= ENVELOPE_BYTES + bodyBytes
		or not isInteger(minimumBodyBytes) or not isInteger(maximumBodyBytes)
		or minimumBodyBytes < 3 or maximumBodyBytes < minimumBodyBytes
		or maximumBodyBytes > MAXIMUM_BODY_BYTES
		or bodyBytes < minimumBodyBytes or bodyBytes > maximumBodyBytes
		or (header.kind ~= 1 and header.kind ~= 2)
		or not isInteger(expectedReferences) or expectedReferences < 0
		or not isInteger(suppliedReferences) or suppliedReferences ~= expectedReferences
		or not isInteger(maxReferences) or expectedReferences > maxReferences
		or expectedReferences > MAXIMUM_REFERENCES
		or not isInteger(maxAdmission) or maxAdmission < 0 or maxAdmission > MAXIMUM_BODY_BYTES
		or bodyBytes + expectedReferences * REFERENCE_BYTES > maxAdmission
		or length + expectedReferences * REFERENCE_BYTES > MAXIMUM_FRAME_BYTES then
		return nil
	end
	if buffer.readu8(packet, ENVELOPE_BYTES) == CODEC_VERSION then
		if expectedReferences ~= 0 or buffer.readu16(packet, ENVELOPE_BYTES + 1) ~= header.methodId then return nil end
	elseif version == 2 and buffer.readu8(packet, ENVELOPE_BYTES) == REFERENCE_FORMAT then
		if bodyBytes < 4
			or buffer.readu16(packet, ENVELOPE_BYTES + 1) ~= header.methodId
			or buffer.readu8(packet, ENVELOPE_BYTES + 3) ~= expectedReferences then
			return nil
		end
	else
		return nil
	end

	local body = buffer.create(bodyBytes)
	buffer.copy(body, 0, packet, ENVELOPE_BYTES, bodyBytes)
	return body
end

local function wrap(kind, methodId, callId, sessionGuid, body, allowBudgetFailure, version, referenceCount)
	version = version or 1
	referenceCount = referenceCount or 0
	if (allowBudgetFailure ~= nil and type(allowBudgetFailure) ~= "boolean")
		or (version ~= 1 and version ~= 2)
		or not validKind(kind, version, allowBudgetFailure) or not validIds(methodId, callId)
		or not validGuid(sessionGuid) or not isInteger(referenceCount)
		or referenceCount < 0 or referenceCount > MAXIMUM_REFERENCES then
		return nil
	end
	local bodyBytes = 0
	if kind == 1 or kind == 2 then
		if typeof(body) ~= "buffer" then return nil end
		bodyBytes = buffer.len(body)
		if bodyBytes < 3 or bodyBytes > MAXIMUM_BODY_BYTES
			or bodyBytes + referenceCount * REFERENCE_BYTES > MAXIMUM_BODY_BYTES then
			return nil
		end
		local format = buffer.readu8(body, 0)
		if format == CODEC_VERSION then
			if referenceCount ~= 0 or buffer.readu16(body, 1) ~= methodId then return nil end
		elseif version == 2 and format == REFERENCE_FORMAT then
			if bodyBytes < 4 or buffer.readu16(body, 1) ~= methodId
				or buffer.readu8(body, 3) ~= referenceCount then
				return nil
			end
		else
			return nil
		end
	elseif body ~= nil or referenceCount ~= 0 then
		return nil
	end

	local packet = buffer.create(ENVELOPE_BYTES + bodyBytes)
	buffer.writeu8(packet, 0, if version == 1 then LEGACY_WIRE_TAG else V2_WIRE_TAG)
	buffer.writeu8(packet, 1, kind)
	buffer.writeu16(packet, 2, methodId)
	buffer.writeu32(packet, 4, callId)
	buffer.writestring(packet, 8, sessionGuid)
	if bodyBytes > 0 then buffer.copy(packet, ENVELOPE_BYTES, body, 0, bodyBytes) end
	return packet
end

return table.freeze({
	LEGACY_WIRE_TAG = LEGACY_WIRE_TAG,
	V2_WIRE_TAG = V2_WIRE_TAG,
	ENVELOPE_BYTES = ENVELOPE_BYTES,
	MAXIMUM_FRAME_BYTES = MAXIMUM_FRAME_BYTES,
	MAXIMUM_REFERENCES = MAXIMUM_REFERENCES,
	REFERENCE_BYTES = REFERENCE_BYTES,
	peek = peek,
	readBody = readBody,
	wrap = wrap,
})
