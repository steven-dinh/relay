--!strict

local SessionOwner = require("./SessionOwner")

export type DeadlineStatus = { kind: "Active" } | { kind: "Expired" }

export type Deadline = {
	check: () -> DeadlineStatus,
}

export type Clock = {
	localNowSeconds: () -> number,
	sharedNowSeconds: () -> number,
	timeoutNowSeconds: () -> number,
	startDeadline: (durationSeconds: number) -> Deadline,
}

local PORT_KEYS = {
	localNowSeconds = true,
	sharedNowSeconds = true,
	timeoutNowSeconds = true,
}

local ACTIVE: DeadlineStatus = { kind = "Active" }
local EXPIRED: DeadlineStatus = { kind = "Expired" }
table.freeze(ACTIVE)
table.freeze(EXPIRED)

local function fail(code: string): never
	error(code, 0)
end

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isNegativeZero(value: number): boolean
	return value == 0 and 1 / value == -math.huge
end

local function isExactPort(candidate: unknown): boolean
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
		return false
	end

	local count = 0
	for key in next, candidate :: any do
		if type(key) ~= "string" or rawget(PORT_KEYS, key) ~= true then
			return false
		end
		count += 1
	end

	return count == 3
		and type(rawget(candidate :: any, "localNowSeconds")) == "function"
		and type(rawget(candidate :: any, "sharedNowSeconds")) == "function"
		and type(rawget(candidate :: any, "timeoutNowSeconds")) == "function"
end

local function readOnce(reader: () -> number): number
	local thread = coroutine.create(reader)
	local results = table.pack(coroutine.resume(thread))
	if results[1] ~= true or coroutine.status(thread) ~= "dead" or results.n ~= 2 then
		if coroutine.status(thread) ~= "dead" then
			pcall(coroutine.close, thread)
		end
		fail("BENCHMARK_CLOCK_E_VALUE")
	end

	local value = results[2]
	if type(value) ~= "number" or not isFinite(value) or value < 0 or isNegativeZero(value) then
		fail("BENCHMARK_CLOCK_E_VALUE")
	end
	return value
end

local function guardReader(reader: () -> number): () -> number
	local previous: number? = nil
	return function(): number
		local value = readOnce(reader)
		if previous ~= nil and value < previous then
			fail("BENCHMARK_CLOCK_E_VALUE")
		end
		previous = value
		return value
	end
end

local function scaledDifference(startSeconds: number, finishSeconds: number, scale: number): number
	if type(startSeconds) ~= "number"
		or type(finishSeconds) ~= "number"
		or not isFinite(startSeconds)
		or not isFinite(finishSeconds)
		or finishSeconds < startSeconds
	then
		fail("BENCHMARK_CLOCK_E_VALUE")
	end

	local deltaSeconds = finishSeconds - startSeconds
	if not isFinite(deltaSeconds) or deltaSeconds < 0 or isNegativeZero(deltaSeconds) then
		fail("BENCHMARK_CLOCK_E_VALUE")
	end

	local scaled = deltaSeconds * scale
	if not isFinite(scaled) or scaled < 0 or isNegativeZero(scaled) then
		fail("BENCHMARK_CLOCK_E_VALUE")
	end
	return scaled
end

local function millisecondsBetween(startSeconds: number, finishSeconds: number): number
	return scaledDifference(startSeconds, finishSeconds, 1_000)
end

local function microsecondsBetween(startSeconds: number, finishSeconds: number): number
	return scaledDifference(startSeconds, finishSeconds, 1_000_000)
end

local function new(port: SessionOwner.BenchmarkClockPort): Clock
	if not isExactPort(port) then
		fail("BENCHMARK_CLOCK_E_CONFIG")
	end

	local source: any = port
	local localNowSeconds = guardReader(rawget(source, "localNowSeconds"))
	local sharedNowSeconds = guardReader(rawget(source, "sharedNowSeconds"))
	local timeoutNowSeconds = guardReader(rawget(source, "timeoutNowSeconds"))

	local function startDeadline(durationSeconds: number): Deadline
		if type(durationSeconds) ~= "number"
			or not isFinite(durationSeconds)
			or durationSeconds <= 0
			or isNegativeZero(durationSeconds)
		then
			fail("BENCHMARK_CLOCK_E_VALUE")
		end

		local startedAtSeconds = timeoutNowSeconds()
		local function check(): DeadlineStatus
			local elapsedSeconds = timeoutNowSeconds() - startedAtSeconds
			return if elapsedSeconds >= durationSeconds then EXPIRED else ACTIVE
		end

		local deadline: Deadline = {
			check = check,
		}
		table.freeze(deadline)
		return deadline
	end

	local clock: Clock = {
		localNowSeconds = localNowSeconds,
		sharedNowSeconds = sharedNowSeconds,
		timeoutNowSeconds = timeoutNowSeconds,
		startDeadline = startDeadline,
	}
	table.freeze(clock)
	return clock
end

local BenchmarkClock = {
	new = new,
	millisecondsBetween = millisecondsBetween,
	microsecondsBetween = microsecondsBetween,
}

table.freeze(BenchmarkClock)

return BenchmarkClock
