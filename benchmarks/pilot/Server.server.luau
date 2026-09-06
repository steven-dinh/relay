--!strict
local benchmark = game:GetService("ReplicatedStorage"):WaitForChild("RelayBenchmark")
require(benchmark:WaitForChild("Pilot"):WaitForChild("PersistentSession")).runServer()
