--!strict

local process = require("@lune/process")
local serde = require("@lune/serde")
local Recovery = require("./BroadcastRecoveryAudit")

if #process.args ~= 2 or process.args[1] ~= "--ledger" then
	error("usage: lune run benchmarks/host/audit-broadcast-recovery.luau --ledger <interrupted-ledger.json>", 0)
end

print(serde.encode("json", Recovery.audit(process.args[2])))
