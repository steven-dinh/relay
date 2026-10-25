--!strict
-- Place this ModuleScript in ReplicatedStorage alongside Relay and Spec.
local Relay = require(game:GetService("ReplicatedStorage").Relay)

local definition, definitionError = Relay.define(require(script.Parent.Spec))

return assert(definition, definitionError and definitionError.message)
