local Definition = require("../../src/Definition")

local scalarTypes = table.freeze({
	boolean = "boolean",
	string = "string",
	u8 = "number",
	u16 = "number",
	u24 = "number",
	u32 = "number",
	i8 = "number",
	i16 = "number",
	i24 = "number",
	i32 = "number",
	f32 = "number",
	f16 = "number",
	f24 = "number",
	f64 = "number",
	quantized = "number",
	Vector2F32 = "Vector2",
	Vector3F32 = "Vector3",
	quantizedVector2 = "Vector2",
	quantizedVector3 = "Vector3",
	CFrame = "CFrame",
	compactCFrame = "CFrame",
	Color3 = "Color3",
})

local nativeTypes = table.freeze({
	UDim = "UDim",
	UDim2 = "UDim2",
	NumberRange = "NumberRange",
	Rect = "Rect",
	BrickColor = "BrickColor",
	Vector2int16 = "Vector2int16",
	Vector3int16 = "Vector3int16",
	NumberSequence = "NumberSequence",
	ColorSequence = "ColorSequence",
	Color3RGB8 = "Color3",
	NumberSequenceKeypoint = "NumberSequenceKeypoint",
	ColorSequenceKeypoint = "ColorSequenceKeypoint",
	TweenInfo = "TweenInfo",
	DateTime = "DateTime",
	Ray = "Ray",
	Axes = "Axes",
	Faces = "Faces",
	Region3 = "Region3",
	Region3int16 = "Region3int16",
	PhysicalProperties = "PhysicalProperties",
	Font = "Font",
	PathWaypoint = "PathWaypoint",
})

local errorCodes = table.freeze({
	"InvalidDefinition", "InvalidOptions", "WrongRuntimeSide", "AlreadyStarted", "NotStarted", "Destroyed",
	"AlreadyConnected", "InvalidHandler", "InvalidPayload", "InvalidPlayer", "InvalidAudience", "StartupTimeout",
	"RemoteOwnershipConflict", "DefinitionMismatch", "Disconnected", "TransportFailure", "RequestLimit",
	"RequestIdExhausted", "RequestTimeout", "Cancelled", "AlreadyAwaiting", "NotYieldable", "HandlerFailure",
	"InvalidResponse", "Busy", "NoListener", "EndpointRateLimited", "ReadinessDisabled", "ReadinessExhausted",
	"QueueLimit", "QueueFull", "QueueClosed", "QueueBusy", "InvalidStateKey", "InvalidPriority",
	"OutboundRateLimited",
})

local function fail(message)
	error("roblox-ts declaration generation: " .. message, 3)
end

local function quote(value)
	if type(value) ~= "string" or utf8.len(value) == nil then
		fail("schema string is not valid UTF-8")
	end

	local pieces = { '"' }
	local index = 1
	while index <= #value do
		local byte = string.byte(value, index)
		if byte == 34 then
			table.insert(pieces, '\\"')
			index += 1
		elseif byte == 92 then
			table.insert(pieces, "\\\\")
			index += 1
		elseif byte == 10 then
			table.insert(pieces, "\\n")
			index += 1
		elseif byte == 13 then
			table.insert(pieces, "\\r")
			index += 1
		elseif byte == 9 then
			table.insert(pieces, "\\t")
			index += 1
		elseif byte == 8 then
			table.insert(pieces, "\\b")
			index += 1
		elseif byte == 12 then
			table.insert(pieces, "\\f")
			index += 1
		elseif byte < 32 or byte == 127 then
			table.insert(pieces, string.format("\\u%04X", byte))
			index += 1
		elseif byte == 226 and string.sub(value, index, index + 2) == "\226\128\168" then
			table.insert(pieces, "\\u2028")
			index += 3
		elseif byte == 226 and string.sub(value, index, index + 2) == "\226\128\169" then
			table.insert(pieces, "\\u2029")
			index += 3
		else
			local width = if byte < 128 then 1 elseif byte < 224 then 2 elseif byte < 240 then 3 else 4
			table.insert(pieces, string.sub(value, index, index + width - 1))
			index += width
		end
	end
	table.insert(pieces, '"')
	return table.concat(pieces)
end

local function sortedKeys(value, label)
	if type(value) ~= "table" then fail(label .. " must be a compiled table") end
	local keys = {}
	for key in value do
		if type(key) ~= "string" then fail(label .. " contains a non-string name") end
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local shapeType

local function fieldsType(fields, label, prefix)
	if type(fields) ~= "table" then fail(label .. " must contain compiled fields") end
	local properties = {}
	if prefix ~= "" then table.insert(properties, prefix) end
	for index = 1, #fields do
		local field = fields[index]
		if type(field) ~= "table" or type(field.name) ~= "string" or type(field.type) ~= "string" then
			fail(label .. " contains a malformed compiled field")
		end
		local optional = field.type == "optional"
		local value = if optional then field.value else field
		if type(value) ~= "table" then fail(label .. " contains a malformed optional field") end
		table.insert(properties, "readonly " .. quote(field.name) .. (if optional then "?" else "")
			.. ": " .. shapeType(value, label .. "." .. field.name))
	end
	if #properties == 0 then
		return "{ readonly [key: string]: never }"
	end
	return "{ " .. table.concat(properties, "; ") .. " }"
