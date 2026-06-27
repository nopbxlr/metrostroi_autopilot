--------------------------------------------------------------------------------
-- Metrostroi Autopilot - spawning AI consists
--------------------------------------------------------------------------------
-- Two ways to get an AI train:
--   1) Convert: spawn any train with the normal Metrostroi Train Spawner, then
--      aim at it and run metrostroi_ai_add. (Most reliable - reuses the game's
--      own perfect consist geometry.)
--   2) Spawn:  metrostroi_ai_spawn <class> <cars> builds a consist on the track
--      you are looking at, couples it (the exact method the stock spawner uses),
--      then engages the autopilot.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI

-- A small, safe default list of driveable head classes.
AI.KnownTrains = {
    ["gmod_subway_81-717_mvm"] = true,
    ["gmod_subway_81-717_lvz"] = true,
    ["gmod_subway_81-714_mvm"] = true,
    ["gmod_subway_81-714_lvz"] = true,
    ["gmod_subway_81-718"]     = true,
    ["gmod_subway_81-720"]     = true,
    ["gmod_subway_81-722"]     = true,
    ["gmod_subway_ezh"]        = true,
    ["gmod_subway_ezh3"]       = true,
    ["gmod_subway_81-502"]     = true,
    ["gmod_subway_81-717"]     = true,
}

local function placeHead(ply, trace, class)
    local ent = ents.Create(class)
    if not IsValid(ent) then return nil end
    ent.Owner = ply
    if CPPI and IsValid(ply) then ent:SetCreator(ply) end
    -- Put it on the track we are aiming at, level with the rails.
    local ang = Angle(0, ply:EyeAngles().yaw, 0)
    ent:SetPos(trace.HitPos + trace.HitNormal * 40)
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()
    if Metrostroi.RerailTrain and IsValid(ent.FrontBogey) and IsValid(ent.RearBogey) then
        pcall(Metrostroi.RerailTrain, ent)
    end
    return ent
end

-- Position `ent` coupled behind `last`, using the exact bogey-offset maths from
-- the stock train spawner (weapons/gmod_tool/stools/train_spawner.lua).
local function placeBehind(ply, last, class)
    local ent = ents.Create(class)
    if not IsValid(ent) then return nil end
    ent.Owner = ply
    if CPPI and IsValid(ply) then ent:SetCreator(ply) end
    ent:Spawn()

    local bogeyL1 = last.RearBogey
    local bogeyE1, bogeyE2 = ent.FrontBogey, ent.RearBogey
    if not (IsValid(bogeyL1) and IsValid(bogeyE1) and IsValid(bogeyE2)) then
        return ent  -- can't align; leave it spawned, will be rerailed by caller
    end

    bogeyE1:SetPos(bogeyL1:LocalToWorld(Vector(
        bogeyL1.CouplingPointOffset.x * 1.1 + bogeyE1.CouplingPointOffset.x * 1.05,
        bogeyL1.CouplingPointOffset.y - bogeyE1.CouplingPointOffset.y,
        bogeyL1.CouplingPointOffset.z - bogeyE1.CouplingPointOffset.z)))
    bogeyE1:SetAngles(bogeyL1:LocalToWorldAngles(Angle(0, 180, 0)))
    bogeyE2:SetAngles(bogeyE1:LocalToWorldAngles(Angle(0, 180, 0)))
    ent:SetPos(bogeyE1:LocalToWorld(bogeyE1.SpawnPos * Vector(1, -1, -1)))
    ent:SetAngles(last:LocalToWorldAngles(Angle(0, 0, 0)))
    bogeyE2:SetPos(ent:LocalToWorld(bogeyE2.SpawnPos))

    if Metrostroi.RerailTrain then pcall(Metrostroi.RerailTrain, ent) end
    return ent
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

    local trace = IsValid(ply) and ply:GetEyeTrace() or nil
    if not (trace and trace.Hit) then
        return false, "aim at a piece of track to spawn on"
    end

    local trains = {}
    local head = placeHead(ply, trace, class)
    if not IsValid(head) then return false, "failed to create the train" end
    trains[1] = head

    for i = 2, count do
        local ent = placeBehind(ply, trains[i - 1], class)
        if IsValid(ent) then trains[i] = ent end
    end

    -- Couple them exactly like the stock spawner does, then engage AI.
    for i, train in ipairs(trains) do
        train.IgnoreEngine = true
        if IsValid(train.FrontBogey) and IsValid(train.RearBogey) then
            train.RearBogey.MotorForce  = 40000
            train.FrontBogey.MotorForce = 40000
            train.RearBogey.PneumaticBrakeForce  = 50000
            train.FrontBogey.PneumaticBrakeForce = 50000
            if i == #trains then
                train.RearBogey.MotorPower  = 1   -- push the stack together
                train.FrontBogey.MotorPower = 0
            else
                train.RearBogey.MotorPower  = 0
                train.FrontBogey.MotorPower = 0
            end
            if i == 1 then
                train.FrontBogey.BrakeCylinderPressure = 3  -- hold the front
                train.RearBogey.BrakeCylinderPressure  = 3
            else
                train.FrontBogey.BrakeCylinderPressure = 0
                train.RearBogey.BrakeCylinderPressure  = 0
            end
        end
        train.RearAutoCouple  = true
        train.FrontAutoCouple = i > 1 and i < #trains
    end

    -- Let physics settle & couple, then hand over to the autopilot.
    local headEnt = trains[1]
    timer.Simple(3 + #trains, function()
        if not IsValid(headEnt) then return end
        for _, t in ipairs(trains) do
            if IsValid(t) and IsValid(t.FrontBogey) then
                t.FrontBogey.MotorPower = 0
                t.RearBogey.MotorPower  = 0
            end
        end
        local ok, drvOrErr = AI.Engage(headEnt)
        if not ok then AI.Msg("spawn: could not engage AI (", tostring(drvOrErr), ")") end
    end)

    return true, head
end
