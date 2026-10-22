local function width(minimum, maximum, bounded)
	if not bounded then return 2 end
	local span = maximum - minimum
	return if span == 0 then 0 elseif span <= 255 then 1 else 2
end

local function read(state, minimum, maximum, countBytes)
	local offset, count = state.offset, minimum
	if countBytes == 1 then
		if offset < 0 or offset >= state.length then return nil end
		count += buffer.readu8(state.value, offset)
	elseif countBytes == 2 then
		if offset < 0 or offset > state.length - 2 then return nil end
		count += buffer.readu16(state.value, offset)
	end
	if count < minimum or count > maximum then return nil end
	state.offset = offset + countBytes
	return count
end

local function write(output, offset, count, minimum, countBytes)
	if countBytes == 1 then
		buffer.writeu8(output, offset, count - minimum)
	elseif countBytes == 2 then
		buffer.writeu16(output, offset, count - minimum)
	end
	return offset + countBytes
end

return table.freeze({ width = width, read = read, write = write })
