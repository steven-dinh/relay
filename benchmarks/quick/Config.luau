-- Edit before Play. Stop/Play after changing the workload or adapter selection.
-- Each run has three rounds; these frame counts apply to each round.
return table.freeze({
	caseId = "state-burst-c2s",
	warmupFrames = 30,
	measuredFrames = 120,
	quietSeconds = 0.25,
	timeoutSeconds = 15,
	autoRun = true,
})
