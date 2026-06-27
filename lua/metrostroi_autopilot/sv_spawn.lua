--------------------------------------------------------------------------------
-- Metrostroi Autopilot - spawning AI consists
--------------------------------------------------------------------------------
-- Each car is spawned through the train entity's OWN SpawnFunction - the exact
-- path the Metrostroi Train Spawner tool uses - so the game handles track
-- detection and rerailing. We just place the extra cars one car-length back
-- along the track, then force-couple the consist and engage the autopilot.
--
-- (Hand-rolling ents.Create + manual RerailTrain was unreliable - cars spawned
--  off-track / frozen. Delegating to SpawnFunction fixes that.)
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI

-- Spawn one car via its entity's SpawnFunction (does track detect + rerail).
local function spawnCar(ply, tr, class)
    local stored = scripted_ents.GetStored(class)
    if not (stored and stored.t and stored.t.SpawnFunction) then return nil end
    local ok, ent = pcall(stored.t.SpawnFunction, stored.t, ply, tr, class, false)
    return (ok and IsValid(ent)) and ent or nil
end

-- A downward world trace at a position, to feed SpawnFunction for the extra cars.
local function downTrace(ply, worldPos)
    return util.TraceLine({
        start  = worldPos + Vector(0, 0, 300),
        endpos = worldPos - Vector(0, 0, 300),
        filter = IsValid(ply) and ply or nil,
        mask   = MASK_NPCWORLDSTATIC,
    })
end

-- Nearest coupler / bogey of a car to a world point (the one facing the neighbour).
local function nearestNamed(car, toPos, names)
    local best, bd
    for _, n in ipairs(names) do
        local e = car[n]
        if IsValid(e) then
            local d = e:GetPos():DistToSqr(toPos)
            if not bd or d < bd then bd, best = d, e end
        end
    end
    return best
end

-- Force two adjacent cars to couple by welding their nearest couplers directly,
-- bypassing the flaky StartTouch auto-couple. gmod_train_couple:Couple()
-- repositions + welds regardless of the gap; falls back to bogey couplers.
function AI.ForceCouple(a, b, maxDist)
    if not (IsValid(a) and IsValid(b)) then return false end
    local maxSqr = (maxDist or 1000) ^ 2   -- only couple genuinely adjacent couplers
    local ca = nearestNamed(a, b:GetPos(), { "FrontCouple", "RearCouple" })
    local cb = nearestNamed(b, a:GetPos(), { "FrontCouple", "RearCouple" })
    if IsValid(ca) and IsValid(cb) and not ca.CoupledEnt and not cb.CoupledEnt
       and ca.Couple and ca:GetPos():DistToSqr(cb:GetPos()) < maxSqr then
        if (pcall(ca.Couple, ca, cb)) then return true end
    end
    local ba = nearestNamed(a, b:GetPos(), { "FrontBogey", "RearBogey" })
    local bb = nearestNamed(b, a:GetPos(), { "FrontBogey", "RearBogey" })
    if IsValid(ba) and IsValid(bb) and not ba.CoupledBogey and not bb.CoupledBogey
       and ba.Couple and ba:GetPos():DistToSqr(bb:GetPos()) < maxSqr then
        return (pcall(ba.Couple, ba, bb))
    end
    return false
end

--------------------------------------------------------------------------------
-- Spawn a consist of `count` cars of `class` and engage the autopilot.
--------------------------------------------------------------------------------
function AI.SpawnConsist(ply, class, count)
    if not (Metrostroi and Metrostroi.RerailTrain) then
        return false, "Metrostroi is not loaded yet"
    end
    class = class or "gmod_subway_81-717_mvm"
    if not scripted_ents.GetStored(class) then
        return false, "unknown train class '" .. tostring(class) .. "'"
    end
    count = math.Clamp(math.floor(tonumber(count) or 4), 1, 8)
    if not IsValid(ply) then
        return false, "spawn must be run by a player aiming at track"
    end
    local trace = ply:GetEyeTrace()
    if not (trace and trace.Hit) then
        return false, "aim at a piece of track to spawn on"
    end

    -- Head car: the train's own SpawnFunction puts it on the track and rerails it.
    local head = spawnCar(ply, trace, class)
    if not IsValid(head) then
        return false, "failed to spawn the head car (train limit reached?)"
    end
    local trains = { head }

    -- Extra cars: one car-length back along the head's facing, dropped onto the
    -- track by SpawnFunction (which traces down and rerails each one).
    local CAR  = 1010                 -- ~ coupler-to-coupler length, source units
    local back = -head:GetForward()
    for i = 2, count do
        local p = head:GetPos() + back * (CAR * (i - 1))
        local ent = spawnCar(ply, downTrace(ply, p), class)
        if IsValid(ent) then trains[i] = ent end
    end

    -- Couple + engage shortly after, once couplers/bogeys exist.
    timer.Simple(0.7, function()
        local coupled = 0
        for i = 1, #trains - 1 do
            if IsValid(trains[i]) and IsValid(trains[i + 1])
               and AI.ForceCouple(trains[i], trains[i + 1], 1400) then
                coupled = coupled + 1
            end
        end
        AI.Msg("spawned ", #trains, " car(s), force-coupled ", coupled, " joint(s).")
        timer.Simple(0.5, function()
            if IsValid(head) then
                local ok, err = AI.Engage(head)
                if not ok then AI.Msg("spawn: could not engage AI (", tostring(err), ")") end
            end
        end)
    end)

    return true, head
end
