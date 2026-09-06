--!strict

local Schema = require("./HostManifestSchema")

export type RepositoryModuleArtifact = Schema.RepositoryModuleArtifact
export type EngineBuiltInArtifact = Schema.EngineBuiltInArtifact
export type HostManifest = Schema.HostManifest
export type ManifestIssueCode = Schema.ManifestIssueCode
export type ManifestIssue = Schema.ManifestIssue
export type ValidationResult = Schema.ValidationResult

return Schema.create(1)
