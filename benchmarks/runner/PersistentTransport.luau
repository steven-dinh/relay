--!strict

-- One physical adapter side, with one independently owned sink per logical window.
local function copy(value: any): any
	if type(value) ~= "table" then return value end
	local result = {}
	for key, nested in value do result[key] = copy(nested) end
	return result
end

local function equal(left: any, right: any): boolean
	if type(left) ~= "table" or type(right) ~= "table" then return left == right end
	for key, value in left do
		if not equal(value, right[key]) then return false end
	end
	for key in right do
		if left[key] == nil then return false end
	end
	return true
end

local function invokeFresh(callback: any, ...: any): (any, boolean)
	if type(callback) ~= "function" then return table.pack(false), true end
	local thread = coroutine.create(callback)
	local results = table.pack(coroutine.resume(thread, ...))
	local dead = coroutine.status(thread) == "dead"
	if not dead and coroutine.status(thread) == "suspended" then coroutine.close(thread) end
	return results, dead
end

local function new(rawFactory: any, physicalRoot: any): any
	local rawSide: any = nil
	local role: string? = nil
	local selection: any = nil
	local recipients: any = nil
	local participantIndex: number? = nil
	local target: any = nil
	local current: any = nil
	local setupDone, closed = false, false
	local failure: string? = nil

	local function latch(code: string)
		if failure == nil then failure = code end
	end
	local function assertHealthy()
		if failure ~= nil then error(failure, 0) end
	end
	local function reject(code: string)
		latch(code)
		assertHealthy()
	end
	local function invoke(callback: any, returnCount: number, ...: any): any
		local results, dead = invokeFresh(callback, ...)
		if results[1] ~= true or not dead or results.n ~= returnCount + 1 then
			reject("PERSISTENT_TRANSPORT_E_ADAPTER")
		end
		assertHealthy()
		return results[2]
	end
	local function sink(...: any)
		if target == nil then
			latch("PERSISTENT_TRANSPORT_E_GAP_DELIVERY")
			return
		end
		-- Forward untouched arguments, including any receipt timestamp. Callback
		-- failures must survive asynchronous adapter dispatch and final cleanup.
		local ok = pcall(target, ...)
		if not ok then latch("PERSISTENT_TRANSPORT_E_DELIVERY") end
	end

	local function construct(context: any, requestedRole: string): any
		assertHealthy()
		if closed or current ~= nil then reject("PERSISTENT_TRANSPORT_E_STATE") end
		if role ~= nil then
			if role ~= requestedRole or not equal(selection, context.selection)
				or participantIndex ~= context.participantIndex then
				reject("PERSISTENT_TRANSPORT_E_SELECTION")
			end
			if requestedRole == "Server" then
				if #recipients ~= #context.recipients then reject("PERSISTENT_TRANSPORT_E_ROSTER") end
				for index, recipient in recipients do
					if recipient ~= context.recipients[index] then reject("PERSISTENT_TRANSPORT_E_ROSTER") end
				end
			end
		else
			role, selection = requestedRole, copy(context.selection)
			participantIndex = context.participantIndex
			recipients = if requestedRole == "Server" then table.clone(context.recipients) else nil
		end
		local token = {}
		current, target = token, context.sink
		if rawSide == nil then
			local physicalContext = table.clone(context)
			physicalContext.resourceRoot, physicalContext.sink = physicalRoot, sink
			local results, dead = invokeFresh(rawFactory["construct" .. requestedRole], physicalContext)
			-- Retain a returned cleanup handle even when extra return values make
			-- construction invalid. No invalid construction may become a window.
			if results[1] == true and dead and type(results[2]) == "table" then rawSide = results[2] end
			if results[1] ~= true or not dead or results.n ~= 2 or rawSide == nil then
				reject("PERSISTENT_TRANSPORT_E_ADAPTER")
			end
			assertHealthy()
		end
		local started, ready, released = false, false, false
		local function check()
			assertHealthy()
			if closed or released or current ~= token then reject("PERSISTENT_TRANSPORT_E_STATE") end
		end
		local side: any = {}
		function side.setup()
			check()
			if started then reject("PERSISTENT_TRANSPORT_E_STATE") end
			if not setupDone then
				invoke(rawSide.setup, 0)
				setupDone = true
			end
			started = true
		end
		function side.ready(): boolean
			check()
			if not started then reject("PERSISTENT_TRANSPORT_E_STATE") end
			ready = invoke(rawSide.ready, 1)
			if type(ready) ~= "boolean" then reject("PERSISTENT_TRANSPORT_E_ADAPTER") end
			return ready
		end
		function side.teardown()
			if released then return end
			released = true
			if current == token then current, target = nil, nil end
		end
		local sendName = if requestedRole == "Server" then "broadcast" else "submit"
		if rawSide[sendName] ~= nil then
			side[sendName] = function(...: any)
				check()
				if not ready then reject("PERSISTENT_TRANSPORT_E_STATE") end
				invoke(rawSide[sendName], 0, ...)
			end
		end
		return table.freeze(side)
	end

	local function close()
		if not closed then
			closed, current, target = true, nil, nil
			if rawSide ~= nil then
				if type(rawSide.teardown) ~= "function" then
					latch("PERSISTENT_TRANSPORT_E_CLEANUP")
				else
					local results, dead = invokeFresh(rawSide.teardown)
					if results[1] ~= true or not dead or results.n ~= 1 then latch("PERSISTENT_TRANSPORT_E_CLEANUP") end
				end
			end
		end
		assertHealthy()
	end
	return table.freeze({
		factory = table.freeze({
			constructServer = function(context: any) return construct(context, "Server") end,
			constructClient = function(context: any) return construct(context, "Client") end,
		}),
		assertHealthy = assertHealthy,
		close = close,
	})
end

return table.freeze({ new = new })