end

shapeType = function(shape, label)
	if type(shape) ~= "table" or type(shape.type) ~= "string" then fail(label .. " is not a compiled shape") end
	local kind = shape.type
	local scalar = scalarTypes[kind]
	if scalar ~= nil then return scalar end
	if kind == "buffer" then return "buffer" end
	if kind == "Instance" then
		if type(shape.className) ~= "string" then fail(label .. " has no compiled Instance class") end
		return shape.className
	elseif kind == "enum" then
		if type(shape.values) ~= "table" or #shape.values == 0 then fail(label .. " has no compiled enum values") end
		local values = {}
		for index, value in shape.values do
			if type(value) ~= "string" then fail(label .. " has a malformed enum value") end
			values[index] = quote(value)
		end
		return table.concat(values, " | ")
	elseif kind == "robloxEnum" then
		if type(shape.enumFamily) ~= "string" or string.match(shape.enumFamily, "^Enum%.[A-Za-z_][A-Za-z0-9_]*$") == nil
			or type(shape.values) ~= "table" or #shape.values == 0 then
			fail(label .. " has malformed compiled Roblox enum values")
		end
		local values = {}
		for index, value in shape.values do
			if typeof(value) ~= "EnumItem" or string.match(value.Name, "^[A-Za-z_][A-Za-z0-9_]*$") == nil then
				fail(label .. " has an unsupported Roblox enum item")
			end
			values[index] = shape.enumFamily .. "." .. value.Name
		end
		return table.concat(values, " | ")
	elseif kind == "struct" then
		return fieldsType(shape.fields, label, "")
	elseif kind == "array" then
		return "ReadonlyArray<" .. shapeType(shape.element, label .. "[]") .. ">"
	elseif kind == "set" then
		return "ReadonlyMap<" .. shapeType(shape.element, label .. " set element") .. ", true>"
	elseif kind == "map" then
		return "ReadonlyMap<" .. shapeType(shape.key, label .. " map key") .. ", "
			.. shapeType(shape.value, label .. " map value") .. ">"
	elseif kind == "optional" then
		return shapeType(shape.value, label .. " optional value") .. " | undefined"
	elseif kind == "taggedUnion" then
		if type(shape.tag) ~= "string" or type(shape.variants) ~= "table" or #shape.variants == 0 then
			fail(label .. " has malformed compiled tagged-union variants")
		end
		local variants = {}
		for index, variant in shape.variants do
			if type(variant) ~= "table" or type(variant.label) ~= "string" or type(variant.shape) ~= "table"
				or variant.shape.type ~= "struct" then
				fail(label .. " has a malformed compiled tagged-union variant")
			end
			variants[index] = fieldsType(variant.shape.fields, label .. "." .. variant.label,
				"readonly " .. quote(shape.tag) .. ": " .. quote(variant.label))
		end
		return table.concat(variants, " | ")
	end
	local native = nativeTypes[kind]
	if native ~= nil then return native end
	fail(label .. " uses unsupported shape type " .. kind)
end

local function argumentTypes(fields, label, skipFirst, includePlayer)
	local arguments = {}
	if includePlayer then table.insert(arguments, "player: Player") end
	local nextArgument = 0
	for index = if skipFirst then 2 else 1, #fields do
		local field = fields[index]
		if type(field) ~= "table" then fail(label .. " contains a malformed compiled field") end
		table.insert(arguments, "arg" .. nextArgument .. ": " .. shapeType(field, label .. "[" .. index .. "]"))
		nextArgument += 1
	end
	return table.concat(arguments, ", ")
end

local function callbackType(fields, label, includePlayer)
	local arguments = argumentTypes(fields, label, false, includePlayer)
	return "(this: void" .. (if arguments == "" then "" else ", " .. arguments) .. ") => void"
end

local function eventType(event, side, label)
	if type(event) ~= "table" or type(event.direction) ~= "string" or type(event.fields) ~= "table" then
		fail(label .. " is not a compiled event")
	end
	local receives = (side == "server" and event.direction == "ClientToServer")
		or (side == "client" and event.direction == "ServerToClient")
	if receives then
		local callback = callbackType(event.fields, label, side == "server")
		return "{ Connect(handler: " .. callback .. "): " ..
			"LuaTuple<[Connection | undefined, RelayError | undefined]>; Once(handler: " .. callback .. "): " ..
			"LuaTuple<[Connection | undefined, RelayError | undefined]> }"
	end
	local autoTimestamp = side == "client" and event.direction == "ClientToServer" and event.timestampWindow ~= nil
	local arguments = argumentTypes(event.fields, label, autoTimestamp, side == "server")
	local send = "Send(" .. arguments .. "): LuaTuple<[boolean, RelayError | undefined]>"
	if side == "client" then return "{ " .. send .. " }" end
	local payloadArguments = argumentTypes(event.fields, label, false, false)
	return "{ " .. send .. "; Broadcast(" .. payloadArguments .. "): LuaTuple<[boolean, RelayError | undefined]>"
		.. "; SendTo(recipients: ReadonlyArray<Player>" .. (if payloadArguments == "" then "" else ", " .. payloadArguments)
		.. "): LuaTuple<[boolean, RelayError | undefined, number]>"
		.. "; SendExcept(excluded: ReadonlyArray<Player>" .. (if payloadArguments == "" then "" else ", " .. payloadArguments)
		.. "): LuaTuple<[boolean, RelayError | undefined, number]>"
		.. "; GetReadyPlayers(): LuaTuple<[ReadonlyArray<Player> | undefined, RelayError | undefined]> }"
