--[[
    miked core
    ABSOLUTELY VIBE CODED (these comments are slop)
]]

-- ── standalone bootstrap ─────────────────────────────────────────────────
-- Running core.lua directly? This sets config + pulls Socket. If a loader
-- already set Miked up, its values are kept and this is skipped.
getgenv().Miked = getgenv().Miked or {
    Config = {
        mainAccount = "mainname",
        altAccounts = {
            "altname1",
            "altname2"
        },
        commanders  = {"commandername1","commandername2"},                             -- extra people allowed to command
        prefix      = "/",                            -- command prefix
        wsUrl       = "ws://127.0.0.1:8080",          -- relay address (localhost)
        fpsCap      = 15,                             -- bot fps cap
        nukeWorkspace = false,                        -- bots: DELETE the map instead of taming it (DO NOT ENABLE IT IS NOT WORKING AS INTENDED)
        announceOnLoad = true,                       -- bots chat "Miked loaded"
        autoUnmute  = false,                          -- voice games: auto-unmute mic
        vcbEnabled  = false,                          -- voice games: auto-rejoin on VC ban
    },
    State = {}, Conns = {}, Cache = {},
}

--[[ ── fast flags ────────────────────────────────────────────────────────
     FIRST. Above the Socket fetch and above the game:IsLoaded() wait, because
     both of those cost more time than we have — the engine reads these very
     early and whatever it has already read is settled.

     Bots only; the main still has to be playable.

     Every value carries the engine default it overrides. On the Int flags 0
     is the "no override" sentinel and NOT a minimum, which is why the CSG
     distances are small-but-nonzero and the grass movement factor is high
     rather than low.
──────────────────────────────────────────────────────────────────────── ]]
do
    local C  = getgenv().Miked.Config
    local Pl = game:GetService("Players")

    -- LocalPlayer resolves long before game:IsLoaded(), so asking now costs
    -- almost nothing and still tells us whether we are a bot. Bounded so a
    -- bad join can never hang autoexec.
    local spun = 0
    while not Pl.LocalPlayer and spun < 300 do task.wait(); spun = spun + 1 end

    local me    = Pl.LocalPlayer and Pl.LocalPlayer.Name:lower() or ""
    local isBot = me ~= tostring(C.mainAccount):lower()
    if isBot then
        local known = false
        for _, n in ipairs(C.altAccounts or {}) do
            if me == tostring(n):lower() then known = true break end
        end
        isBot = known
    end

    if isBot and setfflag then
        for name, value in pairs({
            -- CSG level of detail: the ranges at which a union drops to a
            -- cheaper mesh. Small = drops almost immediately. Ascending so
            -- the four bands stay ordered.   (defaults 250/500/750/1000)
            DFIntCSGLevelOfDetailSwitchingDistance    = "0",
            DFIntCSGLevelOfDetailSwitchingDistanceL12 = "0",
            DFIntCSGLevelOfDetailSwitchingDistanceL23 = "0",
            DFIntCSGLevelOfDetailSwitchingDistanceL34 = "0",

            -- Textures to the floor. The memory win is the point at 16 clients.
            DFFlagTextureQualityOverrideEnabled = "true",   -- default false
            DFIntTextureQualityOverride         = "0",      -- default 3

            -- Quality pin. Here 0 IS "no override", so 1 is the floor.
            DFIntDebugFRMQualityLevelOverride = "1",        -- default 0 = off
            DFFlagDebugPauseVoxelizer         = "true",     -- default false
            FFlagDebugSkyGray                 = "true",     -- default false

            -- Grass: distance 0 draws none. The movement factor is a REDUCED
            -- motion factor, so high means less motion.  (290 / 100 / 5)
            FIntFRMMaxGrassDistance              = "0",
            FIntFRMMinGrassDistance              = "0",
            FIntGrassMovementReducedMotionFactor = "100",

            -- One backend. D3D11 is the lightest per-instance on Windows;
            -- Vulkan is faster solo but costs more memory per client, which
            -- is the wrong trade at sixteen. The other two are named so a
            -- leftover cannot stack.
            FFlagDebugGraphicsPreferD3D11  = "true",
            FFlagDebugGraphicsPreferVulkan = "false",
            FFlagDebugGraphicsPreferOpenGL = "false",

            DFFlagDisableDPIScale = "true",                 -- default false

            -- Belt and braces behind setfpscap, set later once services exist.
            DFIntTaskSchedulerTargetFps = tostring(C.fpsCap or 15),
        }) do
            pcall(setfflag, name, value)
        end
        getgenv().Miked.flagsApplied = true
    end
end

if not getgenv().Miked.Socket then
    loadstring(game:HttpGet("https://raw.githubusercontent.com/mikeexploits/Miked/refs/heads/main/Systems/Socket.lua"))()
end

local Players = game:GetService("Players")

-- Autoexec (and queue_on_teleport) run before the game finishes loading, so
-- LocalPlayer, remotes and CoreGui aren't ready yet. Wait for both.
if not game:IsLoaded() then game.Loaded:Wait() end
if not Players.LocalPlayer then
    repeat task.wait() until Players.LocalPlayer
end
local LP = Players.LocalPlayer

local Miked  = getgenv().Miked
assert(Miked and Miked.Config, "[Miked] core.lua loaded before loader set Miked.Config")
local Config = Miked.Config

local function lc(s) return tostring(s):lower() end
Miked._lc = lc
Miked.State.startTime = Miked.State.startTime or tick()

-- ── built-in constants (owned by core, NOT user config) ──────────────────
Miked._version = "1.0.0-beta"
local GAMES = {
    micup = { [6884319169] = true },   -- Mic Up
}
local EMOTE_CATALOG_URL = "https://raw.githubusercontent.com/mikeexploits/Miked/refs/heads/main/Systems/Emotes.lua"
local LOADER_URL        = "https://raw.githubusercontent.com/mikeexploits/Miked/refs/heads/main/Loader.lua"


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
        local set = GAMES[tag]
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

    -- ctx.index / ctx.total resolve LIVE (via __index) instead of being frozen
    -- at dispatch time, so a running formation rebalances by itself whenever a
    -- bot joins or leaves mid-command.
    local ctxMeta = { __index = function(_, k)
        if k == "index" then return Miked.roster.index() end
        if k == "total" then return Miked.roster.total() end
        return nil
    end }

    -- the fat ctx handed to every command body
    local function buildCtx(entry, args, speaker)
        local ctx = setmetatable({
            cmd     = entry.name,
            args    = args,
            speaker = speaker,
        }, ctxMeta)
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
        local prefix = Config.prefix or "/"
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

-- Commands that must never be replayed to a late joiner — one-shot or
-- destructive things that would misfire on a bot that just walked in.
local NO_REPLAY = {
    quit=true, exit=true, leave=true, rejoin=true, rj=true, re=true,
    reset=true, respawn=true, kill=true,
    countdown=true, cd=true, scanall=true, report=true, friend=true, block=true,
    ping=true, ram=true, memory=true, uptime=true, altcount=true, alts=true,
    credits=true, rest=true, firework=true, nuke=true, ref=true, whitelist=true, blacklist=true,
}

-- ══ CAGE DIRECTOR (main only) ════════════════════════════════════════════
-- EVERY BOT REPORTS WHAT IT SEES. MAIN AVERAGES. THE MODEL GOES THERE.
--
-- No single client knows where the target is. Each one watches them through its
-- own interpolation buffer with its own jitter and its own hiccups, and picking
-- one machine to trust just means inheriting that machine's particular wrongness
-- — which is what every previous version did, and why moving the read from main
-- to a bot and back never fixed anything.
--
-- Seven noisy readings of the same thing are worth more than the best one of
-- them. Every bot streams its view of the target, main throws out anything wild
-- and averages the rest, and THAT is the model — one transform, derived from
-- everybody, that no client's individual bad frame can move. Everyone then
-- builds their slot off the same number, so the cell is rigid by construction.
--
-- The average does not remove the lag; every client is late by roughly the same
-- amount, and a mean of equally-late numbers is still late. It removes the
-- DISAGREEMENT, which is what makes cells deform and bodies jitter. The lag is
-- handled the other way:
--
--   FOLLOW  the model tracks them. Not a jail, and not pretending to be — it is
--           holding station until they stop.
--   HOLD    the model freezes. The error in a frozen point is speed × latency,
--           so main only ever freezes when speed is ~0, and then it is exact.
Miked.CAGE = {
    rate      = 0.05,   -- model broadcast period
    still     = 3.0,    -- studs/s. At or under this the freeze is exact.
    settle    = 0.15,   -- has to be still this long before converting
    patience  = 2.0,    -- seconds of following before it locks ANYWAY. A target
                        -- that never stops would otherwise never get caged, and
                        -- a cage placed slightly behind a runner still beats a
                        -- cage that is still waiting for a moment that never comes.
                        -- They escape, it re-follows, it tries again.
    establish = 2,      -- standoff on EVERY axis while FOLLOWING. Anything that
                        -- tracks a player and touches them is a feedback loop:
                        -- it nudges them, the model follows, it nudges again.
                        -- Walls do that sideways just as floors do it upward.
    floorGap  = 0,      -- clearance once HELD. Nothing follows anything by then,
                        -- so the loop cannot start and flush is safe.
    pad       = 2.0,    -- escape radius = the cell's own half-span + this, so a
                        -- 16-bot cage isn't judged by a 6-bot cage's geometry
    tighten   = 0.75,   -- studs every layout is pulled in by, horizontally.
                        -- Set to 0 to use the models exactly as measured.
}

-- ── LATENCY ──────────────────────────────────────────────────────────────
-- Two delays sit between the target's real position and a bot standing in the
-- right place, and they are measured separately because they have nothing to do
-- with each other.
--
--   game ping   how stale main's copy of the target is. Roblox reports this.
--   wire        how long main -> relay -> bot takes. Nothing reports this, so
--               main times its own round trip to the alts.
local Stats = game:GetService("Stats")

function Miked.gamePing()
    local ok, v = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(v) == "number" and v > 0 and v < 2000 then return v / 1000 end
    return 0.10                              -- no telemetry: assume 100ms
end

function Miked.wirePing()
    return (Miked.State.wireRTT or 0.06) * 0.5      -- one way
end

if Miked.isMain then
    Miked.Socket.on("sys.pong", function(d)
        if not (d and d.t) then return end
        local rtt = tick() - d.t
        if rtt > 0 and rtt < 2 then
            -- smoothed: one slow packet should not move the estimate much
            Miked.State.wireRTT = (Miked.State.wireRTT or rtt) * 0.8 + rtt * 0.2
        end
    end)
    task.spawn(function()
        while true do
            Miked.Socket.send("sys.ping", { t = tick() })
            task.wait(2)
        end
    end)
elseif Miked.isBot then
    Miked.Socket.on("sys.ping", function(d, sender)
        local to = sender and sender.name and { to = sender.name } or nil
        Miked.Socket.send("sys.pong", { t = d and d.t }, to)
    end)
end

local CAGE_CMDS = { cage = true, trap = true }

