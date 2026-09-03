opt server_output = "../../generated/zap/Server.luau"
opt client_output = "../../generated/zap/Client.luau"
opt types_output = "../../generated/zap/Types.luau"
opt remote_folder = "RELAY_EVENT_V1_ZAP"
opt remote_scope = "RELAY_EVENT_V1"
opt manual_event_loop = true

event TinyC2S = {
    from: Client,
    type: Reliable,
    call: SingleSync,
    data: (u32, boolean)
}
event TinyS2C = {
    from: Server,
    type: Reliable,
    call: SingleSync,
    data: (u32, boolean)
}
event StateC2S = {
    from: Client,
    type: Reliable,
    call: SingleSync,
    data: (u32, u16, Vector3, f32, u8)
}
event StateS2C = {
    from: Server,
    type: Reliable,
    call: SingleSync,
    data: (u32, u16, Vector3, f32, u8)
}
