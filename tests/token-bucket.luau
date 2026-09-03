local TokenBucket = require("../src/internal/TokenBucket")

local now = 100
local function clock()
    return now
end

local bucket = assert(TokenBucket.new(2, 2, clock))
local backward = assert(TokenBucket.new(1, 1, clock))
assert(backward:take())
now = 90
assert(not backward:take())
now = 100
assert(not backward:take(), "100 -> 90 -> 100 must not refill twice")
assert(bucket:take() and bucket:take(), "bucket starts full")
assert(not bucket:take(), "empty bucket rejects")
now = 100.25
assert(not bucket:take(), "fractional token is insufficient")
now = 100.5
assert(bucket:take(), "exact refill boundary admits")
assert(not bucket:take(), "refill is spent once")
now = 90
assert(not bucket:take(), "backward clock does not refill")
now = 100.5
assert(not bucket:take(), "return to previous time does not double refill")
now = 101
assert(bucket:take() and not bucket:take(), "refill resumes beyond high water mark")
now = 1e300
assert(bucket:take() and bucket:take() and not bucket:take(), "large jump saturates capacity")

now = 0
local overflowing = assert(TokenBucket.new(2, 1e308, clock))
assert(overflowing:take() and overflowing:take())
now = 1e308
assert(overflowing:take() and overflowing:take() and not overflowing:take(), "overflow saturates capacity")

for _, value in { 0, -1, 0.5, math.huge, -math.huge, 0 / 0, false, "1", {} } do
    assert(TokenBucket.new(value, 1) == nil, "invalid capacity rejects")
end
for _, value in { 0, -1, math.huge, -math.huge, 0 / 0, false, "1", {} } do
    assert(TokenBucket.new(1, value) == nil, "invalid refill rejects")
end
assert(TokenBucket.new(nil, 1) == nil and TokenBucket.new(1, nil) == nil)
assert(TokenBucket.new(1, 1, false) == nil, "invalid clock rejects")
assert(TokenBucket.new(1, 0.5):take(), "fractional refill and production clock work")
assert(table.isfrozen(bucket) and table.isfrozen(TokenBucket), "surfaces are frozen")

print("PASS Relay.ReliableEvents.TokenBucket")
