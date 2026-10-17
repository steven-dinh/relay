-- Native Instance-reference fixtures shared by the Studio server and clients.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Relay = require(ReplicatedStorage.Relay)
local schema = Relay.schema

local ROOT_NAME = "RelayProofInstances"
local SCOPE_NAME = "RelayProofInstanceScope"
local FAR_MODEL_NAME = "RelayProofUnstreamedModel"

local function child(parent, className, name)
    local value = Instance.new(className)
    value.Name = name
    value.Parent = parent
    return value
end

local function prepare()
    local previous = ReplicatedStorage:FindFirstChild(ROOT_NAME)
    if previous then previous:Destroy() end
    previous = ReplicatedStorage:FindFirstChild(SCOPE_NAME)
    if previous then previous:Destroy() end

    local root = child(ReplicatedStorage, "Folder", ROOT_NAME)
    child(root, "Folder", "RootFolder")
    local part = child(root, "Part", "PartReference")
    part.Anchored = true
    local meshPart = child(root, "MeshPart", "MeshPartReference")
    meshPart.Anchored = true
    local model = child(root, "Model", "ModelReference")
    local humanoid = child(model, "Humanoid", "HumanoidReference")
    child(humanoid, "Animator", "AnimatorReference")
    child(root, "Tool", "ToolReference")
    child(part, "Attachment", "AttachmentReference")
    local screen = child(root, "ScreenGui", "ScreenReference")
    child(screen, "Frame", "FrameReference")
    child(root, "Sound", "SoundReference")
    child(root, "Animation", "AnimationReference")
    child(root, "Folder", "MapFolder")

    local scope = child(ReplicatedStorage, "Folder", SCOPE_NAME)
    child(scope, "Folder", "InsideFolder")
    local scopePart = child(scope, "Part", "InsidePart")
    scopePart.Anchored = true
    return root, scope
end

local function waitChild(parent, name)
    return parent:WaitForChild(name, 10) or error("missing Instance proof fixture " .. name)
end

local function objects(player)
    local root = waitChild(ReplicatedStorage, ROOT_NAME)
    local part = waitChild(root, "PartReference")
    local model = waitChild(root, "ModelReference")
    return {
        rootFolder = waitChild(root, "RootFolder"),
        part = part,
        meshPart = waitChild(root, "MeshPartReference"),
        humanoid = waitChild(model, "HumanoidReference"),
        animator = waitChild(waitChild(model, "HumanoidReference"), "AnimatorReference"),
        model = model,
        tool = waitChild(root, "ToolReference"),
        attachment = waitChild(part, "AttachmentReference"),
        player = player,
        gui = waitChild(waitChild(root, "ScreenReference"), "FrameReference"),
        sound = waitChild(root, "SoundReference"),
        animation = waitChild(root, "AnimationReference"),
        mapFolder = waitChild(root, "MapFolder"),
    }
end

local function payload(valueObjects, branch, animatorPresent)
    return {
        core = {
            instance = valueObjects.rootFolder,
            part = valueObjects.part,
            meshPart = valueObjects.meshPart,
            humanoid = valueObjects.humanoid,
            attachment = valueObjects.attachment,
            player = valueObjects.player,
            gui = valueObjects.gui,
            sound = valueObjects.sound,
        },
        parts = { valueObjects.part, valueObjects.meshPart },
        assets = { scene = { folder = valueObjects.mapFolder, animation = valueObjects.animation } },
        animator = if animatorPresent then valueObjects.animator else nil,
        choice = if branch == "Model" then { kind = "Model", model = valueObjects.model }
            else { kind = "Tool", tool = valueObjects.tool },
    }
end

local function identity(shapeClass, value)
    assert(typeof(value) == "Instance" and value:IsA(shapeClass), "native Instance class " .. shapeClass)
    assert(value:IsDescendantOf(game), "native Instance is live in the DataModel")
    local receipt = { schemaClass = shapeClass, className = value.ClassName, name = value.Name, path = value:GetFullName() }
    if value:IsA("Player") then receipt.userId = value.UserId end
    return receipt
