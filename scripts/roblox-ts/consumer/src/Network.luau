local Relay = require(script.Parent.Relay)
local definition, problem = Relay.define(require(script.Parent.Spec))
assert(definition, problem and problem.message)

return table.freeze({
	createServer = function(options)
		return Relay.createServer(definition, options)
	end,
	createClient = function(options)
		return Relay.createClient(definition, options)
	end,
})
