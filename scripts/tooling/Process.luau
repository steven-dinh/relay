local process = require("@lune/process")
local task = require("@lune/task")

local WINDOWS_PARENT = "$self = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID); $parent = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $self.ParentProcessId); if ($parent.Name -notmatch '^lune(\.exe)?$' -or -not $parent.ExecutablePath) { exit 3 }; $parent.ExecutablePath"
local LOG_LIMIT = 16_384

local function executable()
	if process.os == "windows" then
		local found = process.exec("powershell.exe", { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", WINDOWS_PARENT })
		local path = string.gsub(found.stdout, "[\r\n]+$", "")
		if not found.ok or path == "" then error("LuneExecutableUnavailable: " .. found.stderr, 2) end
		return path
	end
	error("UnsupportedHost: owned Lune worker discovery is qualified only on Windows", 2)
end

local function collect(reader, state, key)
	local value = ""
	while true do
		local chunk = reader:read(1024)
		if chunk == nil then break end
		local remaining = LOG_LIMIT - #value
		if remaining > 0 then value ..= string.sub(chunk, 1, remaining) end
	end
	local valid, invalidAt = utf8.len(value)
	if not valid then value = string.sub(value, 1, invalidAt - 1) end
	state[key] = value
	state[key .. "Done"] = true
end

local function run(executablePath, arguments, cwd, deadlineSeconds)
	local child = process.create(executablePath, arguments, { cwd = cwd })
	local state = { stdoutDone = false, stderrDone = false }
	task.spawn(collect, child.stdout, state, "stdout")
	task.spawn(collect, child.stderr, state, "stderr")
	task.spawn(function() state.status = child:status() end)
	local started = os.clock()
	while state.status == nil and os.clock() - started < deadlineSeconds do task.wait(0.01) end
	local timedOut = state.status == nil
	if timedOut then child:kill() end
	while state.status == nil or not state.stdoutDone or not state.stderrDone do task.wait(0.01) end
	return { status = state.status, timedOut = timedOut,
		stdout = state.stdout or "", stderr = state.stderr or "" }
end

return table.freeze({ executable = executable, run = run, LOG_LIMIT = LOG_LIMIT })
