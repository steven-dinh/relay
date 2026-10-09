local Relay = require("../src")
local Definition = require("../src/Definition")
local s = Relay.schema

local function event(id, direction)
    return { id = id, direction = direction, fields = {} }
end

local function countKeys(value)
    local count = 0
    for _ in value do count += 1 end
    return count
end

local combat = {
    Attack = s.clientToServer(1, s.ordered(s.field("amount", s.u16()))),
    Damage = s.serverToClient(2, s.ordered(s.field("amount", s.u16()))),
}
local inventory = {
    State = s.serverToClient(65_535, s.ordered(s.field("count", s.u16()))),
}

local merged, composeError = s.compose(combat, inventory)
assert(merged and composeError == nil)
assert(table.isfrozen(merged) and countKeys(merged) == 3)
assert(merged.Attack == combat.Attack and merged.Damage == combat.Damage and merged.State == inventory.State)

local function descriptor(events)
    local token, problem = Relay.define({ name = "Composed", version = 1, events = events })
    assert(token, problem and problem.message)
    return Definition.get(token).descriptor
end

local direct = descriptor({ Attack = combat.Attack, Damage = combat.Damage, State = inventory.State })
assert(descriptor(merged) == direct, "composition must preserve literal-map descriptors")
assert(descriptor(assert(s.compose(inventory, combat))) == direct, "fragment order must not change descriptors")

local function rejected(label, ...)
    local called, events, problem = pcall(s.compose, ...)
    assert(called, `{label} must return an error instead of throwing`)
    assert(events == nil and type(problem) == "table", `{label} must reject`)
    assert(table.isfrozen(problem) and problem.code == "InvalidDefinition", `{label} error must be frozen`)
    assert(type(problem.message) == "string" and #problem.message > 0 and #problem.message <= 256,
        `{label} error must be bounded`)
    assert(countKeys(problem) == 2, `{label} error must contain only code and message`)
end

rejected("zero fragments")
rejected("empty composition", {})
rejected("duplicate name", { Attack = combat.Attack }, { Attack = combat.Attack })
rejected("duplicate ID across directions", { Input = event(7, "ClientToServer") }, { Output = event(7, "ServerToClient") })
rejected("low ID", { Input = event(0, "ClientToServer") })
rejected("fractional ID", { Input = event(1.5, "ClientToServer") })
rejected("high ID", { Input = event(65_536, "ClientToServer") })
rejected("invalid direction", { Input = event(1, "Wrong") })
rejected("invalid name", { ["bad-name"] = event(1, "ClientToServer") })
rejected("non-string key", { [true] = event(1, "ClientToServer") })

local iterCalls = 0
local trap = {
    __iter = function()
        iterCalls += 1
        error("must not iterate")
    end,
    __index = function()
        iterCalls += 1
        error("must not index")
    end,
    __tostring = function()
        iterCalls += 1
        error("must not stringify")
    end,
}
rejected("fragment metatable", setmetatable({ Input = event(1, "ClientToServer") }, trap))
rejected("event metatable", { Input = setmetatable({ id = 1, direction = "ClientToServer" }, trap) })
rejected("hostile key", { [setmetatable({}, trap)] = event(1, "ClientToServer") })
assert(iterCalls == 0, "composition must not invoke input metamethods")

local badKey = { ["Invalid"] = { id = 1, direction = "ClientToServer", fields = setmetatable({}, trap) } }
local unvalidated, unvalidatedError = s.compose(badKey)
assert(unvalidated and unvalidatedError == nil, "compose must leave nested grammar validation to define")
local invalidDefinition, definitionError = Relay.define({ name = "InvalidNested", version = 1, events = unvalidated })
assert(invalidDefinition == nil and definitionError.code == "InvalidDefinition",
    "define must remain authoritative for the closed event grammar")
assert(iterCalls == 0)

local tooManyEvents = {}
for index = 1, 65 do
    tooManyEvents[`Event{index}`] = event(index, "ClientToServer")
end
rejected("65 events", tooManyEvents)

local fragments = {}
for index = 1, 64 do
    fragments[index] = { [`Event{index}`] = event(index, "ClientToServer") }
end
local maximum, maximumError = s.compose(table.unpack(fragments))
assert(maximum and maximumError == nil and countKeys(maximum) == 64,
    "composition must accept exactly 64 fragments and events")
assert(table.isfrozen(maximum))

local tooManyFragments = table.create(65)
for index = 1, 65 do tooManyFragments[index] = {} end
rejected("65 fragments", table.unpack(tooManyFragments))

print("PASS bounded schema composition, identity, collisions, frozen errors, and define validation")