end

local function check(value, valueObjects, branch, animatorPresent)
    assert(type(value) == "table" and type(value.core) == "table", "native Instance payload record")
    assert(value.core.instance == valueObjects.rootFolder and value.core.part == valueObjects.part
        and value.core.meshPart == valueObjects.meshPart and value.core.humanoid == valueObjects.humanoid
        and value.core.attachment == valueObjects.attachment and value.core.player == valueObjects.player
        and value.core.gui == valueObjects.gui and value.core.sound == valueObjects.sound,
        "native Instance core identity")
    assert(type(value.parts) == "table" and #value.parts == 2
        and value.parts[1] == valueObjects.part and value.parts[2] == valueObjects.meshPart,
        "native Instance array identity/order")
    assert(type(value.assets) == "table" and type(value.assets.scene) == "table"
        and value.assets.scene.folder == valueObjects.mapFolder
        and value.assets.scene.animation == valueObjects.animation,
        "native Instance map value identity")
    assert(value.animator == (if animatorPresent then valueObjects.animator else nil),
        "native Instance optional presence")
    if branch == "Model" then
        assert(type(value.choice) == "table" and value.choice.kind == "Model"
            and value.choice.model == valueObjects.model, "native Instance Model union identity")
    else
        assert(branch == "Tool" and type(value.choice) == "table" and value.choice.kind == "Tool"
            and value.choice.tool == valueObjects.tool, "native Instance Tool union identity")
    end

    local references = {
        identity("Instance", value.core.instance),
        identity("Part", value.core.part),
        identity("MeshPart", value.core.meshPart),
        identity("Humanoid", value.core.humanoid),
        identity("Attachment", value.core.attachment),
        identity("Player", value.core.player),
        identity("GuiObject", value.core.gui),
        identity("Sound", value.core.sound),
        identity("BasePart", value.parts[1]),
        identity("BasePart", value.parts[2]),
        identity("Folder", value.assets.scene.folder),
        identity("Animation", value.assets.scene.animation),
    }
    if animatorPresent then table.insert(references, identity("Animator", value.animator)) end
    table.insert(references, identity(branch, if branch == "Model" then value.choice.model else value.choice.tool))
    return { branch = branch, animatorPresent = animatorPresent, references = references }
end

local function create()
    local references = schema.Instance
    local core = schema.struct(
        { instance = references("Instance") },
        { part = references("Part") },
        { meshPart = references("MeshPart") },
        { humanoid = references("Humanoid") },
        { attachment = references("Attachment") },
        { player = references("Player") },
        { gui = references("GuiObject") },
        { sound = references("Sound") }
    )
    local asset = schema.struct(
        { folder = references("Folder") },
        { animation = references("Animation") }
    )
    local choice = schema.taggedUnion("kind", {
        Model = schema.struct({ model = references("Model") }),
        Tool = schema.struct({ tool = references("Tool") }),
    })
    local value = schema.struct(
        { core = core },
        { parts = schema.array(references("BasePart"), 2) },
        { assets = schema.map(schema.string(16), asset, 1) },
        { animator = schema.optional(references("Animator")) },
        { choice = choice }
    )
    local scopedFields = {
        schema.field("first", references("Folder")),
        schema.field("second", references("Part")),
    }
    return assert(Relay.define({ name = "RelayInstanceReferenceProof", version = 1, events = {
        Input = { id = 1, direction = "ClientToServer", fields = { schema.field("value", value) } },
        Output = { id = 2, direction = "ServerToClient", fields = { schema.field("value", value) } },
        MissingInput = { id = 3, direction = "ClientToServer", fields = {
            schema.field("value", references("Folder")),
        } },
        MissingOutput = { id = 4, direction = "ServerToClient", fields = {
            schema.field("value", references("Folder")),
        } },
        ScopedInput = { id = 5, direction = "ClientToServer", fields = scopedFields },
        ScopedOutput = { id = 6, direction = "ServerToClient", fields = scopedFields },
        StreamingOutput = { id = 7, direction = "ServerToClient", fields = {
            schema.field("value", references("Part")),
        } },
    } }))
