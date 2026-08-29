--!strict

local AdapterContract = require("../adapters/AdapterContract")

export type DeliveryHandler = (
	argumentCount: number,
	delivery: unknown,
	metadata: unknown
) -> ()

export type StaleHandler = () -> ()
export type DisableResult = "Clean" | "PreReadyViolation"

export type SinkGate = {
	bind: (handler: DeliveryHandler) -> boolean,
	arm: () -> boolean,
	beginTeardownObservation: (handler: StaleHandler) -> (),
	disable: () -> DisableResult,
}

export type ServerRoute<TSender> = {
	sink: AdapterContract.ServerDeliverySink<TSender>,
	gate: SinkGate,
}

export type ClientRoute = {
	sink: AdapterContract.ClientDeliverySink,
	gate: SinkGate,
}

type State =
	"Unbound"
	| "Bound"
	| "Armed"
	| "Observing"
	| "PreReadyViolation"
	| "Disabled"

type Handler = DeliveryHandler | StaleHandler

local function fail(code: string)
	error(code, 0)
end

local function newRoute(): any
	local state: State = "Unbound"
	local handler: Handler? = nil
	local preReadyViolation = false

	local function sink(...: unknown)
		if state == "Unbound" or state == "Bound" then
			preReadyViolation = true
			state = "PreReadyViolation"
			handler = nil
			return
		elseif state == "Armed" then
			local activeHandler = handler :: DeliveryHandler
			local argumentCount = select("#", ...)
			local delivery = select(1, ...)
			local metadata = select(2, ...)
			activeHandler(argumentCount, delivery, metadata)
		elseif state == "Observing" then
			local staleHandler = handler :: StaleHandler
			staleHandler()
		end
	end

	local function bind(candidate: DeliveryHandler): boolean
		if type(candidate) ~= "function" then
			fail("DELIVERY_ROUTER_E_HANDLER")
		end

		if state == "PreReadyViolation" then
			return false
		elseif state ~= "Unbound" then
			fail("DELIVERY_ROUTER_E_STATE")
		end

		handler = candidate
		state = "Bound"
		return true
	end

	local function arm(): boolean
		if state == "PreReadyViolation" then
			return false
		elseif state ~= "Bound" then
			fail("DELIVERY_ROUTER_E_STATE")
		end

		state = "Armed"
		return true
	end

	local function beginTeardownObservation(candidate: StaleHandler)
		if type(candidate) ~= "function" then
			fail("DELIVERY_ROUTER_E_HANDLER")
		end
		if state ~= "Armed" then
			fail("DELIVERY_ROUTER_E_STATE")
		end

		state, handler = "Observing", candidate
	end

	local function disable(): DisableResult
		state, handler = "Disabled", nil
		return if preReadyViolation then "PreReadyViolation" else "Clean"
	end

	local gate: SinkGate = {
		bind = bind,
		arm = arm,
		beginTeardownObservation = beginTeardownObservation,
		disable = disable,
	}
	table.freeze(gate)

	local route = {
		sink = sink,
		gate = gate,
	}
	table.freeze(route)
	return route
end

local function newServer<TSender>(): ServerRoute<TSender>
	return newRoute()
end

local function newClient(): ClientRoute
	return newRoute()
end

local DeliveryRouter = {
	newServer = newServer,
	newClient = newClient,
}

table.freeze(DeliveryRouter)

return DeliveryRouter
