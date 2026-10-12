--!strict

local process = require("@lune/process")
local serde = require("@lune/serde")
local Review = require("../../../../benchmarks/reporting/BenchmarkReview")

local ok, options = pcall(Review.parseArgs, process.args)
local result = if ok then Review.assess(options) else {
	schema = "Relay.BenchmarkReview", version = 1, state = "Blocked", rankingEligible = false,
	reasons = { "BENCH_REVIEW_E_ARGS" },
	usage = "--ledger PATH --maximum-control-drift FRACTION [--current-root PATH --source-role baseline|candidate]",
}
print(serde.encode("json", result))
process.exit(if result.state == "Blocked" then 2 elseif result.state == "Inconclusive" then 1 else 0)
