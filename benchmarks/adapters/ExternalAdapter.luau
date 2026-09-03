--!strict

-- Private lifecycle shared by the process-isolated external qualification adapters.
-- Library initialization belongs in setup; the binding never owns the runner sink.
local Players = game:GetService("Players")

local function new(binding: any): any
	local function construct(context: any, isServer: boolean): any
		local selection = context.selection
		local probe = selection.kind == "SeparateProbe"
		local sends = probe or selection.direction == (if isServer then "ServerToClient" else "ClientToServer")
		local receives = probe or not sends
		local root, sink, envelopes = context.resourceRoot, context.sink, context.envelopes
		local recipients = if isServer then context.recipients else nil
		local session: any = nil
		local open, started, closed = false, false, false

		local function record(player: any, value: any)
			if not open then return end
			sink(envelopes.record(value), if isServer then { kind = "ClientToServer", sender = player }
				else { kind = "ServerToClient" })
		end
		local function positional(player: any, ...: any)
			if not open then return end
			sink(envelopes.positional(...), if isServer then { kind = "ClientToServer", sender = player }
				else { kind = "ServerToClient" })
		end

		local side: any = {}
		function side.setup()
			if started or closed then error("EXTERNAL_ADAPTER_E_SETUP", 0) end
			started = true
			-- Install the cleanup slot before initialization can fail or yield.
			session = {}
			binding.setup(session, root, selection, isServer, receives, record, positional)
		end
		function side.ready(): boolean
			if not started or closed or session == nil then error("EXTERNAL_ADAPTER_E_READY", 0) end
			if session.ready ~= nil and not session.ready() then return false end
			if isServer and sends then
				local actual = Players:GetPlayers()
				if #actual ~= #recipients then error("EXTERNAL_ADAPTER_E_ROSTER", 0) end
				for _, player in actual do
					if table.find(recipients, player) == nil then error("EXTERNAL_ADAPTER_E_ROSTER", 0) end
				end
			end
			open = true
			return true
		end
		function side.teardown()
			if closed then return end
			open, closed = false, true
			-- A callback retained by a process singleton now has no runner references.
			root, sink, envelopes, recipients = nil, nil, nil, nil
			local old = session
			session = nil
			if old ~= nil and old.disconnect ~= nil then old.disconnect() end
		end
		if sends then
			side[if isServer then "broadcast" else "submit"] = function(payload: any, boundary: any)
				if not open then error("EXTERNAL_ADAPTER_E_SEND", 0) end
				session.send(payload)
				if boundary == "FlushBeforeReturn" and session.flush ~= nil then session.flush() end
			end
		end
		return table.freeze(side)
	end
	return table.freeze({
		constructServer = function(context: any) return construct(context, true) end,
		constructClient = function(context: any) return construct(context, false) end,
	})
end

return table.freeze({ new = new })
