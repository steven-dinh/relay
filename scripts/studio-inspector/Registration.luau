local Attachment = require(if script then script.Parent.Attachment else "./Attachment")

local function createServer(Relay, definition, options, metadata)
    return Attachment.Construct("createServer", Relay, definition, options, metadata)
end

local function createClient(Relay, definition, options, metadata)
    return Attachment.Construct("createClient", Relay, definition, options, metadata)
end

return table.freeze({ createServer = createServer, createClient = createClient })
