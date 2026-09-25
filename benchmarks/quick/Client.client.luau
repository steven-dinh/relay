local quick = game:GetService("ReplicatedStorage"):WaitForChild("RelayBenchmark"):WaitForChild("Quick")
if require(quick.Config).autoRun then require(quick.Session).run() end
