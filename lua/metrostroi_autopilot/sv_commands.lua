--------------------------------------------------------------------------------
-- Metrostroi Autopilot - player console & chat commands (add / remove / list /
-- help / status / tp). Debug dumps live in sv_diagnostics.lua, the map net code
-- in sv_map.lua, and the shared helpers in sv_util.lua. Loaded after sv_util.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI
local canUse, tell, resolveTrain = AI.CanUse, AI.Tell, AI.ResolveTrain
local orderedDrivers, bogeySpeed, nearStation = AI.OrderedDrivers, AI.BogeySpeed, AI.NearStation

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
        "  metrostroi_ai_remove [all]   - stop AI on the aimed train (or 'all')",
        "  metrostroi_ai_status         - where every train (AI + manual) is",
        "  metrostroi_ai_tp <#>         - board an AI train's forward cab",
        "  metrostroi_ai_map            - open the track-network map window",
        "  chat: !ai  |  !ai add  |  !ai status  |  !ai tp 2  |  !ai map",
        "  tuning cvars: metrostroi_ai_cruise_speed, _dwell, _decel, _accel, _obey_signals ...",
    }
    for _, line in ipairs(L) do tell(ply, line) end
end

-- The driver seat that faces our travel direction (the forward cab), for !ai tp.
local function forwardSeat(drv)
    local best, bestAlong
    for _, w in ipairs(drv.wagons or {}) do
        if IsValid(w) and IsValid(w.DriverSeat) and isvector(drv.travelDir)
           and w:GetForward():Dot(drv.travelDir) > 0 then
            local along = w:GetPos():Dot(drv.travelDir)
            if not bestAlong or along > bestAlong then best, bestAlong = w.DriverSeat, along end
        end
    end
    if not best then            -- fallback: any driver seat in the consist
        for _, w in ipairs(drv.wagons or {}) do
            if IsValid(w) and IsValid(w.DriverSeat) then best = w.DriverSeat break end
        end
    end
    return best
end

-- Overview of EVERY train on the map: AI ones numbered for !ai tp, plus manual.
function AI.CmdStatus(ply)
    local function line(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[AI] " .. s .. "\n") end
        tell(ply, s)
    end
    local drivers = orderedDrivers()
    line("=== AI trains (" .. #drivers .. ") - !ai tp <#> to board ===")
    for i, drv in ipairs(drivers) do
        local lead = IsValid(drv.head) and drv.head or drv.lead
        if IsValid(lead) then
            local st, dist = nearStation(lead:GetPos())
            line(string.format("#%d  %s  x%d  %d km/h  %s  @st.%s (%dm)",
                i, lead:GetClass():gsub("^gmod_subway_", ""), #(drv.wagons or {}),
                bogeySpeed(lead), tostring(drv.state or "?"), st, math.Round(dist)))
        end
    end

    -- Manual trains: spawned consists with no car under AI control.
    local aiWag = {}
    for _, drv in ipairs(drivers) do
        for _, w in ipairs(drv.wagons or {}) do aiWag[w] = true end
    end
    local seen, manual = {}, 0
    for t in pairs(Metrostroi.SpawnedTrains or {}) do
        if IsValid(t) and not seen[t] then
            local cars = {}
            if istable(t.WagonList) then
                for _, w in pairs(t.WagonList) do if IsValid(w) then cars[#cars + 1] = w; seen[w] = true end end
            end
            if #cars == 0 then cars = { t }; seen[t] = true end
            local isAI = false
            for _, w in ipairs(cars) do if aiWag[w] then isAI = true break end end
            if not isAI then
                manual = manual + 1
                local st, dist = nearStation(cars[1]:GetPos())
                line(string.format("(manual)  %s  x%d  %d km/h  @st.%s (%dm)",
                    cars[1]:GetClass():gsub("^gmod_subway_", ""), #cars, bogeySpeed(cars[1]), st, math.Round(dist)))
            end
        end
    end
    if manual == 0 then line("(no manual trains)") end
end

-- Board an AI train's forward driver seat (nearest one if no number given).
function AI.CmdTeleport(ply, args)
    if not IsValid(ply) then return tell(ply, "run this in-game.") end
    if not canUse(ply) then return tell(ply, "admins only.") end
    local drivers = orderedDrivers()
    local n = tonumber(args and args[1])
    if not n then                          -- no number -> nearest AI train
        local bd
        for i, drv in ipairs(drivers) do
            local lead = IsValid(drv.head) and drv.head or drv.lead
            if IsValid(lead) then
                local d = lead:GetPos():DistToSqr(ply:GetPos())
                if not bd or d < bd then bd, n = d, i end
            end
        end
    end
    local drv = n and drivers[n]
    if not drv then return tell(ply, "no AI train #" .. tostring(n) .. " - try !ai status.") end
    local seat = forwardSeat(drv)
    if not IsValid(seat) then return tell(ply, "that train has no usable driver seat.") end
    if IsValid(seat:GetDriver()) then return tell(ply, "the forward cab is occupied.") end
    if IsValid(ply:GetVehicle()) then ply:ExitVehicle() end
    ply:EnterVehicle(seat)
    tell(ply, "boarded AI train #" .. n .. " (forward cab).")
end

--------------------------------------------------------------------------------
-- Register console commands
--------------------------------------------------------------------------------
concommand.Add("metrostroi_ai_status", function(ply) AI.CmdStatus(ply) end)
concommand.Add("metrostroi_ai_tp",     function(ply, _, a) AI.CmdTeleport(ply, a) end)
concommand.Add("metrostroi_ai_add",    function(ply) AI.CmdAdd(ply) end)
concommand.Add("metrostroi_ai_remove", function(ply, _, a) AI.CmdRemove(ply, a) end)
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
    elseif sub == "remove" or sub == "stop" or sub == "del" then AI.CmdRemove(ply, { parts[3] })
    elseif sub == "ars" then AI.CmdArsDebug(ply)
    elseif sub == "doors" or sub == "door" then AI.CmdDoorDebug(ply)
    elseif sub == "term" or sub == "terminus" then AI.CmdTermDebug(ply)
    elseif sub == "reg" or sub == "regulation" then AI.CmdRegDebug(ply)
    elseif sub == "status" or sub == "where" then AI.CmdStatus(ply)
    elseif sub == "tp" or sub == "goto" or sub == "board" then AI.CmdTeleport(ply, { parts[3] })
    elseif sub == "map" then if IsValid(ply) then net.Start("MetrostroiAI_OpenMap") net.Send(ply) end
    elseif sub == "list" then AI.CmdList(ply)
    elseif sub == "help" then AI.CmdHelp(ply)
    else AI.CmdHelp(ply) end
    return ""
end)
