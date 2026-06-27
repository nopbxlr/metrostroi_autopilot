--------------------------------------------------------------------------------
-- Metrostroi Autopilot - console & chat commands
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI

local function canUse(ply)
    if not IsValid(ply) then return true end          -- server console
    return ply:IsAdmin()
end

local function tell(ply, ...)
    if IsValid(ply) then
        ply:PrintMessage(HUD_PRINTTALK, "[Metrostroi AI] " .. table.concat({ ... }, ""))
    else
        AI.Msg(...)
    end
end

-- Resolve the train a player means: the one aimed at, or the one they're riding.
local function resolveTrain(ply)
    if not IsValid(ply) then return nil end
    local e = ply:GetEyeTrace().Entity
    if IsValid(e) then return e end
    local veh = ply:GetVehicle()
    if IsValid(veh) then
        local t = veh:GetNW2Entity("TrainEntity")
        if IsValid(t) then return t end
        if IsValid(veh:GetParent()) then return veh:GetParent() end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
function AI.CmdAdd(ply)
    if not canUse(ply) then return tell(ply, "admins only.") end
    local t = resolveTrain(ply)
    if not IsValid(t) then return tell(ply, "aim at a Metrostroi train first.") end
    local ok, err = AI.Engage(t)
    if ok then tell(ply, "this train is now an AI 'fake player'.")
    else tell(ply, "could not engage: ", tostring(err)) end
end

function AI.CmdRemove(ply, args)
    if not canUse(ply) then return tell(ply, "admins only.") end
    if args and string.lower(args[1] or "") == "all" then
        local n = 0
        for _, drv in pairs(table.Copy(AI.Drivers)) do drv:Disengage() n = n + 1 end
        return tell(ply, "disengaged ", n, " AI train(s).")
    end
    local t = resolveTrain(ply)
    if not IsValid(t) then return tell(ply, "aim at an AI train (or use: remove all).") end
    -- find the driver owning this entity
    for lead, drv in pairs(AI.Drivers) do
        if lead == t then drv:Disengage() return tell(ply, "AI disengaged.") end
        for _, w in ipairs(drv.wagons or {}) do
            if w == t then drv:Disengage() return tell(ply, "AI disengaged.") end
        end
    end
    tell(ply, "that train is not on AI.")
end

function AI.CmdSpawn(ply, args)
    if not canUse(ply) then return tell(ply, "admins only.") end
    local class = args[1]
    -- allow shorthand like "81-717" or "717"
    if class and not scripted_ents.GetStored(class) then
        local guess = "gmod_subway_" .. class
        if scripted_ents.GetStored(guess) then class = guess
        elseif scripted_ents.GetStored("gmod_subway_81-" .. class) then class = "gmod_subway_81-" .. class end
    end
    class = class or "gmod_subway_81-717_mvm"
    local cars = tonumber(args[2]) or 4
    local ok, err = AI.SpawnConsist(ply, class, cars)
    if ok then tell(ply, "spawning ", cars, "-car ", class, " ... it will start driving shortly.")
    else tell(ply, "spawn failed: ", tostring(err)) end
end

function AI.CmdList(ply)
    local n = 0
    for lead, drv in pairs(AI.Drivers) do
        if IsValid(lead) then
            n = n + 1
            local sp = (IsValid(drv.head) and drv.head.Speed or 0)
            tell(ply, "#", n, ": ", lead:GetClass(), "  cars=", #(drv.wagons or {}),
                 "  state=", drv.state or "?", "  ", math.Round(sp), " km/h")
        end
    end
    if n == 0 then tell(ply, "no AI trains active.") end
end

function AI.CmdHelp(ply)
    local L = {
        "Metrostroi Autopilot commands:",
        "  metrostroi_ai_add            - make the train you aim at drive itself",
        "  metrostroi_ai_spawn C N      - spawn an N-car AI train of class C on the track you aim at",
        "  metrostroi_ai_remove [all]   - stop AI on the aimed train (or 'all')",
        "  metrostroi_ai_list           - list active AI trains",
        "  chat: !ai  |  !ai spawn 717 4  |  !ai remove [all]  |  !ai list",
        "  tuning cvars: metrostroi_ai_cruise_speed, _dwell, _decel, _accel, _obey_signals ...",
    }
    for _, line in ipairs(L) do tell(ply, line) end
end

--------------------------------------------------------------------------------
-- Register console commands
--------------------------------------------------------------------------------
concommand.Add("metrostroi_ai_add",    function(ply) AI.CmdAdd(ply) end)
concommand.Add("metrostroi_ai_remove", function(ply, _, a) AI.CmdRemove(ply, a) end)
concommand.Add("metrostroi_ai_spawn",  function(ply, _, a) AI.CmdSpawn(ply, a) end)
concommand.Add("metrostroi_ai_list",   function(ply) AI.CmdList(ply) end)
concommand.Add("metrostroi_ai_help",   function(ply) AI.CmdHelp(ply) end)

--------------------------------------------------------------------------------
-- Chat commands: !ai ...
--------------------------------------------------------------------------------
hook.Add("PlayerSay", "MetrostroiAI.Chat", function(ply, text)
    local parts = string.Explode(" ", string.Trim(text))
    local cmd = string.lower(parts[1] or "")
    if cmd ~= "!ai" and cmd ~= "/ai" then return end
    local sub = string.lower(parts[2] or "")
    local rest = { parts[3], parts[4] }

    if sub == "" or sub == "add" or sub == "drive" then AI.CmdAdd(ply)
    elseif sub == "spawn" then AI.CmdSpawn(ply, { parts[3], parts[4] })
    elseif sub == "remove" or sub == "stop" or sub == "del" then AI.CmdRemove(ply, { parts[3] })
    elseif sub == "list" then AI.CmdList(ply)
    elseif sub == "help" then AI.CmdHelp(ply)
    else AI.CmdHelp(ply) end
    return ""
end)
