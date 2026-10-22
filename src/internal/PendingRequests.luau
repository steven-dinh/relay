local Definition = require(if script then script.Parent.Parent.Definition else "../Definition")

local function failure(code)
	return table.freeze({ ok = false, error = Definition.error(code) })
end

local function settle(record, result, clear)
	if record.settled or not clear() then return false end
	record.settled = true
	local timer = record.timer
	record.timer = nil
	if timer ~= nil then pcall(task.cancel, timer) end
	local waiterToken, waiterThread = record.waiterToken, record.waiterThread
	record.result = result
	record.readClock = nil
	record.settle = nil
	record.decodeResponse = nil
	record.encodeResponse = nil
	if waiterToken ~= nil and waiterThread ~= nil then
		if coroutine.status(waiterThread) == "dead" then
			if record.waiterToken == waiterToken and record.waiterThread == waiterThread then
				record.waiterToken = nil
				record.waiterThread = nil
			end
		else
			task.defer(function()
				if record.waiterToken ~= waiterToken or record.waiterThread ~= waiterThread then return end
				local function clearWaiter()
					if record.waiterToken == waiterToken and record.waiterThread == waiterThread then
						record.waiterToken = nil
						record.waiterThread = nil
					end
				end
				local status = coroutine.status(waiterThread)
				if status == "dead" then
					clearWaiter()
				elseif status == "suspended" then
					task.spawn(waiterThread)
					if coroutine.status(waiterThread) == "dead" then clearWaiter() end
				end
			end)
		end
	end
	return true
end

local function await(record)
	if record.settled then return record.result end
	if record.waiterToken ~= nil then
		if record.waiterThread ~= nil and coroutine.status(record.waiterThread) ~= "dead" then
			return failure("AlreadyAwaiting")
		end
		record.waiterToken = nil
		record.waiterThread = nil
	end
	if not coroutine.isyieldable() then return failure("NotYieldable") end
	local token = {}
	local thread = coroutine.running()
	record.waiterToken = token
	record.waiterThread = thread
	while not record.settled do
		if record.readClock() >= record.deadline then
			record:settle(failure("RequestTimeout"))
			break
		end
		coroutine.yield()
	end
	if record.waiterToken == token then
		record.waiterToken = nil
		record.waiterThread = nil
	end
	return record.result
end

local function arm(record)
	record.timer = task.delay(record.deadline - record.readClock(), function()
		if record.settled then return end
		record.timer = nil
		if record.readClock() >= record.deadline then
			record:settle(failure("RequestTimeout"))
		else
			arm(record)
		end
	end)
end

local function handle(record)
	return table.freeze({
		Await = function() return await(record) end,
		Cancel = function()
			if not record.settled then record:settle(failure("Cancelled")) end
		end,
	})
end

return table.freeze({ failure = failure, settle = settle, arm = arm, handle = handle })
