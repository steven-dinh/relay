--!strict

local Contract = require("../contracts/event-v1")

export type MismatchReason =
	"WrongContainerType"
	| "ArityMismatch"
	| "MissingField"
	| "ExtraField"
	| "WrongType"
	| "NonFinite"
	| "NonInteger"
	| "OutOfRange"
	| "NotFloat32"
	| "ValueMismatch"

export type Mismatch = {
	path: string,
	reason: MismatchReason,
	expectedPresent: boolean,
	actualPresent: boolean,
	expected: (boolean | number)?,
	actual: (boolean | number)?,
}

type Field = {
	name: string,
	valueType: string,
	minimum: number?,
	maximum: number?,
}

local COMPONENTS = { "X", "Y", "Z" }
local floatBuffer = buffer.create(4)

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isDiagnosticValue(value: any): boolean
	return type(value) == "boolean" or (type(value) == "number" and isFinite(value))
end

local function newMismatch(
	path: string,
	reason: MismatchReason,
	expectedPresent: boolean,
	actualPresent: boolean,
	expectedValue: any,
	actualValue: any,
	storeValues: boolean
): Mismatch
	local mismatch: Mismatch = {
		path = path,
		reason = reason,
		expectedPresent = expectedPresent,
		actualPresent = actualPresent,
	}

	if storeValues and isDiagnosticValue(expectedValue) then
		mismatch.expected = expectedValue
	end
	if storeValues and isDiagnosticValue(actualValue) then
		mismatch.actual = actualValue
	end

	return mismatch
end

local function float32(value: number): (number, number)
	buffer.writef32(floatBuffer, 0, value)
	return buffer.readf32(floatBuffer, 0), buffer.readu32(floatBuffer, 0)
end

local function resolvePayload(payloadId: string): any
	local payload = Contract.payloads[payloadId]
	if payload == nil then
		error(`unknown Event V1 payload id {payloadId}`, 3)
	end
	return payload
end

local function compareFloat32(
	field: Field,
	path: string,
	expectedValue: number,
	actualValue: any,
	actualPresent: boolean
): Mismatch?
	if type(actualValue) ~= "number" then
		return newMismatch(path, "WrongType", true, actualPresent, expectedValue, actualValue, true)
	end
	if not isFinite(actualValue) then
		return newMismatch(path, "NonFinite", true, actualPresent, expectedValue, actualValue, true)
	end

	local minimum = field.minimum
	local maximum = field.maximum
	if (minimum ~= nil and actualValue < minimum) or (maximum ~= nil and actualValue > maximum) then
		return newMismatch(path, "OutOfRange", true, actualPresent, expectedValue, actualValue, true)
	end

	local roundTrip, actualBits = float32(actualValue)
	if roundTrip ~= actualValue then
		return newMismatch(path, "NotFloat32", true, actualPresent, expectedValue, actualValue, true)
	end

	local _, expectedBits = float32(expectedValue)
	if actualBits ~= expectedBits then
		return newMismatch(path, "ValueMismatch", true, actualPresent, expectedValue, actualValue, true)
	end

	return nil
end

local function compareField(
	field: Field,
	expectedValue: any,
	actualValue: any,
	actualPresent: boolean
): Mismatch?
	local path = field.name
	local valueType = field.valueType

	if valueType == "boolean" then
		if type(actualValue) ~= "boolean" then
			return newMismatch(path, "WrongType", true, actualPresent, expectedValue, actualValue, true)
		end
		if actualValue ~= expectedValue then
			return newMismatch(path, "ValueMismatch", true, actualPresent, expectedValue, actualValue, true)
		end
		return nil
	end

	if valueType == "u8" or valueType == "u16" or valueType == "u32" then
		if type(actualValue) ~= "number" then
			return newMismatch(path, "WrongType", true, actualPresent, expectedValue, actualValue, true)
		end
		if not isFinite(actualValue) then
			return newMismatch(path, "NonFinite", true, actualPresent, expectedValue, actualValue, true)
		end
		if actualValue % 1 ~= 0 then
			return newMismatch(path, "NonInteger", true, actualPresent, expectedValue, actualValue, true)
		end

		local minimum = field.minimum
		local maximum = field.maximum
		if (minimum ~= nil and actualValue < minimum) or (maximum ~= nil and actualValue > maximum) then
			return newMismatch(path, "OutOfRange", true, actualPresent, expectedValue, actualValue, true)
		end
		if actualValue ~= expectedValue then
			return newMismatch(path, "ValueMismatch", true, actualPresent, expectedValue, actualValue, true)
		end
		return nil
	end

	if valueType == "f32" then
		return compareFloat32(field, path, expectedValue, actualValue, actualPresent)
	end

	if valueType == "Vector3F32" then
		if typeof(actualValue) ~= "Vector3" then
			return newMismatch(path, "WrongType", true, actualPresent, expectedValue, actualValue, true)
		end

		for _, component in COMPONENTS do
			local componentMismatch = compareFloat32(
				field,
				`{path}.{component}`,
				expectedValue[component],
				actualValue[component],
				actualPresent
			)
			if componentMismatch ~= nil then
				return componentMismatch
			end
		end
		return nil
	end

	error(`unsupported Event V1 payload value type {valueType}`, 3)
end

local function compareRecord(
	payloadId: string,
	expected: { [string]: any },
	actual: unknown
): (boolean, Mismatch?)
	local payload = resolvePayload(payloadId)
	if type(actual) ~= "table" then
		return false, newMismatch("$", "WrongContainerType", true, true, expected, actual, false)
	end
	if getmetatable(actual) ~= nil then
		return false, newMismatch("$", "WrongContainerType", true, true, expected, actual, false)
	end

	for _, field in payload.fields do
		local actualValue = rawget(actual, field.name)
		if actualValue == nil then
			return false, newMismatch(
				field.name,
				"MissingField",
				true,
				false,
				rawget(expected, field.name),
				nil,
				true
			)
		end
	end

	local declaredFieldCount = #payload.fields
	local rawKeyCount = 0
	local key = next(actual)
	while key ~= nil do
		rawKeyCount += 1
		if rawKeyCount > declaredFieldCount then
			return false, newMismatch("$", "ExtraField", false, true, nil, nil, false)
		end
		key = next(actual, key)
	end
	if rawKeyCount ~= declaredFieldCount then
		return false, newMismatch("$", "ExtraField", false, true, nil, nil, false)
	end

	for _, field in payload.fields do
		local expectedValue = rawget(expected, field.name)
		local mismatch = compareField(field, expectedValue, rawget(actual, field.name), true)
		if mismatch ~= nil then
			return false, mismatch
		end
	end

	return true, nil
end

local function comparePositional(
	payloadId: string,
	expected: { [string]: any },
	...: any
): (boolean, Mismatch?)
	local payload = resolvePayload(payloadId)
	local expectedCount = #payload.fields
	local actualCount = select("#", ...)
	if actualCount ~= expectedCount then
		return false, newMismatch("$", "ArityMismatch", true, true, expectedCount, actualCount, true)
	end

	for index, field in payload.fields do
		local mismatch = compareField(field, rawget(expected, field.name), select(index, ...), true)
		if mismatch ~= nil then
			return false, mismatch
		end
	end

	return true, nil
end

return {
	compareRecord = compareRecord,
	comparePositional = comparePositional,
}
