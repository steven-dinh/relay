-- Native Studio fixtures for the RR16 RPC, bounded schema, and Instance routes.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local InstanceValues = require(ReplicatedStorage.RelayProofInstanceValues)
local schema = Relay.schema
local part = schema.Instance("Part")
local folder = schema.Instance("Folder")

local function referenceFields()
    return {
        schema.field("part", part),
        schema.field("samePart", part),
        schema.field("folder", folder),
    }
end

local function create()
    local numericFields = {
        schema.field("unsigned", schema.u24()),
        schema.field("signed", schema.i24()),
        schema.field("half", schema.f16(-2, 2)),
        schema.field("compactFloat", schema.f24(-4, 4)),
        schema.field("double", schema.f64(-4, 4)),
        schema.field("wideGrid", schema.quantized(0, 4_294_967_295, 1)),
    }
    local boundedCollections = schema.struct(
        schema.field("text", schema.string(5, 3)),
        schema.field("binary", schema.buffer(4, 2)),
        schema.field("exact", schema.array(schema.u8(), 2, 2)),
        schema.field("items", schema.array(schema.u8(), 4, 2)),
        schema.field("members", schema.set(schema.u8(), 4, 2)),
        schema.field("scores", schema.map(schema.u8(), schema.u24(), 4, 2))
    )
    local definition, failure = Relay.define({
        name = "RelayRpcBoundedRoutesProof",
        version = 1,
        readiness = true,
        events = {
            Input = { id = 1, direction = "ClientToServer", fields = referenceFields() },
            Output = { id = 2, direction = "ServerToClient", fields = referenceFields() },
            UnreliableInput = { id = 3, direction = "ClientToServer", delivery = "Unreliable",
                fields = referenceFields() },
            UnreliableOutput = { id = 4, direction = "ServerToClient", delivery = "Unreliable",
                fields = referenceFields() },
            OrderedInput = { id = 5, direction = "ClientToServer", delivery = "OrderedUnreliable",
                fields = referenceFields() },
            OrderedOutput = { id = 6, direction = "ServerToClient", delivery = "OrderedUnreliable",
                fields = referenceFields() },
            QueueInput = { id = 7, direction = "ClientToServer", queue = "Batch", fields = referenceFields() },
            QueueOutput = { id = 8, direction = "ServerToClient", queue = "Batch", fields = referenceFields() },
            UnreliableQueueInput = { id = 9, direction = "ClientToServer", delivery = "Unreliable",
                queue = "Batch", fields = referenceFields() },
            UnreliableQueueOutput = { id = 10, direction = "ServerToClient", delivery = "Unreliable",
                queue = "Batch", fields = referenceFields() },
            StateInput = { id = 11, direction = "ClientToServer", queue = "State", fields = referenceFields() },
            StateOutput = { id = 12, direction = "ServerToClient", queue = "State", fields = referenceFields() },
            LegacyInput = { id = 18, direction = "ClientToServer", fields = { schema.field("value", schema.u8()) } },
            LegacyOutput = { id = 19, direction = "ServerToClient", fields = { schema.field("value", schema.u8()) } },
            LegacyQueueInput = { id = 20, direction = "ClientToServer", queue = "Batch",
                fields = { schema.field("value", schema.u8()) } },
            LegacyQueueOutput = { id = 21, direction = "ServerToClient", queue = "Batch",
                fields = { schema.field("value", schema.u8()) } },
            NumericInput = { id = 13, direction = "ClientToServer", fields = numericFields },
            NumericOutput = { id = 14, direction = "ServerToClient", fields = numericFields },
            BoundedInput = { id = 15, direction = "ClientToServer", fields = {
                schema.field("value", boundedCollections),
            } },
            BoundedOutput = { id = 16, direction = "ServerToClient", fields = {
                schema.field("value", boundedCollections),
            } },
            MinimumInput = { id = 17, direction = "ClientToServer", fields = {
                schema.field("value", schema.string(5, 3)),
            } },
        },
        requests = {
            Echo = schema.request(100, { schema.field("part", part) }, part, {
                concurrency = 2,
                refusals = true,
            }),
            Concurrent = schema.request(101, { schema.field("hold", schema.boolean()) },
                schema.optional(schema.boolean()), { concurrency = 2, refusals = true }),
            ClientCall = schema.request(102, {
                schema.field("part", part),
                schema.field("returnNil", schema.boolean()),
                schema.field("returnMissing", schema.boolean()),
                schema.field("hold", schema.boolean()),
            }, schema.struct(
                schema.field("part", part),
                schema.field("status", schema.optional(schema.boolean()))
            ), {
                direction = "ServerToClient",
                concurrency = 2,
                refusals = true,
            }),
            NoListener = schema.request(103, { schema.field("value", schema.u8()) }, schema.boolean(), {
                direction = "ServerToClient",
                refusals = true,
            }),
            LegacyRpc = schema.request(104, { schema.field("value", schema.u8()) }, schema.u8()),
        },
    })
    assert(definition ~= nil, failure and failure.message or "RPC/bounded native definition failed")
    return definition