end

local function scopeObjects()
    local root = waitChild(ReplicatedStorage, SCOPE_NAME)
    return {
        root = root,
        folder = waitChild(root, "InsideFolder"),
        part = waitChild(root, "InsidePart"),
        outsidePart = waitChild(waitChild(ReplicatedStorage, ROOT_NAME), "PartReference"),
    }
end

local function scopeReceipt(first, second)
    assert(typeof(first) == "Instance" and first:IsA("Folder"), "scoped Folder identity")
    assert(typeof(second) == "Instance" and second:IsA("Part"), "scoped Part identity")
    return { first = identity("Folder", first), second = identity("Part", second) }
end

local function serverOnly()
    local storage = game:GetService("ServerStorage")
    local previous = storage:FindFirstChild("RelayProofServerOnlyFolder")
    if previous then previous:Destroy() end
    return child(storage, "Folder", "RelayProofServerOnlyFolder")
end

local function prepareFar()
    local previous = Workspace:FindFirstChild(FAR_MODEL_NAME)
    if previous then previous:Destroy() end
    local model = Instance.new("Model")
    model.Name = FAR_MODEL_NAME
    local part = child(model, "Part", "UnstreamedPart")
    part.Anchored = true
    part.CFrame = CFrame.new(1_000_000, 0, 0)
    model.Parent = Workspace
    return model, part
end

local function duplicateSecondSlotPacket()
    local packet = buffer.create(6)
    buffer.writeu8(packet, 0, 4)
    buffer.writeu16(packet, 1, 5)
    buffer.writeu8(packet, 3, 2)
    buffer.writeu8(packet, 4, 1)
    buffer.writeu8(packet, 5, 1)
    return packet
end

local function rawReceipt(endpointId, packet, ...)
    local arguments = table.pack(packet, ...)
    local receipt = {
        endpoint = endpointId,
        argumentCount = arguments.n,
        instanceArguments = 0,
        nilArguments = 0,
        references = table.create(math.max(0, arguments.n - 1)),
    }
    if typeof(packet) == "buffer" then
        local length = buffer.len(packet)
        receipt.length = length
        if length >= 1 then receipt.format = buffer.readu8(packet, 0) end
        if length >= 3 then receipt.eventId = buffer.readu16(packet, 1) end
        if length >= 4 then receipt.referenceCount = buffer.readu8(packet, 3) end
        if endpointId == 5 and length >= 6 then
            receipt.ordinals = { buffer.readu8(packet, 4), buffer.readu8(packet, 5) }
        end
    end
    for index = 2, arguments.n do
        local reference = arguments[index]
        if typeof(reference) == "Instance" then
            receipt.instanceArguments += 1
            local sidecar = {
                kind = "Instance", className = reference.ClassName, name = reference.Name,
                path = reference:GetFullName(),
            }
            if reference:IsA("Player") then sidecar.userId = reference.UserId end
            receipt.references[index - 1] = sidecar
        else
            if reference == nil then
                receipt.nilArguments += 1
                receipt.references[index - 1] = { kind = "nil" }
            else
                receipt.references[index - 1] = { kind = typeof(reference) }
            end
        end
    end
    return receipt
end

return table.freeze({
    classes = table.freeze({ "Instance", "BasePart", "Part", "MeshPart", "Model", "Humanoid", "Tool",
        "Attachment", "Player", "Folder", "GuiObject", "Sound", "Animation", "Animator" }),
    prepare = prepare,
    objects = objects,
    payload = payload,
    check = check,
    create = create,
    scopeObjects = scopeObjects,
    scopeReceipt = scopeReceipt,
    serverOnly = serverOnly,
    prepareFar = prepareFar,
    duplicateSecondSlotPacket = duplicateSecondSlotPacket,
    rawReceipt = rawReceipt,
    farModelName = FAR_MODEL_NAME,
})
