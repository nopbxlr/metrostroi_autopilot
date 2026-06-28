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

-- Resolve the AI driver for the train a player aims at / rides / stands nearest.
local function resolveDriver(ply)
    local t = resolveTrain(ply)
    if IsValid(t) and t.GetNW2Entity then
        local p = t:GetNW2Entity("TrainEntity"); if IsValid(p) then t = p end
    end
    for lead, d in pairs(AI.Drivers) do
        if lead == t then return d end
        for _, w in ipairs(d.wagons or {}) do if w == t then return d end end
    end
    if IsValid(ply) then
        local drv, bd
        for _, d in pairs(AI.Drivers) do
            if IsValid(d.head) then
                local dd = d.head:GetPos():DistToSqr(ply:GetPos())
                if not bd or dd < bd then bd, drv = dd, d end
            end
        end
        return drv
    end
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

-- Print exactly what ARS code the governing signal is sending for the nearest /
-- aimed AI train, so we can see why a section reads slower than expected.
function AI.CmdArsDebug(ply)
    local drv
    local t = resolveTrain(ply)
    if IsValid(t) and t.GetNW2Entity then
        local p = t:GetNW2Entity("TrainEntity"); if IsValid(p) then t = p end
    end
    for lead, d in pairs(AI.Drivers) do
        if lead == t then drv = d break end
        for _, w in ipairs(d.wagons or {}) do if w == t then drv = d break end end
        if drv then break end
    end
    if not drv and IsValid(ply) then
        local bd
        for _, d in pairs(AI.Drivers) do
            if IsValid(d.head) then
                local dd = d.head:GetPos():DistToSqr(ply:GetPos())
                if not bd or dd < bd then bd, drv = dd, d end
            end
        end
    end
    if not drv then return tell(ply, "no AI train found - aim at one or stand near it.") end

    local function line(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[AI ARS] " .. s .. "\n") end
        tell(ply, s)
    end

    local head = drv.head
    local tp  = Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    local pos = tp and tp[1]
    local dir = Metrostroi.TrainDirections and Metrostroi.TrainDirections[head]
    line(string.format("dir=%s path=%s x=%s speed=%d", tostring(dir),
        pos and pos.path and tostring(pos.path.id) or "?",
        pos and string.format("%.1f", pos.x) or "?", math.Round(drv:GetSpeed())))
    if not (pos and pos.node1 and type(dir) == "boolean") then
        return line("no valid network position (off-network map?)")
    end
    local ok, fwd = pcall(Metrostroi.GetARSJoint, pos.node1, pos.x, dir, head)
    if not ok or not IsValid(fwd) then return line("GetARSJoint -> no signal: " .. tostring(fwd)) end
    if not fwd.GetARS then return line("signal '" .. tostring(fwd.Name) .. "' has no GetARS") end
    local tbl = head.SubwayTrain and head.SubwayTrain.ALS
    local f15 = (not tbl) or (not tbl.TwoToSix)
    line(string.format("signal '%s'  ARSSpeedLimit=%s  Next=%s  TwoToSix=%s",
        tostring(fwd.Name), tostring(fwd.ARSSpeedLimit), tostring(fwd.ARSNextSpeedLimit), tostring(fwd.TwoToSix)))
    line(string.format("f15=%s  GetARS 8=%s 7=%s 6=%s 4=%s 0=%s", tostring(f15),
        tostring(fwd:GetARS(8, f15)), tostring(fwd:GetARS(7, f15)), tostring(fwd:GetARS(6, f15)),
        tostring(fwd:GetARS(4, f15)), tostring(fwd:GetARS(0, f15))))
    line("decoded -> " .. tostring(drv:DecodeARS(fwd)) .. " km/h")
    local function f(v) if not v or v >= 9000 then return "-" end return tostring(math.Round(v)) end
    local d = drv.dbg
    if d then
        line(string.format("LIMITS km/h: cruise=%s ars=%s curve=%s signal=%s train=%s term=%s plat=%s  => target=%s",
            f(d.cruise), f(d.ars), f(d.curve), f(d.signal), f(d.train), f(d.term), f(d.platform), f(d.target)))
    end
end

-- Dump the live door-circuit state per car so we can see exactly which
-- precondition is unmet. The door opens only if BOTH (a) the electrical command
-- reaches the valve: VDOL/VDOP == 1 (needs wire10 * A21 * reverser-engaged for
-- D1 power, then DoorSelect + KDL/VDL + A31), AND (b) air: DoorLinePressure > 3.5.
function AI.CmdDoorDebug(ply)
    local drv
    local t = resolveTrain(ply)
    if IsValid(t) and t.GetNW2Entity then
        local p = t:GetNW2Entity("TrainEntity"); if IsValid(p) then t = p end
    end
    for lead, d in pairs(AI.Drivers) do
        if lead == t then drv = d break end
        for _, w in ipairs(d.wagons or {}) do if w == t then drv = d break end end
        if drv then break end
    end
    if not drv and IsValid(ply) then
        local bd
        for _, d in pairs(AI.Drivers) do
            if IsValid(d.head) then
                local dd = d.head:GetPos():DistToSqr(ply:GetPos())
                if not bd or dd < bd then bd, drv = dd, d end
            end
        end
    end
    if not drv then return tell(ply, "no AI train found - aim at one or stand near it.") end

    local function line(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[AI DOORS] " .. s .. "\n") end
        tell(ply, s)
    end
    local function val(w, sys, field)
        if not IsValid(w) or not w[sys] then return "-" end
        local ok, v = pcall(function() return w[sys][field or "Value"] end)
        if not ok or v == nil then return "?" end
        if type(v) == "number" then return string.format("%.2f", v) end
        return tostring(v)
    end
    local function wire(w, n)
        if IsValid(w) and w.ReadTrainWire then
            local ok, v = pcall(w.ReadTrainWire, w, n)
            if ok then return string.format("%.1f", v) end
        end
        return "?"
    end
    local function door(w, key)
        if IsValid(w) and w.GetPackedBool then
            local ok, v = pcall(w.GetPackedBool, w, key)
            if ok then return tostring(v) end
        end
        return "?"
    end

    line("=== door circuit (open needs VDOL/VDOP=1 AND DoorLinePress>3.5) ===")
    for i, w in ipairs(drv.wagons or {}) do
        if i > 4 then break end
        local tag = (w == drv.head) and "HEAD" or ("car" .. i)
        line(string.format("%s %s  wire10=%s A21=%s rev=%s D-D1=%s  | DSel=%s KDL=%s VDL=%s VUD1=%s A31=%s",
            tag, w:GetClass(), wire(w, 10), val(w, "A21"), val(w, "KV", "ReverserPosition"),
            val(w, "KV", "D-D1"), val(w, "DoorSelect"), val(w, "KDL"), val(w, "VDL"),
            val(w, "VUD1"), val(w, "A31")))
        line(string.format("     VDOL=%s VDOP=%s  DoorLinePress=%s  physDoorL=%s physDoorR=%s",
            val(w, "VDOL"), val(w, "VDOP"), val(w, "Pneumatic", "DoorLinePressure"),
            door(w, "DoorL"), door(w, "DoorR")))
    end
end

-- Terminus / turn-back diagnostic: distance to the buffer ahead, which crossover
-- switch the turn-back would throw, and the switches near the train (id, forward
-- dist in m, lateral in units, current alt state) so we can verify the pick.
function AI.CmdTermDebug(ply)
    local drv = resolveDriver(ply)
    if not drv then return tell(ply, "no AI train found - aim at one or stand near it.") end
    local function line(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[AI TERM] " .. s .. "\n") end
        tell(ply, s)
    end
    local head = drv.head
    if not IsValid(head) then return line("driver has no head wagon") end
    local tp  = Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    local pos = tp and tp[1]
    local term = pos and drv:TerminusDistance(pos)
    local thrown = "-"
    if drv.turnbackSwitches and #drv.turnbackSwitches > 0 then
        local ids = {}
        for _, sw in ipairs(drv.turnbackSwitches) do
            if IsValid(sw) then ids[#ids + 1] = sw:GetNW2String("ID", "?") end
        end
        thrown = table.concat(ids, "+")
    end
    line(string.format("state=%s  term=%s  turnback=%s",
        tostring(drv.state),
        term and (string.format("%.0f m to buffer", term)) or "none (track continues / loop)",
        thrown))
    -- What platform (if any) the driver is currently locked onto - the prime
    -- suspect for getting stuck at a terminus is the OPPOSITE-track face being
    -- re-acquired (small farFd, lateral ~= track gap) so the platform block keeps
    -- returning before the terminus reverse can run.
    local pf = drv:NextPlatform()
    if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
        local farFd  = drv:ForwardDist(drv:PlatformStopPoint(pf)) / AI.U_PER_M
        local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
        line(string.format("nextPlatform: station %s  farFd=%+.0fm  lateral=%.0fu",
            tostring(pf.StationIndex or "?"), farFd, drv:LateralDist(center)))
    else
        line("nextPlatform: none")
    end
    line(string.format("servedPlatform=%s  doorsOpen=%s",
        IsValid(drv.servedPlatform) and tostring(drv.servedPlatform.StationIndex or "?") or "-",
        tostring(drv.doorsOpen)))
    -- Scan BOTH ways along travel: +fwd = toward the buffer ahead, -fwd = behind us
    -- toward the line (where an approach-side crossover lives).
    local ref = head:GetPos()
    local dir = drv.travelDir or head:GetForward()
    local n = 0
    for _, sw in ipairs(ents.FindByClass("gmod_track_switch")) do
        if IsValid(sw) then
            local rel = sw:GetPos() - ref
            local fd  = rel:Dot(dir)
            local lat = (rel - dir * fd):Length()
            if math.abs(fd) < 450 * AI.U_PER_M and lat < 1000 then
                n = n + 1
                line(string.format("  switch %s  fwd=%+.0fm  lat=%.0fu  alt=%s",
                    tostring(sw:GetNW2String("ID", "?")), fd / AI.U_PER_M, lat, tostring(sw.AlternateTrack)))
                if n >= 10 then break end
            end
        end
    end
    if n == 0 then line("  no switches within ~450 m either direction (single-track / stub terminus?)") end
end

-- Stable-ordered list of AI drivers (by lead EntIndex) so "#n" means the same
-- train across !ai status and !ai tp.
local function orderedDrivers()
    local list = {}
    for lead, drv in pairs(AI.Drivers) do
        if IsValid(lead) then list[#list + 1] = drv end
    end
    table.sort(list, function(a, b)
        return (IsValid(a.lead) and a.lead:EntIndex() or 0) < (IsValid(b.lead) and b.lead:EntIndex() or 0)
    end)
    return list
end

local function bogeySpeed(w)
    local b = (IsValid(w.FrontBogey) and w.FrontBogey) or (IsValid(w.RearBogey) and w.RearBogey)
    return math.Round((IsValid(b) and b.Speed) or w.Speed or 0)
end

-- Nearest platform/station to a world position -> (stationIndex, distance_m).
local function nearStation(pos)
    local best, bd
    for _, pf in ipairs(ents.FindByClass("gmod_track_platform")) do
        if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
            local c = (pf.PlatformStart + pf.PlatformEnd) * 0.5
            local d = c:DistToSqr(pos)
            if not bd or d < bd then bd, best = d, pf end
        end
    end
    if best then return tostring(best.StationIndex or "?"), math.sqrt(bd) / AI.U_PER_M end
    return "?", 0
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

-- Why isn't regulation working? Shows the route chains, how many trains landed on
-- each, and the aimed train's leader gap / spacing target.
function AI.CmdRegDebug(ply)
    local function line(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[AI REG] " .. s .. "\n") end
        tell(ply, s)
    end
    line("regulation=" .. AI.CVars.regulation:GetInt() .. "  maxhold=" .. AI.CVars.reg_maxhold:GetInt())
    local chains = AI.EnsureRoute and AI.EnsureRoute()
    line("route chains: " .. (chains and tostring(#chains) or "NIL (route build failed)"))
    if AI.EnsureLines then AI.EnsureLines() end
    if AI.ConsistReps then
        local perLine, total = {}, 0
        for _, rep in ipairs(AI.ConsistReps()) do
            total = total + 1
            local tp = Metrostroi.TrainPositions and Metrostroi.TrainPositions[rep.w]
            local p = tp and tp[1]
            if p and p.path then
                local ci, cd = AI.ChainPos(math.floor(tonumber(p.path.id) or 0), p.x or 0)
                if ci then
                    local rs = AI.RegState and AI.RegState[rep.w]
                    local root = AI.TrainLinePos(ci, cd, rs and rs.vsign or 1)
                    if root then perLine[root] = (perLine[root] or 0) + 1 end
                end
            end
        end
        line("consists (trains): " .. total)
        local shown = 0
        for root, n in pairs(perLine) do
            shown = shown + 1
            if shown <= 8 then line(string.format("  line %s: %d train(s)", tostring(root), n)) end
        end
    end
    local drv = resolveDriver(ply)
    if drv then
        local head = IsValid(drv.head) and drv.head or drv.lead
        local tp = IsValid(head) and Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
        local p = tp and tp[1]
        local ci, cd
        if p and p.path then ci, cd = AI.ChainPos(math.floor(tonumber(p.path.id) or 0), p.x or 0) end
        local rs = IsValid(head) and AI.RegState and AI.RegState[head]
        local root, lp = ci and AI.TrainLinePos(ci, cd, rs and rs.vsign or 1)
        line(string.format("aimed: state=%s chain=%s line=%s linePos=%s | leaderGap=%s target=%s",
            tostring(drv.state), tostring(ci), tostring(root),
            lp and string.format("%.3f", lp) or "?",
            drv.regLeaderGap and string.format("%.3f", drv.regLeaderGap) or "nil",
            drv.regTarget and string.format("%.3f", drv.regTarget) or "nil"))
    end
end

--------------------------------------------------------------------------------
-- Register console commands
--------------------------------------------------------------------------------
concommand.Add("metrostroi_ai_regdebug", function(ply) AI.CmdRegDebug(ply) end)
concommand.Add("metrostroi_ai_status", function(ply) AI.CmdStatus(ply) end)
concommand.Add("metrostroi_ai_tp",     function(ply, _, a) AI.CmdTeleport(ply, a) end)
concommand.Add("metrostroi_ai_termdebug", function(ply) AI.CmdTermDebug(ply) end)
concommand.Add("metrostroi_ai_add",    function(ply) AI.CmdAdd(ply) end)
concommand.Add("metrostroi_ai_arsdebug", function(ply) AI.CmdArsDebug(ply) end)
concommand.Add("metrostroi_ai_doordebug", function(ply) AI.CmdDoorDebug(ply) end)
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

--------------------------------------------------------------------------------
-- Track-network map: serve the rail geometry (decimated XY per path) on request,
-- and the live train positions for the client map window.
--------------------------------------------------------------------------------
util.AddNetworkString("MetrostroiAI_Map")
util.AddNetworkString("MetrostroiAI_Schematic")
util.AddNetworkString("MetrostroiAI_Trains")
util.AddNetworkString("MetrostroiAI_OpenMap")

local function netPos(w)
    local tp = Metrostroi.TrainPositions and Metrostroi.TrainPositions[w]
    local p = tp and tp[1]
    if p and p.path then return math.Clamp(math.floor(tonumber(p.path.id) or 0), 0, 65535), p.x or 0 end
    return 0, 0
end

local function shortClass(w)
    return (w:GetClass():gsub("^gmod_subway_81%-", ""):gsub("^gmod_subway_", ""))
end

-- The full rich status (APPROACH/DOORS/TERMINUS/HELD AT SIGNAL/...) the driver
-- already publishes, minus the trailing "  62/80" speed/target (shown separately).
local function statusTag(lead, fallback)
    local s = lead:GetNW2String("AIStatus", "")
    s = (s:gsub("%s%s+%-?%d+/.*$", ""))
    if s == "" then return fallback or "?" end
    return s
end

local function networkPaths()
    local out, total = {}, 0
    for _, path in pairs(Metrostroi.Paths or {}) do
        if istable(path) and #path >= 2 and total < 6000 then
            local step = math.max(1, math.floor(#path / 120))   -- cap ~120 pts/path
            local pts = {}
            for i = 1, #path, step do
                local n = path[i]
                if n and isvector(n.pos) then pts[#pts + 1] = n.pos end
            end
            local last = path[#path]
            if last and isvector(last.pos) then pts[#pts + 1] = last.pos end
            if #pts >= 2 then out[#out + 1] = pts; total = total + #pts end
        end
    end
    return out
end

net.Receive("MetrostroiAI_Map", function(_, ply)
    local paths = networkPaths()
    net.Start("MetrostroiAI_Map")
    net.WriteUInt(#paths, 16)
    for _, pts in ipairs(paths) do
        net.WriteUInt(#pts, 16)
        for _, p in ipairs(pts) do net.WriteFloat(p.x) net.WriteFloat(p.y) end
    end
    net.Send(ply)
end)

net.Receive("MetrostroiAI_Trains", function(_, ply)
    local drivers = orderedDrivers()
    local aiWag, entries = {}, {}
    for i, drv in ipairs(drivers) do
        local lead = IsValid(drv.head) and drv.head or drv.lead
        if IsValid(lead) then
            for _, w in ipairs(drv.wagons or {}) do aiWag[w] = true end
            local pid, px = netPos(lead)
            local st = nearStation(lead:GetPos())
            entries[#entries + 1] = {
                p = lead:GetPos(), a = drv.travelDir or lead:GetForward(), ai = i,
                path = pid, x = px, spd = bogeySpeed(lead),
                tag = statusTag(lead, tostring(drv.state or "?")),
            }
        end
    end
    local seen = {}
    for t in pairs(Metrostroi.SpawnedTrains or {}) do
        if IsValid(t) and not seen[t] then
            local cars, n, isAI = (istable(t.WagonList) and t.WagonList or { t }), 0, false
            for _, w in pairs(cars) do if IsValid(w) then n = n + 1; seen[w] = true; if aiWag[w] then isAI = true end end end
            if not isAI then
                local pid, px = netPos(t)
                entries[#entries + 1] = {
                    p = t:GetPos(), a = t:GetForward(), ai = 0, path = pid, x = px, spd = bogeySpeed(t),
                    tag = "@" .. nearStation(t:GetPos()) .. " x" .. n,
                }
            end
        end
    end
    net.Start("MetrostroiAI_Trains")
    net.WriteUInt(#entries, 12)
    for _, e in ipairs(entries) do
        net.WriteFloat(e.p.x) net.WriteFloat(e.p.y)
        net.WriteFloat(e.a.x) net.WriteFloat(e.a.y)
        net.WriteUInt(e.ai, 8)
        net.WriteUInt(e.path, 16) net.WriteFloat(e.x)
        net.WriteInt(math.Clamp(e.spd, -300, 300), 16)
        net.WriteString(e.tag)
    end
    net.Send(ply)
end)

net.Receive("MetrostroiAI_Schematic", function(_, ply)
    local chains = AI.EnsureRoute() or {}   -- shared route stitching (sv_regulation.lua)
    local stations = {}
    for _, pf in ipairs(ents.FindByClass("gmod_track_platform")) do
        if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
            local c = (pf.PlatformStart + pf.PlatformEnd) * 0.5
            local ok, res = pcall(Metrostroi.GetPositionOnTrack, c, pf:GetAngles())
            if ok and res and res[1] and res[1].path then
                stations[#stations + 1] = {
                    path = math.Clamp(math.floor(tonumber(res[1].path.id) or 0), 0, 65535),
                    x = res[1].x or 0, wx = c.x, wy = c.y, st = tostring(pf.StationIndex or "?") }
            end
        end
    end
    net.Start("MetrostroiAI_Schematic")
    net.WriteUInt(#chains, 16)
    for _, chain in ipairs(chains) do
        net.WriteUInt(#chain.segs, 16)
        for _, s in ipairs(chain.segs) do
            net.WriteUInt(s.id, 16) net.WriteFloat(s.offset) net.WriteFloat(s.len) net.WriteBool(s.flip)
        end
    end
    net.WriteUInt(#stations, 16)
    for _, s in ipairs(stations) do
        net.WriteUInt(s.path, 16) net.WriteFloat(s.x) net.WriteFloat(s.wx) net.WriteFloat(s.wy) net.WriteString(s.st)
    end
    net.Send(ply)
end)
