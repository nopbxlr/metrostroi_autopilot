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

function AI.CmdSpawn(ply, args)
    if not canUse(ply) then return tell(ply, "admins only.") end
    local class = args[1]
    -- allow shorthand like "81-717" or "717" -> try the real class names
    if class and not scripted_ents.GetStored(class) then
        local found
        for _, c in ipairs({
            "gmod_subway_" .. class,
            "gmod_subway_81-" .. class,
            "gmod_subway_81-" .. class .. "_mvm",
            "gmod_subway_81-" .. class .. "_lvz",
            "gmod_subway_" .. class .. "_mvm",
        }) do
            if scripted_ents.GetStored(c) then found = c break end
        end
        class = found
    end
    if not (class and scripted_ents.GetStored(class)) then
        class = "gmod_subway_81-717_mvm"   -- safe default if unresolved
    end
    local cars = tonumber(args[2]) or 4
    local ok, err = AI.SpawnConsist(ply, class, cars)
    if ok then tell(ply, "spawning ", cars, "-car ", class, " ... it will couple and start driving shortly.")
    else tell(ply, "spawn failed: ", tostring(err)) end
end

-- Force-couple a consist that didn't auto-couple (tool-spawned or otherwise).
function AI.CmdCouple(ply)
    if not canUse(ply) then return tell(ply, "admins only.") end
    local t = resolveTrain(ply)
    if IsValid(t) and t.GetNW2Entity then
        local p = t:GetNW2Entity("TrainEntity")
        if IsValid(p) then t = p end
    end
    if not (IsValid(t) and (t.FrontCouple or t.RearCouple)) then
        return tell(ply, "aim at a Metrostroi train car.")
    end
    -- gather nearby cars, order them along the aimed car's axis, couple neighbours
    local cars = {}
    for _, e in ipairs(ents.FindInSphere(t:GetPos(), 1600)) do
        if IsValid(e) and (e.FrontCouple or e.RearCouple) and (e.FrontBogey or e.RearBogey) then
            cars[#cars + 1] = e
        end
    end
    if #cars < 2 then return tell(ply, "no neighbouring cars found within range.") end
    local fwd = t:GetForward()
    table.sort(cars, function(a, b) return a:GetPos():Dot(fwd) < b:GetPos():Dot(fwd) end)
    local n = 0
    for i = 1, #cars - 1 do
        if AI.ForceCouple(cars[i], cars[i + 1], 700) then n = n + 1 end
    end
    tell(ply, "force-coupled ", n, " joint(s) across ", #cars, " cars.")
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

--------------------------------------------------------------------------------
-- Register console commands
--------------------------------------------------------------------------------
concommand.Add("metrostroi_ai_termdebug", function(ply) AI.CmdTermDebug(ply) end)
concommand.Add("metrostroi_ai_add",    function(ply) AI.CmdAdd(ply) end)
concommand.Add("metrostroi_ai_arsdebug", function(ply) AI.CmdArsDebug(ply) end)
concommand.Add("metrostroi_ai_doordebug", function(ply) AI.CmdDoorDebug(ply) end)
concommand.Add("metrostroi_ai_remove", function(ply, _, a) AI.CmdRemove(ply, a) end)
concommand.Add("metrostroi_ai_spawn",  function(ply, _, a) AI.CmdSpawn(ply, a) end)
concommand.Add("metrostroi_ai_couple", function(ply) AI.CmdCouple(ply) end)
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
    elseif sub == "couple" then AI.CmdCouple(ply)
    elseif sub == "ars" then AI.CmdArsDebug(ply)
    elseif sub == "doors" or sub == "door" then AI.CmdDoorDebug(ply)
    elseif sub == "term" or sub == "terminus" then AI.CmdTermDebug(ply)
    elseif sub == "list" then AI.CmdList(ply)
    elseif sub == "help" then AI.CmdHelp(ply)
    else AI.CmdHelp(ply) end
    return ""
end)
