--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Report = require("./BroadcastStudyReport")

local options = Report.parseArgs(process.args)
local report = Report.report(options.ledgerPath, options.maximumControlDrift)
if options.outputPath ~= nil then
	-- Never replace raw evidence, a prior report, or any other existing file.
	assert(process.os == "windows" or process.os == "linux", "BCAST_REPORT_E_OUTPUT_PLATFORM: stdout reporting is portable")
	local temporary = options.outputPath .. ".tmp-" .. string.sub(serde.hash("sha256", tostring({}) .. tostring(os.clock())), 1, 24)
	assert(not fs.metadata(temporary).exists, "BCAST_REPORT_E_OUTPUT_EXISTS")
	fs.writeFile(temporary, serde.encode("json", report))
	-- Lune 0.10.5 fs.move checks then renames, leaving a replacement race.
	-- This native two-argument move fails if the destination exists at move time.
	local ok, moved
	if process.os == "windows" then
		ok, moved = pcall(process.exec, "powershell.exe", { "-NoProfile", "-NonInteractive", "-Command",
			[[& { $ErrorActionPreference='Stop'; [System.IO.File]::Move($env:RELAY_STUDY_REPORT_TEMP, $env:RELAY_STUDY_REPORT_OUTPUT) }]] },
			{ cwd = process.cwd, env = { RELAY_STUDY_REPORT_TEMP = temporary, RELAY_STUDY_REPORT_OUTPUT = options.outputPath } })
	else
		-- Same-directory hard-link creation is atomic and never replaces a name.
		-- -T also rejects a directory at the destination instead of linking inside.
		ok, moved = pcall(process.exec, "/bin/ln", { "-T", "--", temporary, options.outputPath }, { cwd = process.cwd })
	end
	if fs.isFile(temporary) then fs.removeFile(temporary) end
	assert(ok and moved.ok, "BCAST_REPORT_E_OUTPUT_EXISTS_OR_MOVE_FAILED")
end
print(Report.render(report))
