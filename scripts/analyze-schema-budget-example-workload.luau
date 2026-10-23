return {
	events = {
		Input = { sendsPerSecond = 12, recipients = 1, path = "QueuedSingleRecord" },
		NearbyState = { sendsPerSecond = 2, recipients = 20, path = "Immediate" },
		InventoryDelta = { sendsPerSecond = 0.5, recipients = 20, path = "QueuedSingleRecord" },
	},
	requests = {
		InspectItem = { callsPerSecond = 0.2, recipients = 1 },
	},
}
