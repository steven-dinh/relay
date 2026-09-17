local TokenBucket = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

function TokenBucket.new(capacity, refillPerSecond, clock)
    if not finite(capacity) or capacity < 1 or capacity % 1 ~= 0
        or not finite(refillPerSecond) or refillPerSecond <= 0
        or (clock ~= nil and type(clock) ~= "function") then
        return nil
    end
    local now = clock or os.clock
    local last = now()
    local tokens = capacity
    return table.freeze({
        take = function(_, timestamp)
            local effectiveNow = math.max(last, timestamp or now())
            local elapsed = effectiveNow - last
            last = effectiveNow
            tokens = math.min(capacity, tokens + elapsed * refillPerSecond)
            if tokens < 1 then
                return false
            end
            tokens -= 1
            return true
        end,
    })
end

return table.freeze(TokenBucket)
