--!strict

export type Entity = { id: number, health: number }
export type SnapshotStatus = "Ready" | "Denied" | "Busy"
export type UpdateKind = "Put" | "Delete" | "Reset" | "Closed"

export type Snapshot = {
	read status: SnapshotStatus,
	read epoch: number,
	read revision: number,
	read entities: { Entity },
}

export type Update = {
	epoch: number,
	revision: number,
	kind: UpdateKind,
	id: number,
	health: number,
}

export type ClientSnapshot = {
	epoch: number,
	revision: number,
	entities: { [number]: number },
	ready: boolean,
}

return {}
