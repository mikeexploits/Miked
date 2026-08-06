# Miked
## I got tired of using year old alt controls that were buggy and basic, so i made my own\
> [!] You MUST download the relay for this to work. 
\
LOADER
```lua
getgenv().Miked = {
    Config = {
        mainAccount = "MainGuy345",
        altAccounts = {
            "Altman19999", 
            "Superdude67" 
        },
        commanders  = {"CommanderMan16","Extraperson198"}, -- extra people allowed to command

        prefix = "/", -- command prefix
        wsUrl  = "ws://127.0.0.1:8080", -- relay address (localhost)

        fpsCap         = 15,
        announceOnLoad = true,
        autoUnmute     = false,   -- voice games: auto-unmute mic on load (does not work rn)
        vcbEnabled     = false,   -- voice games: auto-rejoin on voice-chat ban (does not work rn)
    },
    State = {}, Conns = {}, Cache = {},
}

if not game:IsLoaded() then game.Loaded:Wait() end
repeat task.wait() until game:GetService("Players").LocalPlayer

local BASE = "https://raw.githubusercontent.com/mikeexploits/Miked/refs/heads/main/Systems/"
local function use(f) return loadstring(game:HttpGet(BASE .. f))() end
```
\
WARNING: vibe coded