end

local function objects(player)
    local values = InstanceValues.scopeObjects()
    return values.part, values.folder
end

local function checkReferences(first, second, third, player)
    local expectedPart, expectedFolder = objects(player)
    assert(first == expectedPart and second == expectedPart and third == expectedFolder,
        "native reference slot identity and duplicate preservation")
    return {
        part = first:GetFullName(),
        partClass = first.ClassName,
        folder = third:GetFullName(),
        folderClass = third.ClassName,
    }
end

local function referenceValues(player)
    local first, second = objects(player)
    return first, first, second
end

local function numericValues()
    return 16_777_215, -8_388_608, 1.5, -2.25, math.pi, 4_294_967_295
end

local function checkNumeric(unsigned, signed, half, compactFloat, double, wideGrid)
    assert(unsigned == 16_777_215 and signed == -8_388_608, "u24/i24 extrema")
    assert(half == 1.5 and compactFloat == -2.25 and double == math.pi, "native compact float values")
    assert(wideGrid == 4_294_967_295, "four-byte quantized index maximum")
    return { unsigned = unsigned, signed = signed, half = half, compactFloat = compactFloat,
        double = double, wideGrid = wideGrid }
end

local function boundedValue()
    local binary = buffer.create(3)
    buffer.writeu8(binary, 0, 201)
    buffer.writeu8(binary, 1, 202)
    buffer.writeu8(binary, 2, 203)
    return {
        text = "abcd",
        binary = binary,
        exact = { 10, 11 },
        items = { 12, 13, 14 },
        members = { [1] = true, [2] = true, [3] = true },
        scores = { [1] = 0x010203, [2] = 0x040506, [3] = 0x070809 },
    }
end

