--!strict

local Schema = require("./HostManifestSchema")
local Identity = require("./AdapterIdentity")

export type RepositoryModuleArtifact = Schema.RepositoryModuleArtifact
export type EngineBuiltInArtifact = Schema.EngineBuiltInArtifact
export type ManifestIssueCode = Schema.ManifestIssueCode
export type ManifestIssue = Schema.ManifestIssue
export type HostManifest = Schema.HostManifest<Identity.AdapterIdentity<"PersistentSession">> & {
	benchmarkSource: {
		revision: string,
		dirty: boolean,
		placeFingerprint: string,
		measurementFingerprint: string,
		adapterFingerprint: string,
	},
}
export type ValidationResult = { kind: "Valid", value: HostManifest } | { kind: "Invalid", issue: ManifestIssue }

return (Schema.create(2) :: any) :: { validate: (candidate: unknown) -> ValidationResult }
