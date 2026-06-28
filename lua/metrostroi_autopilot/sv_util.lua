--------------------------------------------------------------------------------
-- Metrostroi Autopilot - shared helpers for the command / map modules: resolve
-- the player's train & driver, the stable-ordered driver list, bogey speed and
-- nearest station. Split out of sv_commands.lua; loaded BEFORE the modules
-- (sv_commands / sv_diagnostics / sv_map) that re-localize these.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI

function AI.CanUse(ply)
    if not IsValid(ply) then return true end          -- server console
    return ply:IsAdmin()
end

function AI.Tell(ply, ...)
    if IsValid(ply) then
        ply:PrintMessage(HUD_PRINTTALK, "[Metrostroi AI] " .. table.concat({ ... }, ""))
    else
        AI.Msg(...)
    end
end

-- Resolve the train a player means: the one aimed at, or the one they're riding.
function AI.ResolveTrain(ply)
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
local resolveTrain = AI.ResolveTrain

-- Resolve the AI driver for the train a player aims at / rides / stands nearest.
function AI.ResolveDriver(ply)
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

-- Stable-ordered list of AI drivers (by lead EntIndex) so "#n" means the same
-- train across !ai status and !ai tp.
function AI.OrderedDrivers()
    local list = {}
    for lead, drv in pairs(AI.Drivers) do
        if IsValid(lead) then list[#list + 1] = drv end
    end
    table.sort(list, function(a, b)
        return (IsValid(a.lead) and a.lead:EntIndex() or 0) < (IsValid(b.lead) and b.lead:EntIndex() or 0)
    end)
    return list
end

function AI.BogeySpeed(w)
    local b = (IsValid(w.FrontBogey) and w.FrontBogey) or (IsValid(w.RearBogey) and w.RearBogey)
    return math.Round((IsValid(b) and b.Speed) or w.Speed or 0)
end

-- Nearest platform/station to a world position -> (stationIndex, distance_m).
function AI.NearStation(pos)
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
