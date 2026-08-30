--!strict

local REJECTED = table.freeze({ kind = "Rejected" })

local function resolve(...: any)
	if select("#", ...) ~= 1 or type(select(1, ...)) ~= "string" then
		error("ADAPTER_ALLOWLIST_E_INPUT", 0)
	end
	return REJECTED
end

return table.freeze({ resolve = resolve })
