--[[
    Miked core — everything but comms.
    Loaded by loader.lua AFTER socket.lua, so getgenv().Miked and
    Miked.Config (your settings) and Miked.Socket already exist.

    Sections (built one at a time):
      · ROLES      identity, auth, game-gating          [done]
      · REGISTRY   Miked.cmd() + the single socket wiring   [next]
      · ROSTER     heartbeats -> live roster + bot index
      · COMMANDS   the Miked.cmd{} registration blocks
      · GUI        main-only panel, generated from registry
      · SURVIVAL   persistence / rejoin / anti-afk / cleanup
]]

-- ── standalone bootstrap ─────────────────────────────────────────────────
-- Running core.lua directly? This sets config + pulls Socket. If a loader
-- already set Miked up, its values are kept and this is skipped.
getgenv().Miked = getgenv().Miked or {
    _version = "1.0.0-beta",
    Config = {
        mainAccount = "ChaosBacon72",                 -- << YOUR main account
        altAccounts = { "ttm22327", "Bladezsteel" },  -- << YOUR bot usernames
        commanders  = {},                             -- extra people allowed to command
        prefix      = "!",                            -- command prefix
        wsUrl       = "ws://127.0.0.1:8080",          -- relay address (localhost)
        games       = { micup = {} },                 -- [PlaceId] = true  (later)
        fpsCap      = 10,                             -- bot fps cap
        announceOnLoad = false,                       -- bots chat "Miked loaded"
        autoUnmute  = false,                          -- voice games: auto-unmute mic
        vcbEnabled  = false,                          -- voice games: auto-rejoin on VC ban
    },
    State = {}, Conns = {}, Cache = {},
}
if not getgenv().Miked.Socket then
    loadstring(game:HttpGet("https://raw.githubusercontent.com/mikeexploits/Miked/refs/heads/main/Systems/Socket.lua"))()
end

local Players = game:GetService("Players")
local LP      = Players.LocalPlayer

local Miked  = getgenv().Miked
assert(Miked and Miked.Config, "[Miked] core.lua loaded before loader set Miked.Config")
local Config = Miked.Config

local function lc(s) return tostring(s):lower() end
Miked._lc = lc
Miked.State.startTime = Miked.State.startTime or tick()


-- ══ ROLES ════════════════════════════════════════════════════════════════
-- Who is this account? main / bot / none. Plus command auth + game gating.
do
    -- case-insensitive alt lookup
    local altSet = {}
    for _, n in ipairs(Config.altAccounts or {}) do altSet[lc(n)] = true end
    Miked.Cache.altSet = altSet

    -- who may command the swarm: main is always allowed, plus any extras
    local commanderSet = { [lc(Config.mainAccount or "")] = true }
    for _, n in ipairs(Config.commanders or {}) do commanderSet[lc(n)] = true end
    Miked.Cache.commanderSet = commanderSet

    local me = lc(LP.Name)
    Miked.isMain = (me == lc(Config.mainAccount or ""))
    Miked.isBot  = (altSet[me] == true) and not Miked.isMain
    Miked.role   = Miked.isMain and "main" or (Miked.isBot and "bot" or "none")
    Miked.State.role = Miked.role

    -- is `name` allowed to issue commands?
    function Miked.isCommander(name)
        return commanderSet[lc(name)] == true
    end

    -- is a bot username (used by roster / targeting)?
    function Miked.isAlt(name)
        return altSet[lc(name)] == true
    end

    -- are we in a game that a situational module wants? e.g. inGame("micup")
    function Miked.inGame(tag)
        local set = Config.games and Config.games[tag]
        return set ~= nil and set[game.PlaceId] == true
    end

    -- validation
    if not Config.mainAccount or Config.mainAccount == "" then
        warn("[Miked] mainAccount is not set in loader.lua")
    end
    if not Config.altAccounts or #Config.altAccounts == 0 then
        warn("[Miked] no altAccounts configured in loader.lua")
    end

    print(("[Miked] %s  →  role: %s"):format(LP.Name, Miked.role:upper()))
end


-- ══ HELPERS ══════════════════════════════════════════════════════════════
-- Ported from Hyperion's dispatch layer; the registry leans on these.
local TextChatService   = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Send a message to game chat (TextChatService or legacy).
local function ChatSend(text)
    pcall(function()
        if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
            local ch = TextChatService.TextChannels:FindFirstChild("RBXGeneral")
            if ch then ch:SendAsync(text) end
        else
            local r = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
            local s = r and r:FindFirstChild("SayMessageRequest")
            if s then s:FireServer(text, "All") end
        end
    end)
end
Miked.chat = ChatSend

