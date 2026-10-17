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
    local function refill(timestamp)
        local effectiveNow = timestamp or now()
        if effectiveNow > last then
            tokens = math.min(capacity, tokens + (effectiveNow - last) * refillPerSecond)
            last = effectiveNow
        end
    end
    local function validAmount(amount)
        return finite(amount) and amount > 0 and amount % 1 == 0
    end
    return table.freeze({
        canTake = function(_, timestamp, amount)
            if amount == nil then
                amount = 1
            elseif not validAmount(amount) then
                return false
            end
            refill(timestamp)
            return tokens >= amount
        end,
        take = function(_, timestamp, amount)
            if amount == nil then
                amount = 1
            elseif not validAmount(amount) then
                return false
            end
            refill(timestamp)
            if tokens < amount then
                return false
            end
            tokens -= amount
            return true
        end,
    })
end

return table.freeze(TokenBucket)
