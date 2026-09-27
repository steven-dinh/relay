--!strict

-- Carry field order in the type without adding a runtime metadata property.
export type FieldList<T...> = { [number]: unknown } & { [never]: (T...) -> () }

local function ordered<T...>(...: T...): FieldList<T...>
    local fields = { ... }
    for index, field in fields do
        if type(field) == "table" then
            fields[index] = table.freeze(table.clone(field :: any))
        end
    end
    return table.freeze(fields) :: any
end

return ordered
