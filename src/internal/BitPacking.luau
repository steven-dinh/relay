local LengthBounds = require(if script then script.Parent.LengthBounds else "./LengthBounds")

local function enumBitWidth(count)
	local width, capacity = 0, 1
	while capacity < count do
		capacity *= 2
		width += 1
	end
	return math.max(1, width)
end

local function flagKind(shape)
	if shape.type == "boolean" then return "boolean", 1 end
	if shape.type == "enum" then
		return "enum", enumBitWidth(#shape.values)
	end
	if shape.type == "optional" then
		local kind, width = flagKind(shape.value)
		if kind == "boolean" or kind == "enum" then return "optional" .. kind, width + 1 end
		return "optional", 1
	end
	return nil, 0
end

local function maskBytes(bits)
	return math.ceil(bits / 8)
end

local function fieldsBounds(fields)
	local bits, minimum, maximum = 0, 0, 0
	for _, field in fields do
		local kind, width = flagKind(field)
		bits += width
		if kind == nil then
			minimum += field.minimumEncodedBytes
			maximum += field.maximumEncodedBytes
		elseif kind == "optional" then
			maximum += field.value.maximumEncodedBytes
		end
	end
	local mask = maskBytes(bits)
	return mask + minimum, mask + maximum
end

local function bounds(shape)
	local kind = shape.type
	if kind == "struct" then
		return fieldsBounds(shape.fields)
	elseif kind == "optional" then
		return fieldsBounds({ shape })
	elseif kind == "taggedUnion" then
		local minimum, maximum = math.huge, 0
		for _, variant in shape.variants do
			local childMinimum, childMaximum = bounds(variant.shape)
			minimum = math.min(minimum, childMinimum)
			maximum = math.max(maximum, childMaximum)
		end
		return 1 + minimum, 1 + maximum
	elseif kind == "array" or kind == "set" then
		local element = shape.element
		local flag, width = flagKind(element)
		local capacity = if kind == "array" then shape.maximumLength else shape.maximumSize
		local minimumCount = if kind == "array" then shape.minimumLength else shape.minimumSize
		local countBytes = shape.countBytes
		if flag == "boolean" or flag == "enum" then
			return countBytes + maskBytes(minimumCount * width), countBytes + maskBytes(capacity * width)
		end
		return countBytes + minimumCount * element.minimumEncodedBytes,
			countBytes + capacity * element.maximumEncodedBytes
	elseif kind == "map" then
		local pairMinimum, pairMaximum = fieldsBounds({ shape.key, shape.value })
		return shape.countBytes + shape.minimumSize * pairMinimum,
			shape.countBytes + shape.maximumSize * pairMaximum
	elseif kind == "boolean" or kind == "enum" then
		return fieldsBounds({ shape })
	end
	return shape.minimumEncodedBytes, shape.maximumEncodedBytes
end

local function enumWidth(node)
	return enumBitWidth(#node.values)
end

local function nodeFlagKind(node)
	if node.type == "boolean" then return "boolean", 1 end
	if node.type == "enum" then return "enum", enumWidth(node) end
	if node.type == "optional" then
		local kind, width = nodeFlagKind(node.value)
		if kind == "boolean" or kind == "enum" then return "optional" .. kind, width + 1 end
		return "optional", 1
	end
	return nil, 0
end

local function makeLayout(fields)
	local entries = table.create(#fields)
	local bits, minimumBody = 0, 0
	for index, field in fields do
		local node = field.child or field
		local kind, width = nodeFlagKind(node)
		entries[index] = { node = node, name = field.name, kind = kind,
			presenceBit = bits, valueBit = bits + (if kind == "optional" or kind == "optionalboolean"
				or kind == "optionalenum" then 1 else 0), width = width - (if kind == "optionalboolean"
				or kind == "optionalenum" then 1 else 0) }
		bits += width
		if kind == nil then minimumBody += node.minimum end
	end
	local bytes = maskBytes(bits)
	return { entries = entries, bits = bits, bytes = bytes, minimum = bytes + minimumBody }
end

local function compile(event, mode, compileScalar, context, helpers)
	if mode == nil then mode = "validate" end
	if mode ~= "encode" and mode ~= "validate" and mode ~= "decode" then
		return function(...) return nil end
	end

	local fields = event.fields
	local nodes = table.create(#fields)
	for index, field in fields do nodes[index] = helpers.compileNode(field) end
	local layouts = {}
	local blockSize, writeBlock, readPacked, writePacked
	local function prepare(node)
		if layouts[node] ~= nil then return end
		if node.type == "struct" then
			layouts[node] = makeLayout(node.fields)
			for _, field in node.fields do prepare(field.child) end
		elseif node.type == "taggedUnion" then
			for _, variant in node.variants do prepare(variant.node) end
		elseif node.type == "array" or node.type == "set" then
			prepare(node.element)
		elseif node.type == "map" then
			prepare(node.key)
			prepare(node.value)
			layouts[node] = makeLayout({ node.key, node.value })
		elseif node.type == "optional" then
			prepare(node.value)
		end
	end
	for _, node in nodes do prepare(node) end
	local tupleLayout = makeLayout(nodes)
	local hasReferences = event.hasReferences == true
	local headerBytes = if hasReferences then helpers.referenceHeaderBytes else 3
	local formatVersion = if hasReferences then helpers.referenceFormat else 1
	local maximumTotalBytes = if event.delivery == "Unreliable" then 900 else 8_192
	local maximumBufferBytes = math.min(
		maximumTotalBytes, event.maximumEncodedBytes)
	local maximumReferences = math.min(event.maximumReferences or 0, helpers.maximumReferences)

	local function packedSize(node, value)
		if node.type == "struct" then
			return blockSize(layouts[node], value)
		elseif node.type == "taggedUnion" then
			local variant = node.byTag[value[node.tag]]
			if variant == nil then return nil end
			return 1 + blockSize(layouts[variant.node], value)
		elseif node.type == "array" then
			local count = #value
			local flag, width = nodeFlagKind(node.element)
			if flag == "boolean" or flag == "enum" then return node.countBytes + maskBytes(count * width) end
			local size = node.countBytes
			for index = 1, count do
				local childSize = packedSize(node.element, value[index])
				if childSize == nil then return nil end
				size += childSize
			end
			return size
		elseif node.type == "set" then
			local count, flag, width = 0, nodeFlagKind(node.element)
			for _ in value do count += 1 end
			if flag == "boolean" or flag == "enum" then return node.countBytes + maskBytes(count * width) end
			local size = node.countBytes
			for element in value do
				local childSize = packedSize(node.element, element)
				if childSize == nil then return nil end
				size += childSize
			end
			return size
		elseif node.type == "map" then
			local size = node.countBytes
			local key = next(value)
			while key ~= nil do
				size += blockSize(layouts[node], { key, rawget(value, key) })
				key = next(value, key)
			end
			return size
		elseif node.type == "optional" then
			if value == nil then return 0 end
			return packedSize(node.value, value)
		elseif node.type == "boolean" or node.type == "enum" then
			return 0
		elseif node.type == "buffer" then
			return node.countBytes + buffer.len(value)
		elseif node.native then
			local valid, _, size = node.native.normalize(value)
			return if valid then size else nil
		elseif node.type == "string" then
			return node.countBytes + #value
		end
		return node.minimum
	end

	blockSize = function(layout, values)
		local size = layout.bytes
		for _, entry in layout.entries do
			local value = if entry.name ~= nil then rawget(values, entry.name) else values[_]
			local kind = entry.kind
			if kind == nil then
				local childSize = packedSize(entry.node, value)
				if childSize == nil then return nil end
				size += childSize
			elseif kind == "optional" and value ~= nil then
				local childSize = packedSize(entry.node.value, value)
				if childSize == nil then return nil end
				size += childSize
			end
		end
		return size
	end

	local function writeBit(output, offset, bitOffset, value)
		if value == 0 then return end
		local byteOffset = offset + math.floor(bitOffset / 8)
		local bit = bit32.lshift(1, bitOffset % 8)
		buffer.writeu8(output, byteOffset, bit32.bor(buffer.readu8(output, byteOffset), bit))
	end

	local function writeBits(output, offset, bitOffset, width, value)
		for index = 0, width - 1 do
			writeBit(output, offset, bitOffset + index, math.floor(value / (2 ^ index)) % 2)
		end
	end

	local function readBitsAt(state, baseOffset, offset, width)
		local value = 0
		for index = 0, width - 1 do
			local absolute = offset + index
			local byte = buffer.readu8(state.value, baseOffset + math.floor(absolute / 8))
			value += bit32.band(bit32.rshift(byte, absolute % 8), 1) * (2 ^ index)
		end
		return value
	end

	writePacked = function(node, value, output, offset, referenceState)
		if node.type == "struct" then
			return writeBlock(layouts[node], value, output, offset, referenceState)
		elseif node.type == "taggedUnion" then
			local variant = node.byTag[value[node.tag]]
			buffer.writeu8(output, offset, variant.ordinal)
			return writeBlock(layouts[variant.node], value, output, offset + 1, referenceState)
		elseif node.type == "array" or node.type == "set" then
			local isArray = node.type == "array"
			local count = if isArray then #value else 0
			if not isArray then for _ in value do count += 1 end end
			offset = LengthBounds.write(output, offset, count, node.minimumLength, node.countBytes)
			local flag, width = nodeFlagKind(node.element)
			if flag == "boolean" or flag == "enum" then
				local maskLength = maskBytes(count * width)
				local baseBit = 0
				if isArray then
					for index = 1, count do
						local element = value[index]
						local code = if flag == "boolean" then (if element then 1 else 0) else node.element.ordinals[element]
						writeBits(output, offset, baseBit, width, code)
						baseBit += width
					end
				else
					for element in value do
						local code = if flag == "boolean" then (if element then 1 else 0) else node.element.ordinals[element]
						writeBits(output, offset, baseBit, width, code)
						baseBit += width
					end
				end
				return offset + maskLength
			end
			if isArray then
				for index = 1, count do offset = writePacked(node.element, value[index], output, offset, referenceState) end
			else
				for element in value do offset = writePacked(node.element, element, output, offset, referenceState) end
			end
			return offset
		elseif node.type == "map" then
			local countOffset = offset
			offset += node.countBytes
			local count, key = 0, next(value)
			while key ~= nil do
				count += 1
				offset = writeBlock(layouts[node], { key, rawget(value, key) }, output, offset, referenceState)
				key = next(value, key)
			end
			LengthBounds.write(output, countOffset, count, node.minimumLength, node.countBytes)
			return offset
		elseif node.type == "optional" then
			local layout = makeLayout({ node })
			return writeBlock(layout, { value }, output, offset, referenceState)
		elseif node.type == "boolean" or node.type == "enum" then
			local layout = makeLayout({ node })
			return writeBlock(layout, { value }, output, offset, referenceState)
		end
		if node.containsReferences then
			return helpers.writeReferenceNode(node, value, output, offset, referenceState)
		end
		return helpers.writeNode(node, value, output, offset)
	end

	writeBlock = function(layout, values, output, offset, referenceState)
		local maskOffset, bodyOffset = offset, offset + layout.bytes
		for index, entry in layout.entries do
			local value = if entry.name ~= nil then rawget(values, entry.name) else values[index]
			local kind = entry.kind
			if kind == "boolean" then
				writeBits(output, maskOffset, entry.valueBit, 1, if value then 1 else 0)
			elseif kind == "enum" then
				writeBits(output, maskOffset, entry.valueBit, entry.width, entry.node.ordinals[value])
			elseif kind == "optionalboolean" or kind == "optionalenum" then
				if value ~= nil then
					writeBit(output, maskOffset, entry.presenceBit, 1)
					local child = entry.node.value
					local code = if kind == "optionalboolean" then (if value then 1 else 0) else child.ordinals[value]
					writeBits(output, maskOffset, entry.valueBit, entry.width, code)
				end
			elseif kind == "optional" then
				if value ~= nil then
					writeBit(output, maskOffset, entry.presenceBit, 1)
					bodyOffset = writePacked(entry.node.value, value, output, bodyOffset, referenceState)
				end
			else
				bodyOffset = writePacked(entry.node, value, output, bodyOffset, referenceState)
			end
		end
		return bodyOffset
	end

	local function hasBytes(state, count)
		return count >= 0 and state.offset <= state.length - count
	end

	local function readBlock(layout, state)
		local start, maskSize = state.offset, layout.bytes
		if not hasBytes(state, maskSize) then return false end
		local bodyStart = start + maskSize
		local maskBits = layout.bits
		if maskBits % 8 ~= 0 and maskSize > 0 then
			local last = buffer.readu8(state.value, start + maskSize - 1)
			if last >= 2 ^ (maskBits % 8) then return false end
		end

		local minimumBody = 0
		for _, entry in layout.entries do
			local kind = entry.kind
			if kind == "enum" then
				if readBitsAt(state, start, entry.valueBit, entry.width) >= #entry.node.values then return false end
			elseif kind == "optionalboolean" or kind == "optionalenum" then
				local present = readBitsAt(state, start, entry.presenceBit, 1)
				local valueCode = readBitsAt(state, start, entry.valueBit, entry.width)
				if present == 0 and valueCode ~= 0 then return false end
				if present == 1 and kind == "optionalenum" and valueCode >= #entry.node.value.values then return false end
			elseif kind == "optional" then
				if readBitsAt(state, start, entry.presenceBit, 1) == 1 then minimumBody += entry.node.value.minimum end
			elseif kind == nil then
				minimumBody += entry.node.minimum
			end
		end
		state.offset = bodyStart
		if not hasBytes(state, minimumBody) then state.offset = start; return false end
		local values = table.create(#layout.entries)
		for index, entry in layout.entries do
			local kind, node = entry.kind, entry.node
			if kind == "boolean" then
				values[index] = readBitsAt(state, start, entry.valueBit, 1) == 1
			elseif kind == "enum" then
				values[index] = node.values[readBitsAt(state, start, entry.valueBit, entry.width) + 1]
			elseif kind == "optionalboolean" or kind == "optionalenum" then
				if readBitsAt(state, start, entry.presenceBit, 1) == 1 then
					local code = readBitsAt(state, start, entry.valueBit, entry.width)
					values[index] = if kind == "optionalboolean" then code == 1 else node.value.values[code + 1]
				end
			elseif kind == "optional" then
				if readBitsAt(state, start, entry.presenceBit, 1) == 1 then
					local valid, child = readPacked(node.value, state)
					if not valid then state.offset = start; return false end
					values[index] = child
				end
			else
				local valid, child = readPacked(node, state)
				if not valid then state.offset = start; return false end
				values[index] = child
			end
		end
		return true, values
	end

		readPacked = function(node, state)
		if node.type == "struct" then
			local valid, fieldsValue = readBlock(layouts[node], state)
			if not valid then return false end
			local result = {}
			for index, field in node.fields do
				if fieldsValue[index] ~= nil then result[field.name] = fieldsValue[index] end
			end
			return true, result
		elseif node.type == "taggedUnion" then
			if not hasBytes(state, 1) then return false end
			local ordinal = buffer.readu8(state.value, state.offset)
			state.offset += 1
			local variant = node.variants[ordinal + 1]
			if variant == nil then return false end
			local valid, result = readPacked(variant.node, state)
			if not valid then return false end
			result[node.tag] = variant.label
			return true, result
		elseif node.type == "array" or node.type == "set" then
			local count = LengthBounds.read(state, node.minimumLength, node.maximumLength, node.countBytes)
			if count == nil then return false end
			local flag, width = nodeFlagKind(node.element)
			if flag == "boolean" or flag == "enum" then
				local bytes = maskBytes(count * width)
				if not hasBytes(state, bytes) then return false end
				local maskStart = state.offset
				local usedBits = count * width
				if usedBits % 8 ~= 0 and bytes > 0
					and buffer.readu8(state.value, maskStart + bytes - 1) >= 2 ^ (usedBits % 8) then return false end
				for index = 0, count - 1 do
					if flag == "enum" and readBitsAt(state, maskStart, index * width, width) >= #node.element.values then return false end
				end
				state.offset += bytes
				local output = if node.type == "array" then table.create(count) else {}
				for index = 0, count - 1 do
					local code = readBitsAt(state, maskStart, index * width, width)
					local value = if flag == "boolean" then code == 1 else node.element.values[code + 1]
					if node.type == "array" then output[index + 1] = value
					elseif rawget(output, value) ~= nil then return false
					else output[value] = true end
				end
				return true, output
			end
			if count * node.element.minimum > state.length - state.offset then return false end
			local output = if node.type == "array" then table.create(count) else {}
			for index = 1, count do
				local valid, child = readPacked(node.element, state)
				if not valid then return false end
				if node.type == "array" then output[index] = child
				elseif rawget(output, child) ~= nil then return false
				else output[child] = true end
			end
			return true, output
		elseif node.type == "map" then
			local count = LengthBounds.read(state, node.minimumLength, node.maximumLength, node.countBytes)
			if count == nil then return false end
			local layout = layouts[node]
			if count * layout.minimum > state.length - state.offset then return false end
			local output, seen = {}, {}
			for _ = 1, count do
				local valid, pair = readBlock(layout, state)
				if not valid then return false end
				local key, value = pair[1], pair[2]
				if rawget(seen, key) ~= nil then return false end
				seen[key] = true
				if value ~= nil then output[key] = value end
			end
			return true, output
		elseif node.type == "optional" then
			local valid, values = readBlock(makeLayout({ node }), state)
			if not valid then return false end
			return true, values[1]
		elseif node.type == "boolean" or node.type == "enum" then
			local valid, values = readBlock(makeLayout({ node }), state)
			if not valid then return false end
			return true, values[1]
		end
		if node.containsReferences then return helpers.decodeReferenceNode(node, state) end
		return helpers.decodeNode(node, state)
	end

	local function writeTuple(values, output, offset, referenceState)
		return writeBlock(tupleLayout, values, output, offset, referenceState)
	end

	if mode == "encode" or mode == "validate" then
		return function(...)
			if select("#", ...) ~= #nodes then return nil end
			local values = table.pack(...)
			local referenceState = if hasReferences then { context = context,
				maximumReferences = maximumReferences, referenceCount = 0 } else nil
			for index, node in nodes do
				local valid, normalized
				if hasReferences then
					valid, normalized = helpers.normalizeReferenceNode(node, values[index], referenceState)
				else
					valid, normalized = helpers.normalizeNode(node, values[index])
				end
				if not valid then return nil end
				values[index] = normalized
			end
			if mode == "validate" then return true, table.unpack(values, 1, #nodes) end

			local size = blockSize(tupleLayout, values)
			if size == nil then return nil end
			local referenceCount = if hasReferences then referenceState.referenceCount else 0
			local totalBytes = headerBytes + size
			if totalBytes > maximumBufferBytes
				or (hasReferences and totalBytes + referenceCount * helpers.referenceBytes > maximumTotalBytes) then return nil end
			local output = buffer.create(totalBytes)
			buffer.writeu8(output, 0, formatVersion)
			buffer.writeu16(output, 1, event.id)
			if hasReferences then buffer.writeu8(output, 3, referenceCount) end
			local writeState = if hasReferences then { referenceCount = 0,
				references = table.create(referenceCount) } else nil
			local offset = writeTuple(values, output, headerBytes, writeState)
			if offset ~= totalBytes or (hasReferences and writeState.referenceCount ~= referenceCount) then return nil end
			if hasReferences then return true, output, table.unpack(writeState.references, 1, referenceCount) end
			return true, output
		end
	end

	local minimumEncodedBytes = event.minimumEncodedBytes
	local function decode(...)
		local argumentCount = select("#", ...)
		if (hasReferences and (argumentCount < 1 or argumentCount > helpers.maximumReferences + 1))
			or (not hasReferences and argumentCount ~= 1) then return nil end
		local value = ...
		if typeof(value) ~= "buffer" then return nil end
		local length = buffer.len(value)
		if length < minimumEncodedBytes or length > maximumBufferBytes or length < headerBytes then return nil end
		if buffer.readu8(value, 0) ~= formatVersion or buffer.readu16(value, 1) ~= event.id then return nil end
		local state = { value = value, length = length, offset = headerBytes }
		local references
		if hasReferences then
			local count = buffer.readu8(value, 3)
			if count > maximumReferences or argumentCount ~= count + 1
				or length + count * helpers.referenceBytes > maximumTotalBytes then return nil end
			for index = 1, count do
				if not helpers.validReference(select(index + 1, ...), "Instance", context) then return nil end
			end
			references = table.create(count)
			for index = 1, count do references[index] = select(index + 1, ...) end
			state.context = context
			state.references = references
			state.referenceCount = count
			state.nextReference = 1
		end
		local valid, decoded = readBlock(tupleLayout, state)
		if not valid or state.offset ~= length
			or (hasReferences and state.nextReference ~= state.referenceCount + 1) then return nil end
		return true, table.unpack(decoded, 1, #nodes)
	end
	return function(...)
		return helpers.finish(pcall(decode, ...))
	end
end

return table.freeze({ bounds = bounds, fieldsBounds = fieldsBounds, compile = compile })