end

local function requestType(request, side, label)
	if type(request) ~= "table" or type(request.request) ~= "table" or type(request.response) ~= "table" then
		fail(label .. " is not a compiled request")
	end
	local requestFields = request.request.fields
	if type(requestFields) ~= "table" then fail(label .. " has no compiled request fields") end
	local direction = request.request.direction
	if type(direction) ~= "string" then fail(label .. " has no compiled request direction") end
	local responseShape = request.response.fields[1]
	local response = shapeType(responseShape, label .. " response")
	local receives = (side == "server" and direction == "ClientToServer")
		or (side == "client" and direction == "ServerToClient")
	if receives then
		local arguments = argumentTypes(requestFields, label .. " request", false, side == "server")
		local callback = "(this: void" .. (if arguments == "" then "" else ", " .. arguments) .. ") => " .. response
		return "{ Connect(handler: " .. callback .. "): " ..
			"LuaTuple<[Connection | undefined, RelayError | undefined]> }"
	end
	local arguments = argumentTypes(requestFields, label .. " request", false, false)
	local sendArguments = (if side == "server" then "player: Player, " else "") .. "timeoutSeconds: number"
		.. (if arguments == "" then "" else ", " .. arguments)
	return "{ Request(" .. sendArguments .. "): LuaTuple<[PendingRequest<" .. response
		.. "> | undefined, RelayError | undefined]> }"
end

local function endpointMap(source, side, label, emitType)
	local keys = sortedKeys(source, label)
	local properties = {}
	for _, name in keys do
		properties[#properties + 1] = "readonly " .. quote(name) .. ": " .. emitType(source[name], side, label .. "." .. name)
	end
	return if #properties == 0 then "{ readonly [key: string]: never }" else "{ " .. table.concat(properties, "; ") .. " }"
end

local function sessionType(compiled, side)
	local events = endpointMap(compiled.events, side, side .. " events", eventType)
	local requests = endpointMap(compiled.requests, side, side .. " requests", requestType)
	return "{ readonly events: " .. events .. "; readonly requests: " .. requests ..
		"; Start(): LuaTuple<[boolean, RelayError | undefined]>; Destroy(): void }"
end

local function generate(spec)
	local token, definitionError = Definition.define(spec)
	if token == nil then
		fail(definitionError and definitionError.message or "invalid Relay definition")
	end
	local compiled = Definition.get(token)
	if type(compiled) ~= "table" then fail("Relay compiler did not return a canonical definition") end

	local errorLiterals = {}
	for index, code in errorCodes do errorLiterals[index] = quote(code) end
	return table.concat({
		"export type ErrorCode = " .. table.concat(errorLiterals, " | ") .. ";",
		"export interface RelayError { readonly code: ErrorCode; readonly message: string }",
		"export interface Connection { Disconnect(): void }",
		"export type RequestResult<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: RelayError };",
		"export interface PendingRequest<T> { Await(): RequestResult<T>; Cancel(): void }",
		"export interface EndpointRate { readonly capacity: number; readonly refillPerSecond: number }",
		"export interface InboundRate { readonly perPlayer: EndpointRate; readonly aggregate: EndpointRate; readonly endpoints?: ReadonlyMap<number, EndpointRate>; readonly bytes?: { readonly perPlayer: EndpointRate; readonly aggregate: EndpointRate } }",
		"export interface SessionDiagnosticsOptions { readonly traffic?: boolean; readonly reports?: boolean }",
		"export interface ServerOptions { readonly inboundRate: InboundRate; readonly instanceRoot"
			.. (if compiled.hasReferences then ": Instance" else "?: never") .. "; readonly diagnostics?: SessionDiagnosticsOptions }",
		"export interface ClientOptions { readonly startupTimeoutSeconds: number; readonly diagnostics?: SessionDiagnosticsOptions }",
		"export interface Server " .. sessionType(compiled, "server"),
		"export interface Client " .. sessionType(compiled, "client"),
		"export declare function createServer(this: void, options: ServerOptions): LuaTuple<[Server | undefined, RelayError | undefined]>;",
		"export declare function createClient(this: void, options: ClientOptions): LuaTuple<[Client | undefined, RelayError | undefined]>;",
		"",
	}, "\n")
end

return table.freeze({ generate = generate })
