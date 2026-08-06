--[[
    warning: vibe coded


    Miked.Socket — client-to-client transport (foundation brick #1)
    ----------------------------------------------------------------
    Transport: WebSocket to a local relay (relay.py) that fans messages
    out to every other connected client. All accounts run on one machine,
    so they all dial ws://127.0.0.1:PORT. Nothing Roblox can delete.

    On top of the raw socket this layers a real protocol:
      · JSON envelopes:  { id, t, to, from, fromId, ack, d }
      · dedupe · self-echo filtering · targeted delivery · optional acks
      · auto-reconnect with backoff · outbound buffer flushed on connect
      · re-exec safe, all state under getgenv().Miked

    Public API
      Miked.Socket.send(type, data, opts)   opts = {to=, ack=, onAck=, timeout=}
      Miked.Socket.on(type, fn)  -> fn(data, sender, env) ; returns unsub
      Miked.Socket.off(type, fn)
      Miked.Socket.ping()                   probe the swarm (built-in test)
      Miked.Socket.status()
      Miked.Socket.teardown()

    sender passed to handlers is normalized: { name, userId, player }
]]

local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")

-- Autoexec (and queue_on_teleport) run before the game finishes loading, so
-- LocalPlayer doesn't exist yet. Wait for both before touching anything.
if not game:IsLoaded() then game.Loaded:Wait() end
if not Players.LocalPlayer then
    repeat task.wait() until Players.LocalPlayer
end

-- Never trust a captured LocalPlayer. On rejoin / teleport the old one is
-- destroyed while this module's coroutines are still alive, so every read
-- goes through me() and every caller handles nil instead of throwing.
local LP = Players.LocalPlayer
local function me()
    if not LP or not LP.Parent then LP = Players.LocalPlayer end
    return LP
end


-- Namespace root — core.lua (or loader.lua) normally sets this up first.
-- Socket just ensures every field exists so it works no matter the load order
-- (core-first, loader-first, or Socket standalone). Never clobbers.
local Miked = getgenv().Miked or {}
getgenv().Miked = Miked
Miked._version = Miked._version or "0.2.0"
Miked.Config   = Miked.Config   or {}   -- your settings (main/alts/wsUrl…)
Miked.State    = Miked.State    or {}   -- live swarm state
Miked.Conns    = Miked.Conns    or {}   -- tracked connections, for teardown
Miked.Cache    = Miked.Cache    or {}   -- rosters / bot indexes


-- Config with safe defaults (a real Config module can override) -----------
local WS_URL   = Miked.Config.wsUrl   or "ws://127.0.0.1:8080"
local MAX_QUEUE = 256   -- outbound messages buffered while disconnected


-- Socket object (reused across re-exec, never rebuilt) --------------------
local Socket = Miked.Socket or {}
Miked.Socket = Socket

Socket.url        = WS_URL
Socket.connected  = false
Socket.receiveOwn = false
Socket._handlers  = {}                       -- reset each load: no dup handlers
Socket._seen      = Socket._seen      or {}  -- id -> true (dedupe), persists
Socket._seenOrder = Socket._seenOrder or {}
Socket._pending   = Socket._pending   or {}  -- id -> {cb, expires} for acks
Socket._outbox    = Socket._outbox    or {}  -- queued sends while offline
Socket._msgn      = Socket._msgn      or 0

-- kill any socket / loops from a previous execution
if Socket._ws then pcall(function() Socket._ws:Close() end) end
Socket._ws     = nil
Socket._alive  = true
Socket._gen    = (Socket._gen or 0) + 1      -- invalidates old reconnect loops
local GEN      = Socket._gen


-- Helpers -----------------------------------------------------------------
local function makeId()
    Socket._msgn += 1
    local p = me()
    return string.format("%d:%d:%d", p and p.UserId or 0, math.floor(tick() * 1000), Socket._msgn)
end

local function seen(id)
    if Socket._seen[id] then return true end
    Socket._seen[id] = true
    table.insert(Socket._seenOrder, id)
    if #Socket._seenOrder > 512 then
        Socket._seen[table.remove(Socket._seenOrder, 1)] = nil
    end
    return false
end

local function amTarget(to)
    if to == nil or to == "all" then return true end
    local p = me(); if not p then return false end
    if to == p.Name or to == p.Name:lower() or to == p.UserId then return true end
    return false
end


-- Send --------------------------------------------------------------------
local function rawSend(jsonStr)
    if Socket.connected and Socket._ws then
        local ok = pcall(function() Socket._ws:Send(jsonStr) end)
        if ok then return true end
        Socket.connected = false          -- send failed: treat as dropped
    end
    -- buffer for flush on reconnect
    if #Socket._outbox < MAX_QUEUE then
        table.insert(Socket._outbox, jsonStr)
    end
    return false
end

function Socket.send(msgType, data, opts)
    opts = opts or {}
    local p = me()
    if not p then return nil end          -- mid-rejoin: nothing to send as
    local env = {
        id     = makeId(),
        t      = msgType,
        to     = opts.to or "all",
        from   = p.Name,
        fromId = p.UserId,
        ack    = opts.ack and true or nil,
        d      = data,
    }
    if opts.ack and opts.onAck then
        Socket._pending[env.id] = { cb = opts.onAck, expires = tick() + (opts.timeout or 3) }
    end
    local ok, jsonStr = pcall(function() return HttpService:JSONEncode(env) end)
    if not ok then warn("[Miked.Socket] encode failed for type " .. tostring(msgType)); return nil end
    rawSend(jsonStr)
    return env.id
end


-- Subscribe / unsubscribe -------------------------------------------------
function Socket.on(msgType, fn)
    local list = Socket._handlers[msgType]
    if not list then list = {}; Socket._handlers[msgType] = list end
    table.insert(list, fn)
    return function() Socket.off(msgType, fn) end
end

function Socket.off(msgType, fn)
    local list = Socket._handlers[msgType]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end


-- Dispatch (the receive brain) --------------------------------------------
local function dispatch(env)
    if type(env) ~= "table" or not env.id or not env.t then return end
    local p = me()
    if not p then return end              -- no identity yet: drop, relay will resend
    if env.from == p.Name and not Socket.receiveOwn then return end
    if seen(env.id) then return end

    -- ack replies resolve a pending send, ignoring targeting
    if env.t == "sys.ack" then
        local ref = env.d and env.d.id
        local p   = ref and Socket._pending[ref]
        if p then p.cb(env.from); Socket._pending[ref] = nil end
        return
    end

    if not amTarget(env.to) then return end

    if env.ack then
        Socket.send("sys.ack", { id = env.id }, { to = env.from })
    end

    local sender = {
        name   = env.from,
        userId = env.fromId,
        player = env.from and Players:FindFirstChild(env.from) or nil,
    }

    local list = Socket._handlers[env.t]
    if not list then return end
    for _, fn in ipairs(list) do
        task.spawn(function()
            local ok, err = pcall(fn, env.d, sender, env)
            if not ok then warn("[Miked.Socket] handler error (" .. env.t .. "): " .. tostring(err)) end
        end)
    end
end


-- Connection + reconnect --------------------------------------------------
local function flushOutbox()
    if #Socket._outbox == 0 then return end
    local pending = Socket._outbox
    Socket._outbox = {}
    for _, jsonStr in ipairs(pending) do rawSend(jsonStr) end
end

local function connect()
    if not Socket._alive or Socket._gen ~= GEN then return end

    local ok, ws = pcall(WebSocket.connect, WS_URL)
    if not ok or not ws then
        warn("[Miked.Socket] connect failed (" .. WS_URL .. ") — is relay.py running? retrying...")
        return false
    end

    Socket._ws = ws
    Socket.connected = true
    print("[Miked.Socket] ► connected to " .. WS_URL)

    ws.OnMessage:Connect(function(message)
        local ok2, env = pcall(function() return HttpService:JSONDecode(message) end)
        if ok2 then dispatch(env) end
    end)

    ws.OnClose:Connect(function()
        if Socket._ws == ws then
            Socket.connected = false
            Socket._ws = nil
            warn("[Miked.Socket] ◄ disconnected")
        end
    end)

    flushOutbox()
    return true
end

-- single reconnect loop with backoff, tied to this execution's GEN
if not Socket._loopRunning then
    Socket._loopRunning = true
    task.spawn(function()
        local backoff = 1
        while Socket._alive do
            if Socket._gen ~= GEN then break end          -- newer exec took over
            if not Socket.connected then
                if connect() then backoff = 1
                else backoff = math.min(backoff * 2, 15) end
            end
            task.wait(Socket.connected and 1 or backoff)
        end
        Socket._loopRunning = false
    end)
end

-- ack timeout sweeper
task.spawn(function()
    while Socket._alive and Socket._gen == GEN do
        local now = tick()
        for id, p in pairs(Socket._pending) do
            if now > p.expires then
                task.spawn(function() pcall(p.cb, nil) end)  -- nil = timed out
                Socket._pending[id] = nil
            end
        end
        task.wait(0.5)
    end
end)


-- Teardown ----------------------------------------------------------------
function Socket.teardown()
    Socket._alive = false
    Socket.connected = false
    if Socket._ws then pcall(function() Socket._ws:Close() end); Socket._ws = nil end
    Socket._handlers = {}
end


-- Built-in self-test ------------------------------------------------------
Socket.on("sys.ping", function(_, sender)
    local p = me(); if not p then return end
    Socket.send("sys.pong", { name = p.Name }, { to = sender.name })
end)

Socket.on("sys.pong", function(_, sender)
    print(("[Miked.Socket] ◄ pong from %s"):format(sender.name))
end)

function Socket.ping()
    print("[Miked.Socket] ► pinging swarm...")
    Socket.send("sys.ping")
end

function Socket.status()
    local h = 0; for _ in pairs(Socket._handlers) do h += 1 end
    print(("[Miked.Socket] v%s | connected=%s | url=%s | types=%d | queued=%d")
        :format(Miked._version, tostring(Socket.connected), WS_URL, h, #Socket._outbox))
end

task.delay(1, Socket.status)
return Socket

--pip install websockets
