--[[ ═══════════════════════════════════════════════════════════════
     Miked ALT Control — v1.0.0-beta
     Run this on EVERY account (main + all alts). Start relay.py first.
     Edit the settings below; that's the only file you touch.
═══════════════════════════════════════════════════════════════════ ]]

getgenv().Miked = {
    _version = "1.0.0-beta",
    Config = {
        -- ── accounts ──
        mainAccount = "main",                  -- your main username
        altAccounts = { "user2", "user2" },   -- your bot usernames
        commanders  = {},                              -- extra people allowed to command

        -- ── core ──
        prefix = "!",                                  -- command prefix
        wsUrl  = "ws://127.0.0.1:8080",                -- relay address (localhost)

        -- ── optional urls ──
        loaderUrl       = "https://raw.githubusercontent.com/mikeexploits/Miked/refs/heads/main/Loader.lua",
        emoteCatalogUrl = nil,                         -- your hosted emote-id list (for !emote / !sync)

        -- ── games (situational modules) ──
        games = { micup = { --[[ [PLACEID] = true ]] } },

        -- ── bot lifecycle ──
        fpsCap         = 10,
        announceOnLoad = false,
        autoUnmute     = true,   -- voice games: auto-unmute mic on load
        vcbEnabled     = true,   -- voice games: auto-rejoin on voice-chat ban
    },
    State = {}, Conns = {}, Cache = {},
}

local BASE = "https://raw.githubusercontent.com/mikeexploits/Miked/refs/heads/main/Systems/"
local function use(f) return loadstring(game:HttpGet(BASE .. f))() end

use("Socket.lua")   -- transport
use("Core.lua")     -- roles, registry, roster, commands, GUI, survival