local function checkBounded(value)
    assert(type(value) == "table" and value.text == "abcd", "minimum-relative string length")
    assert(typeof(value.binary) == "buffer" and buffer.len(value.binary) == 3, "minimum-relative buffer length")
    assert(buffer.readu8(value.binary, 0) == 201 and buffer.readu8(value.binary, 1) == 202
        and buffer.readu8(value.binary, 2) == 203, "native bounded buffer bytes")
    assert(type(value.exact) == "table" and #value.exact == 2
        and value.exact[1] == 10 and value.exact[2] == 11, "exact array length")
    assert(type(value.items) == "table" and #value.items == 3
        and value.items[1] == 12 and value.items[2] == 13 and value.items[3] == 14,
        "minimum-relative array length")
    local memberCount = 0
    for item, present in value.members do
        assert(present == true and (item == 1 or item == 2 or item == 3), "bounded set member")
        memberCount += 1
    end
    assert(memberCount == 3, "minimum-relative set length")
    local expected = { [1] = 0x010203, [2] = 0x040506, [3] = 0x070809 }
    local scoreCount = 0
    for key, score in value.scores do
        assert(expected[key] == score, "minimum-relative map entry")
        scoreCount += 1
    end
    assert(scoreCount == 3, "minimum-relative map length")
    return { text = value.text, binaryBytes = buffer.len(value.binary), exactCount = #value.exact,
        binaryValues = { buffer.readu8(value.binary, 0), buffer.readu8(value.binary, 1),
            buffer.readu8(value.binary, 2) },
        itemCount = #value.items, memberCount = memberCount, scoreCount = scoreCount }
end

local function bytes(length, values)
    local result = buffer.create(length)
    for offset, value in values do buffer.writeu8(result, offset, value) end
    return result
end

local function malformedMinimumPacket()
    -- MinimumInput has one string field with a 3..5 byte range. The compact
    -- prefix is an offset, so 3 is outside its permitted span [0, 2].
    return bytes(4, { [0] = 1, [1] = 17, [2] = 0, [3] = 3 })
end

local function malformedReferencePacket(eventId)
    return bytes(7, { [0] = 4, [1] = eventId % 256, [2] = math.floor(eventId / 256),
        [3] = 3, [4] = 1, [5] = 2, [6] = 4 })
end

local function malformedLateQueuePacket(kind, eventId)
    assert(kind == 1 and (eventId == 7 or eventId == 9), "Batch kind and queued endpoint")
    return bytes(22, {
        [0] = 5, [1] = kind, [2] = 2, [3] = 6,
        [4] = 7, [5] = 0,
        [6] = 4, [7] = eventId % 256, [8] = math.floor(eventId / 256),
        [9] = 3, [10] = 1, [11] = 2, [12] = 3,
        [13] = 7, [14] = 0,
        [15] = 4, [16] = eventId % 256, [17] = math.floor(eventId / 256),
        [18] = 3, [19] = 1, [20] = 2, [21] = 7,
    })
end

local function queueSidecars(player)
    local first, second, third = referenceValues(player)
    return { first, second, third, first, second, third }
end

local function outOfScopeQueuePacket(kind, eventId)
    assert(kind == 1 and (eventId == 7 or eventId == 9), "Batch kind and queued endpoint")
    return bytes(13, {
        [0] = 5, [1] = kind, [2] = 1, [3] = 3,
        [4] = 7, [5] = 0,
        [6] = 4, [7] = eventId % 256, [8] = math.floor(eventId / 256),
        [9] = 3, [10] = 1, [11] = 2, [12] = 3,
    })
end

local function instanceReceipt(endpoint, packet, ...)
    local args = table.pack(...)
    local receipt = {
        endpoint = endpoint,
        length = if typeof(packet) == "buffer" then buffer.len(packet) else nil,
        format = if typeof(packet) == "buffer" and buffer.len(packet) >= 1 then buffer.readu8(packet, 0) else nil,
        referenceCount = args.n,
        argumentCount = args.n + 1,
        instanceArguments = 0,
        nilArguments = 0,
        references = table.create(args.n),
    }
    if typeof(packet) == "buffer" and buffer.len(packet) >= 4 then
        if receipt.format == 1 then
            if endpoint == 0 and buffer.len(packet) >= 44 then
                receipt.rpcTag = 1
                receipt.rpcKind = buffer.readu8(packet, 1)
                receipt.methodId = buffer.readu16(packet, 2)
                if buffer.len(packet) > 44 then receipt.bodyFormat = buffer.readu8(packet, 44) end
            else
                receipt.eventId = buffer.readu16(packet, 1)
            end
        elseif receipt.format == 2 then
            receipt.queueKind = buffer.readu8(packet, 1)
            receipt.recordCount = buffer.readu8(packet, 2)
        elseif receipt.format == 4 then
            receipt.eventId = buffer.readu16(packet, 1)
            receipt.localReferenceCount = buffer.readu8(packet, 3)
            if buffer.len(packet) >= 7 then
                receipt.ordinals = { buffer.readu8(packet, 4), buffer.readu8(packet, 5),
                    buffer.readu8(packet, 6) }
            end
        elseif receipt.format == 5 and buffer.len(packet) >= 4 then
            receipt.queueKind = buffer.readu8(packet, 1)
            receipt.recordCount = buffer.readu8(packet, 2)
            receipt.localReferenceCount = buffer.readu8(packet, 3)
        elseif receipt.format == 6 and buffer.len(packet) >= 12 then
            receipt.eventId = buffer.readu16(packet, 1)
            receipt.localReferenceCount = buffer.readu8(packet, 11)
        elseif receipt.format == 7 and buffer.len(packet) >= 44 then
            receipt.rpcTag = 7
            receipt.rpcKind = buffer.readu8(packet, 1)
            receipt.methodId = buffer.readu16(packet, 2)
            if buffer.len(packet) > 44 then receipt.bodyFormat = buffer.readu8(packet, 44) end
            if receipt.bodyFormat == 4 and buffer.len(packet) >= 48 then
                receipt.localReferenceCount = buffer.readu8(packet, 47)
            end
        end
        if (receipt.format == 2 or receipt.format == 5) and receipt.recordCount ~= nil
            and receipt.recordCount <= 32 then
            local offset = if receipt.format == 5 then 4 else 3
            local records = table.create(receipt.recordCount)
            for _ = 1, receipt.recordCount do
                if offset + 2 > buffer.len(packet) then break end
                local bodyBytes = buffer.readu16(packet, offset)
                if bodyBytes < 3 or bodyBytes > buffer.len(packet) - offset - 2 then break end
                local bodyOffset = offset + 2
                table.insert(records, {
                    format = buffer.readu8(packet, bodyOffset),
                    eventId = buffer.readu16(packet, bodyOffset + 1),
                    length = bodyBytes,
                    localReferenceCount = if buffer.readu8(packet, bodyOffset) == 4 and bodyBytes >= 4
                        then buffer.readu8(packet, bodyOffset + 3) else 0,
                })
                offset = bodyOffset + bodyBytes
            end
            receipt.records = records
        end
        if receipt.format == 1 and (receipt.eventId == 13 or receipt.eventId == 14)
            and buffer.len(packet) == 26 then
            local encoded = table.create(23)
            for offset = 3, 25 do encoded[offset - 2] = buffer.readu8(packet, offset) end
            receipt.numericBytes = encoded
        elseif receipt.format == 1 and (receipt.eventId == 15 or receipt.eventId == 16)
            and buffer.len(packet) == 35 then
            receipt.compactPrefixes = {
                text = buffer.readu8(packet, 3),
                binary = buffer.readu8(packet, 8),
                items = buffer.readu8(packet, 14),
                members = buffer.readu8(packet, 18),
                scores = buffer.readu8(packet, 22),
            }
            receipt.exactArrayBytes = { buffer.readu8(packet, 12), buffer.readu8(packet, 13) }
        elseif receipt.format == 1 and receipt.eventId == 17 and buffer.len(packet) >= 4 then
            receipt.minimumOffset = buffer.readu8(packet, 3)
        end
    end
    for index = 1, args.n do
        local value = args[index]
        if typeof(value) == "Instance" then
            receipt.instanceArguments += 1
            receipt.references[index] = {
                kind = "Instance",
                className = value.ClassName,
                name = value.Name,
                path = value:GetFullName(),
            }
            if value:IsA("Player") then receipt.references[index].userId = value.UserId end
        elseif value == nil then
            receipt.nilArguments += 1
            receipt.references[index] = { kind = "nil", className = "nil" }
        else
            receipt.references[index] = { kind = typeof(value), className = typeof(value) }
        end
    end
    return receipt
end

local function rawOrderedReceipt(endpoint, packet, ...)
    local receipt = instanceReceipt(endpoint, packet, ...)
    if typeof(packet) == "buffer" and buffer.len(packet) >= 1 then
        receipt.orderedTag = buffer.readu8(packet, 0)
    end
    return receipt
end

return table.freeze({
    create = create,
    objects = objects,
    checkReferences = checkReferences,
    referenceValues = referenceValues,
    numericValues = numericValues,
    checkNumeric = checkNumeric,
    boundedValue = boundedValue,
    checkBounded = checkBounded,
    malformedMinimumPacket = malformedMinimumPacket,
    malformedReferencePacket = malformedReferencePacket,
    malformedLateQueuePacket = malformedLateQueuePacket,
    queueSidecars = queueSidecars,
    outOfScopeQueuePacket = outOfScopeQueuePacket,
    instanceReceipt = instanceReceipt,
    rawOrderedReceipt = rawOrderedReceipt,
})
