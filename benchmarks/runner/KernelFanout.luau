--!strict

local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local RunState = require("./RunState")
local RunnerKernel = require("./RunnerKernel")

export type KernelLike = {
	status: () -> RunState.GenerationStatus,
	command: (command: RunnerKernel.KernelCommand) -> RunState.GenerationStatus,
}

export type RecordInvariant = (fact: RunState.CoordinatorFailureFactV1) -> ()
export type SetTermination = (termination: HarnessTerminationV1.HarnessTerminationV1) -> ()

type CallOutcome = "Returned" | "Threw" | "Yielded"

local function invokeNonYielding(callback: any, ...: any): (CallOutcome, any?, number)
	local thread = coroutine.create(callback)
	local results = table.pack(coroutine.resume(thread, ...))
	if results[1] ~= true then
		return "Threw", nil, 0
	end
	if coroutine.status(thread) ~= "dead" then
		pcall(coroutine.close, thread)
		return "Yielded", nil, 0
	end
	return "Returned", results[2], results.n - 1
end

local function recordExecutionInvariant(recordInvariant: RecordInvariant)
	recordInvariant({
		code = "InternalError",
		occurrences = 1,
		discriminator = { kind = "Stage", value = "Execution" },
	})
end

local function commandAll(
	kernels: { KernelLike },
	command: RunnerKernel.KernelCommand,
	recordInvariant: RecordInvariant,
	setTermination: SetTermination
): boolean
	local clean = true
	for _, kernel in kernels do
		local statusOutcome, statusValue, statusCount = invokeNonYielding(kernel.status)
		if statusOutcome ~= "Returned" or statusCount ~= 1 or type(statusValue) ~= "table" then
			clean = false
			continue
		end
		if rawget(statusValue :: any, "kind") == "Terminated" then
			setTermination(rawget(statusValue :: any, "termination"))
			continue
		end
		local phase = rawget(statusValue :: any, "phase")
		local kind = rawget(command :: any, "kind")
		local eligible = (kind == "BeginWarmup" and phase == "Prepared")
			or (kind == "ArmMeasured" and phase == "ControlQuiet")
			or (kind == "FinishMeasured" and rawget(command :: any, "outcome") == "Complete"
				and (phase == "Measured" or phase == "Draining"))
		local safelyFinished = kind == "FinishMeasured" and phase == "Verified"
		if safelyFinished then
			continue
		elseif not eligible then
			clean = false
			continue
		end
		local outcome, value, count = invokeNonYielding(kernel.command, command)
		if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
			clean = false
		elseif rawget(value :: any, "kind") == "Terminated" then
			setTermination(rawget(value :: any, "termination"))
			clean = false
		end
	end
	if not clean then
		recordExecutionInvariant(recordInvariant)
	end
	return clean
end

local function abortAllKernels(
	kernels: { KernelLike },
	recordInvariant: RecordInvariant,
	setTermination: SetTermination
): boolean
	local clean = true
	for _, kernel in kernels do
		local statusOutcome, statusValue, statusCount = invokeNonYielding(kernel.status)
		if statusOutcome ~= "Returned" or statusCount ~= 1 or type(statusValue) ~= "table" then
			clean = false
			continue
		end
		if rawget(statusValue :: any, "kind") == "Terminated" then
			setTermination(rawget(statusValue :: any, "termination"))
			continue
		end
		local phase = rawget(statusValue :: any, "phase")
		local command: RunnerKernel.KernelCommand?
		if phase == "Prepared" or phase == "Warmup" or phase == "WarmupDrained"
			or phase == "ControlQuiet" or phase == "ArmedMeasured"
		then
			command = { kind = "AbortBeforeMeasured" }
		elseif phase == "Measured" or phase == "Draining" then
			command = { kind = "FinishMeasured", outcome = "Abort" }
		elseif phase ~= "Aborting" and phase ~= "Verified" then
			clean = false
		end
		if command ~= nil then
			local outcome, value, count = invokeNonYielding(kernel.command, command)
			if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
				clean = false
			elseif rawget(value :: any, "kind") == "Terminated" then
				setTermination(rawget(value :: any, "termination"))
				clean = false
			end
		end
	end
	if not clean then
		recordExecutionInvariant(recordInvariant)
	end
	return clean
end

local KernelFanout = {
	commandAll = commandAll,
	abortAllKernels = abortAllKernels,
}

table.freeze(KernelFanout)
return KernelFanout
