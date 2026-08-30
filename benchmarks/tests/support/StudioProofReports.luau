--!strict

local BOUND = table.freeze({ kind = "BoundReport" })
local READY = table.freeze({ kind = "ReadyReport", outcome = "Ready" })
local WARMUP = table.freeze({ kind = "WarmupReport", outcome = "Clean" })
local REPETITION = table.freeze({ kind = "RepetitionReport", outcome = "Clean", isolationPassed = true })

local function clockReply(clock: {
	localNowSeconds: () -> number,
	sharedNowSeconds: () -> number,
})
	local before = clock.localNowSeconds()
	local shared = clock.sharedNowSeconds()
	local after = clock.localNowSeconds()
	return table.freeze({
		kind = "ClockReply",
		participantSharedSeconds = shared,
		localBeforeSeconds = before,
		localAfterSeconds = after,
	})
end

return table.freeze({
	SENTINEL = "RelayStudioControlProofV1",
	FAILURE_SENTINEL = "RelayStudioControlProofFailureV1",
	listenerReady = "RelayStudioControlListenerReadyV1",
	controlQuietComplete = "RelayStudioControlQuietCompleteV1",
	measuredQuietComplete = "RelayStudioMeasuredQuietCompleteV1",
	measuredQuietRelease = "RelayStudioMeasuredQuietReleaseV1",
	bound = BOUND,
	ready = READY,
	warmup = WARMUP,
	repetition = REPETITION,
	clockReply = clockReply,
})