-- Resolve a target name to a Player. Handles me / random / all / partial.
local function FindTarget(name, speaker)
    if not name or name == "" then return speaker end
    local nl = lc(name)
    if nl == "me" then return speaker end
    if nl == "random" then
        local p = Players:GetPlayers()
        return #p > 0 and p[math.random(#p)] or nil
    end
    if nl == "all" then return nil end
    for _, v in ipairs(Players:GetPlayers()) do
        if lc(v.Name):sub(1, #name) == nl or lc(v.DisplayName):sub(1, #name) == nl then
            return v
        end
    end
    return nil
end
Miked.findTarget = FindTarget

-- ══ ROSTER ═══════════════════════════════════════════════════════════════
-- Deterministic per-bot index: every client independently sorts the online
-- alts the same way, so bot #4 KNOWS it's #4 without asking anyone. This is
-- what lets formations split the swarm with zero coordination traffic.
Miked.roster = Miked.roster or {}
do
    local bc = { list = {}, map = {}, total = 0, last = 0 }

    local function refresh()
        local now = tick()
        if now - bc.last < 2 then return end
        bc.last = now
        local altSet = Miked.Cache.altSet or {}
        local online = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if altSet[lc(p.Name)] then online[#online + 1] = lc(p.Name) end
        end
        table.sort(online)
        local map = {}
        for i, n in ipairs(online) do map[n] = i end
        bc.list, bc.map, bc.total = online, map, #online
    end

    function Miked.roster.index()
        refresh()
        return bc.map[lc(LP.Name)] or 1
    end
    function Miked.roster.total()
        refresh()
        return bc.total > 0 and bc.total or 1
    end
    function Miked.roster.names()
        refresh()
        return bc.list
    end
end


-- ══ REGISTRY ═════════════════════════════════════════════════════════════
-- One function to add a command. It absorbs the boilerplate every Hyperion
-- command repeats: solo guard, bot-targeting, game-gating, target/ctx setup.
do
    local Commands = {}          -- name/alias (lower) -> entry
    local Ordered  = {}          -- registration order, for the GUI
    Miked.Commands = Commands
    Miked.CommandList = Ordered

    -- accept:  (table)  |  (name, fn)  |  (name, opts, fn)
    local function normalize(a, b, c)
        if type(a) == "table" then return a end
        if type(a) == "string" and type(b) == "function" then
            return { name = a, run = b }
        end
        if type(a) == "string" and type(b) == "table" and type(c) == "function" then
            b.name, b.run = a, c; return b
        end
        error("Miked.cmd: expected (def) | (name, fn) | (name, opts, fn)")
    end

    function Miked.cmd(a, b, c)
        local def = normalize(a, b, c)
        assert(def.name and def.run, "Miked.cmd needs a name and a run function")

        -- game gate: a placed command simply doesn't exist off its map
        if def.place and not Miked.inGame(def.place) then return end

        local entry = {
            name      = def.name,
            aliases   = def.aliases or {},
            category  = def.category or "Misc",
            desc      = def.desc or "",
            args      = def.args,          -- hint string for the GUI arg box
            solo      = def.solo or false, -- only runs with no params
            botTarget = def.botTarget or false,
            run       = def.run,
        }
        Commands[lc(def.name)] = entry
        for _, al in ipairs(entry.aliases) do Commands[lc(al)] = entry end
        table.insert(Ordered, entry)
        return entry
    end

    -- "botN target ..." -> strip the botN, return whether THIS bot should run
    local function parseBotTarget(args)
        if not args[2] then return true, args end
        local n = tostring(args[2]):lower():match("^bot(%d+)$")
        if not n then return true, args end
        local newArgs = { args[1] }
        for i = 3, #args do newArgs[#newArgs + 1] = args[i] end
        return tonumber(n) == Miked.roster.index(), newArgs
    end

    -- the fat ctx handed to every command body
    local function buildCtx(entry, args, speaker)
        local ctx = {
            cmd     = entry.name,
            args    = args,
            speaker = speaker,
            index   = Miked.roster.index(),
            total   = Miked.roster.total(),
        }
        function ctx.find(nameOrNil) return FindTarget(nameOrNil or args[2], speaker) end
        function ctx.char() return LP.Character end
        function ctx.root() local c = LP.Character; return c and c:FindFirstChild("HumanoidRootPart") end
        function ctx.hum()  local c = LP.Character; return c and c:FindFirstChildOfClass("Humanoid") end
        function ctx.reply(text, opts)
            opts = opts or {}
            task.spawn(function()
                if opts.stagger then
                    local gap = (opts.stagger == true) and 0.3 or opts.stagger
                    task.wait((ctx.index - 1) * gap)
                end
                ChatSend(text)
            end)
        end
        return ctx
    end

    -- local execution (runs on bots; main is the controller, never self-runs)
    function Miked.exec(text, speaker)
        if Miked.isMain then return end
        local prefix = Config.prefix or "!"
        if type(text) ~= "string" or text:sub(1, #prefix) ~= prefix then return end

        local args  = text:split(" ")
        local name  = lc(args[1]:sub(#prefix + 1))
        local entry = Commands[name]
        if not entry then return end

        if entry.botTarget then
            local run, newArgs = parseBotTarget(args)
            if not run then return end
            args = newArgs
        end
        if entry.solo and args[2] ~= nil and args[2] ~= "" then return end

        local ctx = buildCtx(entry, args, speaker)
        local ok, err = pcall(entry.run, ctx)
        if not ok then warn(("[Miked] command error (%s): %s"):format(name, tostring(err))) end
    end
end

-- ── the ONE socket wiring: every command flows through this single point ──
Miked.Socket.on("cmd", function(data, sender)
    if not data or not data.text then return end
    if not Miked.isCommander(sender.name) then return end     -- auth (replaces chat-whitelist)
    Miked.exec(data.text, sender.player or sender)
end)

-- main's send path: GUI clicks AND chat-typing both funnel here
function Miked.send(text)
    Miked.Socket.send("cmd", { text = text })
end

if Miked.isMain then
    -- typing a command in chat broadcasts it to the swarm.
    -- chat is just an INPUT here — the socket is the transport, bots never read chat.
    local prefix = Config.prefix or "!"
    table.insert(Miked.Conns, LP.Chatted:Connect(function(msg)
        if msg:sub(1, #prefix) == prefix then Miked.send(msg) end
    end))
end


-- ══ COMMANDS ═════════════════════════════════════════════════════════════
-- Ported from Hyperion, boilerplate stripped, reshaped onto ctx + Miked.State.
do
    local RunService = game:GetService("RunService")
    local State = Miked.State
    State.cmd = "None"                       -- current exclusive movement tag

    local sin, cos, abs, sqrt = math.sin, math.cos, math.abs, math.sqrt
    local PI, PI2 = math.pi, math.pi * 2

    -- ── shared control ──────────────────────────────────────────────────
    -- Clears exclusive movement only. Persistent states (noclip/ws/antivoid)
    -- survive, exactly like Hyperion's StopAll.
    local function stopAll()
        State.cmd = "None"
        State.emote = nil
        local c = LP.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if r then r.Velocity = Vector3.zero; r.RotVelocity = Vector3.zero; r.Anchored = false end
        if h then h.AutoRotate = true; if not State.speedLock then h.WalkSpeed = 16 end end
        if State.stackPart then pcall(function() State.stackPart:Destroy() end); State.stackPart = nil end
        -- kill emotes/dances: the tracked catalog emote + any /e action tracks
        if State.emoteTrack then pcall(function() State.emoteTrack:Stop(0) end); State.emoteTrack = nil end
        if h then
            local anim = h:FindFirstChildOfClass("Animator")
            if anim then
                for _, tr in pairs(anim:GetPlayingAnimationTracks()) do
                    if tr.Priority == Enum.AnimationPriority.Action then pcall(function() tr:Stop(0) end) end
                end
            end
        end
    end
    Miked.stopAll = stopAll

    -- ── arg parsers ─────────────────────────────────────────────────────
    local function speedTarget(ctx, defSpeed)
        local a = ctx.args
        local speed, tname = defSpeed, nil
        if a[2] then
            local n = tonumber(a[2])
            if n then speed = n; tname = a[3] else tname = a[2] end
        end
        return speed, ctx.find(tname)
    end

    local function speedRangeTarget(ctx, defS, defR)
        local a = ctx.args
        local s, r, tname = defS, defR, nil
        if a[2] then
            local n1 = tonumber(a[2])
            if n1 then
                s = n1
                if a[3] then
                    local n2 = tonumber(a[3])
                    if n2 then r = n2; tname = a[4] else tname = a[3] end
                end
            else tname = a[2] end
        end
        return s, r, ctx.find(tname)
    end

    local function myRoot() local c = LP.Character; return c and c:FindFirstChild("HumanoidRootPart") end
    local function myHum()  local c = LP.Character; return c and c:FindFirstChildOfClass("Humanoid") end

    -- ══ MOVEMENT ════════════════════════════════════════════════════════
    Miked.cmd{ name="goto", category="Movement", desc="Teleport to target", args="[bot] Target", botTarget=true,
        run=function(ctx)
            local t = ctx.find(); if not (t and t.Character and t.Character:FindFirstChild("HumanoidRootPart")) then return end
            local mR = myRoot(); if not mR then return end
            local a = (ctx.index / ctx.total) * PI2
            mR.CFrame = t.Character.HumanoidRootPart.CFrame * CFrame.new(cos(a)*6, 0, sin(a)*6) * CFrame.Angles(0, a+PI, 0)
        end }

    Miked.cmd{ name="bring", category="Movement", desc="Summon bots to target", args="[bot] Target", botTarget=true,
        run=function(ctx)
            local t = ctx.find(); if not (t and t.Character and t.Character:FindFirstChild("HumanoidRootPart")) then return end
            local mR = myRoot(); if not mR then return end
            local idx, total = ctx.index, ctx.total
            local cols = math.ceil(sqrt(total))
            local row, col = math.floor((idx-1)/cols), (idx-1)%cols
            mR.CFrame = t.Character.HumanoidRootPart.CFrame * CFrame.new((col-(cols-1)/2)*4, 0, (row+1)*4)
            mR.Velocity = Vector3.zero
        end }

    Miked.cmd{ name="follow", category="Movement", desc="Follow target", args="Target",
        run=function(ctx)
            local t = ctx.find(); if not (t and t.Character) then return end
            stopAll(); task.wait(0.05); State.cmd = "Follow"
            task.spawn(function()
                while State.cmd=="Follow" and t and t.Character do
                    local h, mR = myHum(), myRoot()
                    local tR = t.Character:FindFirstChild("HumanoidRootPart")
                    if h and mR and tR then
                        if h.Sit then h.Sit=false end
                        local a = (ctx.index/ctx.total)*PI2
                        local goal = tR.Position + Vector3.new(cos(a)*5,0,sin(a)*5)
                        if (mR.Position-goal).Magnitude > 50 then mR.CFrame = CFrame.new(goal, tR.Position) else h:MoveTo(goal) end
                    end
                    task.wait(0.15)
                end
            end)
        end }

    Miked.cmd{ name="walkto", aliases={"to"}, category="Movement", desc="Walk to target", args="Target",
        run=function(ctx)
            local t = ctx.find(); if not (t and t.Character) then return end
            stopAll(); task.wait(0.05); State.cmd = "WalkTo"
            task.spawn(function()
                while State.cmd=="WalkTo" and t and t.Character do
                    local h, mR = myHum(), myRoot()
                    local tR = t.Character:FindFirstChild("HumanoidRootPart")
                    if h and mR and tR then
                        if h.Sit then h.Sit=false end
                        local idx, total = ctx.index, ctx.total
                        local cols = math.ceil(sqrt(total))
                        local row, col = math.floor((idx-1)/cols), (idx-1)%cols
                        h:MoveTo((tR.CFrame*CFrame.new((col-(cols-1)/2)*5,0,(row+1)*5)).Position)
                    end
                    task.wait(0.1)
                end
            end)
        end }

    Miked.cmd{ name="stalk", category="Movement", desc="Stalk from behind", args="Target",
        run=function(ctx)
            local t = ctx.find(); if not (t and t.Character) then return end
            stopAll(); task.wait(0.05); State.cmd = "Stalk"
            task.spawn(function()
                while State.cmd=="Stalk" and t and t.Character do
                    local h, mR = myHum(), myRoot()
                    local tR = t.Character:FindFirstChild("HumanoidRootPart")
                    if h and mR and tR then
                        if h.Sit then h.Sit=false end
                        local idx = ctx.index
                        local col, row = (idx-1)%3, math.floor((idx-1)/3)
                        local behind = tR.CFrame * CFrame.new((col-1)*4, 0, (row+1)*4)
                        local diff = mR.Position - tR.Position
                        if diff.Magnitude > 0.1 and (diff.Unit:Dot(tR.CFrame.LookVector) > 0.3 or tR.Velocity.Magnitude > 100) then
                            mR.CFrame = behind; mR.Velocity = Vector3.zero
                        else h:MoveTo(behind.Position) end
                    end
                    task.wait(0.05)
                end
            end)
        end }

    Miked.cmd{ name="worm", category="Movement", desc="Snake chain", args="Target",
        run=function(ctx)
            local t = ctx.find(); if not t then return end
            stopAll(); task.wait(0.05); State.cmd = "Worm"; local idx = ctx.index
            task.spawn(function()
                while State.cmd=="Worm" do
                    local h = myHum(); if h and h.Sit then h.Sit=false end
                    local ft
                    if idx==1 then ft = t else
                        local names = Miked.roster.names(); local pn = names[idx-1]
                        if pn then for _,p in ipairs(Players:GetPlayers()) do if lc(p.Name)==pn then ft=p break end end end
                    end
                    if h and ft and ft.Character then
                        local tR = ft.Character:FindFirstChild("HumanoidRootPart"); local mR = myRoot()
                        if tR and mR then
                            if (mR.Position-tR.Position).Magnitude > 4 then h:MoveTo(tR.Position) else h:MoveTo(mR.Position) end
                        end
                    end
                    task.wait(0.1)
                end
            end)
        end }

    Miked.cmd{ name="swarm", category="Movement", desc="Chaotic swarm", args="Target [speed] [range]",
        run=function(ctx)
            local t     = ctx.find(ctx.args[2])
            local speed = tonumber(ctx.args[3])           -- nil or 0 = leave walkspeed alone
            local range = tonumber(ctx.args[4]) or 15
            local setWS = speed ~= nil and speed > 0
            if not (t and t.Character) then return end
            stopAll(); task.wait(0.05); State.cmd = "Swarm"
            task.spawn(function()
                local goal, gt = Vector3.zero, 0
                while State.cmd=="Swarm" and t and t.Character do
                    local h, mR = myHum(), myRoot()
                    local tR = t.Character:FindFirstChild("HumanoidRootPart")
                    if h and mR and tR then
                        if h.Sit then h.Sit=false end
                        if setWS then h.WalkSpeed = speed end
                        if (mR.Position-goal).Magnitude < 5 or tick()-gt > 1.2 then
                            local rng = Random.new()
                            goal = tR.Position + Vector3.new(rng:NextNumber(-range,range),0,rng:NextNumber(-range,range)); gt=tick()
                        end
                        h:MoveTo(goal)
                    end
                    task.wait(0.03)
                end
                if setWS then local h = myHum(); if h then h.WalkSpeed = State.speedLock or 16 end end
            end)
        end }

    Miked.cmd{ name="wonder", category="Movement", desc="Wander randomly", solo=true,
        run=function(ctx)
            stopAll(); task.wait(0.05); State.cmd = "Wonder"; local idx = ctx.index
            task.spawn(function()
                while State.cmd=="Wonder" do
                    local h, r = myHum(), myRoot()
                    if h and r then
                        if h.Sit then h.Sit=false end
                        local rng = Random.new(tick()+idx)
                        h:MoveTo(r.Position + Vector3.new(rng:NextNumber(-30,30),0,rng:NextNumber(-30,30)))
                        local done, el = false, 0
                        local cn = h.MoveToFinished:Connect(function() done=true end)
                        repeat task.wait(0.1); el+=0.1 until done or State.cmd~="Wonder" or el>10
                        cn:Disconnect()
                    end
                    task.wait(math.random(1,2))
                end
            end)
        end }

    Miked.cmd{ name="carpet", aliases={"floor","bridge"}, category="Movement", desc="Rolling carpet under target", args="Target",
        run=function(ctx)
            local t = ctx.find(); if not (t and t.Character) then return end
            stopAll(); task.wait(0.05); State.cmd = "Carpet"; local idx = ctx.index
            task.spawn(function()
                local conn; conn = RunService.Heartbeat:Connect(function()
                    if State.cmd~="Carpet" then conn:Disconnect() return end
                    local mR = myRoot(); local tR = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                    local tH = t.Character and t.Character:FindFirstChildOfClass("Humanoid")
                    if mR and tR and tH then
                        local dir = (tH.MoveDirection.Magnitude>0) and tH.MoveDirection or tR.CFrame.LookVector
                        local off = dir*(idx*7.5)
                        local p = tR.Position + off + Vector3.new(0,-3.2,0)
                        mR.CFrame = CFrame.new(p, p+dir) * CFrame.Angles(math.rad(90),0,0)
                        mR.Velocity = Vector3.zero
                    end
                end)
                table.insert(Miked.Conns, conn)
            end)
        end }

    Miked.cmd{ name="stackon", category="Movement", desc="Vertical tower on target", args="Target",
        run=function(ctx)
            local t = ctx.find(); if not t then return end
            stopAll()
            local part = Instance.new("Part"); part.Name="MikedStack"; part.Size=Vector3.new(4,1,4)
            part.Transparency=1; part.Anchored=true; part.CanCollide=true; part.Parent=workspace; State.stackPart=part
            State.cmd="Stack"; local hOff = ctx.index*5
            task.spawn(function()
                while State.cmd=="Stack" do
                    local mR = myRoot(); local tR = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                    if tR and mR then
                        local cf = tR.CFrame*CFrame.new(0,hOff,0); part.CFrame=cf
                        mR.CFrame = cf*CFrame.new(0,1.5,0); mR.Velocity=Vector3.zero
                    else break end
                    RunService.Heartbeat:Wait()
                end
                if State.stackPart then pcall(function() State.stackPart:Destroy() end); State.stackPart=nil end
            end)
        end }

    Miked.cmd{ name="tp", aliases={"tpto"}, category="Movement", desc="Teleport to coords/target", args="[bot] X Y Z / Target", botTarget=true,
        run=function(ctx)
            local mR = myRoot(); if not mR then return end
            local a = ctx.args
            if a[2] and tonumber(a[2]) then
                mR.CFrame = CFrame.new(tonumber(a[2]) or 0, tonumber(a[3]) or 0, tonumber(a[4]) or 0)
            else
                local t = ctx.find()
                if t and t.Character and t.Character:FindFirstChild("HumanoidRootPart") then
                    local ang = (ctx.index/ctx.total)*PI2
                    mR.CFrame = t.Character.HumanoidRootPart.CFrame * CFrame.new(cos(ang)*6,0,sin(ang)*6)
                end
            end
        end }

    Miked.cmd{ name="scatter", category="Movement", desc="Random scatter", args="[Range]",
        run=function(ctx)
            stopAll(); local range = tonumber(ctx.args[2]) or 30
            local mR = myRoot()
            if mR then
                local rng = Random.new(tick()+ctx.index)
                mR.CFrame = CFrame.new(mR.Position + Vector3.new(rng:NextNumber(-range,range),0,rng:NextNumber(-range,range)))
            end
        end }

    -- ══ FORMATIONS ══════════════════════════════════════════════════════
    Miked.cmd{ name="circle", category="Formations", desc="Snap to circle", args="[R] Target",
        run=function(ctx)
            local radius, t = speedTarget(ctx, nil)
            if not (t and t.Character and t.Character:FindFirstChild("HumanoidRootPart")) then return end
            local idx, total = ctx.index, ctx.total
            radius = radius or math.max(8, total*1.2)
            local a = (idx/total)*PI2
            local off = Vector3.new(cos(a)*radius,0,sin(a)*radius)
            local tR = t.Character.HumanoidRootPart; local mR = myRoot()
            if mR then mR.CFrame = CFrame.new(tR.Position+off, tR.Position) end
        end }

    Miked.cmd{ name="loopcircle", category="Formations", desc="Iterative circle", args="[R] Target",
        run=function(ctx)
            local radiusIn, t = speedTarget(ctx, nil)
            if not (t and t.Character) then return end
            stopAll(); task.wait(0.05); State.cmd="LoopCircle"
            task.spawn(function()
                while State.cmd=="LoopCircle" and t and t.Character do
                    local idx, total = ctx.index, ctx.total
                    local radius = radiusIn or math.max(8, total*1.2)
                    local a = (idx/total)*PI2
                    local tR = t.Character:FindFirstChild("HumanoidRootPart"); local mR = myRoot()
                    if tR and mR then mR.CFrame = CFrame.new(tR.Position+Vector3.new(cos(a)*radius,0,sin(a)*radius), tR.Position) end
                    task.wait()
                end
            end)
        end }

    -- line formations (r/l/f/b + loop variants)
    local LINE_DIRS = { rline=Vector3.new(4,0,0), lline=Vector3.new(-4,0,0), fline=Vector3.new(0,0,-4), bline=Vector3.new(0,0,4) }
    local function doLine(ctx, base, isLoop)
        local dir = LINE_DIRS[base]; if not dir then return end
        local t = ctx.find(); if not (t and t.Character and t.Character:FindFirstChild("HumanoidRootPart")) then return end
        local off = CFrame.new(dir*ctx.index)
        if isLoop then
            stopAll(); task.wait(0.05); State.cmd="LoopLine"
            task.spawn(function()
                while State.cmd=="LoopLine" and t and t.Character do
                    local tR = t.Character:FindFirstChild("HumanoidRootPart"); local mR = myRoot()
                    if tR and mR then mR.CFrame = tR.CFrame*off; mR.Velocity=Vector3.zero end
                    RunService.Heartbeat:Wait()
                end
            end)
        else
            local tR = t.Character.HumanoidRootPart; local mR = myRoot()
            if mR then mR.CFrame = tR.CFrame*off; mR.Velocity=Vector3.zero end
        end
    end
    for base in pairs(LINE_DIRS) do
        Miked.cmd{ name=base, category="Formations", desc=base.." formation", args="Target", run=function(ctx) doLine(ctx, base, false) end }
        Miked.cmd{ name="loop"..base, category="Formations", desc="loop "..base, args="Target", run=function(ctx) doLine(ctx, base, true) end }
    end

    Miked.cmd{ name="arrow", category="Formations", desc="V-shape", args="Target",
        run=function(ctx)
            local t = ctx.find() or ctx.speaker
            if not (t and t.Character and t.Character:FindFirstChild("HumanoidRootPart")) then return end
            local root = t.Character.HumanoidRootPart; local mR = myRoot(); if not mR then return end
            local idx, total, sp = ctx.index, ctx.total, 4; local fwd = root.CFrame.LookVector
            local head = (total>=8) and 5 or 3
            local function place(o) local p=(root.CFrame*o).Position; mR.CFrame=CFrame.new(p, p+fwd) end
            if idx<=head then
                if idx==1 then place(CFrame.new(0,0,-sp*1.5))
                elseif idx<=3 then place(CFrame.new(((idx==2) and 1 or -1)*sp,0,-sp*0.5))
                else place(CFrame.new(((idx==4) and 2 or -2)*sp,0,sp*0.5)) end
            else place(CFrame.new(0,0,(idx-head)*sp+sp*0.5)) end
        end }

    Miked.cmd{ name="box", aliases={"square"}, category="Formations", desc="Square array", args="Target",
        run=function(ctx)
            local t = ctx.find() or ctx.speaker
            if not (t and t.Character and t.Character:FindFirstChild("HumanoidRootPart")) then return end
            local root = t.Character.HumanoidRootPart; local mR = myRoot(); if not mR then return end
            local idx, sp = ctx.index, 6
            local grid = {{-1,-1},{0,-1},{1,-1},{-1,0},{1,0},{-1,1},{0,1},{1,1}}
            local g = grid[((idx-1)%#grid)+1]; local gx, gz = g[1], g[2]
            if idx > #grid then gx, gz = gx*2, gz*2 end
            local fwd, rgt = root.CFrame.LookVector, root.CFrame.RightVector
            local p = root.CFrame.Position + rgt*(gx*sp) + fwd*(gz*sp)
            mR.CFrame = CFrame.new(p, p+fwd)
        end }

    -- shields 1-5
    local function doShield(ctx, sn)
        local t = ctx.find(); if not (t and t.Character) then return end
        stopAll(); task.wait(0.05); State.cmd="Shield"
        task.spawn(function()
            local idx, total = ctx.index, ctx.total
            while State.cmd=="Shield" and t and t.Character do
                local mR = myRoot(); local tR = t.Character:FindFirstChild("HumanoidRootPart")
                if mR and tR then
                    local h = myHum(); if h and h.Sit then h.Sit=false end
                    local off = CFrame.new(0,0,0)
                    if sn==1 then local tw=(total-1)*4; off=CFrame.new(((idx-1)*4)-(tw/2),0,-6)
                    elseif sn==2 then local a=((idx-1)/math.max(total-1,1))*PI-(PI/2); off=CFrame.new(sin(a)*8,0,-cos(a)*8)
                    elseif sn==3 then local s=(idx%2==0) and 1 or -1; local d=math.floor(idx/2)*3; off=CFrame.new(s*(d*0.8),0,-d-3)
                    elseif sn==4 then local bpr=math.ceil(total/2); local cr=math.floor((idx-1)/bpr); local pr=(idx-1)%bpr; off=CFrame.new((pr*4)-((bpr-1)*4/2),cr*6,-7)
                    elseif sn==5 then local sc=math.ceil(total/4); local si=math.floor((idx-1)/sc); local ps=(idx-1)%sc; local o=(ps-(sc-1)/2)*4; local d=8
                        if si==0 then off=CFrame.new(o,0,-d) elseif si==1 then off=CFrame.new(o,0,d) elseif si==2 then off=CFrame.new(-d,0,o) else off=CFrame.new(d,0,o) end
                    end
                    mR.CFrame = tR.CFrame*off; mR.Velocity=Vector3.zero
                end
                RunService.Heartbeat:Wait()
            end
        end)
    end
    Miked.cmd{ name="shield", category="Formations", desc="Protective wall", args="Target", run=function(ctx) doShield(ctx,1) end }
    for i=1,5 do Miked.cmd{ name="shield"..i, category="Formations", desc="Shield "..i, args="Target", run=function(ctx) doShield(ctx,i) end } end

    -- ══ ORBITS & SPIRALS ════════════════════════════════════════════════
    local function runCurve(ctx, curve, tag)
        local speed, range, t = speedRangeTarget(ctx, 4, 10)
        if not (t and t.Character) then return end
        stopAll(); task.wait(0.05); State.cmd = tag
        local idx, total = ctx.index, ctx.total
        local startT = tick()
        task.spawn(function()
            while State.cmd==tag and t and t.Character do
                local mR = myRoot(); local tR = t.Character:FindFirstChild("HumanoidRootPart")
                if mR and tR then
                    local h = myHum(); if h and h.Sit then h.Sit=false end
                    local pos = curve((tick()-startT)*(speed/4), idx, total, range)
                    mR.CFrame = CFrame.new(tR.Position+pos, tR.Position)
                    mR.Velocity=Vector3.zero; mR.RotVelocity=Vector3.zero
                end
                RunService.Heartbeat:Wait()
            end
        end)
    end

    local Orbit = {}
    Orbit[0]  = function(t,i,n,R) R=math.max(R,n*3); local p=(t/15+(i-1)/n)*PI2; return Vector3.new(sin(p)*R,0,cos(p)*R) end
    Orbit[1]  = function(t,i,n,R) local p=(t/12+(i-1)/n)*PI2; local b=R+sin(t*0.5)*1.5; return Vector3.new(sin(p)*b,0,cos(p)*b) end
    Orbit[2]  = function(t,i,n,R) local s=(i%2==0) and 0 or 1; local p=(t/14+(i-1)/n)*PI2+s*PI; return Vector3.new(sin(p)*R,sin(p*0.5)*(R*0.7),cos(p)*R) end
    Orbit[3]  = function(t,i,n,R) local pl=i%3; local gi=math.floor((i-1)/3); local gt=math.max(math.ceil(n/3),1); local p=(t/16+gi/gt)*PI2
        if pl==0 then return Vector3.new(cos(p)*R,sin(p)*R,0) elseif pl==1 then return Vector3.new(cos(p)*R,0,sin(p)*R) else return Vector3.new(0,cos(p)*R,sin(p)*R) end end
    Orbit[4]  = function(t,i,n,R) local arms=math.min(3,math.ceil(n/3)); local arm=(i-1)%arms; local pia=math.floor((i-1)/arms)
        local d=3+pia*2.5; local p=(arm/arms)*PI2+pia*0.5+t*0.5; return Vector3.new(cos(p)*d,sin(t+i)*1.5,sin(p)*d) end
    Orbit[5]  = function(t,i,n,R) local f=(i-1)/n; local p=(t/14+f)*PI2; local cr=3+f*R; return Vector3.new(cos(p)*cr,f*20-10,sin(p)*cr) end
    Orbit[6]  = function(t,i,n,R) local p=(t/18+(i-1)/n)*PI2; local dn=1+sin(p)*sin(p); return Vector3.new(R*cos(p)/dn,sin(p*2)*3,R*sin(p)*cos(p)/dn) end
    Orbit[7]  = function(t,i,n,R) local p=(t/12+(i-1)/n)*PI2; local b=R+sin(t*2)*(R*0.5); return Vector3.new(cos(p)*b,sin(t*3+i)*2,sin(p)*b) end
    Orbit[8]  = function(t,i,n,R) local rings=math.min(3,math.ceil(n/3)); local rg=(i-1)%rings; local pir=math.floor((i-1)/rings); local bir=math.max(math.ceil(n/rings),1)
        local p=(t/14+pir/bir)*PI2; local tilt=(rg/rings)*PI*0.6; local lx,ly=cos(p)*R,sin(p)*R; return Vector3.new(lx,ly*cos(tilt),ly*sin(tilt)) end
    Orbit[9]  = function(t,i,n,R) local p=(t/20+(i-1)/n)*PI2; local rr=R*abs(cos(3*p)); return Vector3.new(cos(p)*rr,sin(p*2)*3,sin(p)*rr) end
    Orbit[10] = function(t,i,n,R) local s=i*1.1; return Vector3.new(sin(t*1.3+s)*R*cos(t*0.7+s*2),cos(t*0.9+s*1.5)*(R*0.6)*sin(t*1.1+s),sin(t*1.1+s*0.8)*R*cos(t*1.3+s*1.7)) end
    Orbit[11] = function(t,i,n,R) local p=(t/16+(i-1)/n)*PI2; local w=sin(p*3)*1.5; local b=R+sin(t)*0.8; return Vector3.new(sin(p)*b,w,cos(p)*b) end
    Orbit[12] = function(t,i,n,R) local p=(t/20+(i-1)/n)*PI2; return Vector3.new(sin(p)*R,sin(p*2)*(R*0.35),cos(p)*R*cos(p*0.5)) end
    Orbit[13] = function(t,i,n,R) local g=i*PI*(3-sqrt(5)); local p=t/18+g; local th=math.acos(1-2*((i-0.5)/n)); return Vector3.new(sin(th)*cos(p)*R,cos(th)*R,sin(th)*sin(p)*R) end
    Orbit[14] = function(t,i,n,R) local p=(t/15+(i-1)/n)*PI2; return Vector3.new(0,sin(p)*R,cos(p)*R) end
    Orbit[15] = function(t,i,n,R) local p=(t/14+(i-1)/n)*PI2; local yo=((i-1)/n)*12-6; local b=R+sin(t*2+(i-1)/n*PI2)*3; return Vector3.new(sin(p)*b,yo+sin(p*3)*1.5,cos(p)*b) end
    Orbit[16] = function(t,i,n,R) local f=(i-1)/n; local y=f*25-12; local fr=R*(1-f*0.7); local p=(t/12+f*2)*PI2; return Vector3.new(sin(p)*fr,y,cos(p)*fr) end
    Orbit[17] = function(t,i,n,R) local p=(t/15+(i-1)/n)*PI2; local be=1+abs(sin(t*3+i*0.7))*0.4; return Vector3.new(sin(p)*R*be,sin(t*2+i)*2,cos(p)*R*be) end
    Orbit[18] = function(t,i,n,R) local p=(t/18+(i-1)/n)*PI2; return Vector3.new(sin(p)*R*1.5,sin(p*2)*2,cos(p)*R*0.6) end
    Orbit[19] = function(t,i,n,R) local p=(t/20+(i-1)/n)*PI2; local tw=p*0.5; local fl=sin(p)*R; return Vector3.new(cos(p)*R,fl*sin(tw),fl*cos(tw)) end
    Orbit[20] = function(t,i,n,R) local p=(t/16+(i-1)/n)*PI2; local dm=cos(p*0.5); local tr=R*(0.3+abs(dm)*0.7); return Vector3.new(sin(p)*tr,dm*(R*0.5)+sin(t*2+i)*1.5,cos(p)*tr) end

    local Spiral = {}
    Spiral[1]  = function(t,i,n,R) local p=(t/12+(i-1)/n)*PI2; local dR=R+sin(t*0.5)*5; return Vector3.new(cos(p)*dR,sin(t+(i-1)/n*PI2)*6,sin(p)*dR) end
    Spiral[2]  = function(t,i,n,R) local f=(i-1)/n; local p=(t/14+f)*PI2; local hd=f*16; local ht=sin(t+hd)*4+hd; local cr=(ht/16)*R; return Vector3.new(cos(p)*cr,ht,sin(p)*cr) end
    Spiral[3]  = function(t,i,n,R) local s=(i%2==0) and 0 or 1; local pI=math.floor((i-1)/2); local hh=(pI/math.max(math.ceil(n/2),1))*16; local p=(t/14+(i-1)/n)*PI2+s*PI; return Vector3.new(cos(p)*R,hh+sin(t*0.5)*2-8,sin(p)*R) end
    Spiral[4]  = function(t,i,n,R) local f=(i-1)/n; local cy=(t/16*0.3+f*PI2)%PI2; local ph=cy/PI2; local y,cr; if ph<0.6 then y=(ph/0.6)*15; cr=R*0.4 else local ap=(ph-0.6)/0.4; y=15*(1-ap*ap); cr=R*0.4+R*ap end; local p=(t/16+f)*PI2; return Vector3.new(cos(p)*cr,y-5,sin(p)*cr) end
    Spiral[5]  = function(t,i,n,R) local f=(i-1)/n; local h=((t/14*0.5+f*20)%20); local nH=h/20; local tR2=R*(0.3+nH*0.7); local p=(t/14+f)*PI2+nH*PI*4; return Vector3.new(cos(p)*tR2,h-10,sin(p)*tR2) end
    Spiral[6]  = function(t,i,n,R) local g=i*PI*(3-sqrt(5)); local d=sqrt(i)*3; local p=g+t*0.5; return Vector3.new(cos(p)*d,sin(t+i*0.5)*2,sin(p)*d) end
    Spiral[7]  = function(t,i,n,R) local cp=sin(t*1.5)*0.5+0.5; local sp=2+cp*4; local y=(i-(n+1)/2)*sp; local p=(t/10+(i-1)/n)*PI2; return Vector3.new(cos(p)*(R*(0.5+cp*0.5)),y,sin(p)*(R*(0.5+cp*0.5))) end
    Spiral[8]  = function(t,i,n,R) local f=(i-1)/n; local cy=(t/16*0.4+f*PI2)%PI2; local ph=cy/PI2; local wR=R*(1-ph*0.8); local p=(t/16+f)*PI2+ph*PI*4; return Vector3.new(cos(p)*wR,-ph*8+4,sin(p)*wR) end
    Spiral[9]  = function(t,i,n,R) local p=(t/14+(i-1)/n)*PI2; local wR=R+sin(p*3+t)*(R*0.4); return Vector3.new(cos(p)*wR,sin(t+(i-1)/n*PI2)*6,sin(p)*wR) end
    Spiral[10] = function(t,i,n,R) local ly=math.min(4,math.ceil(n/2)); local la=(i-1)%ly; local pil=math.floor((i-1)/ly); local bpl=math.max(math.ceil(n/ly),1); local p=((pil/bpl)*PI2)+t*(1+la*0.3); return Vector3.new(cos(p)*R,(la-(ly-1)/2)*5,sin(p)*R) end
    Spiral[11] = function(t,i,n,R) local p=(t/18+(i-1)/n)*PI2; local st=math.floor(p/(PI/4))*2; return Vector3.new(sin(p)*R,st+sin(p*2)*0.5-8,cos(p)*R) end
    Spiral[12] = function(t,i,n,R) local f=(i-1)/n; local p=(t/20+f)*PI2; local ac=1+f*2; local wR=R*(1-f*0.6); return Vector3.new(sin(p*ac)*wR,f*15-7,cos(p*ac)*wR) end
    Spiral[13] = function(t,i,n,R) local sp=((i-1)/n)*PI2; local wv=sin(t+sp*2)*5+sin(t*1.7+sp)*3; return Vector3.new(sin(sp)*R,wv,cos(sp)*R) end
    Spiral[14] = function(t,i,n,R) local g=i*PI*(3-sqrt(5)); local th=math.acos(1-2*((i-0.5)/n)); local pu=(sin(t*2)+1)*0.5; local d=R*(0.3+pu*0.7); return Vector3.new(sin(th)*cos(g+t*0.3)*d,cos(th)*d,sin(th)*sin(g+t*0.3)*d) end
    Spiral[15] = function(t,i,n,R) local y=((i-1)/n)*20-10; local sw=sin(t+y*0.2)*R*0.8; local dp=cos(t*0.7+y*0.15)*R*0.4; return Vector3.new(sw,y,dp) end
    Spiral[16] = function(t,i,n,R) local f=(i-1)/n; local an=f*PI*6+t*0.4; local d=2+f*R; return Vector3.new(cos(an)*d,sin(t+f*PI2)*2,sin(an)*d) end
    Spiral[17] = function(t,i,n,R) local p=(t/12+(i-1)/n)*PI2; local bo=abs(sin(t*1.5))*8; return Vector3.new(sin(p)*R,((i-1)/n)*bo-bo/2,cos(p)*R) end
    Spiral[18] = function(t,i,n,R) local p=(t/16+(i-1)/n)*PI2; return Vector3.new(sin(p)*R,abs(sin(p*5))*6,cos(p)*R) end
    Spiral[19] = function(t,i,n,R) local hf=math.ceil(n/2); local top=i<=hf; local li=top and i or (i-hf); local lc2=top and hf or (n-hf); local f=(li-1)/math.max(lc2,1); local p=(t/14+f)*PI2; local dir=top and 1 or -1; local wR=R*(1-f*0.5); return Vector3.new(sin(p)*wR,f*12*dir,cos(p)*wR) end
    Spiral[20] = function(t,i,n,R) local p=(t/18+(i-1)/n)*PI2; local ar=sin(p*0.5); local sp=R*(1-abs(ar)*0.5); return Vector3.new(sin(p)*sp,abs(ar)*15-3,cos(p)*sp) end

    Miked.cmd{ name="orbit", category="Orbits", desc="Flat circular orbit", args="[spd] [r] Target", run=function(ctx) runCurve(ctx, Orbit[0], "Orbit") end }
    for i=1,20 do Miked.cmd{ name="orbit"..i, category="Orbits", desc="Orbit pattern "..i, args="[spd] [r] Target", run=function(ctx) runCurve(ctx, Orbit[i], "Orbit") end } end
    Miked.cmd{ name="spiral", category="Spirals", desc="Upward helix", args="[spd] [r] Target", run=function(ctx) runCurve(ctx, Spiral[1], "Spiral") end }
    for i=1,20 do Miked.cmd{ name="spiral"..i, category="Spirals", desc="Spiral pattern "..i, args="[spd] [r] Target", run=function(ctx) runCurve(ctx, Spiral[i], "Spiral") end } end

    -- ══ ACTION ══════════════════════════════════════════════════════════
    Miked.cmd{ name="helicopter", aliases={"heli"}, category="Action", desc="Overhead rotor mount", args="[spd] Target",
        run=function(ctx)
            local speed, t = speedTarget(ctx, 18)
            if not (t and t.Character) then return end
            stopAll(); task.wait(0.05); State.cmd="Helicopter"
            task.spawn(function()
                local myOff = ((ctx.index-1)/ctx.total)*PI2
                while State.cmd=="Helicopter" and t and t.Character do
                    local mR = myRoot(); local tHead = t.Character:FindFirstChild("Head")
                    if mR and tHead then
                        local h = myHum(); if h and h.Sit then h.Sit=false end
                        local ang = myOff + tick()*speed
                        local op = tHead.Position + Vector3.new(cos(ang)*6,0,sin(ang)*6)
                        mR.CFrame = CFrame.new(op, tHead.Position) * CFrame.Angles(math.rad(90),0,0)
                        mR.Velocity=Vector3.zero; mR.RotVelocity=Vector3.zero
                    end
                    RunService.Heartbeat:Wait()
                end
            end)
        end }

    Miked.cmd{ name="spin", category="Action", desc="Axial spin", args="[Speed]",
        run=function(ctx)
            local sp = tonumber(ctx.args[2]) or 20
            stopAll(); task.wait(0.05); State.cmd="Spin"
            task.spawn(function()
                local rot=0; local h=myHum(); if h then h.AutoRotate=false end
                while State.cmd=="Spin" do
                    local r=myRoot()
                    if r then rot+=sp; r.CFrame=CFrame.new(r.Position)*CFrame.Angles(0,math.rad(rot),0); r.Velocity=Vector3.zero; r.RotVelocity=Vector3.zero end
                    RunService.Heartbeat:Wait()
                end
                local hh=myHum(); if hh then hh.AutoRotate=true end
            end)
        end }

    Miked.cmd{ name="firework", category="Action", desc="Launch skyward", solo=true,
        run=function(ctx)
            stopAll()
            local r, h = myRoot(), myHum(); if not (r and h) then return end
            if h.Sit then h.Sit=false end
            task.spawn(function()
                local bv=Instance.new("BodyVelocity"); bv.MaxForce=Vector3.new(1e6,1e6,1e6); bv.Velocity=Vector3.new(0,75,0); bv.Parent=r
                local ba=Instance.new("BodyAngularVelocity"); ba.MaxTorque=Vector3.new(1e6,1e6,1e6); ba.AngularVelocity=Vector3.new(0,60,0); ba.Parent=r
                task.wait(2.5); bv:Destroy(); ba:Destroy()
                r.Velocity=Vector3.new(Random.new():NextNumber(-50,50),Random.new():NextNumber(80,120),Random.new():NextNumber(-50,50))
                local c=LP.Character; if c then c:BreakJoints() end
            end)
        end }

    Miked.cmd{ name="nuke", category="Action", desc="Orbital drop on target", args="Target",
        run=function(ctx)
            stopAll(); local t = ctx.find()
            local r, h = myRoot(), myHum()
            if not (t and t.Character and r and h) then return end
            local tR = t.Character:FindFirstChild("HumanoidRootPart"); if not tR then return end
            r.CFrame = tR.CFrame*CFrame.new(0, 15+ctx.index*2, 0)
            if h.Sit then h.Sit=false end; h:MoveTo(r.Position)
            task.spawn(function()
                local ba=Instance.new("BodyAngularVelocity"); ba.MaxTorque=Vector3.new(1e6,1e6,1e6); ba.AngularVelocity=Vector3.new(0,150,0); ba.Parent=r; task.wait(0.6); ba:Destroy()
                r.Velocity=Vector3.new(Random.new():NextNumber(-60,60),Random.new():NextNumber(-30,-10),Random.new():NextNumber(-60,60))
                local c=LP.Character; if c then c:BreakJoints() end
            end)
        end }

    Miked.cmd{ name="vfling", aliases={"kill"}, category="Action", desc="Velocity fling", args="Target",
        run=function(ctx)
            stopAll(); local t = ctx.find()
            if not (t and t.Character) then return end
            local tR = t.Character:FindFirstChild("HumanoidRootPart"); if not tR then return end
            State.cmd="Fling"
            task.spawn(function()
                local mR, h = myRoot(), myHum()
                if mR and h then
                    h.Sit=false
                    local conn; conn = RunService.Heartbeat:Connect(function()
                        if State.cmd~="Fling" or not tR.Parent then conn:Disconnect(); if mR.Parent then mR.Velocity=Vector3.zero; mR.RotVelocity=Vector3.zero end return end
                        mR.RotVelocity=Vector3.new(150000,150000,150000)
                        local j=Vector3.new(math.random(-10,10)/100,math.random(-10,10)/100,math.random(-10,10)/100)
                        mR.CFrame=tR.CFrame*CFrame.new(j)+(tR.Velocity*0.15); mR.Velocity=Vector3.new(500,500,500)
                    end)
                    table.insert(Miked.Conns, conn)
                    task.delay(10, function() if State.cmd=="Fling" then State.cmd="None" end end)
                end
            end)
        end }

    local function bangLoop(ctx, tag, useHead)
        local spd, t = speedTarget(ctx, 1)
        if not (t and t.Character) then return end
        local anchor = useHead and t.Character:FindFirstChild("Head") or t.Character:FindFirstChild("HumanoidRootPart")
        if not anchor then return end
        stopAll(); task.wait(0.05); State.cmd=tag
        if useHead then local mh=myHum(); if mh then mh.AutoRotate=false end end
        task.spawn(function()
            local step, inc = 0, true; local si = 0.45*spd
            while State.cmd==tag and t and t.Character and anchor.Parent do
                local mR = myRoot(); local h = myHum()
                if mR then
                    if h and h.Sit then h.Sit=false end
                    if inc then step+=si; if step>=1 then inc=false end else step-=si; if step<=0 then inc=true end end
                    if useHead then
                        local zOff=0.5+step*1.5; local isR15=LP.Character:FindFirstChild("LowerTorso")~=nil; local yO=isR15 and 0.75 or 0
                        local fp = anchor.CFrame.Position + anchor.CFrame.LookVector*zOff
                        mR.CFrame = CFrame.new(Vector3.new(fp.X,anchor.Position.Y+yO,fp.Z), Vector3.new(anchor.Position.X,anchor.Position.Y+yO,anchor.Position.Z))
                    else
                        mR.CFrame = anchor.CFrame*CFrame.new(0,0,0.8+step*1.2)
                    end
                    mR.Velocity=Vector3.zero; mR.RotVelocity=Vector3.zero
                end
                RunService.Heartbeat:Wait()
            end
            if useHead then local hh=myHum(); if hh then hh.AutoRotate=true end end
        end)
    end
    Miked.cmd{ name="bang", category="Action", desc="Rear engage", args="[bot] [spd] Target", botTarget=true, run=function(ctx) bangLoop(ctx,"Bang",false) end }
    Miked.cmd{ name="fbang", category="Action", desc="Frontal engage", args="[bot] [spd] Target", botTarget=true, run=function(ctx) bangLoop(ctx,"FaceBang",true) end }

    -- mirror suite
    local MIRROR = { mirror={0,0,0}, rmirror={5,0,0}, lmirror={-5,0,0}, fmirror={0,0,-5}, bmirror={0,0,5} }
    for name, o in pairs(MIRROR) do
        Miked.cmd{ name=name, category="Action", desc="Mirror target", args="Target",
            run=function(ctx)
                local t = ctx.find(); if not (t and t.Character) then return end
                stopAll(); task.wait(0.05); local tag=name:upper(); State.cmd=tag
                task.spawn(function()
                    local conn; conn = RunService.Heartbeat:Connect(function()
                        if State.cmd~=tag or not t.Character then conn:Disconnect() return end
                        local mR = myRoot(); local tR = t.Character:FindFirstChild("HumanoidRootPart")
                        if mR and tR then
                            mR.CFrame = tR.CFrame*CFrame.new(o[1],o[2],o[3])
                            local mH, tH = myHum(), t.Character:FindFirstChildOfClass("Humanoid")
                            if mH and tH then mH.Jump=tH.Jump; if tH.Sit~=mH.Sit then mH.Sit=tH.Sit end end
                            mR.Velocity=Vector3.zero; mR.RotVelocity=Vector3.zero
                        end
                    end)
                    table.insert(Miked.Conns, conn)
                end)
            end }
    end

    Miked.cmd{ name="rest", category="Action", desc="Ragdoll reset", solo=true,
        run=function(ctx) local c = LP.Character; if c then c:BreakJoints() end end }

    -- ══ CHARACTER / SYSTEM (basics) ═════════════════════════════════════
    Miked.cmd{ name="stop", aliases={"unall","unf"}, category="System", desc="Halt all movement", run=function() stopAll() end }

    Miked.cmd{ name="ws", aliases={"speed"}, category="Character", desc="Set walkspeed", args="Speed",
        run=function(ctx)
            local spd = tonumber(ctx.args[2]); if not spd then State.speedLock=nil; local h=myHum(); if h then h.WalkSpeed=16 end return end
            local h = myHum()
            if h then
                if h.Sit then h.Sit=false end
                h.WalkSpeed=spd; State.speedLock=spd
                task.spawn(function()
                    local lv=spd
                    while State.speedLock==lv do local hh=myHum(); if hh and hh.WalkSpeed~=lv then hh.WalkSpeed=lv end; task.wait(0.5) end
                end)
            end
        end }
    Miked.cmd{ name="unws", aliases={"unspeed"}, category="Character", desc="Reset walkspeed", run=function() State.speedLock=nil; local h=myHum(); if h then h.WalkSpeed=16 end end }

    Miked.cmd{ name="noclip", category="Character", desc="Disable collisions", solo=true,
        run=function()
            if State.noclip then return end
            State.noclip=true; State.noclipOrig={}
            local c=LP.Character; if c then for _,p in ipairs(c:GetDescendants()) do if p:IsA("BasePart") then State.noclipOrig[p]=p.CanCollide end end end
            State.noclipConn = RunService.Stepped:Connect(function()
                if not State.noclip then return end
                local ch=LP.Character; if ch then for _,p in ipairs(ch:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide=false end end end
            end)
            table.insert(Miked.Conns, State.noclipConn)
        end }
    Miked.cmd{ name="clip", category="Character", desc="Restore collisions", solo=true,
        run=function()
            State.noclip=false
            if State.noclipConn then pcall(function() State.noclipConn:Disconnect() end); State.noclipConn=nil end
            for p,o in pairs(State.noclipOrig or {}) do if p and p.Parent then pcall(function() p.CanCollide=o end) end end
            State.noclipOrig={}
        end }

    Miked.cmd{ name="freeze", category="Character", desc="Anchor in place", solo=true, run=function() local r=myRoot(); if r then r.Anchored=true end end }
    Miked.cmd{ name="unfreeze", category="Character", desc="Unanchor", solo=true, run=function() local r=myRoot(); if r then r.Anchored=false end end }

    Miked.cmd{ name="antivoid", category="System", desc="Void-death platform", solo=true,
        run=function()
            if State.antivoid then return end
            State.antivoid=true
            local part=Instance.new("Part"); part.Name="MikedAntiVoid"; part.Size=Vector3.new(2048,1,2048)
            part.Transparency=1; part.Anchored=true; part.CanCollide=true; part.Parent=workspace; State.avPart=part
            task.spawn(function()
                while State.antivoid do
                    local r=myRoot(); if r and State.avPart then State.avPart.CFrame=CFrame.new(r.Position.X,0,r.Position.Z) end
                    RunService.Heartbeat:Wait()
                end
                if State.avPart then pcall(function() State.avPart:Destroy() end); State.avPart=nil end
            end)
        end }
    Miked.cmd{ name="unantivoid", category="System", desc="Remove void platform", solo=true,
        run=function() State.antivoid=false; if State.avPart then pcall(function() State.avPart:Destroy() end); State.avPart=nil end end }

    -- ══ CHAT (basics) ═══════════════════════════════════════════════════
    Miked.cmd{ name="say", aliases={"chat"}, category="Chat", desc="Broadcast message", args="Message",
        run=function(ctx) local m = table.concat(ctx.args," ",2); if m~="" then ctx.reply(m, {stagger=0.15}) end end }

    Miked.cmd{ name="spam", category="Chat", desc="Loop a message", args="[dly] Msg",
        run=function(ctx)
            State.spamming=false; task.wait(0.1)
            local dly = tonumber(ctx.args[2]); local delay = dly or 1.0
            local msg = dly and table.concat(ctx.args," ",3) or table.concat(ctx.args," ",2)
            if msg~="" then
                State.spamming=true; local id=tick(); State.spamId=id
                task.spawn(function() while State.spamming and State.spamId==id do ChatSend(msg); task.wait(delay) end end)
            end
        end }
    Miked.cmd{ name="unspam", category="Chat", desc="Stop spamming", solo=true, run=function() State.spamming=false; State.spamId=nil end }
end

-- ══ COMMANDS (batch 2) ══════════════════════════════════════════════════
-- Emotes, troll set, social/chat, info, system, and the gated Mic Up module.
do
    local RunService   = game:GetService("RunService")
    local HttpService  = game:GetService("HttpService")
    local Teleport     = game:GetService("TeleportService")
    local Stats        = game:GetService("Stats")
    local CoreGui      = game:GetService("CoreGui")
    local StarterGui   = game:GetService("StarterGui")
    local VIM          = game:GetService("VirtualInputManager")
    local RS           = game:GetService("ReplicatedStorage")
    local State        = Miked.State
    local ChatSend     = Miked.chat

    local function myRoot() local c = LP.Character; return c and c:FindFirstChild("HumanoidRootPart") end
    local function myHum()  local c = LP.Character; return c and c:FindFirstChildOfClass("Humanoid") end

    -- ══ EMOTES ══════════════════════════════════════════════════════════
    -- catalog (id list) loads from your repo when Config.emoteCatalogUrl is set
    if not Miked.Cache.emotes then
        Miked.Cache.emotes = {}
        if Config.emoteCatalogUrl then
            task.spawn(function()
                pcall(function()
                    local data = HttpService:JSONDecode(game:HttpGet(Config.emoteCatalogUrl))
                    Miked.Cache.emotes = data.data or data
                end)
            end)
        end
    end

    for _, n in ipairs({"dance1","dance2","dance3"}) do
        Miked.cmd{ name=n, aliases=(n=="dance1" and {"dance","d"} or nil), category="Emotes", desc="Play "..n, solo=true,
            run=function()
                Miked.stopAll()
                local h = myHum(); if h then if h.Sit then h.Sit=false; task.wait(0.1) end
                    ChatSend("/e " .. (n=="dance1" and "dance" or n)) end
            end }
    end

    for i=1,8 do
        Miked.cmd{ name="emote"..i, category="Emotes", desc="Emote "..i, solo=true,
            run=function()
                Miked.stopAll()
                local h, r = myHum(), myRoot()
                if h and r then
                    h.Sit=false; h:MoveTo(r.Position); r.Velocity=Vector3.zero; r.RotVelocity=Vector3.zero
                    h.AutoRotate=false; r.Anchored=true; task.wait(0.2); r.Anchored=false
                    ChatSend("/e emote"..i)
                    task.spawn(function() task.wait(0.5); local hh=myHum(); if hh then hh.AutoRotate=true end end)
                end
            end }
    end

    for _, e in ipairs({"laugh","point","cheer","wave"}) do
        Miked.cmd{ name=e, category="Emotes", desc=e, solo=true, run=function() ChatSend("/e "..e) end }
    end

    local function findEmoteId(query)
        query = query:lower()
        local id
        for _, e in ipairs(Miked.Cache.emotes or {}) do
            local nm = tostring(e.name or ""):lower()
            if nm:find(query, 1, true) then id = tonumber(e.id); if nm==query then break end end
        end
        return id
    end

    local function playEmote(ctx, looped)
        local q = table.concat(ctx.args, " ", 2):lower()
        if q == "" then return end
        local id = findEmoteId(q); if not id then return end
        State.emote = id
        local hum = ctx.hum(); if not hum then return end
        local anim = hum:FindFirstChildOfClass("Animator"); if not anim then return end
        if State.emoteTrack then pcall(function() State.emoteTrack:Stop(0) end); State.emoteTrack=nil end
        local ok, track = pcall(function() return hum:PlayEmoteAndGetAnimTrackById(id) end)
        if ok and track and typeof(track)=="Instance" then
            State.emoteTrack = track; track.Priority = Enum.AnimationPriority.Action; track:Play()
        else
            local obj = Instance.new("Animation"); obj.AnimationId = "rbxassetid://"..id
            local ok2, tr = pcall(function() return anim:LoadAnimation(obj) end)
            if ok2 and tr then State.emoteTrack=tr; tr.Priority=Enum.AnimationPriority.Action; tr.Looped=true; tr:Play() end
        end
    end

    Miked.cmd{ name="emote", category="Emotes", desc="Play catalog emote", args="Name", botTarget=true, run=function(ctx) playEmote(ctx, true) end }
    Miked.cmd{ name="sync",  category="Emotes", desc="Server-synced emote", args="Name", botTarget=true,
        run=function(ctx)
            playEmote(ctx, true)
            local tr = State.emoteTrack
            if tr then task.spawn(function()
                local w=0; while tr.Length==0 and w<40 do task.wait(0.05); w+=1 end
                if tr.Length>0 then pcall(function() tr.TimePosition = math.fmod(workspace:GetServerTimeNow(), tr.Length) end) end
            end) end
        end }
    Miked.cmd{ name="unemote", category="Emotes", desc="Stop emote", botTarget=true,
        run=function() State.emote=nil; if State.emoteTrack then pcall(function() State.emoteTrack:Stop(0) end); State.emoteTrack=nil end end }

    Miked.cmd{ name="jump", category="Emotes", desc="Hop", botTarget=true, run=function(ctx) local h=ctx.hum(); if h then h.Jump=true end end }
    Miked.cmd{ name="sit",  category="Emotes", desc="Sit", solo=true, run=function(ctx) local h=ctx.hum(); if h then h.Sit=true end end }

    -- invisible (emote-based)
    local INVIS_ID = 92018855869257
    Miked.cmd{ name="invisible", aliases={"invis","hide"}, category="Character", desc="Go invisible", solo=true,
        run=function(ctx)
            local h = ctx.hum(); if not h then return end
            State.invis = true
            pcall(function() h:PlayEmoteAndGetAnimTrackById(INVIS_ID) end)
        end }
    Miked.cmd{ name="visible", aliases={"vis","show"}, category="Character", desc="Become visible", solo=true,
        run=function() State.invis=false; if State.invisTrack then pcall(function() State.invisTrack:Stop() end); State.invisTrack=nil end end }

    -- ══ TROLL ═══════════════════════════════════════════════════════════
    local HS_MSG = {
        [1]="(့、fเɹჺkɐԀყჿเɹꞅıาาჿıาาꞅลพ、 (့)`",[2]="(့、ჺlาเɹဌรɐıาาɐıาลıาԀรพลıาԀịνɐჿffลfเɹჺkịıาဌlวꞅịԀဌɐ、 (့)`",
        [3]="(့、ị'ƖƖνịჿƖลϯɐყჿเɹꞅlวƖჿჿԀƖịıาɐ,ყჿเɹჺเɹıาϯ、 (့)`",[4]="(့、ჺลıาพɐԀჿlวჿჿıาาlวลყลlา、 (့)`",
        [5]="(့、ꞅลıาาลԀịƖԀჿเɹꞁวყჿเɹꞅꞅɐჺϯเɹıาา、 (့)`",[6]="(့、ყჿเɹꞅıาาჿıาารɋเɹịꞅϯɐԀჿıาıาาɐ、 (့)`",
        [7]="(့、รพลƖƖჿพlวƖɐลჺlาჺเɹıาϯ、 (့)`",[8]="(့、รkเɹƖƖfเɹჺkჺჿꞅꞁวรɐ、 (့)`",
        [9]="(့、ჺเɹıาาꞅลဌlวลlวყlวịϯჺlา、 (့)`",[10]="(့、ဌƖลรรịıาลรรჺเɹıาϯ、 (့)`",
        [11]="(့、ƖịჺklวลƖƖรϯlาɐıาԀịɐ、 (့)`",[12]="(့、ịƖƖꞅลꞁวɐყჿเɹꞅfลıาาịƖყ、 (့)`",
        [13]="(့、ɐลϯลรรลıาԀlาลıาဌϯพịჺɐ、 (့)`",[14]="(့、รlาჿνɐลჺลჺϯเɹรเɹꞁวყჿเɹꞅลรรჺเɹıาϯ、 (့)`",
        [15]="(့、Ԁꞅịıาkꞁวịรรϯlาɐıาɉเɹıาาꞁวịıาϯꞅลffịჺlวịϯჺlา、 (့)`",[16]="(့、ჺเɹꞅlวรϯჿıาาꞁวყჿเɹꞅพlาჿƖɐfเɹჺkịıาဌfลıาาịƖყ、 (့)`",
        [17]="(့、ყჿเɹჺเɹıาาꞅลဌϯพลϯ,ყჿเɹɉเɹรϯıาาลkɐıาาყfลჺɐıาาɐıาาɐ、 (့)`",[18]="(့、ϯꞅลıาıาყჺเɹıาϯlวịϯჺlา、 (့)`",
        [19]="(့、ჺเɹıาาဌเɹʑʑƖịıาဌfลဌ、 (့)`",[20]="(့、ลịԀรɋเɹɐɐꞅϯꞅลรlา、 (့)`",
    }
    local HS_EMOTE = { "/e point","/e point","/e point","/e wave","/e point","/e point","/e shrug","/e point","/e laugh","/e point",
                       "/e point","/e laugh","/e wave","/e point","/e shrug","/e wave","/e point","/e point","/e shrug","/e laugh" }

    local function doHS(ctx, num)
        local t = ctx.find(); if not (t and t.Character) then return end
        local tR = t.Character:FindFirstChild("HumanoidRootPart"); if not tR then return end
        Miked.stopAll(); task.wait(0.05); State.cmd="HS"
        task.spawn(function()
            local idx, total = ctx.index, ctx.total
            local mR = myRoot(); if not mR then return end
            local origCF = mR.CFrame
            local ang = ((idx-1)/total)*(math.pi*2); local R = math.max(6, total*1.2)
            mR.CFrame = CFrame.new(tR.Position + Vector3.new(math.cos(ang)*R,0,math.sin(ang)*R), tR.Position); mR.Velocity=Vector3.zero
            task.wait(0.3)
            ChatSend(HS_EMOTE[num] or "/e point")
            local holdEnd = tick()+20
            local lastChat = 0
            while State.cmd=="HS" and tick()<holdEnd do
                local m2, t2 = myRoot(), t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                if m2 and t2 then local a=((idx-1)/total)*(math.pi*2); m2.CFrame=CFrame.new(t2.Position+Vector3.new(math.cos(a)*R,0,math.sin(a)*R), t2.Position); m2.Velocity=Vector3.zero end
                if tick()-lastChat > 3 then ChatSend(HS_MSG[num] or HS_MSG[1]); lastChat = tick() end   -- spam the line
                RunService.Heartbeat:Wait()
            end
            local cur = myRoot(); if cur then cur.CFrame = origCF end
        end)
    end
    Miked.cmd{ name="hs", category="Action", desc="Harass strike", args="Target", run=function(ctx) doHS(ctx,1) end }
    for i=1,20 do Miked.cmd{ name="hs"..i, category="Action", desc="Strike "..i, args="Target", run=function(ctx) doHS(ctx,i) end } end

    local RIZZ = {
        "I don't usually get distracted, but you made me forget what I was saying.",
        "You've got that calm energy that makes everything feel easier.",
        "There's something about you that feels different — in a good way.",
        "I can tell you're not just pretty, you've got depth.",
        "You seem like the kind of person people feel safe around.",
        "You've got that quiet confidence that's hard to ignore.",
        "Talking to you feels way too easy… and I don't mind that at all.",
        "You don't even have to try. That's what makes it dangerous.",
        "If energy is real, yours is undefeated.",
        "I'm not even trying to impress you… I just like talking to you.",
    }
    Miked.cmd{ name="rizz", category="Action", desc="Sequential approach", args="Target",
        run=function(ctx)
            local t = ctx.find(); if not (t and t.Character) then return end
            Miked.stopAll(); task.wait(0.05); State.cmd="Rizz"
            task.spawn(function()
                local idx, total = ctx.index, ctx.total
                local mR, mH = myRoot(), myHum()
                local tR = t.Character:FindFirstChild("HumanoidRootPart")
                if not (mR and mH and tR) then return end
                mH:MoveTo((tR.CFrame*CFrame.new(0,0,-(15+idx*4))).Position)
                task.wait((idx-1)*7)
                if State.cmd~="Rizz" then return end
                local tR2 = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                if tR2 then mH:MoveTo((tR2.CFrame*CFrame.new(0,0,-3)).Position) end
                task.wait(2.2)
                local tR3 = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                if tR3 then mR.CFrame = CFrame.new(mR.Position, Vector3.new(tR3.Position.X, mR.Position.Y, tR3.Position.Z)) end
                ChatSend(RIZZ[((idx-1)%#RIZZ)+1]); task.wait(4)
                while State.cmd=="Rizz" and t and t.Character do
                    local lR = t.Character:FindFirstChild("HumanoidRootPart")
                    if lR then local sp=(idx/total)*(math.pi*2); mR.CFrame=CFrame.new(lR.Position+Vector3.new(math.cos(sp)*8,0,math.sin(sp)*8), lR.Position); mR.Velocity=Vector3.zero end
                    RunService.Heartbeat:Wait()
                end
            end)
        end }

    -- ══ SOCIAL / CHAT ═══════════════════════════════════════════════════
    Miked.cmd{ name="mimic", category="Chat", desc="Parrot target's chat", args="Target", botTarget=true,
        run=function(ctx)
            local t = ctx.find(); if not t then return end
            if State.mimicConn then pcall(function() State.mimicConn:Disconnect() end) end
            local prefix = Config.prefix or "!"
            State.mimicConn = t.Chatted:Connect(function(msg)
                if msg:sub(1,#prefix) == prefix then return end
                ctx.reply(msg, { stagger = 0.15 })
            end)
            table.insert(Miked.Conns, State.mimicConn)
        end }
    Miked.cmd{ name="unmimic", category="Chat", desc="Stop mimicking", solo=true,
        run=function() if State.mimicConn then pcall(function() State.mimicConn:Disconnect() end); State.mimicConn=nil end end }

    Miked.cmd{ name="countdown", aliases={"cd"}, category="Chat", desc="Staggered countdown", args="Number",
        run=function(ctx)
            local count = tonumber(ctx.args[2]); if not count then return end
            count = math.clamp(count,1,30); local total, idx = ctx.total, ctx.index
            task.spawn(function()
                for i=count,1,-1 do if (((i-1)%total)+1)==idx then ChatSend(tostring(i).."...") end; task.wait(1) end
                if idx==1 then ChatSend("GO!") end
            end)
        end }

    Miked.cmd{ name="credits", category="System", desc="Show credits", solo=true,
        run=function(ctx) ctx.reply("Miked ALT Control", { stagger = 0.5 }) end }

    local NPC_LINES = {
        "My trust issues have trust issues.","I don't fall in love. I trip into mild attachment.",
        "I'm not a red flag. I'm a limited-edition warning label.","Love is temporary. Taxes are forever.",
        "I'm not emotionally unavailable. I'm emotionally buffering.","I'm not toxic. I just come with extended lore.",
        "I bring two things to the table: trust issues and snacks.","I'm not lost. I'm on an unplanned adventure.",
        "My vibe? Controlled chaos with a splash of overthinking.",
    }
    Miked.cmd{ name="npc", category="Chat", desc="Wander + one-liners", solo=true,
        run=function(ctx)
            Miked.stopAll(); State.cmd="NPC"; local idx = ctx.index
            State.npcLine = State.npcLine or 0
            task.spawn(function()
                while State.cmd=="NPC" do
                    local h, r = myHum(), myRoot()
                    if h and r then
                        if h.Sit then h.Sit=false end
                        local wEnd = tick()+math.random(20,40)
                        while State.cmd=="NPC" and tick()<wEnd do
                            local rng=Random.new(tick()+idx)
                            h:MoveTo(r.Position+Vector3.new(rng:NextNumber(-30,30),0,rng:NextNumber(-30,30)))
                            local done,el=false,0; local cn=h.MoveToFinished:Connect(function() done=true end)
                            repeat task.wait(0.1); el+=0.1 until done or State.cmd~="NPC" or el>10
                            cn:Disconnect(); task.wait(math.random(2,5))
                        end
                        if State.cmd=="NPC" then State.npcLine=(State.npcLine%#NPC_LINES)+1; ChatSend(NPC_LINES[State.npcLine]) end
                    else task.wait(1) end
                end
            end)
        end }

    -- UI-automation helpers (English-text dependent — fragile on localized clients)
    local function simClick(el)
        if not el then return end
        pcall(function()
            local inset = game:GetService("GuiService"):GetGuiInset()
            local pos, size = el.AbsolutePosition, el.AbsoluteSize
            VIM:SendMouseButtonEvent(pos.X+size.X/2, pos.Y+size.Y/2+inset.Y, 0, true, game, 1)
            task.wait(0.05)
            VIM:SendMouseButtonEvent(pos.X+size.X/2, pos.Y+size.Y/2+inset.Y, 0, false, game, 1)
        end)
    end
    local function findGui(text, exact)
        for _, v in ipairs(CoreGui:GetDescendants()) do
            local ok, res = pcall(function()
                if v:IsA("TextLabel") or v:IsA("TextButton") then
                    local t=""; pcall(function() t=v.Text end)
                    if (exact and t==text) or (not exact and t:find(text,1,true)) then
                        local tgt=v
                        if not tgt:IsA("GuiButton") then local p=tgt.Parent
                            for _=1,6 do if not p or p==CoreGui then break end; if p:IsA("GuiButton") then tgt=p break end; p=p.Parent end end
                        return tgt
                    end
                end
            end)
            if ok and res then return res end
        end
    end
    local function clickText(text, exact) local el=findGui(text,exact); if el then simClick(el) end; return el~=nil end

    Miked.cmd{ name="friend", category="Chat", desc="Send friend request", args="Target", botTarget=true,
        run=function(ctx)
            local t = ctx.find(); if not t then return end
            task.spawn(function()
                task.wait((ctx.index-1)*Random.new():NextNumber(3,6))
                pcall(function() StarterGui:SetCore("PromptSendFriendRequest", t) end)
                task.wait(1.5); clickText("Send Request", true)
            end)
        end }
    Miked.cmd{ name="block", category="Chat", desc="Block target", args="Target", botTarget=true,
        run=function(ctx)
            local t = ctx.find(); if not t then return end
            task.spawn(function()
                task.wait((ctx.index-1)*Random.new():NextNumber(3,6))
                if not clickText(t.DisplayName, true) then clickText(t.Name, true) end
                task.wait(1); clickText("Block", true); task.wait(1.5); clickText("Block", true)
            end)
        end }
    Miked.cmd{ name="report", category="Chat", desc="Report target", args="Target Reason", botTarget=true,
        run=function(ctx)
            local t = ctx.find(); local reasonQ = ctx.args[3]
            if not t or not reasonQ then return end
            local reasons = {"Swearing","Personal information","Dating/Sex","Cheating","Username","Bullying","Scamming"}
            local reason; local ql=reasonQ:lower()
            for _,r in ipairs(reasons) do if r:lower():sub(1,#ql)==ql then reason=r break end end
            if not reason then return end
            task.spawn(function()
                task.wait((ctx.index-1)*Random.new():NextNumber(5,10))
                if not clickText(t.DisplayName, true) then clickText(t.Name, true) end
                task.wait(0.8); clickText("Report Abuse", true); task.wait(2)
                clickText("Choose One", true); task.wait(1)
                clickText(reason, true); task.wait(1); clickText("Submit", true)
            end)
        end }

    -- ══ INFO ════════════════════════════════════════════════════════════
    Miked.cmd{ name="ping", aliases={"latency","net"}, category="Info", desc="Report ping", solo=true,
        run=function(ctx) ctx.reply("["..LP.Name.."] Ping: "..math.round(LP:GetNetworkPing()*1000).."ms", {stagger=0.3}) end }
    Miked.cmd{ name="ram", aliases={"memory"}, category="Info", desc="Report memory", solo=true,
        run=function(ctx) ctx.reply("["..LP.Name.."] RAM: "..math.floor(Stats:GetTotalMemoryUsageMb()).." MB", {stagger=0.7}) end }
    Miked.cmd{ name="uptime", category="Info", desc="Session uptime", solo=true,
        run=function(ctx)
            if ctx.index~=1 then return end
            local s = tick()-(State.startTime or tick())
            ChatSend(("Uptime: %dh %dm %ds"):format(math.floor(s/3600), math.floor((s%3600)/60), math.floor(s%60)))
        end }
    Miked.cmd{ name="altcount", aliases={"alts"}, category="Info", desc="Count online alts", solo=true,
        run=function(ctx) if ctx.index==1 then ChatSend("Alts Online: "..ctx.total) end end }

    -- ══ SYSTEM ══════════════════════════════════════════════════════════
    Miked.cmd{ name="whitelist", category="System", desc="Grant command rights", args="Target",
        run=function(ctx) local t=ctx.find(); if t then Miked.Cache.commanderSet[lc(t.Name)]=true; if ctx.index==1 then ChatSend("Whitelisted "..t.Name) end end end }
    Miked.cmd{ name="blacklist", category="System", desc="Revoke command rights", args="Target",
        run=function(ctx) local t=ctx.find(); if t and lc(t.Name)~=lc(Config.mainAccount or "") then Miked.Cache.commanderSet[lc(t.Name)]=nil; if ctx.index==1 then ChatSend("Blacklisted "..t.Name) end end end }

    Miked.cmd{ name="rejoin", aliases={"rj","re"}, category="System", desc="Rejoin server", solo=true,
        run=function()
            if Miked.savePos then Miked.savePos() end
            local qot = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
            if qot and Config.loaderUrl then
                qot('task.wait(3); pcall(function() loadstring(game:HttpGet("'..Config.loaderUrl..'"))() end)')
            end
            pcall(function() Teleport:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP) end)
        end }
    Miked.cmd{ name="quit", aliases={"exit","leave"}, category="System", desc="Leave game", solo=true,
        run=function() Miked.stopAll(); task.delay(1, function() LP:Kick("Miked: Quit") end) end }

    Miked.cmd{ name="scanall", category="System", desc="Breach scan players", solo=true,
        run=function(ctx)
            if ctx.index~=1 or State.scanning then return end
            State.scanning=true
            task.spawn(function()
                pcall(function()
                    ChatSend("Scan started..."); local found={}
                    for _,p in ipairs(Players:GetPlayers()) do
                        if p~=LP and lc(p.Name)~=lc(Config.mainAccount or "") then
                            local ok,data = pcall(function() return HttpService:JSONDecode(game:HttpGet("https://leakcheck.io/api/public?check="..HttpService:UrlEncode(p.Name))) end)
                            if ok and data and data.success and data.found and data.found>0 then found[#found+1]=p.Name end
                            task.wait(0.8)
                        end
                    end
                    ChatSend("Scan done. Breached: "..#found)
                    if #found>0 then task.wait(1); ChatSend("Found: "..table.concat(found,", ")) end
                end)
                State.scanning=false
            end)
        end }

    -- ══ MIC UP MODULE (situational — only registers on that PlaceId) ═════
    do
        local place = "micup"
        local cloneRS   = RS:FindFirstChild("GrabStatus")
        local cloneEv   = RS:FindFirstChild("event_clone_avatar")
        local refreshEv = RS:FindFirstChild("event_modify_refresh")
        local grabEv    = RS:FindFirstChild("GrabRequest")
        local pvpEv     = RS:FindFirstChild("event_option_pvp")
        local genEv     = RS:FindFirstChild("event_generation")

        Miked.cmd{ name="clone", category="Mic Up", desc="Clone target's avatar", args="Target", place=place,
            run=function(ctx) local t=ctx.find(); if t and cloneRS and cloneEv then pcall(function() cloneRS:InvokeServer(t.UserId); task.wait(0.1); cloneEv:FireServer(t.UserId) end) end end }
        Miked.cmd{ name="loopclone", aliases={"fj"}, category="Mic Up", desc="Clone friends on loop", solo=true, place=place,
            run=function()
                State.loopClone=true
                task.spawn(function()
                    while State.loopClone do
                        for _,v in ipairs(Players:GetPlayers()) do
                            if not State.loopClone then break end
                            if v~=LP and LP:IsFriendsWith(v.UserId) and cloneRS and cloneEv then
                                pcall(function() cloneRS:InvokeServer(v.UserId); task.wait(0.1); cloneEv:FireServer(v.UserId) end); task.wait(1.5)
                            end
                        end
                        task.wait(2)
                    end
                end)
            end }
        Miked.cmd{ name="unloopclone", aliases={"unfj"}, category="Mic Up", desc="Stop cloning", solo=true, place=place, run=function() State.loopClone=false end }
        Miked.cmd{ name="ref", category="Mic Up", desc="Refresh avatar", solo=true, place=place, run=function() if refreshEv then pcall(function() refreshEv:FireServer() end) end end }
        Miked.cmd{ name="grab", aliases={"b","xbring"}, category="Mic Up", desc="Grab target", args="Target", place=place,
            run=function(ctx)
                if ctx.index~=1 then return end
                local t = ctx.find(); local ic = ctx.speaker and ctx.speaker.Character
                if not (t and t.Character and ic) then return end
                State.grab=true
                local mR=myRoot(); local tR=t.Character:FindFirstChild("HumanoidRootPart"); local iR=ic:FindFirstChild("HumanoidRootPart")
                if not (mR and tR and iR) then return end
                task.spawn(function()
                    mR.CFrame=tR.CFrame*CFrame.new(0,0,3); ChatSend("Accept Grab!")
                    local start,lc2,ok=tick(),0,false
                    while State.grab and (tick()-start)<15 do
                        if grabEv then pcall(function() grabEv:FireServer(t.UserId,"cute") end) end
                        if (mR.Position-tR.Position).Magnitude<1.7 then lc2+=1 else lc2=0 end
                        if lc2>=5 then ok=true break end; task.wait(0.2)
                    end
                    mR.CFrame=iR.CFrame*CFrame.new(0,0,3); State.grab=false
                end)
            end }
        Miked.cmd{ name="pvp", category="Mic Up", desc="Toggle PVP", place=place, botTarget=true, run=function() if pvpEv then pcall(function() pvpEv:FireServer() end) end end }
        Miked.cmd{ name="gentool", category="Mic Up", desc="Generate AI tool", args="[Size] Prompt", place=place, botTarget=true,
            run=function(ctx)
                local rest = table.concat(ctx.args," ",2)
                local sizeStr, prompt = rest:match("^(%d+)%s+(.+)$")
                if sizeStr and prompt and genEv then
                    local sz = math.clamp(tonumber(sizeStr), 1, 300)
                    pcall(function() genEv:FireServer(prompt, Vector3.new(sz,sz,sz)) end)
                end
            end }
    end
end


-- ══ GUI (main-only, generated from the registry) ═════════════════════════
if Miked.isMain then
    local TS  = game:GetService("TweenService")
    local UIS = game:GetService("UserInputService")
    local prefix = Config.prefix or "!"

    -- blue palette
    local T = {
        bg      = Color3.fromRGB(14,17,22),
        card    = Color3.fromRGB(23,28,36),
        cardHov = Color3.fromRGB(31,38,48),
        surface = Color3.fromRGB(16,20,26),
        accent  = Color3.fromRGB(60,130,255),
        accHov  = Color3.fromRGB(96,158,255),
        text    = Color3.fromRGB(230,234,242),
        dim     = Color3.fromRGB(138,147,166),
        border  = Color3.fromRGB(38,46,58),
        green   = Color3.fromRGB(53,196,106),
        red     = Color3.fromRGB(229,72,77),
    }
    local CAT_COLOR = {
        Movement=Color3.fromRGB(76,154,255), Formations=Color3.fromRGB(255,162,60),
        Orbits=Color3.fromRGB(176,108,255),  Spirals=Color3.fromRGB(138,92,255),
        Shields=Color3.fromRGB(53,196,160),   Action=Color3.fromRGB(255,92,92),
        Character=Color3.fromRGB(92,200,255),Emotes=Color3.fromRGB(255,201,76),
        Chat=Color3.fromRGB(76,224,138),      Info=Color3.fromRGB(154,166,188),
        System=Color3.fromRGB(255,122,122),   ["Mic Up"]=Color3.fromRGB(255,107,158),
        Misc=Color3.fromRGB(138,147,166),
    }

    local function C(cls, props, parent)
        local i = Instance.new(cls)
        for k,v in pairs(props) do i[k]=v end
        if parent then i.Parent = parent end
        return i
    end
    local function corner(p,r) C("UICorner",{CornerRadius=UDim.new(0,r or 8)},p) end
    local function stroke(p,col,th,tr) C("UIStroke",{Color=col or T.border,Thickness=th or 1,Transparency=tr or 0.35},p) end
    local function tween(o,props,t) TS:Create(o,TweenInfo.new(t or 0.15,Enum.EasingStyle.Quad),props):Play() end

    pcall(function()
        local old = LP.PlayerGui:FindFirstChild("MikedGUI"); if old then old:Destroy() end
    end)
    local SG = C("ScreenGui",{Name="MikedGUI",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=999,ZIndexBehavior=Enum.ZIndexBehavior.Sibling}, LP:WaitForChild("PlayerGui"))

    local WW, WH = 300, 500
    local win = C("Frame",{Name="Window",Size=UDim2.new(0,WW,0,WH),Position=UDim2.new(1,-(WW+18),0.5,-(WH/2)),
        BackgroundColor3=T.bg,BorderSizePixel=0,ClipsDescendants=true}, SG)
    corner(win,12); stroke(win,T.accent,1.5,0.3)

    -- header
    local hdr = C("Frame",{Size=UDim2.new(1,0,0,46),BackgroundColor3=T.card,BorderSizePixel=0}, win)
    C("Frame",{Size=UDim2.new(1,0,0,12),Position=UDim2.new(0,0,1,-12),BackgroundColor3=T.card,BorderSizePixel=0},hdr)
    C("Frame",{Size=UDim2.new(1,-24,0,2),Position=UDim2.new(0,12,1,0),BackgroundColor3=T.accent,BorderSizePixel=0},hdr)
    C("TextLabel",{Size=UDim2.new(0,120,1,0),Position=UDim2.new(0,14,0,-2),BackgroundTransparency=1,Text="Miked",
        TextColor3=T.text,TextSize=18,Font=Enum.Font.GothamBold,TextXAlignment=Enum.TextXAlignment.Left}, hdr)

    local pill = C("TextLabel",{Size=UDim2.new(0,64,0,18),Position=UDim2.new(1,-108,0.5,-10),BackgroundColor3=T.surface,
        Text="● 0",TextColor3=T.green,TextSize=11,Font=Enum.Font.GothamMedium,BorderSizePixel=0}, hdr)
    corner(pill,6)
    task.spawn(function() while SG.Parent do pill.Text = "● "..Miked.roster.total(); task.wait(2) end end)

    local minBtn = C("TextButton",{Size=UDim2.new(0,26,0,26),Position=UDim2.new(1,-36,0.5,-14),BackgroundColor3=T.surface,
        Text="—",TextColor3=T.dim,TextSize=14,Font=Enum.Font.GothamBold,AutoButtonColor=false,BorderSizePixel=0}, hdr)
    corner(minBtn,7)
    minBtn.MouseEnter:Connect(function() tween(minBtn,{BackgroundColor3=T.cardHov,TextColor3=T.text}) end)
    minBtn.MouseLeave:Connect(function() tween(minBtn,{BackgroundColor3=T.surface,TextColor3=T.dim}) end)

    -- search
    local sf = C("Frame",{Size=UDim2.new(1,-20,0,30),Position=UDim2.new(0,10,0,54),BackgroundColor3=T.surface,BorderSizePixel=0}, win)
    corner(sf,7); stroke(sf,T.border,1,0.4)
    C("TextLabel",{Size=UDim2.new(0,20,1,0),Position=UDim2.new(0,6,0,0),BackgroundTransparency=1,Text="⌕",TextColor3=T.dim,TextSize=15,Font=Enum.Font.Gotham}, sf)
    local search = C("TextBox",{Size=UDim2.new(1,-32,1,0),Position=UDim2.new(0,26,0,0),BackgroundTransparency=1,
        PlaceholderText="Search commands...",PlaceholderColor3=T.dim,Text="",TextColor3=T.text,TextSize=13,
        Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left,ClearTextOnFocus=false}, sf)

    -- list
    local list = C("ScrollingFrame",{Size=UDim2.new(1,-16,1,-134),Position=UDim2.new(0,8,0,92),BackgroundTransparency=1,
        BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=T.accent,CanvasSize=UDim2.new(0,0,0,0),
        AutomaticCanvasSize=Enum.AutomaticSize.Y}, win)
    C("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3)}, list)
    C("UIPadding",{PaddingLeft=UDim.new(0,2),PaddingRight=UDim.new(0,6),PaddingBottom=UDim.new(0,4)}, list)

    -- group registry by category (first-seen order)
    local order, groups = {}, {}
    for _, e in ipairs(Miked.CommandList) do
        if not groups[e.category] then groups[e.category] = {}; order[#order+1] = e.category end
        table.insert(groups[e.category], e)
    end

    local rows = {}
    local lo = 0
    for _, cat in ipairs(order) do
        lo += 1
        local col = CAT_COLOR[cat] or T.dim
        local ch = C("Frame",{Size=UDim2.new(1,0,0,24),BackgroundColor3=col,BackgroundTransparency=0.86,BorderSizePixel=0,LayoutOrder=lo}, list)
        corner(ch,6)
        C("Frame",{Size=UDim2.new(0,3,1,-6),Position=UDim2.new(0,0,0,3),BackgroundColor3=col,BorderSizePixel=0}, ch)
        C("TextLabel",{Size=UDim2.new(1,-10,1,0),Position=UDim2.new(0,10,0,0),BackgroundTransparency=1,Text=cat,
            TextColor3=col,TextSize=11,Font=Enum.Font.GothamBold,TextXAlignment=Enum.TextXAlignment.Left}, ch)

        for _, e in ipairs(groups[cat]) do
            lo += 1
            local row = C("TextButton",{Size=UDim2.new(1,0,0,30),BackgroundColor3=T.card,Text="",AutoButtonColor=false,BorderSizePixel=0,LayoutOrder=lo}, list)
            corner(row,6)
            C("TextLabel",{Size=UDim2.new(0,92,1,0),Position=UDim2.new(0,8,0,0),BackgroundTransparency=1,
                Text=prefix..e.name,TextColor3=T.text,TextSize=12,Font=Enum.Font.GothamMedium,TextXAlignment=Enum.TextXAlignment.Left}, row)

            local argBox
            if e.args then
                local af = C("Frame",{Size=UDim2.new(1,-104,1,-8),Position=UDim2.new(0,98,0,4),BackgroundColor3=T.surface,BorderSizePixel=0}, row)
                corner(af,5)
                argBox = C("TextBox",{Size=UDim2.new(1,-10,1,0),Position=UDim2.new(0,5,0,0),BackgroundTransparency=1,
                    PlaceholderText=e.args,PlaceholderColor3=T.dim,Text="",TextColor3=T.text,TextSize=10,
                    Font=Enum.Font.Code,TextXAlignment=Enum.TextXAlignment.Left,ClearTextOnFocus=false,Active=true}, af)
            else
                C("TextLabel",{Size=UDim2.new(1,-104,1,0),Position=UDim2.new(0,98,0,0),BackgroundTransparency=1,
                    Text=e.desc,TextColor3=T.dim,TextSize=10,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd}, row)
            end

            row.MouseEnter:Connect(function() tween(row,{BackgroundColor3=T.cardHov}) end)
            row.MouseLeave:Connect(function() tween(row,{BackgroundColor3=T.card}) end)
            row.MouseButton1Click:Connect(function()
                local text = prefix..e.name
                if argBox and argBox.Text ~= "" then text = text.." "..argBox.Text end
                Miked.send(text)
                row.BackgroundColor3 = T.green
                task.delay(0.18, function() tween(row,{BackgroundColor3=T.card},0.25) end)
            end)
            table.insert(rows, {row=row, cat=cat, e=e, header=nil})
        end
        rows[#rows] = rows[#rows]  -- (headers tracked below)
        table.insert(rows, {isHeader=true, header=ch, cat=cat})
    end

    -- search filter
    search:GetPropertyChangedSignal("Text"):Connect(function()
        local q = search.Text:lower()
        local shown = {}
        for _, r in ipairs(rows) do
            if not r.isHeader then
                local ok = q=="" or r.e.name:find(q,1,true) or (r.e.desc or ""):lower():find(q,1,true) or r.cat:lower():find(q,1,true)
                r.row.Visible = ok
                if ok then shown[r.cat] = true end
            end
        end
        for _, r in ipairs(rows) do
            if r.isHeader then r.header.Visible = (q=="" or shown[r.cat]==true) end
        end
    end)

    -- stop button
    local stop = C("TextButton",{Size=UDim2.new(1,-20,0,32),Position=UDim2.new(0,10,1,-40),BackgroundColor3=T.red,
        Text="STOP ALL",TextColor3=Color3.new(1,1,1),TextSize=12,Font=Enum.Font.GothamBold,AutoButtonColor=false,BorderSizePixel=0}, win)
    corner(stop,7)
    stop.MouseEnter:Connect(function() tween(stop,{BackgroundColor3=T.accHov}) end)
    stop.MouseLeave:Connect(function() tween(stop,{BackgroundColor3=T.red}) end)
    stop.MouseButton1Click:Connect(function() Miked.send(prefix.."stop"); stop.BackgroundColor3=T.green; task.delay(0.18,function() tween(stop,{BackgroundColor3=T.red},0.25) end) end)

    -- minimize / restore
    local icon = C("ImageButton",{Size=UDim2.new(0,46,0,46),Position=UDim2.new(0,14,1,-60),BackgroundColor3=T.accent,
        AutoButtonColor=false,BorderSizePixel=0,Visible=false}, SG)
    corner(icon,12); stroke(icon,T.accHov,1.5,0.2)
    C("TextLabel",{Size=UDim2.new(1,0,1,0),BackgroundTransparency=1,Text="M",TextColor3=Color3.new(1,1,1),TextSize=22,Font=Enum.Font.GothamBold}, icon)
    local function minimize() win.Visible=false; icon.Visible=true end
    local function restore() icon.Visible=false; win.Visible=true end
    minBtn.MouseButton1Click:Connect(minimize)
    icon.MouseButton1Click:Connect(restore)
    UIS.InputBegan:Connect(function(inp,gp) if gp then return end
        if inp.KeyCode==Enum.KeyCode.RightShift then if win.Visible then minimize() else restore() end end
    end)

    -- draggable header
    do
        local dragging, dragStart, startPos
        hdr.InputBegan:Connect(function(inp)
            if inp.UserInputType==Enum.UserInputType.MouseButton1 or inp.UserInputType==Enum.UserInputType.Touch then
                dragging=true; dragStart=inp.Position; startPos=win.Position
                inp.Changed:Connect(function() if inp.UserInputState==Enum.UserInputState.End then dragging=false end end)
            end
        end)
        UIS.InputChanged:Connect(function(inp)
            if dragging and (inp.UserInputType==Enum.UserInputType.MouseMovement or inp.UserInputType==Enum.UserInputType.Touch) then
                local d = inp.Position - dragStart
                win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset+d.X, startPos.Y.Scale, startPos.Y.Offset+d.Y)
            end
        end)
    end

    print("[Miked] GUI ready — RightShift to toggle")
end


-- ══ SURVIVAL (bot-side lifecycle) ═════════════════════════════════════════
if Miked.isBot then
    local VirtualUser = game:GetService("VirtualUser")
    local CoreGui     = game:GetService("CoreGui")
    local VIM         = game:GetService("VirtualInputManager")
    local GuiService  = game:GetService("GuiService")
    local Lighting    = game:GetService("Lighting")
    local Teleport    = game:GetService("TeleportService")

    -- ── anti-afk ──
    table.insert(Miked.Conns, LP.Idled:Connect(function()
        pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
    end))
    task.spawn(function()
        while true do
            task.wait(60)
            pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
        end
    end)

    -- ── performance (run many bots without dying) ──
    pcall(function() if setfpscap then setfpscap(Config.fpsCap or 10) end end)
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    pcall(function() Lighting.GlobalShadows=false; Lighting.FogEnd=1e10 end)
    task.spawn(function()
        for _, v in ipairs(game:GetDescendants()) do
            pcall(function()
                if v:IsA("ParticleEmitter") or v:IsA("Trail") or v:IsA("Beam") then v.Enabled=false
                elseif v:IsA("PostEffect") then v.Enabled=false end
            end)
        end
    end)

    -- ── position persistence (return to spot after a rejoin) ──
    local POS_FILE = "Miked_pos_"..LP.Name..".txt"
    function Miked.savePos()
        pcall(function()
            local r = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
            if r and writefile then writefile(POS_FILE, table.concat({r.CFrame:GetComponents()}, ",")) end
        end)
    end
    task.spawn(function()
        pcall(function()
            if isfile and isfile(POS_FILE) then
                local nums = {}
                for _, s in ipairs(readfile(POS_FILE):split(",")) do nums[#nums+1] = tonumber(s) end
                if #nums >= 12 then
                    local cf = CFrame.new(table.unpack(nums))
                    local char = LP.Character or LP.CharacterAdded:Wait()
                    local r = char:WaitForChild("HumanoidRootPart", 12)
                    if r then task.wait(0.6); r.CFrame = cf end
                end
                if delfile then delfile(POS_FILE) end
            end
        end)
    end)

    -- ── mic frame helpers (voice games) ──
    local function findMic()
        local tba = CoreGui:FindFirstChild("TopBarApp"); if not tba then return nil end
        for _, d in ipairs(tba:GetDescendants()) do
            if d.Name=="toggle_mic_mute" and d:IsA("Frame") then return d end
        end
    end
    local function micMuted()
        local adi = LP:FindFirstChildOfClass("AudioDeviceInput")
        return not (adi and adi.Active)
    end
    local function clickMic()
        local mf = findMic(); if not mf then return end
        local pos, size = mf.AbsolutePosition, mf.AbsoluteSize
        local cx, cy = pos.X+size.X/2, pos.Y+size.Y/2+GuiService:GetGuiInset().Y
        pcall(function()
            VIM:SendMouseMoveEvent(cx,cy,game); task.wait(0.1)
            VIM:SendMouseButtonEvent(cx,cy,0,true,game,0); task.wait(0.1)
            VIM:SendMouseButtonEvent(cx,cy,0,false,game,0)
        end)
    end

    -- ── mic auto-unmute on load ──
    if Config.autoUnmute then
        task.spawn(function()
            task.wait((Config.micUnmuteDelay or 30) + (Miked.roster.index()-1)*2)
            for _=1,3 do if not micMuted() then break end; clickMic(); task.wait(1.5) end
        end)
    end

    -- ── VCB (voice ban) monitor: mic button vanishes -> wait -> rejoin ──
    if Config.vcbEnabled then
        task.spawn(function()
            task.wait(10)
            while true do
                task.wait(5)
                if not Miked.State.vcb and findMic()==nil then
                    Miked.State.vcb = true
                    Miked.chat("VCB detected — timer started")
                    task.wait(Config.vcbTimerSeconds or 360)
                    Miked.chat("Rejoining...")
                    if Miked.savePos then Miked.savePos() end
                    local qot = queue_on_teleport or queueonteleport
                    if qot and Config.loaderUrl then
                        qot('task.wait(3); pcall(function() loadstring(game:HttpGet("'..Config.loaderUrl..'"))() end)')
                    end
                    pcall(function() Teleport:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP) end)
                    Miked.State.vcb = false
                end
            end
        end)
    end

    -- ── announce ──
    if Config.announceOnLoad then
        task.spawn(function()
            task.wait(3 + Miked.roster.index()*1.5)
            Miked.chat("Miked loaded")
        end)
    end
end

print(("[Miked] v%s ready — %s"):format(Miked._version, Miked.role:upper()))