local function startCageDirector(text)
    local C = Miked.CAGE
    Miked.State.cageRun = (Miked.State.cageRun or 0) + 1
    local run = Miked.State.cageRun

    task.spawn(function()
        -- /cage <targets...> [size] [air|ground]
        -- The size and family are optional and order-free, and they glue:
        -- "10air", "12 ground", "8g", "air" on its own. Anything that is not
        -- one of those is a target name, which is why players called "8" or
        -- "air" would confuse it and nobody is called that.
        local args = tostring(text):split(" ")
        local names, wantSize, wantFam = {}, nil, nil
        for i = 2, #args do
            local a = args[i]
            if a ~= "" then
                local low = lc(a)
                local num, fam = low:match("^(%d+)(%a*)$")
                if num then
                    wantSize = tonumber(num)
                    if fam == "air" or fam == "a" then wantFam = "air"
                    elseif fam == "ground" or fam == "g" or fam == "gnd" then wantFam = "ground" end
                elseif low == "air" then wantFam = "air"
                elseif low == "ground" or low == "gnd" then wantFam = "ground"
                else names[#names+1] = a end
            end
        end
        if #names == 0 then names[1] = "me" end

        local targets, seen = {}, {}
        for _, n in ipairs(names) do
            local p = Miked.findTarget(n, LP)
            if p and p.Character and not seen[p.Name] then
                seen[p.Name] = true; targets[#targets+1] = p
            end
        end
        if #targets == 0 then Miked.log("cage: no target matched"); return end

        local Cage = Miked.Cage
        if not Cage then Miked.log("cage: layouts not loaded"); return end

        local roster = Miked.roster.names()          -- sorted, lowercase, online alts
        local total  = #roster
        local cells  = math.min(#targets, math.floor(total / Cage.MIN))
        if cells < 1 then
            Miked.log("cage: need %d bots for a cell, %d online", Cage.MIN, total); return
        end

        -- one decision, made once, for everybody
        local base, extra = math.floor(total / cells), total % cells
        local assign, plans, at = {}, {}, 1
        for c = 1, cells do
            local budget = base + (c <= extra and 1 or 0)
            local t   = targets[c]
            local tR  = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
            local gnd = tR and Cage.grounded(tR.Position) or false
            local size, slots, fam = Cage.pick(budget, gnd, wantSize, wantFam)
            if not slots then
                Miked.log("cage: no %s%s layout - have %s",
                          wantSize and (wantSize .. "-bot ") or "",
                          wantFam or "", Cage.list(wantFam))
                return
            end
            if size > budget then
                Miked.log("cage: %d-bot %s cell needs %d bots, cell %d has %d",
                          size, fam, size, c, budget)
                return
            end

            -- Escape radius from the cell's own geometry. A wall 2.5 studs out
            -- and a wall 8 studs out do not mean the same thing by "outside".
            local span = 0
            for _, sl in ipairs(slots) do
                span = math.max(span, Vector3.new(sl.p.X, 0, sl.p.Z).Magnitude, math.abs(sl.p.Y))
            end

            plans[c] = { t = t, slots = slots, size = size, fam = fam,
                         escape = span + C.pad }
            for s = 1, math.min(size, budget) do
                assign[roster[at]] = { c = c, s = s }
                at += 1
            end
            at = at + (budget - math.min(size, budget))   -- skip this cell's idle bots
            Miked.log("cage: cell %d on %s - %d-bot %s layout, escape at %.1f studs",
                      c, t.Name, size, fam, plans[c].escape)
        end

        local plan = {}
        for name, w in pairs(assign) do
            local pl = plans[w.c]
            plan[name] = { s = w.s, n = pl.size, f = pl.fam, t = pl.t.Name }
        end

        local function targetRoot(c)
            local t = plans[c] and plans[c].t
            return t and t.Character and t.Character:FindFirstChild("HumanoidRootPart")
        end

        -- ── CONSENSUS ────────────────────────────────────────────────────
        -- Every alt's sighting of this target, plus main's own, meaned into one
        -- transform. Wild readings are dropped first: one bot mid-teleport or
        -- one dropped packet would otherwise drag the whole model with it, and
        -- the model is what everybody stands on.
        --
        -- Rotation is averaged as a look vector rather than a CFrame, because
        -- summing basis matrices is not an average of anything. Flattened to the
        -- horizontal — a cage does not care that they are looking at the sky.
        -- MAIN IS THE MODEL. It reads the target itself and that reading is
        -- what every bot builds against — one machine, one number, no vote.
        -- Main is the steadiest source there is: it is the client that issued
        -- the command, it is not being teleported around a formation, and its
        -- copy of the target is not competing with six others for the answer.
        local gen, held, stillSince, centres = 0, false, nil, {}
        local followSince = nil
        local model, frozenModel = {}, {}

        while Miked.State.cageRun == run do
            local now = tick()

            -- Rebuild the model every tick, straight off main's own read.
            for c in ipairs(plans) do
                local tR = targetRoot(c)
                if tR then model[c] = tR.CFrame end
            end

            -- How fast is the fastest occupant. Horizontal only: a jump is not a
            -- reason to refuse the freeze, and gravity would make it look like one.
            local speed = 0
            for c in ipairs(plans) do
                local tR = targetRoot(c)
                local v  = tR and tR.AssemblyLinearVelocity
                if v then
                    local flat = Vector3.new(v.X, 0, v.Z).Magnitude
                    if flat > speed then speed = flat end
                end
            end

            if held then
                -- Held cells only ever get released one way: the occupant is no
                -- longer in the cell we built. Then it is a follow again, which
                -- costs nothing and cannot be wrong, and it waits for the next
                -- stillness like the first one.
                local out, far = false, 0
                for c in ipairs(plans) do
                    local tR, ctr = targetRoot(c), centres[c]
                    if tR and ctr then                 -- no root = dead, not escaped
                        local d = (tR.Position - ctr).Magnitude
                        if d > far then far = d end
                        if d > (plans[c].escape or 6) then out = true end
                    end
                end
                if out then
                    held, stillSince, gen = false, nil, gen + 1
                    followSince, frozenModel = nil, {}
                    Miked.log("cage: out at %.1f studs - following again (leading %.1f studs)",
                              far, 0)
                end
            else
                -- Never convert without a model for EVERY cell. Holding on a
                -- partial one means some slots freeze and some keep waiting,
                -- which is a cage with a side missing.
                local ready = true
                for c in ipairs(plans) do
                    if not model[c] then ready = false end
                end

                -- Two ways to earn a lock. Standing still is the clean one — a
                -- frozen point on a stationary target has no error in it at all.
                -- Running out of patience is the other: a target that never
                -- stops would otherwise never get caged, and a cell placed a bit
                -- behind a runner is worth infinitely more than one that is
                -- still waiting. If it misses they escape, it follows again, and
                -- it tries again a second later. It gets them eventually.
                if followSince == nil then followSince = now end
                local calm  = ready and speed <= C.still
                local bored = ready and (now - followSince >= C.patience)

                if calm then stillSince = stillSince or now else stillSince = nil end

                if (stillSince and now - stillSince >= C.settle) or bored then
                    -- Freeze the model here and keep sending THAT, unchanged,
                    -- for as long as the hold lasts. Every alt then locks to
                    -- one identical transform no matter which packet it acts
                    -- on or how its own clock is running.
                    frozenModel = {}
                    for c in ipairs(plans) do
                        frozenModel[c] = model[c]
                        centres[c] = model[c] and model[c].Position
                                     or (targetRoot(c) and targetRoot(c).Position)
                    end
                    held, gen = true, gen + 1
                    followSince = nil
                    Miked.log("cage: held %s - %.1f studs/s (ping %.0fms + wire %.0fms)",
                              bored and not calm and "on the move" or "still",
                              speed, Miked.gamePing() * 1000, Miked.wirePing() * 1000)
                end
            end

            -- While held this sends ONLY the frozen transform. Never falling back
            -- to the live model matters: a bot caches the first anchor it sees
            -- after the generation flips, so if two bots caught two different
            -- transforms they would freeze in two different cells. Sending
            -- nothing makes a bot wait, which is visible and recoverable.
            local b = {}
            for c, pl in ipairs(plans) do
                local cf = held and frozenModel[c] or model[c]
                if held and not frozenModel[c] then cf = nil end
                if cf then b[pl.t.Name] = { cf:GetComponents() } end
            end
            Miked.Socket.send("cage.snap", { a = plan, b = b, g = gen, h = held })
            task.wait(C.rate)
        end
    end)
end

-- main's send path: GUI clicks AND chat-typing both funnel here
function Miked.send(text)
    -- remember the active command so bots joining later can catch up
    local first = tostring(text):match("^%S+") or ""
    local name  = lc(first:sub(#(Config.prefix or "/") + 1))
    if name == "stop" or name == "unall" or name == "unf" then
        Miked.State.lastCmd = nil
    elseif not NO_REPLAY[name] then
        Miked.State.lastCmd = text
    end
    Miked.Socket.send("cmd", { text = text })
    if CAGE_CMDS[name] then startCageDirector(text)
    else Miked.State.cageRun = (Miked.State.cageRun or 0) + 1 end   -- cancel any director
end

-- ── late-join sync ───────────────────────────────────────────────────────
-- Bots can join whenever. On load a bot announces itself; main replays the
-- currently active command to just that bot so it slots into the formation.
if Miked.isMain then
    Miked.Socket.on("sys.hello", function(_, sender)
        local last = Miked.State.lastCmd
        if not (last and last ~= "" and sender and sender.name) then return end
        task.delay(1, function()
            Miked.Socket.send("cmd", { text = last }, { to = sender.name })
            -- a replayed cage restarts the director, so the new bot gets an
            -- assignment and the cell reforms around the larger roster
            local n = lc((last:match("^%S+") or ""):sub(#(Config.prefix or "/") + 1))
            if CAGE_CMDS[n] then startCageDirector(last) end
        end)
    end)
elseif Miked.isBot then
    task.delay(2, function() Miked.Socket.send("sys.hello", { name = LP.Name }) end)
end

if Miked.isMain then
    -- typing a command in chat broadcasts it to the swarm.
    -- chat is just an INPUT here — the socket is the transport, bots never read chat.
    local prefix = Config.prefix or "/"
    table.insert(Miked.Conns, LP.Chatted:Connect(function(msg)
        if msg:sub(1, #prefix) == prefix then Miked.send(msg) end
    end))
end

-- ── bot -> main console ──────────────────────────────────────────────────
-- A bot that bails out of a command is invisible: its print() lands in its own
-- console and chatting from ten clients is unreadable. This pipes one line back
-- to main's console instead, so a command that silently does nothing can say why.
function Miked.log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    if not ok then s = tostring(fmt) end
    if Miked.isMain then print(("[Miked] %s"):format(s))
    else Miked.Socket.send("sys.log", { m = s }) end
end

if Miked.isMain then
    Miked.Socket.on("sys.log", function(d, sender)
        print(("[Miked] %s: %s"):format(sender and sender.name or "?", d and d.m or ""))
    end)
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
    -- ── physics replication link ─────────────────────────────────────────
    -- Pointing our PhysicsRepRootPart at the target's root makes our position
    -- replicate relative to THEIR physics frame — kills the server-side lag
    -- you'd otherwise get setting CFrame every frame on a moving target.
    -- MUST be cleared when the command stops or we stay bound to them.
    local setHidden = sethiddenproperty or sethiddenprop or set_hidden_property
    local getHidden = gethiddenproperty or gethiddenprop or get_hidden_property

    -- Called EVERY frame by the loop commands: the server overwrites the
    -- property and the Humanoid's state machine fights the CFrame lock, so
    -- both have to be re-asserted continuously rather than set once.
    -- `state` defaults to 0 (FallingDown), the state physrep is known to
    -- replicate in. Pass 16 (Physics) to keep arms and legs collidable while
    -- linked — whether physrep survives that is the open question, so it's an
    -- argument rather than a change.
    -- ── jiggle control, applied to EVERY physrep operation ───────────────
    -- Three things shake a linked body, and none of them is the link.
    --
    -- SIT. This is the big one. A seated humanoid stops running its walk
    -- controller entirely — no ground query, no step-up, no gravity fight, no
    -- attempt to reconcile where it thinks it should be with where we keep
    -- putting it. The controller IS the jitter, and sitting switches it off at
    -- the source instead of out-shouting it every frame.
    --
    -- MOVE DIRECTION. Even seated, an internal move vector left over from before
    -- the link keeps getting integrated. Zero it directly — the public property
    -- is read-only, so this goes through the hidden one.
    --
    -- MOMENTUM. Velocity left over from before the link gets integrated against
    -- a position we overwrite every frame, so the solver and the write argue and
    -- the body buzzes. Zero the whole assembly, not just the root — a swinging
    -- arm carries the torso with it.
    --
    -- And animations move the limbs while all of the above is happening, which
    -- both shakes the body and, in a cage, opens holes nobody placed.
    -- true -> false -> true. It reads like superstition and it is not: Sit is a
    -- property whose SETTER does the work, and setting it to a value it already
    -- holds is a no-op that runs none of it. The round trip forces the humanoid
    -- to actually leave the seated state and re-enter it, which is what tears
    -- down the walk controller instead of just flagging it. Straight
    -- `Sit = true` on a humanoid that thinks it is already seated does nothing.
    local function sitDown(hum)
        if not hum then return end
        pcall(function()
            hum.Sit = true
            hum.Sit = false
            hum.Sit = true
        end)
    end

    -- `noSit` opts out of the seating trick. It is the right call for anything
    -- that wants the bodies posed rather than slumped — a seated humanoid pulls
    -- its own limbs into a sitting shape, which is fine for a wall and wrong for
    -- a formation you are looking at. The move vector still gets zeroed.
    local function harden(char, noSit)
        if not char then return end

        -- Animations FIRST, before anything else touches the humanoid. This arms
        -- the AnimationPlayed hook, and the very next thing we do — sitting —
        -- fires an animation. Arm it after and that one plays unopposed.
        if Miked.animFreeze then Miked.animFreeze(char, true) end

        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            if not noSit then
                sitDown(hum)                             -- kill the walk controller
                pcall(function() hum.AutoRotate = false end)
            end
            if setHidden then
                pcall(setHidden, hum, "MoveDirectionInternal", Vector3.zero)
            end
        end
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then
                pcall(function()
                    p.AssemblyLinearVelocity  = Vector3.zero
                    p.AssemblyAngularVelocity = Vector3.zero
                    p.Velocity, p.RotVelocity = Vector3.zero, Vector3.zero
                end)
            end
        end
    end

    -- `keep` means the caller is taking the body straight into another locked
    -- state and does NOT want it handed back to the humanoid on the way. Without
    -- it, releasing the link stands the bot up and restarts its animations for
    -- however long it takes the next re-assert to land — which is a body that
    -- visibly drops and flails right at the moment it is supposed to be sealing.
    local function soften(keep)
        local char = LP.Character; if not char then return end
        if keep then return end
        if Miked.animFreeze then Miked.animFreeze(char, false) end
        local hum = char:FindFirstChildOfClass("Humanoid"); if not hum then return end
        pcall(function() hum.Sit = false end)
        pcall(function() hum.AutoRotate = true end)
    end

    local function physLink(targetRoot, state, noSit)
        if not (setHidden and targetRoot) then return end
        local char = LP.Character; if not char then return end
        local mR = char:FindFirstChild("HumanoidRootPart"); if not mR then return end
        pcall(setHidden, mR, "PhysicsRepRootPart", targetRoot)
        -- These loops call physLink every frame, so the full walk only runs when
        -- the link is actually new. Velocity is cheap and gets zeroed every time
        -- — it's the one that regrows.
        local hum = char:FindFirstChildOfClass("Humanoid")
        if State.physSelf ~= mR or State.physTo ~= targetRoot or not State.physLinked then
            harden(char, noSit)            -- full pass: sit, animations, momentum

            -- ── THE ANIMATION KILLER ─────────────────────────────────────
            -- harden only fires on a FRESH link, and disabling the Animate
            -- script does not stop the engine deciding to play something
            -- anyway — a landing, an emote, an idle it restarts on its own.
            -- One kill at link time holds for about a second and then the
            -- limbs start drifting out of formation on their own.
            --
            -- So it runs every frame for as long as the link lasts. Its own
            -- generation counter, not a flag, so a re-link never leaves two
            -- of these racing each other.
            local gen = (State.animGen or 0) + 1
            State.animGen = gen
            task.spawn(function()
                while State.animGen == gen and State.physLinked do
                    if Miked.animFreeze then Miked.animFreeze(LP.Character, true) end
                    task.wait()
                end
            end)
        elseif hum then
            -- Cheap per-frame re-assert: velocity and the move vector only.
            -- Sitting is deliberately NOT repeated. It is a one-shot at link
            -- time, because every re-sit fires the sit animation again and a
            -- toggle that runs every frame is an animation that never stops
            -- starting. Keeping the body still is the animation killer's job,
            -- and that runs on its own loop.
            pcall(function()
                mR.AssemblyLinearVelocity  = Vector3.zero
                mR.AssemblyAngularVelocity = Vector3.zero
            end)
            if setHidden then
                pcall(setHidden, hum, "MoveDirectionInternal", Vector3.zero)
            end
        end
        if hum then pcall(function() hum:ChangeState(state or 0) end) end
        if state == 16 then
            -- state 16 is only worth anything if the limbs are actually solid
            for _, p in ipairs(char:GetChildren()) do
                if p:IsA("BasePart") then pcall(function() p.CanCollide = true end) end
            end
        end
        State.physSelf, State.physTo, State.physLinked = mR, targetRoot, true
    end

    -- Cleared to nil. Pointing it at our own root looked equivalent on paper and
    -- is not — a body repping against itself is a cycle, and the engine does not
    -- treat that as "normal", it treats it as broken.
    local function physUnlink(keepState)
        if not (setHidden and State.physLinked) then return end
        local mR = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        if mR then pcall(setHidden, mR, "PhysicsRepRootPart", nil) end
        if State.physSelf and State.physSelf ~= mR then
            pcall(setHidden, State.physSelf, "PhysicsRepRootPart", nil)  -- old body
        end
        State.animGen = (State.animGen or 0) + 1   -- stops the animation killer
        soften(keepState)          -- keepState: leave sit and animations alone
        -- Hand control back to the humanoid so walking commands work again —
        -- unless the caller is about to set a state of its own, in which case
        -- GettingUp here would just be something else to fight.
        if not keepState then
            local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
            if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end) end
        end
        State.physSelf, State.physTo, State.physLinked = nil, nil, false
    end
    Miked.physLink, Miked.physUnlink = physLink, physUnlink

    -- ── the physrep tug, and why world-space writes cause it ─────────────
    -- Physrep does not replicate your position. It replicates your position as
    -- an OFFSET INSIDE the target's CFrame, and every other client rebuilds it
    -- with THEIR copy of that target. So a world-space write gets silently
    -- decomposed against your client's view of the target's rotation and
    -- recomposed against everyone else's — and those two never quite agree,
    -- because the target is a replicated body moving under interpolation. The
    -- disagreement is an angle, and an angle times your orbit radius is studs.
    -- That is the tug: it scales with how far out you are and how fast they turn.
    --
    -- There is no compensating for it. Cancelling the rotation client-side just
    -- bakes YOUR copy of it into the number, and the far end still multiplies by
    -- its own. The only write with no disagreement in it is one that never
    -- mentioned the target's rotation: build the offset in the target's frame
    -- and leave it there. The server expands it against the true transform, so
    -- every client lands on the identical world point by construction.
    --
    -- The shape is unchanged. It rides the target's facing now instead of world
    -- north, which for a ring is a phase and for everything else looks attached.
    local function physCF(tR, off, extra, at)
        local base
        if (off - (at or Vector3.zero)).Magnitude > 1e-3 then
            base = CFrame.new(off, at or Vector3.zero)     -- face the target, in ITS frame
        else
            base = CFrame.new(off)
        end
        if extra then base = base * extra end
        return tR.CFrame * base
    end
    Miked.physCF = physCF

    -- a fresh body has no link; drop the stale bookkeeping so it re-links cleanly
    table.insert(Miked.Conns, LP.CharacterAdded:Connect(function()
        State.physSelf, State.physTo, State.physLinked = nil, nil, false

        if State.stateConns then
            for _, c in ipairs(State.stateConns) do pcall(function() c:Disconnect() end) end
        end
        State.stateHum, State.stateConns = nil, nil   -- re-arm on the new humanoid
        State.stateGen = (State.stateGen or 0) + 1
        if State.animConn then pcall(function() State.animConn:Disconnect() end) end
        State.animConn, State.animAr = nil, nil       -- new body, new Animator
    end))

    -- Motion and emotes are separate layers so they can run at the same time
    -- (dancing orbit, waving follow…). Movement commands clear only motion,
    -- emote commands clear only emotes, !stop clears both.
    local function stopMotion()
        local wasCaged = State.cmd == "Cage"
        State.cmd = "None"
        physUnlink()
        if wasCaged and Miked._releaseCage then pcall(Miked._releaseCage) end
        local c = LP.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if r then r.Velocity = Vector3.zero; r.RotVelocity = Vector3.zero; r.Anchored = false end
        if h then
            h.AutoRotate = true
            h.Sit = false                    -- harden() sat us down; stand back up
            if not State.speedLock then h.WalkSpeed = 16 end
        end
        if State.stackPart then pcall(function() State.stackPart:Destroy() end); State.stackPart = nil end
    end

    -- the tracked catalog emote + any /e action tracks
    local function stopEmotes()
        State.emote = nil
        if State.emoteTrack then pcall(function() State.emoteTrack:Stop(0) end); State.emoteTrack = nil end
        local c = LP.Character
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if h then
            local anim = h:FindFirstChildOfClass("Animator")
            if anim then
                for _, tr in pairs(anim:GetPlayingAnimationTracks()) do
                    if tr.Priority == Enum.AnimationPriority.Action then pcall(function() tr:Stop(0) end) end
                end
            end
        end
    end

    local function stopEverything() stopMotion(); stopEmotes() end

    Miked.stopMotion, Miked.stopEmotes = stopMotion, stopEmotes
    Miked.stopEverything = stopEverything
    Miked.stopAll = stopEverything   -- legacy alias: full halt

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

    -- "/spiral <pattern> <target> [speed] [range]" — the pattern number is
    -- optional, so a leading non-number just slides everything back one slot
    -- and "/spiral me 4 12" still parses the way it always did.
    local function patternTarget(ctx, defP, defS, defR)
        local a = ctx.args
        local p = tonumber(a[2])
        local k = p and 1 or 0                      -- did the pattern eat a slot?
        local tname = a[2 + k]
        return p or defP, ctx.find(tname),
               tonumber(a[3 + k]) or defS,
               tonumber(a[4 + k]) or defR
    end

    local function myRoot() local c = LP.Character; return c and c:FindFirstChild("HumanoidRootPart") end
    local function myHum()  local c = LP.Character; return c and c:FindFirstChildOfClass("Humanoid") end

    -- A CFrame write leaves the old momentum on the part, so a teleport keeps
    -- sliding after it lands. Every snap runs through this.
    -- `Velocity` and `RotVelocity` are the deprecated aliases and they only mean
    -- anything when the part IS its assembly's root — which is not guaranteed
    -- for a character mid-ragdoll. The Assembly properties are the real ones and
    -- writing either of them zeroes the whole assembly in a single go, so this
    -- writes those first and keeps the old names as a fallback for whatever the
    -- executor's API surface actually exposes.
    local function zeroVel(p)
        if not p then return end
        pcall(function()
            p.AssemblyLinearVelocity  = Vector3.zero
            p.AssemblyAngularVelocity = Vector3.zero
        end)
        pcall(function()
            p.Velocity    = Vector3.zero
            p.RotVelocity = Vector3.zero
        end)
    end
    Miked.zeroVel = zeroVel

    -- Nuclear version: every part individually. An assembly write covers the
    -- whole rig only while the joints hold it together, and a character in
    -- Physics state is exactly the case where they might not.
    local function zeroVelAll(char)
        if not char then return end
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then zeroVel(p) end
        end
    end
    Miked.zeroVelAll = zeroVelAll

    -- ══ MOVEMENT ════════════════════════════════════════════════════════
    Miked.cmd{ name="goto", category="Movement", desc="Teleport to target", args="[bot] Target", botTarget=true,
        run=function(ctx)
            local t = ctx.find(); if not (t and t.Character and t.Character:FindFirstChild("HumanoidRootPart")) then return end
            local mR = myRoot(); if not mR then return end
            local a = (ctx.index / ctx.total) * PI2
            mR.CFrame = t.Character.HumanoidRootPart.CFrame * CFrame.new(cos(a)*6, 0, sin(a)*6) * CFrame.Angles(0, a+PI, 0)
            zeroVel(mR)
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
            stopMotion(); task.wait(0.05); State.cmd = "Follow"
            task.spawn(function()
                while State.cmd=="Follow" and t and t.Character do
                    local h, mR = myHum(), myRoot()
                    local tR = t.Character:FindFirstChild("HumanoidRootPart")
                    if h and mR and tR then
                        -- Sit stays ON while linked: harden() uses it to stop the jitter
                        local a = (ctx.index/ctx.total)*PI2
                        local goal = tR.Position + Vector3.new(cos(a)*5,0,sin(a)*5)
                        if (mR.Position-goal).Magnitude > 50 then mR.CFrame = CFrame.new(goal, tR.Position); zeroVel(mR) else h:MoveTo(goal) end
                    end
                    task.wait(0.15)
                end
            end)
        end }

    Miked.cmd{ name="walkto", aliases={"to"}, category="Movement", desc="Walk to target", args="Target",
        run=function(ctx)
            local t = ctx.find(); if not (t and t.Character) then return end
            stopMotion(); task.wait(0.05); State.cmd = "WalkTo"
            task.spawn(function()
                while State.cmd=="WalkTo" and t and t.Character do
                    local h, mR = myHum(), myRoot()
                    local tR = t.Character:FindFirstChild("HumanoidRootPart")
                    if h and mR and tR then
                        -- Sit stays ON while linked: harden() uses it to stop the jitter
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
            stopMotion(); task.wait(0.05); State.cmd = "Stalk"
            task.spawn(function()
                while State.cmd=="Stalk" and t and t.Character do
                    local h, mR = myHum(), myRoot()
                    local tR = t.Character:FindFirstChild("HumanoidRootPart")
                    if h and mR and tR then
                        -- Sit stays ON while linked: harden() uses it to stop the jitter
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
            stopMotion(); task.wait(0.05); State.cmd = "Worm"
            task.spawn(function()
                while State.cmd=="Worm" do
                    local h = myHum(); 
                    local idx = ctx.index   -- live: the chain re-orders on join/leave
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
            stopMotion(); task.wait(0.05); State.cmd = "Swarm"
            task.spawn(function()
                local goal, gt = Vector3.zero, 0
                while State.cmd=="Swarm" and t and t.Character do
                    local h, mR = myHum(), myRoot()
                    local tR = t.Character:FindFirstChild("HumanoidRootPart")
                    if h and mR and tR then
                        -- Sit stays ON while linked: harden() uses it to stop the jitter
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

    -- Bee swarm. Each bot picks its own point inside a dome around the target,
    -- darts to it, picks another. Deliberately no physLink: the phys frame pins
    -- you to the target's ground plane and this needs all three axes.
    Miked.cmd{ name="swarm2", aliases={"bees","hive"}, category="Movement", desc="3D bee dome", args="Target [range] [speed]",
        run=function(ctx)
            local t     = ctx.find(ctx.args[2])
            local range = tonumber(ctx.args[3]) or 14
            local spd   = tonumber(ctx.args[4]) or 34
            if not (t and t.Character) then return end
            stopMotion(); task.wait(0.05); State.cmd = "Swarm2"
            task.spawn(function()
                local rng = Random.new(os.clock()*1e6 + ctx.index*7919)   -- diverge per bot
                -- cube root on the radius spreads points evenly through the volume
                -- instead of bunching them near the middle
                local function pick()
                    local r  = range * (0.4 + 0.6 * rng:NextNumber()^(1/3))
                    local th = rng:NextNumber(0, PI2)
                    local ph = math.acos(rng:NextNumber(-0.2, 1))   -- dome, not full sphere
                    local s  = sin(ph)
                    return Vector3.new(s*cos(th)*r, cos(ph)*r*0.75 + 3, s*sin(th)*r)
                end
                local off, nextPick = pick(), 0
                while State.cmd == "Swarm2" do
                    local dt = RunService.Heartbeat:Wait()
                    local mR = myRoot()
                    local tR = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                    if not (mR and tR) then break end
                    -- Sit stays ON while linked: harden() uses it to stop the jitter

                    if tick() > nextPick then
                        off = pick(); nextPick = tick() + rng:NextNumber(0.45, 1.1)
                    end

                    -- high-frequency wobble so nobody ever hangs perfectly still
                    local n = tick() + ctx.index
                    local buzz = Vector3.new(sin(n*19)*0.6, sin(n*27)*0.45, cos(n*23)*0.6)

                    local goal = tR.Position + off + buzz
                    local d    = goal - mR.Position
                    local dist = d.Magnitude
                    local nxt  = (dist > 0.05) and (mR.Position + d.Unit * math.min(dist, spd*dt)) or mR.Position
                    local look = (dist > 1) and (nxt + d.Unit) or (nxt + mR.CFrame.LookVector)
                    mR.CFrame = CFrame.new(nxt, look)
                    zeroVel(mR)
                end
            end)
        end }

    Miked.cmd{ name="wonder", category="Movement", desc="Wander randomly", solo=true,
        run=function(ctx)
            stopMotion(); task.wait(0.05); State.cmd = "Wonder"; local idx = ctx.index
            task.spawn(function()
                while State.cmd=="Wonder" do
                    local h, r = myHum(), myRoot()
                    if h and r then
                        -- Sit stays ON while linked: harden() uses it to stop the jitter
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
            stopMotion(); task.wait(0.05); State.cmd = "Carpet"
            task.spawn(function()
                local conn; conn = RunService.Heartbeat:Connect(function()
                    if State.cmd~="Carpet" then conn:Disconnect() return end
                    local mR = myRoot(); local tR = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                    if mR and tR then
                        physLink(tR)
                        -- Laid along the target's own -Z. MoveDirection is a
                        -- world vector and using it would put the target's
                        -- rotation back in the offset, which at index*7.5 studs
                        -- out is the tug all over again. Facing is the same
                        -- strip and it costs nothing to replicate.
                        local off = Vector3.new(0, -3.2, -(ctx.index*7.5))   -- live
                        mR.CFrame = tR.CFrame * CFrame.new(off) * CFrame.Angles(math.rad(90),0,0)
                        mR.Velocity = Vector3.zero
                    end
                end)
                table.insert(Miked.Conns, conn)
            end)
        end }

    Miked.cmd{ name="stackon", category="Movement", desc="Vertical tower on target", args="Target",
        run=function(ctx)
            local t = ctx.find(); if not t then return end
            stopMotion()
            local part = Instance.new("Part"); part.Name="MikedStack"; part.Size=Vector3.new(4,1,4)
            part.Transparency=1; part.Anchored=true; part.CanCollide=true; part.Parent=workspace; State.stackPart=part
            State.cmd="Stack"
            task.spawn(function()
                while State.cmd=="Stack" do
                    local mR = myRoot(); local tR = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                    if tR and mR then
                        physLink(tR)
                        local cf = tR.CFrame*CFrame.new(0,ctx.index*5,0); part.CFrame=cf   -- live
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
            zeroVel(mR)
        end }

    Miked.cmd{ name="scatter", category="Movement", desc="Random scatter", args="[Range]",
        run=function(ctx)
            stopMotion(); local range = tonumber(ctx.args[2]) or 30
            local mR = myRoot()
            if mR then
                local rng = Random.new(tick()+ctx.index)
                mR.CFrame = CFrame.new(mR.Position + Vector3.new(rng:NextNumber(-range,range),0,rng:NextNumber(-range,range)))
                zeroVel(mR)
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
            if mR then mR.CFrame = CFrame.new(tR.Position+off, tR.Position); zeroVel(mR) end
        end }

    Miked.cmd{ name="loopcircle", category="Formations", desc="Iterative circle", args="[R] Target",
        run=function(ctx)
            local radiusIn, t = speedTarget(ctx, nil)
            if not (t and t.Character) then return end
            stopMotion(); task.wait(0.05); State.cmd="LoopCircle"
            task.spawn(function()
                while State.cmd=="LoopCircle" and t and t.Character do
                    local idx, total = ctx.index, ctx.total
                    local radius = radiusIn or math.max(8, total*1.2)
                    local a = (idx/total)*PI2
                    local tR = t.Character:FindFirstChild("HumanoidRootPart"); local mR = myRoot()
                    if tR and mR then physLink(tR); mR.CFrame = physCF(tR, Vector3.new(cos(a)*radius,0,sin(a)*radius)); zeroVel(mR) end
                    task.wait()
                end
            end)
        end }

    -- line formations (r/l/f/b + loop variants)
    local LINE_DIRS = { rline=Vector3.new(4,0,0), lline=Vector3.new(-4,0,0), fline=Vector3.new(0,0,-4), bline=Vector3.new(0,0,4) }
    local function doLine(ctx, base, isLoop)
        local dir = LINE_DIRS[base]; if not dir then return end
        local t = ctx.find(); if not (t and t.Character and t.Character:FindFirstChild("HumanoidRootPart")) then return end
        if isLoop then
            stopMotion(); task.wait(0.05); State.cmd="LoopLine"
            task.spawn(function()
                while State.cmd=="LoopLine" and t and t.Character do
                    local tR = t.Character:FindFirstChild("HumanoidRootPart"); local mR = myRoot()
                    if tR and mR then
                        physLink(tR)
                        mR.CFrame = tR.CFrame * CFrame.new(dir*ctx.index)   -- live
                        mR.Velocity=Vector3.zero
                    end
                    RunService.Heartbeat:Wait()
                end
            end)
        else
            local tR = t.Character.HumanoidRootPart; local mR = myRoot()
            if mR then mR.CFrame = tR.CFrame*CFrame.new(dir*ctx.index); mR.Velocity=Vector3.zero end
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
            local function place(o) local p=(root.CFrame*o).Position; mR.CFrame=CFrame.new(p, p+fwd); zeroVel(mR) end
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
            zeroVel(mR)
        end }

    -- ══ CAGE ════════════════════════════════════════════════════════════
    -- Six bots make a sealed cell: four standing walls whose ARM SPAN (4 studs)
    -- covers a whole face, one bot flat as the roof, one flat as the floor.
    -- Roof and floor sit flush on the target's head and feet, so there is no
    -- vertical play at all — they can't jump, only stand.
    --
    -- The cage is full of holes and that's fine. A wall gap only lets someone
    -- out if the column is clear top to bottom, and a roof gap has to be 2x1
    -- to pass legs through. The 2.75-stud gaps at head and leg height and the
    -- 1x1 notches at the roof corners are all unusable.
    --
    -- The bots' arms and legs only collide while the Humanoid is held in the
    -- Physics state. Lose that state and every wall drops from 4 studs to 2.
    --
    -- NOTHING BELOW IS GENERATED. Every layout derived from a rule leaked
    -- somewhere, and the reason is visible the moment you line the built cells
    -- up: they don't share a strategy. The 6 stands four bots upright, the 8
    -- lays two on their side and stands two on their heads, the 10 and 12 put
    -- their lids on a 45-degree diagonal, the 16 is a double-height shell. No
    -- rule produces all of those, so any rule is a layout nobody tested.
    --
    -- These are transcribed off models built and verified in-game. Positions
    -- are relative to the target's HumanoidRootPart and deliberately NOT
    -- recentred — where the target sits inside its own cell is part of the
    -- build. The 10, 12, 16 and 8-ground were grid-snapped in Studio so they
    -- are copied exactly; a 45-degree bot's torso genuinely lands off-grid
    -- (1.8787, not 2) because the rotation moves it off the point that got
    -- snapped, and rounding that "clean" shifts the lid by an eighth of a stud.
    -- Only the two hand-placed originals (6 and 8 air) are half-stud snapped,
    -- because there the off-grid values are jitter rather than geometry.
    --
    -- To add a size: build it, export the .rbxmx, it gets transcribed here.
    -- AIR cells carry their own floor and work anywhere. GROUND cells spend
    -- that bot on the walls instead and only hold up over solid, level footing.
    -- Positions are relative to the target's HumanoidRootPart and are NOT
    -- recentred — where the target sits inside its cell is part of the build.
    local A = CFrame.Angles

    local CAGE_AIR = {
        [6] = {   -- CageModel6Air.rbxmx
            { p = Vector3.new( 0,   -3.5,  0  ), r = A(-PI/2,0,-PI/2) },
            { p = Vector3.new(-2.5,  0,    0  ), r = A(0,PI/2,0) },
            { p = Vector3.new( 0,    0,   -2.5), r = A(0,PI,0) },
            { p = Vector3.new( 0,    0,    2.5), r = A(0,0,0) },
            { p = Vector3.new( 2.5,  0,    0  ), r = A(0,PI/2,0) },
            { p = Vector3.new( 0,    2.5,  0  ), r = A(-PI/2,0,-PI/2) },
        },
        [8] = {   -- CageModel8.rbxmx
            { p = Vector3.new(-1.0, -3.5,  0.5), r = A(PI/2,0,-PI/2) },
            { p = Vector3.new( 1.0, -3.5,  0.5), r = A(-PI/2,0,PI/2) },
            { p = Vector3.new(-2.5, -1.0,  0.5), r = A(0,PI/2,0)*A(PI,0,0) },
            { p = Vector3.new( 3.5, -1.0,  0.5), r = A(0,PI/2,0)*A(PI,0,0) },
            { p = Vector3.new( 1.0,  0.0, -2.0), r = A(PI,0,-PI/2) },
            { p = Vector3.new( 1.0,  0.0,  3.0), r = A(PI,0,-PI/2) },
            { p = Vector3.new(-1.0,  2.5,  0.5), r = A(PI/2,0,-PI/2) },
            { p = Vector3.new( 1.0,  2.5,  0.5), r = A(-PI/2,0,PI/2) },
        },
        [10] = {  -- CageModel10Air.rbxmx
            { p = Vector3.new(-2.2175, -3.5, 0.0607), r = A(PI/2,0,-3*PI/4) },
            { p = Vector3.new( 2.0251, -3.5, 0.0607), r = A(PI/2,0,PI/4) },
            { p = Vector3.new(-4.5,     0,   0     ), r = A(0,PI/2,0) },
            { p = Vector3.new(-2,       0,  -2.5   ), r = A(PI,0,-PI/2) },
            { p = Vector3.new(-2,       0,   2.5   ), r = A(PI,0,-PI/2) },
            { p = Vector3.new( 2,       0,  -2.5   ), r = A(PI,0,PI/2) },
            { p = Vector3.new( 2,       0,   2.5   ), r = A(PI,0,PI/2) },
            { p = Vector3.new( 4.5,     0,   0     ), r = A(0,PI/2,0) },
            { p = Vector3.new(-2.2175,  2.5, 0.0607), r = A(PI/2,0,-3*PI/4) },
            { p = Vector3.new( 2.0251,  2.5, 0.0607), r = A(PI/2,0,PI/4) },
        },
        [16] = {  -- CageModel16Air.rbxmx
            { p = Vector3.new(-1.8787, -3.5, -1.8787), r = A(-PI/2,0,-3*PI/4) },
            { p = Vector3.new(-1.8787, -3.5,  1.8787), r = A(PI/2,0,-3*PI/4) },
            { p = Vector3.new( 1.8787, -3.5, -1.8787), r = A(PI/2,0,PI/4) },
            { p = Vector3.new( 1.8787, -3.5,  1.8787), r = A(-PI/2,0,PI/4) },
            { p = Vector3.new(-4.5,     1,   -2     ), r = A(0,PI/2,0) },
            { p = Vector3.new(-4.5,     1,    2     ), r = A(0,PI/2,0) },
            { p = Vector3.new(-2,       1,   -4.5   ), r = A(0,PI,0) },
            { p = Vector3.new(-2,       1,    4.5   ), r = A(0,PI,0) },
            { p = Vector3.new( 2,       1,   -4.5   ), r = A(0,PI,0) },
            { p = Vector3.new( 2,       1,    4.5   ), r = A(0,PI,0) },
            { p = Vector3.new( 4.5,     1,   -2     ), r = A(0,PI/2,0) },
            { p = Vector3.new( 4.5,     1,    2     ), r = A(0,PI/2,0) },
            { p = Vector3.new(-1.8787,  3.5, -1.8787), r = A(-PI/2,0,-3*PI/4) },
            { p = Vector3.new(-1.8787,  3.5,  1.8787), r = A(PI/2,0,-3*PI/4) },
            { p = Vector3.new( 1.8787,  3.5, -1.8787), r = A(PI/2,0,PI/4) },
            { p = Vector3.new( 1.8787,  3.5,  1.8787), r = A(-PI/2,0,PI/4) },
        },
    }

    local CAGE_GROUND = {
        [8] = {   -- CageModel8GroundSecure.rbxmx
            { p = Vector3.new(-4.3659, 0,   -0.027 ), r = A(0,-PI/2,0) },
            { p = Vector3.new(-1.8659, 0,   -2.527 ), r = A(0,PI,0) },
            { p = Vector3.new(-1.8659, 0,    2.473 ), r = A(0,PI,0) },
            { p = Vector3.new( 2.1341, 0,   -2.527 ), r = A(0,PI,0) },
            { p = Vector3.new( 2.1341, 0,    2.473 ), r = A(0,0,0) },
            { p = Vector3.new( 4.6341, 0,   -0.027 ), r = A(0,PI/2,0) },
            { p = Vector3.new(-2.1085, 2.5, -0.027 ), r = A(-PI/2,0,PI/4) },
            { p = Vector3.new( 2.1341, 2.5, -0.027 ), r = A(-PI/2,0,-3*PI/4) },
        },
        [12] = {  -- CageModel12Ground.rbxmx
            { p = Vector3.new(-4.5,     0,   -2     ), r = A(0,PI/2,0) },
            { p = Vector3.new(-4.5,     0,    2     ), r = A(0,PI/2,0) },
            { p = Vector3.new(-2,       0,   -4.5   ), r = A(0,PI,0) },
            { p = Vector3.new(-2,       0,    4.5   ), r = A(0,PI,0) },
            { p = Vector3.new( 2,       0,   -4.5   ), r = A(0,PI,0) },
            { p = Vector3.new( 2,       0,    4.5   ), r = A(0,PI,0) },
            { p = Vector3.new( 4.5,     0,   -2     ), r = A(0,PI/2,0) },
            { p = Vector3.new( 4.5,     0,    2     ), r = A(0,PI/2,0) },
            { p = Vector3.new(-1.8787,  3.5, -1.8787), r = A(-PI/2,0,-3*PI/4) },
            { p = Vector3.new(-1.8787,  3.5,  1.8787), r = A(PI/2,0,-3*PI/4) },
            { p = Vector3.new( 1.8787,  3.5, -1.8787), r = A(PI/2,0,PI/4) },
            { p = Vector3.new( 1.8787,  3.5,  1.8787), r = A(-PI/2,0,PI/4) },
        },
    }

    -- ── TIGHTEN ──────────────────────────────────────────────────────────
    -- Pulls every body in every layout CAGE_TIGHTEN studs closer to the
    -- occupant. One pass over the tables at load, so the hand-built geometry
    -- above stays exactly as it was measured and the shrink is one number you
    -- can dial or zero out.
    --
    -- HORIZONTAL ONLY, and that is not laziness. The lid already rests on the
    -- top of their skull and the floor already sits under their soles — those
    -- numbers came from the body, not from taste, and there is no slack in them
    -- to take out. Pull them in and a torso ends up occupying the same space as
    -- a head, which the solver resolves by throwing somebody across the map.
    -- The 0.75 you want is horizontal slack, and horizontal is where it is.
    local CAGE_TIGHTEN = Miked.CAGE.tighten or 0
    if CAGE_TIGHTEN > 0 then
        local function pull(v)
            if abs(v) < 1 then return v end          -- not an outward extent
            local s = (v > 0) and 1 or -1
            return v - s * math.min(CAGE_TIGHTEN, abs(v) - 0.5)
        end
        for _, set in ipairs({ CAGE_AIR, CAGE_GROUND }) do
            for _, slots in pairs(set) do
                for _, sl in ipairs(slots) do
                    sl.p = Vector3.new(pull(sl.p.X), sl.p.Y, pull(sl.p.Z))
                end
            end
        end
    end

    local CAGE_MIN       = 6
    local CAGE_FLOOR_GAP = Miked.CAGE.floorGap
    local CAGE_ESTABLISH = Miked.CAGE.establish

    -- Which families are legal, in preference order. Ground cells rest their
    -- walls on the world so they need footing, but they spend no body on a
    -- floor and are therefore roomier — on solid ground they win by default.
    local function families(grounded, want)
        if want == "air"    then return { { CAGE_AIR, "air" } } end
        if want == "ground" then return { { CAGE_GROUND, "ground" } } end
        if grounded then return { { CAGE_GROUND, "ground" }, { CAGE_AIR, "air" } } end
        return { { CAGE_AIR, "air" } }
    end

    -- `size` and `fam` are what the operator asked for and are honoured exactly:
    -- an explicit choice is never quietly swapped for something that fits
    -- better. Ask for something that does not exist and you get nil, which the
    -- director turns into a message rather than a surprise cage.
    local function pickCell(n, grounded, size, fam)
        local order = families(grounded, fam)
        if size then
            -- An explicitly named family is respected even in the air. If you
            -- ask for a ground cell while airborne you get one, and it will be
            -- a bad cage, and that is your call to make.
            if fam then
                local set = (fam == "ground") and CAGE_GROUND or CAGE_AIR
                if set[size] then return size, set[size], fam end
                return nil
            end
            for _, o in ipairs(order) do
                if o[1][size] then return size, o[1][size], o[2] end
            end
            -- named a size that only exists in the family we ruled out
            for _, o in ipairs({ { CAGE_AIR, "air" }, { CAGE_GROUND, "ground" } }) do
                if o[1][size] then return size, o[1][size], o[2] end
            end
            return nil
        end
        -- no size given: largest that the budget can build
        local best, slots, who
        for _, o in ipairs(order) do
            for s, tbl in pairs(o[1]) do
                if s <= n and (not best or s > best) then best, slots, who = s, tbl, o[2] end
            end
        end
        return best, slots, who
    end

    -- "6, 8, 10, 16 air · 8, 12 ground" — for the error message and /cages
    local function listCells(want)
        local out = {}
        for _, o in ipairs({ { CAGE_AIR, "air" }, { CAGE_GROUND, "ground" } }) do
            if not want or want == o[2] then
                local sizes = {}
                for s in pairs(o[1]) do sizes[#sizes+1] = s end
                table.sort(sizes)
                out[#out+1] = table.concat(sizes, ", ") .. " " .. o[2]
            end
        end
        return table.concat(out, " · ")
    end

    -- Ground cells rest their walls on the world, so the world has to actually
    -- be there: solid, anchored, collidable and level across the whole
    -- footprint. Probed at the widest ground cell (12 studs) so one answer is
    -- valid for every size.
    local GROUND_SPAN, GROUND_TOL = 12, 1.0
    local function groundedAt(pos)
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        rp.IgnoreWater = true
        local ex = {}
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl.Character then ex[#ex+1] = pl.Character end
        end
        rp.FilterDescendantsInstances = ex
        local base
        for _, fx in ipairs({-0.5, 0, 0.5}) do
            for _, fz in ipairs({-0.5, 0, 0.5}) do
                local from = pos + Vector3.new(fx*GROUND_SPAN, 4, fz*GROUND_SPAN)
                local hit  = workspace:Raycast(from, Vector3.new(0, -12, 0), rp)
                if not hit then return false end
                if not hit.Instance.CanCollide or not hit.Instance.Anchored then return false end
                base = base or hit.Position.Y
                if abs(hit.Position.Y - base) > GROUND_TOL then return false end
            end
        end
        return true
    end

    -- ── STATE 16 ─────────────────────────────────────────────────────────
    -- Physics is the only state that leaves arms and legs collidable, and the
    -- limbs ARE the wall — one frame out of it is one frame with a hole.
    --
    -- So: set it, from everywhere, constantly. Nothing is disabled, nothing is
    -- suppressed, nothing is negotiated with. Every attempt to be clever about
    -- this (turning the other states off, stopping the state machine) has ended
    -- up creating a window where the ChangeState was silently dropped. Spam has
    -- no window.
    local function forcePhysics(hum)
        if not hum then return end
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end)
    end

    -- Every frame signal the engine offers, on both sides of the physics step,
    -- under whichever names this client's API version exposes. Duplicates are
    -- deliberate: an extra ChangeState costs nothing, a missed one is an escape.
    local function eachRSSignal(fn)
        for _, pair in ipairs({
            { "PreRender",      "RenderStepped" },   -- top of frame
            { "PreAnimation",   nil            },
            { "PreSimulation",  "Stepped"      },    -- immediately BEFORE physics
            { "PostSimulation", "Heartbeat"    },    -- immediately after
        }) do
            local sig
            for _, n in ipairs({ pair[1], pair[2] }) do
                if n and not sig then
                    local ok, s = pcall(function() return RunService[n] end)
                    if ok and typeof(s) == "RBXScriptSignal" then sig = s end
                end
            end
            if sig then fn(sig) end
        end
    end

    local function physicsLock(char)
        local hum = char and char:FindFirstChildOfClass("Humanoid"); if not hum then return end
        forcePhysics(hum)

        for _, p in ipairs(char:GetChildren()) do
            if p:IsA("BasePart") then pcall(function() p.CanCollide = true end) end
        end

        -- Armed once per character; a respawn re-arms through CharacterAdded.
        if State.stateHum == hum and State.stateConns then return end
        if State.stateConns then
            for _, c in ipairs(State.stateConns) do pcall(function() c:Disconnect() end) end
        end
        local conns = {}
        eachRSSignal(function(sig)
            conns[#conns+1] = sig:Connect(function()
                if State.stateHum == hum then forcePhysics(hum) end
            end)
        end)
        -- The instant it changes, not the next frame. This is the one that
        -- actually catches a flicker: the state machine runs inside the physics
        -- step, so a frame signal is always a step behind it.
        conns[#conns+1] = hum.StateChanged:Connect(function(_, new)
            if State.stateHum == hum and new ~= Enum.HumanoidStateType.Physics then
                forcePhysics(hum)
            end
        end)
        State.stateHum, State.stateConns = hum, conns

        -- And a bare loop on top, because task.wait() resumes on the scheduler
        -- rather than on a frame event and lands in the gaps between them.
        -- Armed AFTER stateHum is set: task.spawn runs the body immediately, so
        -- a loop that checked it first would read the previous value and exit.
        local gen = (State.stateGen or 0) + 1
        State.stateGen = gen
        task.spawn(function()
            while State.stateGen == gen and State.stateHum == hum do
                forcePhysics(hum)
                task.wait()
            end
        end)
    end

    local function physicsUnlock(char)
        if State.stateConns then
            for _, c in ipairs(State.stateConns) do pcall(function() c:Disconnect() end) end
        end
        State.stateHum, State.stateConns = nil, nil
        State.stateGen = (State.stateGen or 0) + 1      -- stops the spam loop
        local hum = char and char:FindFirstChildOfClass("Humanoid"); if not hum then return end
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    end

    -- A playing animation moves the limbs, and the limbs ARE the wall. An idle
    -- sway is enough to swing an arm out of its slot and open a hole nobody
    -- placed. Kill the Animate script and stop every track, re-checked each
    -- frame because the engine restarts idle on its own.
    local function animFreeze(char, on)
        local a = char and char:FindFirstChild("Animate")
        if a then pcall(function() a.Disabled = on end) end

        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local ar  = hum and hum:FindFirstChildOfClass("Animator")

        if not on then
            if State.animConn then
                pcall(function() State.animConn:Disconnect() end)
                State.animConn, State.animAr = nil, nil
            end
            return
        end
        if not ar then return end

        -- A per-frame sweep still leaves a track running for up to a frame, and
        -- SITTING is the worst case for that: the engine fires the sit animation
        -- the instant Sit flips, and the sit pose pulls the arms and legs right
        -- out of whatever shape they were holding. So catch them at birth as
        -- well as sweeping — AnimationPlayed fires the moment a track starts,
        -- which is strictly sooner than any loop of ours can look.
        if State.animAr ~= ar then
            if State.animConn then pcall(function() State.animConn:Disconnect() end) end
            State.animAr = ar
            State.animConn = ar.AnimationPlayed:Connect(function(tr)
                pcall(function() tr:Stop(0) end)
            end)
        end

        for _, tr in ipairs(ar:GetPlayingAnimationTracks()) do
            pcall(function() tr:Stop(0) end)
        end
    end
    -- harden() runs long before this exists, so it reaches it through here.
    -- Every physrep operation freezes animations now, not just the cage.
    Miked.animFreeze = animFreeze



    -- Main owns the model; see startCageDirector. Everything the director needs
    -- lives in here, so hand it out.
    -- Main owns the model; see startCageDirector. Everything it needs is here.
    Miked.Cage = { AIR = CAGE_AIR, GROUND = CAGE_GROUND, MIN = CAGE_MIN,
                   pick = pickCell, grounded = groundedAt, list = listCells }

    -- ══ FORMATION ═══════════════════════════════════════════════════════
    -- Formation.rbxmx, transcribed. A stack: eight bodies lying flat above the
    -- target's head, from 2.5 studs up to 9.5, in staggered pairs and singles.
    --
    -- Offsets are measured from the ONE UPRIGHT BODY in the file, which is the
    -- person being stood over rather than a slot to fill — that is the reference
    -- the whole thing hangs off, so it is the origin here too. The heights
    -- already include the clearance over their head; there is no separate offset
    -- to add and nothing to tune.
    --
    -- The file holds sixteen bodies: this eight, repeated once 9.5 studs up. So
    -- the second copy is not in the table — it is what the tier wrap produces on
    -- its own when there are more than eight bots, at FORM_TIER apart.
    -- Rotation straight from the file as a raw basis, never decoded into angles.
    -- Every one of these bodies is lying flat and three of the four differ only
    -- by a quarter turn about a different axis; converting that to Euler and back
    -- is exactly where a sign gets lost and a slab ends up facing out.
    local function M(a,b,c, d,e,f, g,h,i)
        return CFrame.new(0,0,0, a,b,c, d,e,f, g,h,i)
    end

    local FORMATION = {
        { p = Vector3.new( 2.0,  2.5, 0.5), r = M( 1,0, 0,  0,0, 1,  0,-1,0) },
        { p = Vector3.new( 0.0,  4.0, 0.5), r = M( 0,0,-1,  1,0, 0,  0,-1,0) },
        { p = Vector3.new(-3.5,  4.0, 0.5), r = M( 0,0, 1, -1,0, 0,  0,-1,0) },
        { p = Vector3.new( 2.0,  6.0, 0.5), r = M(-1,0, 0,  0,0,-1,  0,-1,0) },
        { p = Vector3.new(-2.0,  6.0, 0.5), r = M(-1,0, 0,  0,0,-1,  0,-1,0) },
        { p = Vector3.new( 3.5,  8.0, 0.5), r = M( 0,0, 1, -1,0, 0,  0,-1,0) },
        { p = Vector3.new( 0.0,  8.0, 0.5), r = M( 0,0, 1, -1,0, 0,  0,-1,0) },
        { p = Vector3.new(-2.0,  9.5, 0.5), r = M(-1,0, 0,  0,0,-1,  0,-1,0) },
    }
    local FORM_TIER = 9.5     -- gap between repeats, measured off the file's own
                              -- second stack rather than picked
    local FORM_GAP  = 2       -- clearance between the target and the stack. The
                              -- file has the lowest slab sitting on their head;
                              -- this lifts the whole thing so it floats instead.

    -- bform.rbxmx. Same construction: one upright reference body at the bottom
    -- (5.5, -0.5, 14 — the identical origin Formation.rbxmx used), sixteen bots
    -- above it, and those sixteen are eight repeated once 14 studs higher. So
    -- again only the base eight are stated and the repeat is the tier wrap.
    --
    -- These bodies are inverted rather than laid flat, and the file already
    -- starts them 5.1 studs up, so there is no gap to add on top.
    local BFORMATION = {
        { p = Vector3.new(-4,  5.1, 0), r = M( 1, 0,0,  0,-1,0,  0,0,-1) },
        { p = Vector3.new( 4,  5.1, 0), r = M( 0, 1,0,  1, 0,0,  0,0,-1) },
        { p = Vector3.new( 0,  7.1, 0), r = M(-1, 0,0,  0, 1,0,  0,0,-1) },
        { p = Vector3.new(-2,  9.1, 0), r = M( 0, 1,0,  1, 0,0,  0,0,-1) },
        { p = Vector3.new( 2,  9.1, 0), r = M( 0,-1,0, -1, 0,0,  0,0,-1) },
        { p = Vector3.new( 0, 11.1, 0), r = M( 1, 0,0,  0,-1,0,  0,0,-1) },
        { p = Vector3.new(-4, 13.1, 0), r = M( 0,-1,0, -1, 0,0,  0,0,-1) },
        { p = Vector3.new( 4, 13.1, 0), r = M(-1, 0,0,  0, 1,0,  0,0,-1) },
    }
    local BFORM_TIER = 14     -- the file's own second stack again
    local BFORM_GAP  = 0      -- it is already high enough

    -- One runner, two shapes. Everything below the table is identical between
    -- them, so the difference stays in the data where it belongs.
    --
    -- `below` mirrors the whole stack under the target instead of over it. Same
    -- offsets, negated: the shape is unchanged, it just hangs down. Useful
    -- because nobody looks down — a stack overhead is the first thing you see
    -- and a stack underfoot is the last.
    -- Tallest slot in a table, so `below` knows how far the whole thing has to
    -- travel to clear the player. Computed once per table, not per frame.
    local function topOf(tbl)
        local m = 0
        for _, s in ipairs(tbl) do if s.p.Y > m then m = s.p.Y end end
        return m
    end

    local FORM_UNDER = 6      -- clearance between the player and the TOP of the
                              -- stack when it hangs below them

    -- PLACED by default, FOLLOWING on request.
    --
    -- Placed is one snapshot and then furniture: the shape is written into the
    -- world where it was made and it stays there whatever the person it was
    -- built around does next. Nothing is linked, so nothing can drag it.
    --
    -- Following is the old behaviour, kept behind a word: physrep on the target
    -- and every slot stated in the target's own frame, so the offset is what
    -- goes on the wire and the stack rides them without smearing.
    local function runForm(ctx, t, tag, tbl, tierGap, gap, below, follow)
        if not (t and t.Character) then return end
        local tR0 = t.Character:FindFirstChild("HumanoidRootPart")
        if not tR0 then return end
        stopMotion(); task.wait(0.05); State.cmd = tag

        local top = topOf(tbl)

        -- Placed takes position and HEADING only. Their pitch and roll are not
        -- the shape's business, and inheriting the full CFrame would tip the
        -- whole stack over the first time they jumped or walked down a slope.
        local base
        if not follow then
            local lv  = tR0.CFrame.LookVector
            local yaw = math.atan2(-lv.X, -lv.Z)
            base = CFrame.new(tR0.Position) * CFrame.Angles(0, yaw, 0)
        end

        task.spawn(function()
            -- The animation killer normally rides along inside physLink. Placed
            -- has no link, so it gets armed here instead — a body held by CFrame
            -- alone still plays its falling and idle animations, and those move
            -- the limbs straight out of the pose. Arming it for both paths is
            -- harmless: the loops key off separate generations.
            animFreeze(LP.Character, true)
            local gen = (State.animGen or 0) + 1
            State.animGen = gen
            task.spawn(function()
                while State.animGen == gen and State.cmd == tag do
                    animFreeze(LP.Character, true)
                    task.wait()
                end
            end)

            while State.cmd == tag do
                if follow and not (t and t.Character) then break end
                local mR = myRoot()

                -- Whole layers only: the roster rounds DOWN to a multiple of the
                -- stack, and anyone past that line sits out rather than starting
                -- a layer nobody can finish. Live, so a join or a leave adds or
                -- retires a whole layer on its own.
                local layers = math.floor(ctx.total / #tbl)
                local seats  = layers * #tbl
                local anchor = base

                if follow then
                    local tR = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                    if tR and mR and ctx.index <= seats then
                        physLink(tR, 16, true)  -- state 16, and no sitting
                        anchor = tR.CFrame
                    else
                        anchor = nil
                    end
                end

                if mR and anchor and ctx.index <= seats then
                    local idx  = ctx.index - 1                  -- live
                    local slot = tbl[(idx % #tbl) + 1]
                    local tier = math.floor(idx / #tbl) * tierGap
                    local y    = slot.p.Y + gap + tier

                    -- `below` LOWERS the stack, it does not mirror it. Negating
                    -- the offsets turned the whole thing upside down — the top
                    -- body became the bottom one and the shape read backwards.
                    -- Subtracting its full height instead keeps the stack the
                    -- right way up and just hangs it underneath.
                    if below then
                        y = y - (top + gap + math.max(layers - 1, 0) * tierGap + FORM_UNDER)
                    end

                    mR.Anchored = false
                    mR.CFrame = anchor * CFrame.new(slot.p.X, y, slot.p.Z) * slot.r
                    zeroVel(mR)
                    local hum = myHum()
                    if hum and setHidden then
                        pcall(setHidden, hum, "MoveDirectionInternal", Vector3.zero)
                    end
                elseif State.physLinked then
                    physUnlink()      -- sat out: stop being welded to it
                end
                RunService.Heartbeat:Wait()
            end

            State.animGen = (State.animGen or 0) + 1
            animFreeze(LP.Character, false)
        end)
    end

    -- Keywords, not numbers, so they can never be mistaken for a target name —
    -- and they are skipped when picking the target, because ctx.find() reads
    -- args[2] blindly and `/form down` would otherwise hunt for a player
    -- called "down".
    local FORM_DOWN   = { down = true, under = true, below = true, u = true }
    local FORM_FOLLOW = { follow = true, track = true, stick = true, f = true }

    local function formArgs(ctx)
        local below, follow, tname = false, false, nil
        for i = 2, #ctx.args do
            local raw = ctx.args[i]
            if raw and raw ~= "" then
                local a = lc(raw)
                if FORM_DOWN[a] then below = true
                elseif FORM_FOLLOW[a] then follow = true
                elseif not tname then tname = raw end
            end
        end
        return ctx.find(tname or "me"), below, follow
    end

    Miked.cmd{ name="form", category="Formations", desc="Stack above the head",
        args="Target [down] [follow]",
        run=function(ctx)
            local t, below, follow = formArgs(ctx)
            runForm(ctx, t, "Form", FORMATION, FORM_TIER, FORM_GAP, below, follow)
        end }

    Miked.cmd{ name="bform", category="Formations", desc="Inverted stack above the head",
        args="Target [down] [follow]",
        run=function(ctx)
            local t, below, follow = formArgs(ctx)
            runForm(ctx, t, "Form", BFORMATION, BFORM_TIER, BFORM_GAP, below, follow)
        end }

    Miked.cmd{ name="cages", category="Formations", desc="List cage layouts", solo=true,
        run=function(ctx)
            if ctx.index ~= 1 then return end     -- one bot answers, not all of them
            Miked.log("cage layouts: %s", listCells())
            Miked.log("usage: /cage <target> [size] [air|ground]  e.g. /cage x 10air")
        end }

    -- Slots, the model, the generation, and the mode. The model is the average
    -- of what all of us reported seeing, so it is worth more than our own read.
    Miked.Socket.on("cage.snap", function(d)
        if not d then return end
        if d.a then Miked.State.cagePlan = d.a end
        if d.b then Miked.State.cageBase = d.b end
        if d.g then Miked.State.cageGen  = d.g end
        Miked.State.cageHold = d.h and true or false
    end)

    Miked.cmd{ name="cage", aliases={"trap"}, category="Formations",
        desc="Seal targets in body cages", args="Target... [size] [air|ground]",
        run=function(ctx)
            -- FOLLOW while they move, HOLD when they stop. Main flips the flag;
            -- this side just obeys it, and each mode is exact in its own window.
            local me = lc(LP.Name)
            stopMotion(); task.wait(0.05)
            State.cmd = "Cage"
            State.cageGen, State.cageHold, State.cageBase = nil, false, nil

            task.spawn(function()
                local relKey, frozen = nil, nil
                local relPark, relHeld = nil, nil          -- our pose in the cell
                local solid = false                        -- true once locked into 16
                local conns, watched = {}, nil
                animFreeze(LP.Character, true)     -- limbs are the wall, keep them still

                -- Only guards once we are SUPPOSED to be in 16. During the state
                -- 0 window this would fight the link we are trying to establish.
                local function guard(hum)
                    if not hum then return end
                    conns[#conns+1] = hum.StateChanged:Connect(function(_, new)
                        if solid and State.cmd == "Cage"
                           and new ~= Enum.HumanoidStateType.Physics then
                            pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end)
                        end
                    end)
                end

                local function entry()
                    local e = State.cagePlan and State.cagePlan[me]
                    if not e then return nil end
                    local set = (e.f == "ground") and CAGE_GROUND or CAGE_AIR
                    local grp = set[e.n]
                    if not grp then return nil end
                    local sl  = grp[e.s]
                    if not sl then return nil end
                    return sl, e
                end

                -- Cached: runs twice a frame, answer changes only on respawn.
                local tPlayer = nil
                local function targetRoot(e)
                    if not e.t then return nil end
                    if not (tPlayer and tPlayer.Parent and tPlayer.Name == e.t) then
                        tPlayer = Players:FindFirstChild(e.t)
                    end
                    return tPlayer and tPlayer.Character
                           and tPlayer.Character:FindFirstChild("HumanoidRootPart")
                end

                -- The whole cell stands off while it is FOLLOWING, on every axis
                -- and not just the flat pieces. Anything that tracks a player and
                -- touches them is a feedback loop — the floor nudges them up, a
                -- wall nudges them sideways, the cell follows the nudge and does
                -- it again. Standing the walls off too means nothing in the cell
                -- can touch them until it stops moving, and then it closes.
                --
                -- Per-axis, not radial: the rotations in the layout are fixed, so
                -- a wall pushed along its own diagonal would face the wrong way
                -- and open a corner. Pushing each component along its own sign
                -- keeps every face parallel to where it started.
                --
                -- Components under a stud are alignment, not extent (the 45-degree
                -- lids carry a few hundredths on their cross axis), so they are
                -- left exactly where they were measured.
                local function offsetFor(sl, held)
                    local g = held and CAGE_FLOOR_GAP or CAGE_ESTABLISH
                    if g == 0 then return sl.p end
                    local function push(v)
                        if abs(v) < 1 then return v end
                        return v + ((v > 0) and g or -g)
                    end
                    local p = sl.p
                    return Vector3.new(push(p.X), push(p.Y), push(p.Z))
                end
                local function poseOf(sl, held)
                    return CFrame.new(offsetFor(sl, held)) * sl.r
                end

                local function hold()
                    if State.cmd ~= "Cage" then return end
                    local ch = LP.Character
                    local mR = ch and ch:FindFirstChild("HumanoidRootPart")
                    if not mR then return end

                    local sl, e = entry()
                    if not (sl and e) then return end

                    local tR = targetRoot(e)

                    -- A new generation means a new capture, so drop the freeze
                    -- and rebuild. Same generation, nothing recomputes.
                    local g = State.cageGen or 0
                    local key = table.concat({ g, e.f or "?", e.n or 0, e.s or 0, e.t or "?" }, "/")
                    if relKey ~= key then
                        relKey = key
                        relPark, relHeld = poseOf(sl, false), poseOf(sl, true)
                        frozen = nil
                        harden(ch)                  -- no momentum into the new pose
                    end
                    if not (relPark and relHeld) then return end

                    -- ── THE MODEL, AND NOTHING ELSE ──────────────────────
                    -- There is deliberately NO fallback here. A bot that has not
                    -- got the model yet must stand still and wait for it, because
                    -- the alternative — building off its own read of the target —
                    -- is a body that freezes somewhere nobody else agrees with.
                    -- One bot doing that is a hole in a wall, and a hole is worse
                    -- than an empty slot: an empty slot is at least visible.
                    --
                    -- The whole point of the average is that every bot stands on
                    -- ONE number. A private fallback throws that away in exactly
                    -- the situation it was built for.
                    local comp = State.cageBase and State.cageBase[e.t]
                    if not (comp and #comp == 12) then return end
                    local anchor = CFrame.new(table.unpack(comp))

                    mR.Anchored = false

                    if State.cageHold then
                        -- ── LOCK ─────────────────────────────────────────
                        -- Freeze on MAIN'S model: the one number every bot in the
                        -- cell shares, so the locked cell is the model and not
                        -- six opinions of it.
                        if not frozen then
                            frozen = anchor * relHeld
                            mR.CFrame = frozen      -- in position before anything else
                            physicsLock(ch)         -- 16: limbs go solid
                            solid = true
                        end

                        -- ── AND THE LINK STAYS ON ────────────────────────
                        -- State 16 shakes without it and state 0 doesn't, and
                        -- that difference is the whole tell: 16 leaves the limbs
                        -- collidable, so six bodies packed into a 1.75-stud shell
                        -- start resolving contacts against each other every
                        -- physics step. Our CFrame writes land on either side of
                        -- that step and never inside it, so the solver always
                        -- gets the last word on the position the wire samples.
                        --
                        -- Physrep takes the wire out of the solver's hands: what
                        -- replicates is an offset, not the shoved-around world
                        -- position. It is why 16 was rock solid in `shield` and
                        -- only ever shaky here, where we had let go of the link.
                        --
                        -- And this does NOT make the cage follow them. We write a
                        -- fixed WORLD CFrame; the client decomposes it against the
                        -- target and the server recomposes it against the target,
                        -- so the two cancel and the cell stays exactly where it
                        -- was put. The link is buying stability, not tracking.
                        if tR then physLink(tR, 16) else physUnlink(true) end
                        mR.CFrame = frozen
                        zeroVelAll(ch)           -- Physics state does not resist gravity
                    else
                        -- ── FOLLOW ───────────────────────────────────────
                        -- Written in the TARGET'S OWN FRAME from our own read,
                        -- exactly the way loopcircle does it. THAT is what makes
                        -- this a model instead of six bodies near each other.
                        --
                        -- Under physrep the thing on the wire is the offset, and
                        -- the offset here is relPark — a constant, identical on
                        -- every bot holding that slot. The server rebuilds all of
                        -- us against the one true target, so the formation is
                        -- exact on the server no matter what any client's copy of
                        -- the target looks like.
                        --
                        -- Writing main's world-space model here was the mistake:
                        -- a world point gets decomposed against OUR view of the
                        -- target before it is sent, so every bot shipped a
                        -- slightly different offset and the model came apart in
                        -- flight. Main's model is for the LOCK, where one shared
                        -- number is what matters.
                        --
                        -- Coming back from a lock, physicsUnlock has to run: it
                        -- kills the loop that is still hammering state 16, which
                        -- would otherwise out-shout the ChangeState(0) below and
                        -- leave us following with collidable limbs.
                        if solid then physicsUnlock(ch); solid = false end
                        if tR then
                            physLink(tR, 0)
                            mR.CFrame = tR.CFrame * relPark
                        else
                            mR.CFrame = anchor * relPark   -- blind: just hold the slot
                        end
                    end
                    zeroVel(mR)
                end

                conns[#conns+1] = RunService.Stepped:Connect(hold)
                conns[#conns+1] = RunService.Heartbeat:Connect(hold)

                while State.cmd == "Cage" do
                    local ch  = LP.Character
                    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                    if hum ~= watched then
                        watched = hum; guard(hum)
                        solid = false                   -- new body starts unlocked
                    end
                    if solid then physicsLock(ch) end   -- not before: it would fight state 0
                    animFreeze(ch, true)
                    task.wait(0.1)
                end

                for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
                local out = myRoot(); if out then out.Anchored = false end
                physUnlink()
                animFreeze(LP.Character, false)
                physicsUnlock(LP.Character)
                State.cageGen, State.cageHold, State.cageBase = nil, false, nil
            end)
        end }

    -- stopMotion runs long before this section exists, so it releases through a hook
    Miked._releaseCage = function()
        local c = LP.Character; if not c then return end
        local r = c:FindFirstChild("HumanoidRootPart"); if r then r.Anchored = false end
        animFreeze(c, false)
        physicsUnlock(c)
    end

    -- shields 1-5
    local function doShield(ctx, sn)
        local t = ctx.find(); if not (t and t.Character) then return end
        stopMotion(); task.wait(0.05); State.cmd="Shield"
        task.spawn(function()
            while State.cmd=="Shield" and t and t.Character do
                local mR = myRoot(); local tR = t.Character:FindFirstChild("HumanoidRootPart")
                if mR and tR then
                    physLink(tR, 16)   -- test bench: does physrep replicate in Physics state?
                    local h = myHum(); 
                    local idx, total = ctx.index, ctx.total   -- live
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
    -- set = the pattern table, forced = skip arg parsing (legacy /spiral7 form)
    local function runCurve(ctx, set, tag, defP, minP, maxP, forced)
        local pat, t, speed, range
        if forced then
            pat = forced
            speed, range, t = speedRangeTarget(ctx, 4, 10)
        else
            pat, t, speed, range = patternTarget(ctx, defP, 4, 10)
        end
        pat = math.clamp(math.floor(pat), minP, maxP)
        local curve = set[pat] or set[defP]
        if not curve then return end
        if not (t and t.Character) then return end
        stopMotion(); task.wait(0.05); State.cmd = tag
        local startT = tick()
        task.spawn(function()
            while State.cmd==tag and t and t.Character do
                local mR = myRoot(); local tR = t.Character:FindFirstChild("HumanoidRootPart")
                if mR and tR then
                    physLink(tR)
                    local h = myHum(); 
                    local idx, total = ctx.index, ctx.total   -- live: rebalances on join/leave
                    -- pattern vector is read in the TARGET'S frame, not world.
                    -- See physCF: this is what kills the tug at radius.
                    local pos = curve((tick()-startT)*(speed/4), idx, total, range)
                    mR.CFrame = physCF(tR, pos)
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

    -- pattern is the first arg now:  /spiral 5 me 4 12
    Miked.cmd{ name="orbit",  category="Orbits",  desc="Circular orbit · 21 patterns", args="[0-20] Target [spd] [r]",
        run=function(ctx) runCurve(ctx, Orbit, "Orbit", 0, 0, 20) end }
    Miked.cmd{ name="spiral", category="Spirals", desc="Ascending helix · 20 patterns", args="[1-20] Target [spd] [r]",
        run=function(ctx) runCurve(ctx, Spiral, "Spiral", 1, 1, 20) end }

    -- legacy /orbit7 /spiral7 forms still resolve, they just aren't listed
    for i=0,20 do Miked.cmd{ name="orbit"..i,  category="Orbits",  desc="Orbit pattern "..i,  args="Target [spd] [r]",
        run=function(ctx) runCurve(ctx, Orbit,  "Orbit",  0, 0, 20, i) end } end
    for i=1,20 do Miked.cmd{ name="spiral"..i, category="Spirals", desc="Spiral pattern "..i, args="Target [spd] [r]",
        run=function(ctx) runCurve(ctx, Spiral, "Spiral", 1, 1, 20, i) end } end

    -- ══ ACTION ══════════════════════════════════════════════════════════
    Miked.cmd{ name="helicopter", aliases={"heli"}, category="Action", desc="Overhead rotor mount", args="[spd] Target",
        run=function(ctx)
            local speed, t = speedTarget(ctx, 18)
            if not (t and t.Character) then return end
            stopMotion(); task.wait(0.05); State.cmd="Helicopter"
            task.spawn(function()
                while State.cmd=="Helicopter" and t and t.Character do
                    local mR = myRoot(); local tR = t.Character:FindFirstChild("HumanoidRootPart")
                    if mR and tR then
                        physLink(tR)
                        local h = myHum(); 
                        local myOff = ((ctx.index-1)/ctx.total)*PI2   -- live
                        local ang = myOff + tick()*speed
                        -- head height off the ROOT, not the Head part: physrep
                        -- binds to the root, so the head is one more replicated
                        -- transform to disagree about. 1.5 is where it sits.
                        local at = Vector3.new(0, 1.5, 0)
                        mR.CFrame = physCF(tR, at + Vector3.new(cos(ang)*6,0,sin(ang)*6),
                                           CFrame.Angles(math.rad(90),0,0), at)
                        mR.Velocity=Vector3.zero; mR.RotVelocity=Vector3.zero
                    end
                    RunService.Heartbeat:Wait()
                end
            end)
        end }

    Miked.cmd{ name="spin", category="Action", desc="Axial spin", args="[Speed]",
        run=function(ctx)
            local sp = tonumber(ctx.args[2]) or 20
            stopMotion(); task.wait(0.05); State.cmd="Spin"
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
            stopMotion()
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
            stopMotion(); local t = ctx.find()
            local r, h = myRoot(), myHum()
            if not (t and t.Character and r and h) then return end
            local tR = t.Character:FindFirstChild("HumanoidRootPart"); if not tR then return end
            r.CFrame = tR.CFrame*CFrame.new(0, 15+ctx.index*2, 0)
            zeroVel(r)
            if h.Sit then h.Sit=false end; h:MoveTo(r.Position)
            task.spawn(function()
                local ba=Instance.new("BodyAngularVelocity"); ba.MaxTorque=Vector3.new(1e6,1e6,1e6); ba.AngularVelocity=Vector3.new(0,150,0); ba.Parent=r; task.wait(0.6); ba:Destroy()
                r.Velocity=Vector3.new(Random.new():NextNumber(-60,60),Random.new():NextNumber(-30,-10),Random.new():NextNumber(-60,60))
                local c=LP.Character; if c then c:BreakJoints() end
            end)
        end }

    Miked.cmd{ name="vfling", aliases={"kill"}, category="Action", desc="Velocity fling", args="Target",
        run=function(ctx)
            stopMotion(); local t = ctx.find()
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
        stopMotion(); task.wait(0.05); State.cmd=tag
        if useHead then local mh=myHum();  end
        task.spawn(function()
            local step, inc = 0, true; local si = 0.45*spd
            while State.cmd==tag and t and t.Character and anchor.Parent do
                local mR = myRoot(); local h = myHum()
                if mR then
                    physLink(t.Character and t.Character:FindFirstChild("HumanoidRootPart"))
                    
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
                stopMotion(); task.wait(0.05); local tag=name:upper(); State.cmd=tag
                task.spawn(function()
                    local conn; conn = RunService.Heartbeat:Connect(function()
                        if State.cmd~=tag or not t.Character then conn:Disconnect() return end
                        local mR = myRoot(); local tR = t.Character:FindFirstChild("HumanoidRootPart")
                        if mR and tR then
                            physLink(tR)
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
    Miked.cmd{ name="stop", aliases={"unall","unf"}, category="System", desc="Halt movement + emotes", run=function() stopEverything() end }

    -- hard reset: drop the loops first so nothing keeps CFraming a corpse
    Miked.cmd{ name="reset", aliases={"respawn","kill"}, category="System", desc="Kill and respawn", botTarget=true,
        run=function(ctx)
            stopEverything()
            local c = LP.Character
            local h = ctx.hum()
            if h then pcall(function() h.Health = 0 end) end
            if c then pcall(function() c:BreakJoints() end) end
        end }

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

    -- Drop the kill plane instead of building a floor. Cheaper, no part to
    -- follow you, and it works everywhere the old platform did.
    local VOID_PROP = "FallenPartsDestroyHeight"
    -- streaming and respawns re-assert the property, so hold it rather than set once
    local function holdVoid()
        task.spawn(function()
            while State.antivoid do
                pcall(setHidden, workspace, VOID_PROP, 0)
                task.wait(1)
            end
        end)
    end
    Miked.cmd{ name="antivoid", category="Character", desc="Disable void death", solo=true,
        run=function()
            if State.antivoid or not setHidden then return end
            if State.avOrig == nil then
                local ok, v = pcall(function() return getHidden and getHidden(workspace, VOID_PROP) end)
                State.avOrig = (ok and tonumber(v)) or -500
            end
            State.antivoid = true
            holdVoid()
        end }
    Miked.cmd{ name="unantivoid", category="Character", desc="Restore void death", solo=true,
        run=function()
            State.antivoid = false
            if setHidden then pcall(setHidden, workspace, VOID_PROP, State.avOrig or -500) end
        end }

    -- State survives a re-exec but the hold loop doesn't, so restart it here.
    -- Also sweeps the platform an older build of this script may have left.
    task.spawn(function()
        local old = workspace:FindFirstChild("MikedAntiVoid")
        if old then pcall(function() old:Destroy() end) end
        State.avPart = nil
        if State.antivoid and setHidden then holdVoid() end
    end)

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
        task.spawn(function()
            pcall(function()
                local data = HttpService:JSONDecode(game:HttpGet(EMOTE_CATALOG_URL))
                Miked.Cache.emotes = data.data or data
            end)
        end)
    end

    for _, n in ipairs({"dance1","dance2","dance3"}) do
        Miked.cmd{ name=n, aliases=(n=="dance1" and {"dance","d"} or nil), category="Emotes", desc="Play "..n, solo=true,
            run=function()
                Miked.stopEmotes()   -- layers over movement: dancing orbit works
                local h = myHum(); if h then if h.Sit then h.Sit=false; task.wait(0.1) end
                    ChatSend("/e " .. (n=="dance1" and "dance" or n)) end
            end }
    end

    for i=1,8 do
        Miked.cmd{ name="emote"..i, category="Emotes", desc="Emote "..i, solo=true,
            run=function()
                Miked.stopEmotes()
                local h, r = myHum(), myRoot()
                if h and r then
                    h.Sit = false
                    -- these emotes normally need a still body to trigger cleanly, but
                    -- anchoring mid-orbit would fight the loop, so skip the settle then
                    local moving = State.cmd and State.cmd ~= "None"
                    if not moving then
                        h:MoveTo(r.Position); r.Velocity=Vector3.zero; r.RotVelocity=Vector3.zero
                        h.AutoRotate=false; r.Anchored=true; task.wait(0.2); r.Anchored=false
                        task.spawn(function() task.wait(0.5); local hh=myHum(); if hh then hh.AutoRotate=true end end)
                    end
                    ChatSend("/e emote"..i)
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
    Miked.cmd{ name="unemote", aliases={"undance"}, category="Emotes", desc="Stop emote, keep moving", botTarget=true,
        run=function() Miked.stopEmotes() end }

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
        Miked.stopMotion(); task.wait(0.05); State.cmd="HS"
        task.spawn(function()
            local idx, total = ctx.index, ctx.total
            local mR = myRoot(); if not mR then return end
            local origCF = mR.CFrame
            local ang = ((idx-1)/total)*(math.pi*2); local R = math.max(6, total*1.2)
            mR.CFrame = Miked.physCF(tR, Vector3.new(math.cos(ang)*R,0,math.sin(ang)*R)); mR.Velocity=Vector3.zero
            task.wait(0.3)
            ChatSend(HS_EMOTE[num] or "/e point")
            local holdEnd = tick()+20
            local lastChat = 0
            while State.cmd=="HS" and tick()<holdEnd do
                local m2, t2 = myRoot(), t.Character and t.Character:FindFirstChild("HumanoidRootPart")
                if m2 and t2 then Miked.physLink(t2); local a=((idx-1)/total)*(math.pi*2); m2.CFrame=Miked.physCF(t2, Vector3.new(math.cos(a)*R,0,math.sin(a)*R)); m2.Velocity=Vector3.zero end
                if tick()-lastChat > 3 then ChatSend(HS_MSG[num] or HS_MSG[1]); lastChat = tick() end   -- spam the line
                RunService.Heartbeat:Wait()
            end
            local cur = myRoot(); if cur then cur.CFrame = origCF; Miked.zeroVel(cur) end
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
            Miked.stopMotion(); task.wait(0.05); State.cmd="Rizz"
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
                if tR3 then mR.CFrame = CFrame.new(mR.Position, Vector3.new(tR3.Position.X, mR.Position.Y, tR3.Position.Z)); Miked.zeroVel(mR) end
                ChatSend(RIZZ[((idx-1)%#RIZZ)+1]); task.wait(4)
                while State.cmd=="Rizz" and t and t.Character do
                    local lR = t.Character:FindFirstChild("HumanoidRootPart")
                    if lR then Miked.physLink(lR); local sp=(idx/total)*(math.pi*2); mR.CFrame=Miked.physCF(lR, Vector3.new(math.cos(sp)*8,0,math.sin(sp)*8)); mR.Velocity=Vector3.zero end
                    RunService.Heartbeat:Wait()
                end
            end)
        end }

    -- ══ SOCIAL / CHAT ═══════════════════════════════════════════════════
    Miked.cmd{ name="mimic", category="Chat", desc="Parrot target's chat", args="Target", botTarget=true,
        run=function(ctx)
            local t = ctx.find(); if not t then return end
            if State.mimicConn then pcall(function() State.mimicConn:Disconnect() end) end
            local prefix = Config.prefix or "/"
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
            Miked.stopMotion(); State.cmd="NPC"; local idx = ctx.index
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
            if qot then
                qot('task.wait(3); pcall(function() loadstring(game:HttpGet("'..LOADER_URL..'"))() end)')
            end
            pcall(function() Teleport:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP) end)
        end }
    Miked.cmd{ name="quit", aliases={"exit","leave"}, category="System", desc="Leave game", solo=true,
        run=function() Miked.stopMotion(); task.delay(1, function() LP:Kick("Miked: Quit") end) end }

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
                    mR.CFrame=tR.CFrame*CFrame.new(0,0,3); Miked.zeroVel(mR); ChatSend("Accept Grab!")
                    local start,lc2,ok=tick(),0,false
                    while State.grab and (tick()-start)<15 do
                        if grabEv then pcall(function() grabEv:FireServer(t.UserId,"cute") end) end
                        if (mR.Position-tR.Position).Magnitude<1.7 then lc2+=1 else lc2=0 end
                        if lc2>=5 then ok=true break end; task.wait(0.2)
                    end
                    mR.CFrame=iR.CFrame*CFrame.new(0,0,3); Miked.zeroVel(mR); State.grab=false
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


-- ══ GUI (main-only · custom) ═════════════════════════════════════════════
if Miked.isMain then
    local TS  = game:GetService("TweenService")
    local UIS = game:GetService("UserInputService")
    local prefix = Config.prefix or "/"

    Miked.Cache.botStatus = Miked.Cache.botStatus or {}
    Miked.Socket.on("status", function(d) if d and d.name then Miked.Cache.botStatus[d.name]={d=d,t=tick()} end end)

    local P = {
        bg=Color3.fromRGB(16,20,28), panel=Color3.fromRGB(22,28,38), row=Color3.fromRGB(28,35,48),
        rowHov=Color3.fromRGB(36,45,60), open=Color3.fromRGB(32,40,54),
        stroke=Color3.fromRGB(42,52,68), accent=Color3.fromRGB(70,132,255), accent2=Color3.fromRGB(96,178,255),
        text=Color3.fromRGB(235,240,248), dim=Color3.fromRGB(134,144,162), faint=Color3.fromRGB(92,102,122),
        green=Color3.fromRGB(120,255,190),
    }
    local CATCOL = {
        Movement=Color3.fromRGB(76,154,255), Formations=Color3.fromRGB(255,162,60), Orbits=Color3.fromRGB(176,108,255),
        Spirals=Color3.fromRGB(138,92,255), Action=Color3.fromRGB(255,92,92), Character=Color3.fromRGB(92,200,255),
        Emotes=Color3.fromRGB(255,201,76), Chat=Color3.fromRGB(76,224,138), Info=Color3.fromRGB(154,166,188), System=Color3.fromRGB(255,122,122),
    }
    local function C(cls,pr,par) local i=Instance.new(cls); for k,v in pairs(pr) do i[k]=v end; if par then i.Parent=par end; return i end
    local function corner(o,r) C("UICorner",{CornerRadius=UDim.new(0,r or 8)},o) end
    local function stroke(o,c,t) C("UIStroke",{Color=c or P.stroke,Thickness=t or 1,Transparency=0.1},o) end
    local function tween(o,pr,t) TS:Create(o,TweenInfo.new(t or 0.13,Enum.EasingStyle.Quad),pr):Play() end
    local function hasTarget(e) for _,k in ipairs(e.order or {}) do if k=="target" then return true end end return false end
    local ACC = ColorSequence.new(Color3.fromRGB(70,132,255), Color3.fromRGB(96,178,255))   -- blue signature gradient
    local function grad(o,cs,rot) return C("UIGradient",{Color=cs,Rotation=rot or 0},o) end

    local CAT = {
        {n="bring",c="Movement",d="Teleport bots to target",ex="!bring me",order={"target"},doc="Snaps all bots onto the target in a packed grid."},
        {n="goto",c="Movement",d="Teleport in a ring",ex="!goto me",order={"target"},doc="Bots teleport around the target facing inward."},
        {n="follow",c="Movement",d="Follow the target",ex="!follow me",order={"target"},doc="Bots trail the target in a ring, keeping pace. Loops until stop."},
        {n="walkto",c="Movement",d="Walk to target",ex="!walkto me",order={"target"},doc="Bots pathfind to a grid around the target."},
        {n="stalk",c="Movement",d="Trail from behind",ex="!stalk x",order={"target"},doc="Holds formation directly behind the target, snapping back if they sprint."},
        {n="worm",c="Movement",d="Snake chain",ex="!worm me",order={"target"},doc="Bots form a follow-the-leader snake."},
        {n="carpet",c="Movement",d="Rolling floor under target",ex="!carpet me",order={"target"},doc="Bots lie flat and tile a moving carpet beneath the target."},
        {n="swarm",c="Movement",d="Chaotic swarm",ex="!swarm me 40 15",order={"target"},doc="Bots dash between random points around the target. Optional: !swarm <target> <speed> <range> — speed 0 leaves walkspeed default."},
        {n="swarm2",c="Movement",d="3D bee dome",ex="!swarm2 me 14 34",order={"target"},doc="Bots fly around the target in a 3D dome like bees — each one darts to its own point, holds a beat, then picks another. Usage: !swarm2 <target> [range] [speed]. Defaults 14 and 34. Also !bees / !hive."},
        {n="scatter",c="Movement",d="Random scatter",ex="!scatter 30",order={},doc="Bots jump to random nearby points. Optional range: !scatter 30."},
        {n="circle",c="Formations",d="Snap to a circle",ex="!circle me",order={"target"},doc="Ring formation around the target; radius auto-scales to bot count."},
        {n="arrow",c="Formations",d="V / arrowhead",ex="!arrow me",order={"target"},doc="Arrowhead aimed along the target's facing direction."},
        {n="box",c="Formations",d="Square array",ex="!box me",order={"target"},doc="Grid box centered on the target."},
        {n="cage",c="Formations",d="Seal targets in body cages",ex="!cage x",order={"target"},doc="Bots build a sealed cell around the target, with a lid just above their head so there's no room to jump. While it's following, each bot is physics-linked into the target's frame, so the cell is exactly right at every instant no matter how they move. Your client waits for them to stand still, then tells the bots to stop — and stopping is just staying where they already are, so nothing shifts. Layouts are hand-built and tested: 6, 8, 10 and 16 in the air, 8 and 12 on the ground. Bare !cage means !cage me; every argument is a target, so !cage x y builds two cells. !stop releases."},
        {n="stackon",c="Formations",d="Vertical tower",ex="!stackon me",order={"target"},doc="Bots stack straight up on the target."},
        {n="rline",c="Formations",d="Right / left / front / back line",ex="!rline me",order={"target"},doc="Lines off the target — also lline, fline, bline."},
        {n="shield",c="Formations",d="Protective shield 1-5",ex="!shield3 me",variants=5,vmin=1,order={"target"},doc="shield1-5: wall, arc, wedge, double-wall, full enclosure."},
        {n="orbit",c="Orbits",d="Circular orbit · 21 patterns",ex="!orbit 5 me 4 12",order={"target"},doc="Bots revolve around the target. Usage: !orbit <pattern 0-20> <target> [speed] [range]. Patterns: flat, helix, atomic, galaxy, vortex, rose and more. Everything after the pattern is optional — !orbit alone gives pattern 0 on you."},
        {n="spiral",c="Spirals",d="Ascending helix · 20 patterns",ex="!spiral 5 me 4 12",order={"target"},doc="Orbit with vertical motion. Usage: !spiral <pattern 1-20> <target> [speed] [range]. Patterns: DNA ladder, tornado, fountain, galaxy arm. The old !spiral5 form still works too."},
        {n="helicopter",c="Action",d="Rotor around head",ex="!helicopter me 20",order={"target"},doc="Bots go flat and spin around the target like rotor blades. Optional speed after target."},
        {n="nuke",c="Action",d="Drop from above",ex="!nuke x",order={"target"},doc="Teleport overhead then plummet spinning onto the target."},
        {n="vfling",c="Action",d="Velocity fling",ex="!vfling x",order={"target"},doc="Fling the target away with velocity."},
        {n="bang",c="Action",d="Rear / front / multi engage",ex="!bang x",order={"target"},doc="Also fbang (front, spin-locked) and mbang (group)."},
        {n="rizz",c="Action",d="Approach + line",ex="!rizz x",order={"target"},doc="Bots queue up, approach one by one, deliver a line, then orbit."},
        {n="hs",c="Action",d="Surround + spam taunt · 1-20",ex="!hs7 x",variants=20,vmin=1,order={"target"},doc="Ring the target and loop a taunt ~20s. hs1-20 = different lines."},
        {n="spin",c="Action",d="Spin in place",ex="!spin 30",order={},doc="Bots rotate on their Y axis. Optional speed: !spin 30."},
        {n="firework",c="Action",d="Launch skyward",ex="!firework",order={},doc="Bots rocket up then ragdoll."},
        {n="mirror",c="Action",d="Mirror target",ex="!mirror x",order={"target"},doc="Bots copy the target's movement."},
        {n="ws",c="Character",d="Set walkspeed",ex="!ws 80",order={},doc="Override and lock walkspeed until !unws. Usage: !ws 80."},
        {n="noclip",c="Character",d="Disable collisions",ex="!noclip",order={},doc="Bots pass through parts. Use !clip to restore."},
        {n="invisible",c="Character",d="Go invisible",ex="!invisible",order={},doc="Emote-based invisibility. Use !visible to revert."},
        {n="freeze",c="Character",d="Anchor in place",ex="!freeze",order={},doc="Lock bots where they stand. !unfreeze releases."},
        {n="antivoid",c="Character",d="Disable void death",ex="!antivoid",order={},doc="Sets workspace FallenPartsDestroyHeight to 0 so bots stop dying to the void. Re-asserted every second because streaming resets it. !unantivoid restores the original height."},
        {n="dance",c="Emotes",d="Dance emote",ex="!dance",order={},doc="Play dance 1. Also dance2 / dance3. Layers on top of movement, so !orbit then !dance gives you a dancing orbit. !unemote drops the dance and keeps moving; !stop kills both."},
        {n="emote",c="Emotes",d="Play catalog emote",ex="!emote salute",order={},doc="Search the 35k emote catalog by name. Usage: !emote <name>. !sync aligns it across bots."},
        {n="say",c="Chat",d="Broadcast message",ex="!say hello",order={},doc="All bots say it, staggered. Usage: !say <message>."},
        {n="spam",c="Chat",d="Loop a message",ex="!spam 2 hi",order={},doc="Repeat every N seconds. Usage: !spam <delay> <message>. !unspam stops."},
        {n="mimic",c="Chat",d="Parrot target chat",ex="!mimic x",order={"target"},doc="Bots repeat what the target types. !unmimic stops."},
        {n="npc",c="Chat",d="Wander + one-liners",ex="!npc",order={},doc="Bots roam randomly and drop lines — ambiance."},
        {n="countdown",c="Chat",d="Staggered countdown",ex="!countdown 5",order={},doc="Bots count down together. Usage: !countdown 5."},
        {n="ping",c="Info",d="Report ping",ex="!ping",order={},doc="Each bot chats its network ping."},
        {n="altcount",c="Info",d="Count online bots",ex="!altcount",order={},doc="Reports how many bots are in the server."},
        {n="stop",c="System",d="Halt everything",ex="!stop",order={},doc="Cancels formations, loops, and dances."},
        {n="reset",c="System",d="Kill and respawn",ex="!reset",order={},doc="Sets health to 0 and breaks joints, forcing a clean respawn. Stops all commands first. Also !respawn / !kill, and !reset bot3 targets one bot."},
        {n="rejoin",c="System",d="Rejoin + return",ex="!rejoin",order={},doc="Teleport to a fresh server, re-inject, and return to spot."},
    }

    -- docs are written with "!" but the live prefix is whatever Config says,
    -- so rewrite once at build time instead of hardcoding it in 40 strings
    do
        local PFX = Config.prefix or "/"
        if PFX ~= "!" then
            for _, e in ipairs(CAT) do
                if e.ex  then e.ex  = e.ex:gsub("!", PFX) end
                if e.doc then e.doc = e.doc:gsub("!", PFX) end
            end
        end
    end

    -- On autoexec the client UI layer isn't up yet and the hidden-GUI container
    -- can be wiped mid-load, so wait for PlayerGui then watchdog the parent.
    LP:WaitForChild("PlayerGui", 20)
    local function guiHost()
        return (gethui and gethui()) or (get_hidden_gui and get_hidden_gui())
            or LP:FindFirstChild("PlayerGui") or game:GetService("CoreGui")
    end
    local guiParent = guiHost()
    pcall(function() local o=guiParent:FindFirstChild("MikedUI"); if o then o:Destroy() end end)
    local SG=C("ScreenGui",{Name="MikedUI",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=999,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},guiParent)
    -- re-parent if the container gets cleared out from under us during load
    task.spawn(function()
        for _ = 1, 30 do
            task.wait(1)
            if not SG.Parent then pcall(function() SG.Parent = guiHost() end) end
        end
    end)
    local WW,WH=330,508
    -- draggable wrapper so the drop-shadow travels with the window
    local root=C("Frame",{Name="Miked",Size=UDim2.fromOffset(WW,WH),Position=UDim2.new(0.5,-WW/2,0.5,-WH/2),BackgroundTransparency=1},SG)
    C("ImageLabel",{Size=UDim2.new(1,60,1,60),Position=UDim2.new(0.5,0,0.5,6),AnchorPoint=Vector2.new(0.5,0.5),BackgroundTransparency=1,Image="rbxassetid://6014261993",ImageColor3=Color3.new(0,0,0),ImageTransparency=0.4,ScaleType=Enum.ScaleType.Slice,SliceCenter=Rect.new(49,49,450,450),ZIndex=0},root)
    local win=C("Frame",{Name="Window",Size=UDim2.new(1,0,1,0),BackgroundColor3=Color3.new(1,1,1),BorderSizePixel=0,ClipsDescendants=true,ZIndex=1},root)
    grad(win, ColorSequence.new(Color3.fromRGB(28,35,48), Color3.fromRGB(14,18,25)), 90)   -- vertical depth
    corner(win,16)
    local wStroke=C("UIStroke",{Thickness=1.4,Transparency=0.35},win); grad(wStroke, ACC, 40) -- gradient border
    -- scale-pop when shown
    local wScale=C("UIScale",{Scale=1},root)
    local function popIn() wScale.Scale=0.9; TS:Create(wScale,TweenInfo.new(0.26,Enum.EasingStyle.Back,Enum.EasingDirection.Out),{Scale=1}):Play() end

    -- title bar: name + minus
    local tbar=C("Frame",{Size=UDim2.new(1,0,0,36),BackgroundColor3=Color3.new(1,1,1),BorderSizePixel=0},win)
    grad(tbar, ColorSequence.new(Color3.fromRGB(24,31,43), Color3.fromRGB(15,20,28)), 90)
    C("Frame",{Size=UDim2.new(1,0,0,1.5),Position=UDim2.new(0,0,1,-1.5),BackgroundColor3=Color3.new(1,1,1),BorderSizePixel=0,ZIndex=2},tbar).Name="accentline"
    local aline=tbar:FindFirstChild("accentline"); grad(aline,ACC,0)
    local lg=C("Frame",{Size=UDim2.fromOffset(18,18),Position=UDim2.new(0,12,0.5,-9),BackgroundColor3=Color3.new(1,1,1),BorderSizePixel=0},tbar); corner(lg,5); grad(lg,ACC,45)
    C("TextLabel",{Size=UDim2.new(1,0,1,0),BackgroundTransparency=1,Text="M",TextColor3=Color3.new(1,1,1),Font=Enum.Font.GothamBold,TextSize=11},lg)
    C("TextLabel",{Size=UDim2.fromOffset(90,36),Position=UDim2.new(0,38,0,0),BackgroundTransparency=1,Text="Miked",TextColor3=P.text,Font=Enum.Font.GothamBold,TextSize=15,TextXAlignment=Enum.TextXAlignment.Left},tbar)
    local minB=C("TextButton",{Size=UDim2.fromOffset(24,24),Position=UDim2.new(1,-32,0.5,-12),BackgroundColor3=P.row,Text="—",TextColor3=P.dim,Font=Enum.Font.GothamBold,TextSize=14,AutoButtonColor=false,BorderSizePixel=0},tbar); corner(minB,6)

    -- tab row (2 tabs, full width segmented)
    local tabRow=C("Frame",{Size=UDim2.new(1,-16,0,30),Position=UDim2.new(0,8,0,42),BackgroundColor3=P.panel,BorderSizePixel=0},win); corner(tabRow,8)
    local views,tabBtns={},{}
    local function selectTab(name)
        for n,v in pairs(views) do v.Visible=(n==name) end
        for n,t in pairs(tabBtns) do
            local on=(n==name)
            tween(t.b,{BackgroundColor3 = on and P.accent or P.panel})
            t.b.TextColor3 = on and Color3.new(1,1,1) or P.dim
        end
    end
    local function mkTab(name,i)
        local b=C("TextButton",{Size=UDim2.new(0.5,-4,1,-6),Position=UDim2.new(i==1 and 0 or 0.5,i==1 and 3 or 1,0,3),BackgroundColor3=P.panel,Text=name,TextColor3=P.dim,Font=Enum.Font.GothamBold,TextSize=13,AutoButtonColor=false,BorderSizePixel=0},tabRow); corner(b,6)
        b.MouseButton1Click:Connect(function() selectTab(name) end); tabBtns[name]={b=b}
    end
    mkTab("Commands",1); mkTab("Info",2)

    local host=C("Frame",{Size=UDim2.new(1,0,1,-124),Position=UDim2.new(0,0,0,78),BackgroundTransparency=1},win)

    -- big command bar (bottom)
    local bar=C("Frame",{Size=UDim2.new(1,-16,0,42),Position=UDim2.new(0,8,1,-48),BackgroundColor3=P.row,BorderSizePixel=0},win); corner(bar,12)
    local barStroke=C("UIStroke",{Color=P.accent,Thickness=1.2,Transparency=0.55,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},bar)
    C("TextLabel",{Size=UDim2.fromOffset(20,42),Position=UDim2.new(0,13,0,0),BackgroundTransparency=1,Text="›",TextColor3=P.accent2,Font=Enum.Font.GothamBold,TextSize=18},bar)
    local barIn=C("TextBox",{Size=UDim2.new(1,-90,1,0),Position=UDim2.new(0,34,0,0),BackgroundTransparency=1,PlaceholderText="type a command…",PlaceholderColor3=P.faint,Text="",TextColor3=P.text,Font=Enum.Font.Code,TextSize=14,TextXAlignment=Enum.TextXAlignment.Left,ClearTextOnFocus=false},bar)
    local runB=C("TextButton",{Size=UDim2.fromOffset(48,30),Position=UDim2.new(1,-56,0.5,-15),BackgroundColor3=P.accent,Text="▸",TextColor3=Color3.new(1,1,1),Font=Enum.Font.GothamBold,TextSize=16,AutoButtonColor=false,BorderSizePixel=0},bar); corner(runB,7)
    local function runBar()
        local v=barIn.Text:gsub("^%s+",""):gsub("%s+$","")
        if v=="" then return end
        if v:sub(1,#prefix)~=prefix then v=prefix..v end
        Miked.send(v); barIn.Text=""
        runB.BackgroundColor3=P.green; task.delay(0.18,function() tween(runB,{BackgroundColor3=P.accent},0.25) end)
    end
    runB.MouseButton1Click:Connect(runBar)
    barIn.Focused:Connect(function() tween(barStroke,{Transparency=0.1},0.15) end)
    barIn.FocusLost:Connect(function(enter) tween(barStroke,{Transparency=0.55},0.15); if enter then runBar() end end)
    local function loadBar(text) barIn.Text=text; barIn:CaptureFocus() end

    -- ══ COMMANDS VIEW (search + accordion list, full width) ══
    local cmdView=C("Frame",{Size=UDim2.new(1,0,1,0),BackgroundTransparency=1},host); views["Commands"]=cmdView
    local srchF=C("Frame",{Size=UDim2.new(1,-16,0,30),Position=UDim2.new(0,8,0,0),BackgroundColor3=P.panel,BorderSizePixel=0},cmdView); corner(srchF,8); stroke(srchF)
    C("TextLabel",{Size=UDim2.fromOffset(18,30),Position=UDim2.new(0,10,0,0),BackgroundTransparency=1,Text="⌕",TextColor3=P.dim,Font=Enum.Font.Gotham,TextSize=14},srchF)
    local srch=C("TextBox",{Size=UDim2.new(1,-38,1,0),Position=UDim2.new(0,30,0,0),BackgroundTransparency=1,PlaceholderText="search commands…",PlaceholderColor3=P.faint,Text="",TextColor3=P.text,Font=Enum.Font.Gotham,TextSize=13,TextXAlignment=Enum.TextXAlignment.Left,ClearTextOnFocus=false},srchF)

    local listF=C("ScrollingFrame",{Size=UDim2.new(1,-16,1,-40),Position=UDim2.new(0,8,0,38),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=P.accent,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y},cmdView)
    C("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3)},listF)
    C("UIPadding",{PaddingBottom=UDim.new(0,6),PaddingRight=UDim.new(0,4)},listF)

    local openRow, openCollapse = nil, nil
    local rows={}
    local order,groups={},{}
    for _,e in ipairs(CAT) do if not groups[e.c] then groups[e.c]={}; order[#order+1]=e.c end; table.insert(groups[e.c],e) end
    local li=0
    for _,cat in ipairs(order) do
        li+=1
        local col=CATCOL[cat] or P.dim
        local head=C("Frame",{Size=UDim2.new(1,0,0,18),BackgroundTransparency=1,LayoutOrder=li},listF)
        C("Frame",{Size=UDim2.fromOffset(3,10),Position=UDim2.new(0,2,0.5,-5),BackgroundColor3=col,BorderSizePixel=0},head)
        C("TextLabel",{Size=UDim2.new(1,-12,1,0),Position=UDim2.new(0,10,0,0),BackgroundTransparency=1,Text=cat:upper(),TextColor3=col,Font=Enum.Font.GothamBold,TextSize=9.5,TextXAlignment=Enum.TextXAlignment.Left},head)

        for _,e in ipairs(groups[cat]) do
            li+=1
            -- glass card
            local cont=C("Frame",{Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,BackgroundColor3=P.row,BackgroundTransparency=0.2,BorderSizePixel=0,LayoutOrder=li,ClipsDescendants=true},listF); corner(cont,10)
            local cStroke=C("UIStroke",{Color=P.accent,Thickness=1,Transparency=0.82,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},cont)
            -- left accent tab (overlays; grows on hover) — sits outside the list flow
            local tab=C("Frame",{Size=UDim2.new(0,4,1,0),Position=UDim2.new(0,0,0,0),BackgroundColor3=P.accent,BorderSizePixel=0,ZIndex=3},cont); grad(tab,ACC,90)
            -- inner holds the vertical layout
            local inner=C("Frame",{Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,BackgroundTransparency=1},cont)
            C("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder},inner)

            local hd=C("TextButton",{Size=UDim2.new(1,0,0,44),BackgroundTransparency=1,Text="",AutoButtonColor=false,LayoutOrder=1,ZIndex=2},inner)
            C("TextLabel",{Size=UDim2.new(1,-96,0,16),Position=UDim2.new(0,16,0,8),BackgroundTransparency=1,Text=prefix..e.n,TextColor3=P.text,Font=Enum.Font.GothamBold,TextSize=14,TextXAlignment=Enum.TextXAlignment.Left},hd)
            C("TextLabel",{Size=UDim2.new(1,-96,0,14),Position=UDim2.new(0,16,0,24),BackgroundTransparency=1,Text=e.d,TextColor3=P.dim,Font=Enum.Font.Gotham,TextSize=11.5,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd},hd)
            -- category badge (pill)
            local badge=C("TextLabel",{AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-30,0,9),Size=UDim2.fromOffset(0,17),AutomaticSize=Enum.AutomaticSize.X,BackgroundColor3=col,BackgroundTransparency=0.8,Text=cat,TextColor3=col,Font=Enum.Font.GothamMedium,TextSize=10,ZIndex=2},hd); corner(badge,8)
            C("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},badge)
            local chev=C("TextLabel",{Size=UDim2.fromOffset(22,44),Position=UDim2.new(1,-26,0,0),BackgroundTransparency=1,Text="+",TextColor3=P.faint,Font=Enum.Font.GothamBold,TextSize=17,ZIndex=2},hd)

            -- expanded detail
            local det=C("Frame",{Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,BackgroundTransparency=1,Visible=false,LayoutOrder=2,ZIndex=2},inner)
            C("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,8)},det)
            C("UIPadding",{PaddingLeft=UDim.new(0,16),PaddingRight=UDim.new(0,14),PaddingBottom=UDim.new(0,13),PaddingTop=UDim.new(0,2)},det)
            C("Frame",{Size=UDim2.new(1,0,0,1),BackgroundColor3=P.stroke,BorderSizePixel=0,LayoutOrder=0},det)
            C("TextLabel",{Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,BackgroundTransparency=1,Text=e.doc,TextColor3=P.dim,Font=Enum.Font.Gotham,TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,LineHeight=1.12,LayoutOrder=1},det)
            C("TextLabel",{Size=UDim2.new(1,0,0,14),BackgroundTransparency=1,Text="›  "..e.ex,TextColor3=P.accent2,Font=Enum.Font.Code,TextSize=11.5,TextXAlignment=Enum.TextXAlignment.Left,LayoutOrder=2},det)
            local brow=C("Frame",{Size=UDim2.new(1,0,0,30),BackgroundTransparency=1,LayoutOrder=3},det)
            local runQ=C("TextButton",{Size=UDim2.new(0.52,-4,1,0),BackgroundColor3=P.accent,Text="Run",TextColor3=Color3.new(1,1,1),Font=Enum.Font.GothamBold,TextSize=13,AutoButtonColor=false,BorderSizePixel=0},brow); corner(runQ,8); grad(runQ,ACC,20)
            local toBar=C("TextButton",{Size=UDim2.new(0.48,-4,1,0),Position=UDim2.new(0.52,4,0,0),BackgroundColor3=P.open,Text="✎ edit",TextColor3=P.text,Font=Enum.Font.GothamMedium,TextSize=12.5,AutoButtonColor=false,BorderSizePixel=0},brow); corner(toBar,8); stroke(toBar,P.accent,1,0.6)
            runQ.MouseButton1Click:Connect(function() Miked.send(prefix..e.n..(hasTarget(e) and " me" or "")); tween(runQ,{BackgroundTransparency=0.4},0.1); task.delay(0.18,function() tween(runQ,{BackgroundTransparency=0},0.25) end) end)
            toBar.MouseButton1Click:Connect(function() loadBar(e.ex) end)

            hd.MouseEnter:Connect(function()
                if openRow~=cont then tween(cont,{BackgroundTransparency=0},0.16); tween(cStroke,{Transparency=0.3},0.16) end
                tween(tab,{Size=UDim2.new(0,6,1,0)},0.16)
            end)
            hd.MouseLeave:Connect(function()
                if openRow~=cont then tween(cont,{BackgroundTransparency=0.2},0.16); tween(cStroke,{Transparency=0.82},0.16); tween(tab,{Size=UDim2.new(0,4,1,0)},0.16) end
            end)
            local function collapse() det.Visible=false; chev.Text="+"; tween(cont,{BackgroundTransparency=0.2},0.15); tween(cStroke,{Transparency=0.82},0.15); tween(tab,{Size=UDim2.new(0,4,1,0)},0.15) end
            hd.MouseButton1Click:Connect(function()
                if openRow==cont then collapse(); openRow=nil; openCollapse=nil
                else
                    if openCollapse then openCollapse() end
                    det.Visible=true; chev.Text="–"
                    tween(cont,{BackgroundTransparency=0},0.15); tween(cStroke,{Transparency=0.3},0.15); tween(tab,{Size=UDim2.new(0,6,1,0)},0.15)
                    openRow=cont; openCollapse=collapse
                end
            end)
            table.insert(rows,{cont=cont,head=head,e=e,cat=cat})
        end
    end
    srch:GetPropertyChangedSignal("Text"):Connect(function()
        local q=srch.Text:lower(); local shown={}
        for _,r in ipairs(rows) do
            local ok=q=="" or r.e.n:find(q,1,true) or r.e.d:lower():find(q,1,true) or r.cat:lower():find(q,1,true)
            r.cont.Visible=ok; if ok then shown[r.cat]=true end
        end
        for _,cat in ipairs(order) do for _,r in ipairs(rows) do if r.cat==cat then r.head.Visible=(q==""or shown[cat]==true); break end end end
    end)

    -- ══ INFO VIEW (stats + roster, full width) ══
    local infoView=C("Frame",{Size=UDim2.new(1,0,1,0),BackgroundTransparency=1,Visible=false},host); views["Info"]=infoView
    local tiles={}
    local tileW=(WW-16-8)/2
    for i,def in ipairs({{"BOTS",P.accent},{"AVG PING",P.accent2},{"UPTIME",P.green},{"REPORTING",P.text}}) do
        local cx=8+((i-1)%2)*(tileW+8); local cy=4+math.floor((i-1)/2)*54
        local t=C("Frame",{Size=UDim2.fromOffset(tileW,48),Position=UDim2.new(0,cx,0,cy),BackgroundColor3=P.panel,BorderSizePixel=0},infoView); corner(t,8); stroke(t)
        C("TextLabel",{Size=UDim2.new(1,-16,0,11),Position=UDim2.new(0,10,0,7),BackgroundTransparency=1,Text=def[1],TextColor3=P.faint,Font=Enum.Font.GothamBold,TextSize=9,TextXAlignment=Enum.TextXAlignment.Left},t)
        tiles[i]=C("TextLabel",{Size=UDim2.new(1,-16,0,22),Position=UDim2.new(0,10,0,20),BackgroundTransparency=1,Text="—",TextColor3=def[2],Font=Enum.Font.Code,TextSize=20,TextXAlignment=Enum.TextXAlignment.Left},t)
    end
    local rosterF=C("ScrollingFrame",{Size=UDim2.new(1,-16,1,-124),Position=UDim2.new(0,8,0,118),BackgroundColor3=P.panel,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=P.accent,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y},infoView)
    corner(rosterF,9); stroke(rosterF)
    C("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4)},rosterF)
    C("UIPadding",{PaddingTop=UDim.new(0,8),PaddingBottom=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},rosterF)

    task.spawn(function()
        while SG.Parent do
            local live,total,sumP={},0,0
            for name,rec in pairs(Miked.Cache.botStatus) do
                if tick()-rec.t < 9 then live[name]=rec.d; total+=1; sumP+=(rec.d.ping or 0) else Miked.Cache.botStatus[name]=nil end
            end
            local up=tick()-(Miked.State.startTime or tick())
            tiles[1].Text=tostring(Miked.roster.total())
            tiles[2].Text=(total>0 and math.floor(sumP/total) or 0).." ms"
            tiles[3].Text=("%dm %ds"):format(math.floor(up/60),math.floor(up%60))
            tiles[4].Text=tostring(total)
            if infoView.Visible then
                for _,c in ipairs(rosterF:GetChildren()) do if not (c:IsA("UIListLayout") or c:IsA("UIPadding")) then c:Destroy() end end
                local sorted={}; for _,d in pairs(live) do sorted[#sorted+1]=d end
                table.sort(sorted,function(a,b) return (a.idx or 0)<(b.idx or 0) end)
                if #sorted==0 then
                    C("TextLabel",{Size=UDim2.new(1,0,0,28),BackgroundTransparency=1,Text="no bots reporting yet…",TextColor3=P.faint,Font=Enum.Font.Gotham,TextSize=12},rosterF)
                else
                    for _,d in ipairs(sorted) do
                        local r=C("Frame",{Size=UDim2.new(1,0,0,36),BackgroundColor3=P.row,BorderSizePixel=0},rosterF); corner(r,7)
                        C("TextLabel",{Size=UDim2.fromOffset(30,36),Position=UDim2.new(0,6,0,0),BackgroundTransparency=1,Text="#"..(d.idx or "?"),TextColor3=P.accent,Font=Enum.Font.Code,TextSize=12},r)
                        C("TextLabel",{Size=UDim2.new(0.55,0,0,15),Position=UDim2.new(0,40,0,4),BackgroundTransparency=1,Text=d.name,TextColor3=P.text,Font=Enum.Font.GothamMedium,TextSize=12.5,TextXAlignment=Enum.TextXAlignment.Left},r)
                        C("TextLabel",{Size=UDim2.new(0.55,0,0,13),Position=UDim2.new(0,40,0,18),BackgroundTransparency=1,Text=(d.cmd or "None"),TextColor3=P.accent2,Font=Enum.Font.Code,TextSize=10.5,TextXAlignment=Enum.TextXAlignment.Left},r)
                        C("TextLabel",{Size=UDim2.fromOffset(60,36),Position=UDim2.new(1,-66,0,0),BackgroundTransparency=1,Text=(d.ping or 0).." ms",TextColor3=P.dim,Font=Enum.Font.Code,TextSize=11,TextXAlignment=Enum.TextXAlignment.Right},r)
                    end
                end
            end
            task.wait(2)
        end
    end)

    -- minimize / drag / toggle
    local icon=C("TextButton",{Size=UDim2.fromOffset(46,46),Position=UDim2.new(0,16,1,-62),BackgroundColor3=P.accent,Text=">_",TextColor3=Color3.new(1,1,1),Font=Enum.Font.GothamBold,TextSize=17,AutoButtonColor=false,BorderSizePixel=0,Visible=false},SG); corner(icon,13); grad(icon,ACC,45); stroke(icon,P.accent2,1.4,0.3)
    C("ImageLabel",{Size=UDim2.new(1,26,1,26),Position=UDim2.new(0.5,0,0.5,4),AnchorPoint=Vector2.new(0.5,0.5),BackgroundTransparency=1,Image="rbxassetid://6014261993",ImageColor3=Color3.new(0,0,0),ImageTransparency=0.45,ScaleType=Enum.ScaleType.Slice,SliceCenter=Rect.new(49,49,450,450),ZIndex=0},icon)
    local function minim() root.Visible=false; icon.Visible=true end
    local function restore() icon.Visible=false; root.Visible=true; popIn() end
    minB.MouseButton1Click:Connect(minim); icon.MouseButton1Click:Connect(restore)
    UIS.InputBegan:Connect(function(inp,gp)
        if inp.KeyCode==Enum.KeyCode.RightShift and not gp then
            if root.Visible then minim() else restore() end
        elseif inp.KeyCode==Enum.KeyCode.Quote and not gp then   -- ' jumps to the command bar
            if not root.Visible then restore() end
            local before=barIn.Text
            barIn:CaptureFocus()
            task.spawn(function() task.wait(); if barIn.Text~=before then barIn.Text=before end; barIn.CursorPosition=#barIn.Text+1 end)
        end
    end)

    -- native drag via UIDragDetector (grabs empty areas incl. the title bar)
    local dragDet = Instance.new("UIDragDetector")
    dragDet.Parent = root

    selectTab("Commands")
    popIn()
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
    local RunService  = game:GetService("RunService")

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
    local FPS = Config.fpsCap or 15

    -- Fast flags are set at the very top of this file, above the Socket fetch
    -- and the load wait. Setting them down here would always be too late.
    pcall(function() if setfpscap then setfpscap(FPS) end end)
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    pcall(function() settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level04 end)
    pcall(function() Lighting.GlobalShadows=false; Lighting.FogEnd=1e10 end)
    pcall(function() RunService:Set3dRenderingEnabled(false) end)   -- biggest single win

    -- Material system: every MaterialVariant is a texture set the client keeps
    -- resident. Nothing references them once every part is SmoothPlastic.
    pcall(function()
        local MS = game:GetService("MaterialService")
        MS.Use2022Materials = false
        for _, v in ipairs(MS:GetChildren()) do
            if v:IsA("MaterialVariant") then v:Destroy() end
        end
    end)

    -- Terrain is skipped by the strip walk (clearing it drops bots through the
    -- floor), so its render settings get flattened directly instead.
    pcall(function()
        local T = workspace.Terrain
        T.Decoration        = false      -- grass tufts
        T.WaterWaveSize     = 0
        T.WaterWaveSpeed    = 0
        T.WaterReflectance  = 0
        T.WaterTransparency = 0
    end)

    -- ── workspace strip ───────────────────────────────────────────────────
    -- Not rendering something does not make it free. An unanchored part is
    -- still solved every physics step, a CanTouch part is still tested against
    -- every moving character, and lights/prompts still tick. This walks the
    -- map ONCE, then keeps up via DescendantAdded.
    --
    -- Player characters are skipped entirely — we position those.
    local STRIP = {
        ParticleEmitter=true, Trail=true, Beam=true, Fire=true, Smoke=true,
        Sparkles=true, Explosion=true, Decal=true, Texture=true,
        SurfaceAppearance=true, PointLight=true, SpotLight=true,
        SurfaceLight=true, Sound=true, ClickDetector=true, ProximityPrompt=true,
        Highlight=true, BillboardGui=true, SurfaceGui=true, Sparkles=true,
        AtmosphereEffect=true,

        -- Meshes that live INSIDE a Part are render-only: the collision was
        -- always the underlying block, so deleting these changes the shape on
        -- screen and nothing else. Free.
        SpecialMesh=true, BlockMesh=true, CylinderMesh=true,
    }

    -- A character mid-load can have parts before it has a Humanoid, and arms
    -- are CanCollide=false — so a Humanoid-only test would happily delete
    -- somebody's limbs during the window. The name check closes that window.
    local function isCharacter(m)
        if not m then return false end
        if Players:GetPlayerFromCharacter(m) then return true end
        if m:FindFirstChildOfClass("Humanoid") then return true end
        return Players:FindFirstChild(m.Name) ~= nil
    end

    local function inCharacter(v)
        local n = v
        for _ = 1, 8 do                       -- bounded: no deep ancestor walks
            local p = n.Parent
            if not p or p == workspace then break end
            n = p
        end
        return n ~= v and isCharacter(n) or isCharacter(v.Parent)
    end

    local function strip(v)
        if STRIP[v.ClassName] then
            v:Destroy()
            return true
        end
        if v:IsA("BasePart") then
            -- Nothing stands on a non-collidable part, so nothing misses it.
            -- That is where the decoration lives: foliage, signs, trim.
            if not v.CanCollide and not v:IsA("Seat") and not v:IsA("VehicleSeat") then
                v:Destroy()
                return true
            end
            v.Anchored   = true           -- out of the solver for good
            v.CanTouch   = false          -- stop testing it against 16 bodies
            v.CanQuery   = false          -- out of the spatial query structure
            v.CastShadow = false
            -- Newer properties: pcall'd so an older client just skips them.
            pcall(function() v.AudioCanCollide    = false end)  -- audio occlusion
            pcall(function() v.EnableFluidForces  = false end)  -- aerodynamics

            -- SmoothPlastic is the one material with no texture, no normal
            -- map and no PBR lookup. Reflectance 0 kills the cubemap sample.
            v.Material    = Enum.Material.SmoothPlastic
            v.Reflectance = 0
            pcall(function() v.MaterialVariant = "" end)

            -- A MeshPart cannot drop its mesh at runtime, but it can drop the
            -- texture it paints on it and stop refining the geometry.
            if v:IsA("MeshPart") then
                pcall(function() v.TextureID = "" end)
                pcall(function() v.RenderFidelity = Enum.RenderFidelity.Performance end)
            end
            return true
        end
        return false
    end

    local function stripAll()
        local killed, tamed = 0, 0
        for _, top in ipairs(workspace:GetChildren()) do
            if not isCharacter(top) and top ~= workspace.Terrain then
                local batch = top:GetDescendants()
                table.insert(batch, 1, top)
                for i, v in ipairs(batch) do
                    local before = v.Parent
                    local ok, did = pcall(strip, v)
                    if ok and did then
                        if before and not v.Parent then killed = killed + 1
                        else tamed = tamed + 1 end
                    end
                    if i % 800 == 0 then task.wait() end   -- don't stall the frame
                end
            end
        end
        Miked.log("workspace stripped: %d destroyed, %d anchored", killed, tamed)
    end
    Miked.stripWorkspace = stripAll

    table.insert(Miked.Conns, workspace.DescendantAdded:Connect(function(v)
        if Miked.State.nuked then return end            -- nuke's own hook handles it
        if inCharacter(v) then return end
        task.defer(function() pcall(strip, v) end)      -- let it finish parenting
    end))

    --[[ ── NUKE ──────────────────────────────────────────────────────────────
         Stripping tames the map. This deletes it.

         The only reason a bot needs a map at all is that it has to stand on
         something: your own character is client-owned, so if the floor
         disappears locally you genuinely fall, and the server believes it.
         Take that away and there is nothing left worth keeping.

         So: destroy every child of workspace except the four things that are
         actually load-bearing, and keep a safety net in reserve.

         MikedFloor is a NET, not a permanent platform. A slab welded under the
         bot forever would mean it can never descend — /follow and /walkto steer
         with Humanoid:MoveTo, which needs the humanoid to actually walk and
         fall, so a bot standing on its own floor tracks a target in X and Z and
         hovers at its old altitude for good. The net only deploys when a probe
         finds nothing at all below, so ordinary ground still does its job.

         What survives:
           · every player's character   - commands read the target's root
           · the Camera                 - destroying it just respawns one
           · MikedFloor                 - the net, parked far away until needed
           · Terrain                    - unless you turn keepTerrain off
    ──────────────────────────────────────────────────────────────────────── ]]
    local NUKE = Miked.NUKE or {
        keepTerrain = true,    -- false = Terrain:Clear() as well
        platform    = true,    -- catch the bot when there is nothing below
        pad         = 12,      -- how wide the net is, in studs
        drop        = 3.5,     -- studs below the root it catches at
        netBelow    = 250,     -- deploy only if nothing is within this far down
    }
    Miked.NUKE = NUKE

    local PARKED = CFrame.new(0, -60000, 0)     -- out of the way, out of reach

    local floor
    local function ensureFloor()
        if not NUKE.platform then return end
        if floor and floor.Parent then return floor end
        floor = Instance.new("Part")
        floor.Name         = "MikedFloor"
        floor.Size         = Vector3.new(NUKE.pad, 1, NUKE.pad)
        floor.Anchored     = true
        floor.CanCollide   = false          -- deployed only when needed
        floor.CanTouch     = false
        floor.CanQuery     = false          -- must not answer its own probe
        floor.CastShadow   = false
        floor.Transparency = 1
        floor.Material     = Enum.Material.SmoothPlastic
        floor.CFrame       = PARKED
        floor.Parent       = workspace
        return floor
    end

    -- Is there anything at all under us? Characters are excluded so a stack of
    -- bots in a /form cannot count as each other's ground.
    local netParams = RaycastParams.new()
    netParams.FilterType  = Enum.RaycastFilterType.Exclude
    netParams.IgnoreWater = false

    local function groundBelow(pos)
        local ex = {}
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl.Character then ex[#ex+1] = pl.Character end
        end
        netParams.FilterDescendantsInstances = ex
        return workspace:Raycast(pos, Vector3.new(0, -NUKE.netBelow, 0), netParams) ~= nil
    end

    local function keepThis(v)
        if v == floor or v.Name == "MikedFloor" then return true end
        if v:IsA("Camera") then return true end
        if v == workspace.Terrain then return NUKE.keepTerrain end
        return isCharacter(v)
    end

    local function nuke()
        ensureFloor()
        local gone = 0
        for _, v in ipairs(workspace:GetChildren()) do
            if not keepThis(v) then
                if pcall(function() v:Destroy() end) then gone = gone + 1 end
            end
        end
        if not NUKE.keepTerrain then
            pcall(function() workspace.Terrain:Clear() end)
        end
        -- Nothing left to fall onto, so stop the engine deleting anything that
        -- does fall. A destroyed character is a respawn loop.
        pcall(function() workspace.FallenPartsDestroyHeight = -50000 end)
        Miked.State.nuked = true
        Miked.log("workspace nuked: %d top-level objects destroyed%s",
                  gone, NUKE.keepTerrain and "" or " + terrain cleared")
    end
    Miked.nukeWorkspace = nuke

    if Config.nukeWorkspace then
        task.spawn(function()
            nuke()
            -- Anything the server sends afterwards goes the same way.
            table.insert(Miked.Conns, workspace.ChildAdded:Connect(function(v)
                task.defer(function()
                    if not keepThis(v) then pcall(function() v:Destroy() end) end
                end)
            end))
            -- The net. Checked five times a second, not per frame: falling
            -- 250 studs takes far longer than 200ms, so it always arrives in
            -- time, and a walking bot never pays for a raycast it did not need.
            task.spawn(function()
                while NUKE.platform do
                    local ch  = LP.Character
                    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
                    local f   = ensureFloor()
                    if hrp and f then
                        if groundBelow(hrp.Position) then
                            if f.CanCollide then           -- ground is back
                                f.CanCollide = false
                                f.CFrame     = PARKED
                            end
                        else
                            f.CFrame     = CFrame.new(hrp.Position
                                           - Vector3.new(0, NUKE.drop + 0.5, 0))
                            f.CanCollide = true
                        end
                    end
                    task.wait(0.2)
                end
            end)
        end)
    else
        task.spawn(stripAll)
    end

    task.spawn(function()
        for _, v in ipairs(Lighting:GetDescendants()) do
            pcall(function() if v:IsA("PostEffect") then v.Enabled = false end end)
        end
    end)

    -- ── park the camera ───────────────────────────────────────────────────
    -- Point it into empty sky, far above the map, facing further up. Nothing
    -- is in front of it, so nothing is in frame to cull, light or draw. The
    -- FOV of 1 degree (the engine minimum) shrinks the frustum to a needle on
    -- top of that.
    --
    -- Scriptable is what stops the default camera module fighting us; it also
    -- means the camera no longer follows the character, which is the point.
    -- Height is well short of the 2^24 float wall.
    local CAM_HOME = CFrame.new(Vector3.new(0, 50000, 0), Vector3.new(0, 60000, 0))

    local function parkCamera()
        local cam = workspace.CurrentCamera
        if not cam then return end
        cam.CameraType    = Enum.CameraType.Scriptable
        cam.CameraSubject = nil
        cam.FieldOfView   = 1
        cam.CFrame        = CAM_HOME
        cam.Focus         = CAM_HOME
    end
    Miked.parkCamera = parkCamera

    task.spawn(function()
        pcall(parkCamera)
        -- Respawning hands the camera back to the default module, and some
        -- games reassign it outright, so re-assert on both signals plus a
        -- slow tick. Once a second is plenty — nobody is watching.
        pcall(function()
            table.insert(Miked.Conns, LP.CharacterAdded:Connect(function()
                task.wait(0.5); pcall(parkCamera)
            end))
            table.insert(Miked.Conns,
                workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
                    pcall(parkCamera)
                end))
        end)
        while true do
            task.wait(1)
            local cam = workspace.CurrentCamera
            if cam and (cam.CameraType ~= Enum.CameraType.Scriptable
                        or (cam.CFrame.Position - CAM_HOME.Position).Magnitude > 1) then
                pcall(parkCamera)
            end
        end
    end)

    -- ── idle screen (3D rendering is off, so cover the blank viewport) ──
    task.spawn(function()
        local ok = pcall(function()
            LP:WaitForChild("PlayerGui", 20)
            local function idleHost()
                return (gethui and gethui()) or LP:FindFirstChild("PlayerGui") or game:GetService("CoreGui")
            end
            local host = idleHost()
            local old = host:FindFirstChild("MikedIdle"); if old then old:Destroy() end

            local A1, A2 = Color3.fromRGB(70,132,255), Color3.fromRGB(96,178,255)
            local function mk(cls, props, parent)
                local i = Instance.new(cls)
                for k,v in pairs(props) do i[k]=v end
                if parent then i.Parent=parent end
                return i
            end

            local sg = mk("ScreenGui",{Name="MikedIdle",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=2147483000},host)
            local bg = mk("Frame",{Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.fromRGB(10,13,19),BorderSizePixel=0},sg)
            mk("UIGradient",{Color=ColorSequence.new(Color3.fromRGB(18,24,34),Color3.fromRGB(8,10,15)),Rotation=90},bg)

            local card = mk("Frame",{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),
                Size=UDim2.fromOffset(360,190),BackgroundColor3=Color3.fromRGB(22,28,38),BorderSizePixel=0},bg)
            mk("UICorner",{CornerRadius=UDim.new(0,16)},card)
            local cs = mk("UIStroke",{Thickness=1.4,Transparency=0.35},card)
            mk("UIGradient",{Color=ColorSequence.new(A1,A2),Rotation=40},cs)

            local logo = mk("Frame",{AnchorPoint=Vector2.new(0.5,0),Position=UDim2.new(0.5,0,0,26),
                Size=UDim2.fromOffset(52,52),BackgroundColor3=A1,BorderSizePixel=0},card)
            mk("UICorner",{CornerRadius=UDim.new(0,14)},logo)
            mk("UIGradient",{Color=ColorSequence.new(A1,A2),Rotation=45},logo)
            mk("TextLabel",{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Text=">_",
                TextColor3=Color3.new(1,1,1),Font=Enum.Font.GothamBold,TextSize=20},logo)

            mk("TextLabel",{Position=UDim2.new(0,0,0,88),Size=UDim2.new(1,0,0,30),BackgroundTransparency=1,
                Text="Miked",TextColor3=Color3.fromRGB(235,240,248),Font=Enum.Font.GothamBold,TextSize=26},card)
            mk("TextLabel",{Position=UDim2.new(0,0,0,116),Size=UDim2.new(1,0,0,18),BackgroundTransparency=1,
                Text="alt control  ·  bot client",TextColor3=Color3.fromRGB(134,144,162),Font=Enum.Font.Gotham,TextSize=13},card)

            local status = mk("TextLabel",{Position=UDim2.new(0,0,0,146),Size=UDim2.new(1,0,0,16),BackgroundTransparency=1,
                Text="",TextColor3=A2,Font=Enum.Font.Code,TextSize=12},card)

            mk("TextLabel",{AnchorPoint=Vector2.new(0.5,1),Position=UDim2.new(0.5,0,1,-18),Size=UDim2.new(1,0,0,16),
                BackgroundTransparency=1,Text="rendering disabled for performance",
                TextColor3=Color3.fromRGB(70,80,98),Font=Enum.Font.Gotham,TextSize=12},bg)

            task.spawn(function()
                for _ = 1, 30 do
                    task.wait(1)
                    if not sg.Parent then pcall(function() sg.Parent = idleHost() end) end
                end
            end)
            task.spawn(function()
                while sg do
                    local up = tick()-(Miked.State.startTime or tick())
                    status.Text = ("%s   ·   bot #%d   ·   up %dm")
                        :format(LP.Name, Miked.roster.index(), math.floor(up/60))
                    task.wait(2)
                end
            end)
        end)
        if not ok then warn("[Miked] idle screen failed to build") end
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
                    if r then task.wait(0.6); r.CFrame = cf; Miked.zeroVel(r) end
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
                    if qot then
                        qot('task.wait(3); pcall(function() loadstring(game:HttpGet("'..LOADER_URL..'"))() end)')
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

    -- ── status heartbeat (feeds the main's Info tab) ──
    task.spawn(function()
        while true do
            task.wait(3)
            pcall(function()
                Miked.Socket.send("status", {
                    name = LP.Name,
                    idx  = Miked.roster.index(),
                    total= Miked.roster.total(),
                    ping = math.round(LP:GetNetworkPing()*1000),
                    cmd  = Miked.State.cmd or "None",
                })
            end)
        end
    end)
end

print(("[Miked] v%s ready — %s"):format(Miked._version, Miked.role:upper()))
