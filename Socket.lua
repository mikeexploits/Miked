--[[ ═══════════════════════════════════════════════════════════════
    Miked.Socket  —  client-to-client transport
    ───────────────────────────────────────────────────────────────
    CREDITS
      BugSocket
      Made by 4DBug
      https://socket.bug.tools/
      https://github.com/4DBug/Socket/tree/main

    PUBLIC API
      Miked.Socket.send(type, data, opts)   opts = {to=, ack=, onAck=, timeout=}
      Miked.Socket.on(type, fn)  -> fn(data, senderPlayer, env) ; returns unsub
      Miked.Socket.off(type, fn)
      Miked.Socket.ping()                   probe the swarm (built-in test)
      Miked.Socket.status()                 print transport state
      Miked.Socket.teardown()
═══════════════════════════════════════════════════════════════════ ]]

local Players    = game:GetService("Players")
local CoreGui    = game:GetService("CoreGui")
local RRS        = game:GetService("RobloxReplicatedStorage")
local LP         = Players.LocalPlayer

------------------------------------------------------------------
-- 0. Namespace root  (Socket is the first brick, so it births it)
------------------------------------------------------------------
local Miked = getgenv().Miked
if not Miked then
    Miked = {
        _version = "0.1.0",
        Config   = {},   -- filled by a later Config module
        State    = {},   -- live swarm state (replaces the old _G soup)
        Conns    = {},   -- tracked connections, for clean teardown
        Cache    = {},   -- rosters / bot indexes
    }
    getgenv().Miked = Miked
end

local function track(conn)
    if conn then table.insert(Miked.Conns, conn) end
    return conn
end

------------------------------------------------------------------
-- 1. Channel config  (a real Config module can override these)
------------------------------------------------------------------
local CH_NAME = Miked.Config.socketChannel or "MikedNet/v1"
local FREQ    = Miked.Config.socketFreq    or 20   -- keepalive Hz

------------------------------------------------------------------
-- 2. Locate the relay remotes
------------------------------------------------------------------
local Request, Replicate
pcall(function()
    Request   = RRS:WaitForChild("RequestDeviceCameraCFrame", 10)
    Replicate = RRS:WaitForChild("ReplicateDeviceCameraCFrame", 10)
end)
if not Request or not Replicate then
    warn("[Miked.Socket] relay remotes missing — transport OFFLINE (ws fallback slots in here later)")
end

------------------------------------------------------------------
-- 3. Channel port  —  djb2 masked to 24 bits (float32-exact)
------------------------------------------------------------------
local function hashPort(name)
    local p = 0
    for i = 1, #name do
        p = bit32.band(bit32.lshift(p, 5) + p + name:byte(i), 0xFFFFFF)
    end
    return p
end
local PORT    = hashPort(CH_NAME)
local PORT_CF = CFrame.new(PORT, PORT, PORT)

------------------------------------------------------------------
-- 4. Socket object  (reused across re-exec — never rebuilt)
------------------------------------------------------------------
local Socket = Miked.Socket or {}
Miked.Socket = Socket

Socket.available  = (Request ~= nil and Replicate ~= nil)
Socket.channel    = CH_NAME
Socket.port       = PORT
Socket.receiveOwn = false                       -- ignore our own echoes
Socket._handlers  = {}                           -- reset each load: no dup handlers
Socket._seen      = Socket._seen      or {}      -- id -> true (dedupe), persists
Socket._seenOrder = Socket._seenOrder or {}      -- ring buffer of ids
Socket._pending   = Socket._pending   or {}      -- id -> {cb, expires} for acks
Socket._msgn      = Socket._msgn      or 0

------------------------------------------------------------------
-- 5. Helpers
------------------------------------------------------------------
local function makeId()
    Socket._msgn += 1
    return string.format("%d:%d:%d", LP.UserId, math.floor(tick() * 1000), Socket._msgn)
end

local function seen(id)                           -- true if already handled
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
    if to == LP.Name or to == LP.Name:lower() or to == LP.UserId then return true end
    return false
end

------------------------------------------------------------------
-- 6. Send
------------------------------------------------------------------
function Socket.send(msgType, data, opts)
    if not Socket.available then return nil end
    opts = opts or {}
    local env = {
        id  = makeId(),
        t   = msgType,
        to  = opts.to or "all",
        ack = opts.ack and true or nil,
        d   = data,
    }
    if opts.ack and opts.onAck then
        Socket._pending[env.id] = { cb = opts.onAck, expires = tick() + (opts.timeout or 3) }
    end
    pcall(function() Replicate:FireServer(PORT_CF, { env }) end)
    return env.id
end

------------------------------------------------------------------
-- 7. Subscribe / unsubscribe
------------------------------------------------------------------
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

------------------------------------------------------------------
-- 8. Dispatch  (the receive brain)
------------------------------------------------------------------
local function dispatch(sender, env)
    if type(env) ~= "table" or not env.id or not env.t then return end
    if seen(env.id) then return end

    -- ack replies resolve a pending send, regardless of targeting
    if env.t == "sys.ack" then
        local ref = env.d and env.d.id
        local p   = ref and Socket._pending[ref]
        if p then p.cb(sender); Socket._pending[ref] = nil end
        return
    end

    if not amTarget(env.to) then return end

    -- auto-ack if the sender asked for confirmation
    if env.ack then
        Socket.send("sys.ack", { id = env.id }, { to = sender.Name })
    end

    local list = Socket._handlers[env.t]
    if not list then return end
    for _, fn in ipairs(list) do
        task.spawn(function()
            local ok, err = pcall(fn, env.d, sender, env)
            if not ok then warn("[Miked.Socket] handler error (" .. env.t .. "): " .. tostring(err)) end
        end)
    end
end

------------------------------------------------------------------
-- 9. Hook the relay  (guarded: one hook across re-exec)
------------------------------------------------------------------
if Socket.available and not Socket._hooked then
    Socket._hooked = true
    track(Replicate.OnClientEvent:Connect(function(sender, cast, args)
        if typeof(cast) ~= "CFrame" or cast ~= PORT_CF then return end
        if sender == LP and not Socket.receiveOwn then return end
        dispatch(sender, args and args[1])
    end))
end

------------------------------------------------------------------
-- 10. Keepalive pump  (primes the relay; guarded singleton)
------------------------------------------------------------------
if Socket.available and not Miked._pumpRunning then
    Miked._pumpRunning = true

    -- quietly drop the self-view core UI (relay side effect, harmless)
    pcall(function()
        local rg = CoreGui:FindFirstChild("RobloxGui")
        local pv = rg and rg:FindFirstChild("CoreScripts/PlayerView")
        if pv then pv.Enabled = false end
    end)

    task.spawn(function()
        local interval = 1 / FREQ
        while Miked._pumpRunning do
            for _, pl in ipairs(Players:GetPlayers()) do
                pcall(function() Request:FireServer(pl.UserId) end)
            end
            task.wait(interval)
        end
    end)

    -- expire timed-out ack callbacks
    task.spawn(function()
        while Miked._pumpRunning do
            local now = tick()
            for id, p in pairs(Socket._pending) do
                if now > p.expires then
                    task.spawn(function() pcall(p.cb, nil) end)  -- nil sender = timeout
                    Socket._pending[id] = nil
                end
            end
            task.wait(0.5)
        end
    end)
end

------------------------------------------------------------------
-- 11. Teardown
------------------------------------------------------------------
function Socket.teardown()
    Miked._pumpRunning = false
    Socket._hooked   = false
    Socket._handlers = {}
    -- tracked connections are dropped by the global Miked cleanup (later brick)
end

------------------------------------------------------------------
-- 12. Built-in self-test  (verify two accounts can talk)
------------------------------------------------------------------
Socket.on("sys.ping", function(_, sender)
    Socket.send("sys.pong", { name = LP.Name }, { to = sender.Name })
end)

Socket.on("sys.pong", function(d, sender)
    print(("[Miked.Socket] ◄ pong from %s"):format(sender.Name))
end)

function Socket.ping()
    print(("[Miked.Socket] ► pinging swarm  (channel=%s  port=%d)"):format(CH_NAME, PORT))
    Socket.send("sys.ping")
end

function Socket.status()
    local h = 0; for _ in pairs(Socket._handlers) do h += 1 end
    print(("[Miked.Socket] v%s | available=%s | channel=%s | port=%d | types=%d")
        :format(Miked._version, tostring(Socket.available), CH_NAME, PORT, h))
end

Socket.status()
return Socket

--[[ ─── HOW TO TEST ─────────────────────────────────────────────
  1. Run this file on TWO accounts in the same server (main + one alt).
  2. Each prints:  [Miked.Socket] v0.1.0 | available=true | ...
  3. On ONE account, run in console:   getgenv().Miked.Socket.ping()
  4. The OTHER account replies; the pinger prints:  ◄ pong from <name>
  If you see the pong, the whole transport works and every later brick
  (commands, roster, GUI) rides on this.
──────────────────────────────────────────────────────────────── ]]
