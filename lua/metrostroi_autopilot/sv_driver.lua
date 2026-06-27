--------------------------------------------------------------------------------
-- Metrostroi Autopilot - per-consist AI driver
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI

-- planning / scan distances (metres)
local STOP_BEFORE_SIGNAL_M = 6      -- stop this far short of a red signal
local STATION_CORRIDOR_U   = 280    -- lateral units a platform may be from us to count as "ours"
local TRAIN_CORRIDOR_U     = 120    -- lateral units to treat another train as "on our track"
local TRAIN_SAFE_GAP_U     = 700    -- keep this far behind another train
local PLATFORM_CLEAR_U     = 500    -- a served platform is "left behind" past this
local ARRIVE_SPEED         = 2.5    -- km/h, considered stopped for arrival
local ARRIVE_TOL_M         = 4.0    -- how close the nose must be to the stop point
local PLATFORM_STOP_OFFSET = 2.5    -- m short of the platform far end to aim the nose

--------------------------------------------------------------------------------
-- Driver "class"
--------------------------------------------------------------------------------
local DRIVER = {}
DRIVER.__index = DRIVER
AI.Driver = DRIVER

function AI.MakeDriver(lead)
    local drv = setmetatable({}, DRIVER)
    drv.lead       = lead
    drv.state      = "DRIVE"
    drv.power      = 0
    drv.lastThink  = CurTime()
    drv.platforms  = {}
    drv.nextPlatformScan = 0
    drv:RefreshWagons()
    return drv
end

--------------------------------------------------------------------------------
-- Engage / disengage
--------------------------------------------------------------------------------
function AI.Engage(ent)
    if not IsValid(ent) then return false, "invalid entity" end

    -- If the player aimed at a bogey / wheels, hop to the parent train.
    local lead = ent
    if ent.GetNW2Entity then
        local p = ent:GetNW2Entity("TrainEntity")
        if IsValid(p) then lead = p end
    end
    if not (lead.WagonList or lead.FrontBogey) then
        return false, "that is not a Metrostroi train"
    end
    if AI.Drivers[lead] then return false, "this train is already on AI" end
    for _, d in pairs(AI.Drivers) do
        for _, w in ipairs(d.wagons or {}) do
            if w == lead then return false, "this consist is already on AI" end
        end
    end

    local drv = AI.MakeDriver(lead)
    drv:Engage()
    AI.Drivers[lead] = drv
    return true, drv
end

function DRIVER:RefreshWagons()
    local lead = self.lead
    self.wagons = {}
    if IsValid(lead) and istable(lead.WagonList) then
        for _, w in pairs(lead.WagonList) do
            if IsValid(w) and (w.FrontBogey or w.RearBogey) then
                self.wagons[#self.wagons + 1] = w
            end
        end
    end
    if #self.wagons == 0 and IsValid(lead) then self.wagons = { lead } end
end

function DRIVER:Engage()
    self:RefreshWagons()
    for _, w in ipairs(self.wagons) do
        w.IgnoreEngine = true               -- take the bogeys away from the dead electric sim
        w.AI_Controlled = true
        w:SetNW2Bool("AIControlled", true)
        for _, b in ipairs({ w.FrontBogey, w.RearBogey }) do
            if IsValid(b) then
                b.MotorForce         = AI.CVars.motorforce:GetFloat()
                b.PneumaticBrakeForce = AI.CVars.brakeforce:GetFloat()
            end
        end
    end
    self.travelDir = self.wagons[1]:GetForward()
    self:GetHead()
    self:ScanPlatforms()
    self.profile = AI.MatchProfile(self.head) or AI.MatchProfile(self.wagons[1])
    if self.profile and AI.CVars.powerup:GetInt() == 1 then
        for _, w in ipairs(self.wagons) do
            self.profile.CarLights(w)
            if w == self.head then self.profile.ActivateCab(w) else self.profile.DeactivateCab(w) end
        end
    end
    self.activeCab = self.head
    self:ApplyDrive(0, AI.HOLD_BRAKE)
    AI.Msg("engaged on a ", #self.wagons, "-car train", self.profile and "" or " (model not profiled: drives only)", ".")
end

function DRIVER:Disengage()
    for _, w in ipairs(self.wagons or {}) do
        if IsValid(w) then
            for _, b in ipairs({ w.FrontBogey, w.RearBogey }) do
                if IsValid(b) then
                    b.MotorPower = 0
                    b.BrakeCylinderPressure = AI.HOLD_BRAKE
                end
            end
            w.IgnoreEngine = false           -- give control back to the real systems
            w.AI_Controlled = nil
            w:SetNW2Bool("AIControlled", false)
            w:SetNW2String("AIStatus", "")
        end
    end
    if IsValid(self.lead) then AI.Drivers[self.lead] = nil end
    AI.Msg("disengaged a train.")
end

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------
-- Find the foremost wagon along the travel direction and refine travelDir to
-- the local track tangent so we follow curves smoothly.
function DRIVER:GetHead()
    self:RefreshWagons()
    if #self.wagons == 0 then return nil end
    if not self.travelDir then self.travelDir = self.wagons[1]:GetForward() end

    local head, best = self.wagons[1], -math.huge
    for _, w in ipairs(self.wagons) do
        local d = w:GetPos():Dot(self.travelDir)
        if d > best then best, head = d, w end
    end

    -- Refine travel direction to the track tangent at the head (keeps the right sense).
    local tp = Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    if tp and tp[1] and tp[1].node1 and tp[1].node1.dir then
        local td = tp[1].node1.dir
        if isvector(td) and td:LengthSqr() > 0 then
            if td:Dot(self.travelDir) < 0 then td = -td end
            self.travelDir = td
        end
    end

    self.head = head
    self.headFront = head:GetPos() + self.travelDir * AI.HALF_CAR
    return head
end

-- Keep the active (head) cab's reverser matched to the direction we're moving:
-- forward if the cab faces our travel direction, reverse if it faces backward.
-- Also performs a cab change when the head end flips (after reversing), so only
-- one cab is ever lit and only one driver brake valve is on the line.
function DRIVER:UpdateReverser()
    local h = self.head
    if not (IsValid(h) and self.profile) then return end

    if self.activeCab ~= h then
        if IsValid(self.activeCab) then self.profile.DeactivateCab(self.activeCab) end
        if AI.CVars.powerup:GetInt() == 1 then self.profile.ActivateCab(h) end
        self.activeCab = h
    end

    local dir = (h:GetForward():Dot(self.travelDir) > 0) and 1 or -1
    if self.reverserHead == h and self.reverserDir == dir then return end   -- no change
    self.reverserHead, self.reverserDir = h, dir
    self.profile.Reverser(h, dir)
end

-- Current speed (km/h). Read from the bogeys, which always compute it,
-- even while IgnoreEngine has taken the wagon away from the electric sim.
function DRIVER:GetSpeed()
    local h = self.head
    if not IsValid(h) then return 0 end
    local b = (IsValid(h.FrontBogey) and h.FrontBogey) or (IsValid(h.RearBogey) and h.RearBogey)
    if IsValid(b) and b.Speed then return b.Speed end
    return h.Speed or 0
end

-- Signed distance (source units) from the nose to a world point, along travel.
function DRIVER:ForwardDist(worldpos)
    return (worldpos - self.headFront):Dot(self.travelDir)
end

-- Lateral distance (units) of a world point from our travel centreline.
function DRIVER:LateralDist(worldpos)
    local rel = worldpos - self.headFront
    local along = rel:Dot(self.travelDir)
    return (rel - self.travelDir * along):Length()
end

--------------------------------------------------------------------------------
-- Braking maths
--------------------------------------------------------------------------------
-- Highest speed (km/h) from which we can still stop within s_m metres.
function DRIVER:StopSpeed(s_m)
    if s_m <= 0 then return 0 end
    local a = math.max(0.1, AI.CVars.decel:GetFloat())
    return math.sqrt(2 * a * s_m) * 3.6
end

-- Speed (km/h) we may run at now so we have slowed to vlimit by s_m metres ahead.
function DRIVER:ApproachSpeed(vlimit_kmh, s_m)
    if s_m <= 0 then return vlimit_kmh or 0 end
    local a = math.max(0.1, AI.CVars.decel:GetFloat())
    local v = (vlimit_kmh or 0) / 3.6
    return math.sqrt(v * v + 2 * a * s_m) * 3.6
end

--------------------------------------------------------------------------------
-- Bogey actuation - the only thing that physically moves the train
--------------------------------------------------------------------------------
function DRIVER:ApplyDrive(power, brake)
    power = math.Clamp(power or 0, 0, 1)
    brake = math.Clamp(brake or 0, 0, 6)
    local D = self.travelDir or vector_origin
    local mf = AI.CVars.motorforce:GetFloat()
    local bf = AI.CVars.brakeforce:GetFloat()
    for _, w in ipairs(self.wagons) do
        if IsValid(w) then
            w.IgnoreEngine = true
            for _, b in ipairs({ w.FrontBogey, w.RearBogey }) do
                if IsValid(b) then
                    b.MotorForce          = mf
                    b.PneumaticBrakeForce = bf
                    -- push this bogey along the consist travel direction
                    b.Reversed = D:Dot(b:GetForward()) > 0
                    b.MotorPower = power
                    b.BrakeCylinderPressure = brake
                end
            end
        end
    end
    self.curPower, self.curBrake = power, brake
end

--------------------------------------------------------------------------------
-- Lookahead: speed limits and stop points
--------------------------------------------------------------------------------
-- IMPORTANT: we must NOT call the recursive track-scan functions
-- (GetARSJoint / GetNextTrafficLight / IsTrackOccupied) ourselves - on looped
-- networks, or with a not-yet-registered train, they can recurse without end
-- and trigger an uncatchable engine "Lua panic". Instead we read the train's
-- own ARS receiver (ALSCoil), which the game computes safely each tick, and we
-- look at signal ENTITIES directly (no recursion) for hard red-signal stops.

-- Scan signal entities ahead that face us (no recursion). Picks the nearest
-- governing signal. If it is red -> returns a stop-curve target. If it is clear,
-- records its ARS code as the permitted block speed (-> self.arsSignalSpeed) so
-- ARSMaxSpeed() can use it as a fallback when the on-board ALS isn't reading.
function DRIVER:SignalScan(limit)
    self.arsSignalSpeed = nil
    if AI.CVars.obey_signals:GetInt() == 0 then self.holdSignal = nil return limit end

    local bestFd, bestSig
    for _, sig in ipairs(self.signals or {}) do
        if IsValid(sig) then
            local p = sig:GetPos()
            local fd = self:ForwardDist(p)
            if fd > 0 and self:LateralDist(p) < STATION_CORRIDOR_U
               and sig:GetForward():Dot(self.travelDir) < -0.25 then   -- faces us
                if not bestFd or fd < bestFd then bestFd, bestSig = fd, sig end
            end
        end
    end
    if not bestSig then self.holdSignal = nil return limit end

    if (bestSig.ARSSpeedLimit == 0) or bestSig.Occupied or bestSig.Close or bestSig.KGU then
        self.holdSignal = true                       -- red / occupied: plan a stop
        local s_m = math.max(0, (bestFd / AI.U_PER_M) - STOP_BEFORE_SIGNAL_M)
        return math.min(limit, self:StopSpeed(s_m))
    end
    self.holdSignal = nil
    self.arsSignalSpeed = AI.ARS_SPEED[bestSig.ARSSpeedLimit]   -- its code = block speed
    return limit
end

-- The ARS-authorised max speed (km/h), or nil if no ARS code is available here.
-- Prefers the train's own ALS receiver; falls back to the governing signal code.
function DRIVER:ARSMaxSpeed()
    if AI.CVars.obey_signals:GetInt() == 0 then return nil end
    local h = self.head
    local als = IsValid(h) and (h.ALSCoil or (h.Systems and h.Systems["ALSCoil"]))
    if als then
        if     (als.F1 or 0) > 0 then return 80
        elseif (als.F2 or 0) > 0 then return 70
        elseif (als.F3 or 0) > 0 then return 60
        elseif (als.F4 or 0) > 0 then return 40
        elseif (als.F5 or 0) > 0 then return 20 end  -- restrictive aspect: crawl
    end
    return self.arsSignalSpeed                        -- from SignalScan (may be nil)
end

-- Curve speed limit: sample the track a little ahead and limit speed where it bends.
function DRIVER:CurveLimit(pos, limit)
    if not (pos and pos.path and pos.x) then return limit end
    local path, x = pos.path, pos.x
    local gp = Metrostroi.GetTrackPosition
    if not gp then return limit end

    -- Sample tangents 8 m and 40 m ahead (in the travel sense). pos.x is in
    -- Metrostroi METRES (same units as node.x), so advance by plain metres. The
    -- 32 m baseline smooths out node-to-node kinks so gentle track isn't seen as
    -- a curve.
    local sgn = (isvector(pos.node1 and pos.node1.dir)
                 and self.travelDir:Dot(pos.node1.dir) < 0) and -1 or 1
    local _, d1 = gp(path, x + sgn * 8)
    local _, d2 = gp(path, x + sgn * 40)
    if not (isvector(d1) and isvector(d2)) then return limit end
    d1:Normalize(); d2:Normalize()
    local dot = math.Clamp(d1:Dot(d2), -1, 1)
    local turn = math.acos(dot)                     -- radians over ~32 m of track
    if turn < 0.04 then return limit end            -- ignore near-straight track
    -- R = arclen / angle; cap lateral acceleration (tunable; higher = faster).
    local R = 32 / turn
    local vmax = math.sqrt(math.max(0.3, AI.CVars.curve_lat:GetFloat()) * R) * 3.6
    return math.min(limit, math.max(25, vmax))      -- never crawl below 25 for a curve
end

-- Nearest other train ahead on our track (collision avoidance / unsignalled maps).
function DRIVER:TrainLimit(limit, speed)
    if AI.CVars.avoid_trains:GetInt() == 0 then return limit end
    if not Metrostroi.TrainPositions then return limit end

    local mine = {}
    for _, w in ipairs(self.wagons) do mine[w] = true end

    local a = math.max(0.1, AI.CVars.decel:GetFloat())
    local stopdist_u = ((speed / 3.6) ^ 2 / (2 * a)) * AI.U_PER_M
    local range = math.max(8 * AI.U_PER_M, stopdist_u + 12 * AI.U_PER_M)

    local nearest
    for w in pairs(Metrostroi.TrainPositions) do
        if IsValid(w) and not mine[w] then
            local fd = self:ForwardDist(w:GetPos())
            if fd > 0 and fd < range and self:LateralDist(w:GetPos()) < TRAIN_CORRIDOR_U then
                if not nearest or fd < nearest then nearest = fd end
            end
        end
    end
    if nearest then
        local s_m = math.max(0, (nearest - TRAIN_SAFE_GAP_U)) / AI.U_PER_M
        return math.min(limit, self:StopSpeed(s_m))
    end
    return limit
end

--------------------------------------------------------------------------------
-- Platforms
--------------------------------------------------------------------------------
function DRIVER:ScanPlatforms()
    self.platforms = ents.FindByClass("gmod_track_platform")
    self.signals   = ents.FindByClass("gmod_track_signal")
end

-- Find the next platform beside our track, ahead of us. Selection is keyed on
-- the STOP POINT (far end) - the point the nose should reach - NOT the platform
-- centre. (Keying on the centre deselected the platform as soon as the nose
-- passed the middle, so the train accelerated away half a platform short.)
function DRIVER:NextPlatform()
    if AI.CVars.station_stops:GetInt() == 0 then return nil end
    local best, bestFd
    for _, pf in ipairs(self.platforms or {}) do
        if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
            local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
            local fd = self:ForwardDist(self:PlatformStopPoint(pf))   -- distance to far end
            if pf == self.servedPlatform then
                -- ignore until we have clearly left it behind
                if fd < -PLATFORM_CLEAR_U then self.servedPlatform = nil end
            elseif fd > -AI.HALF_CAR and self:LateralDist(center) < STATION_CORRIDOR_U then
                if not bestFd or fd < bestFd then best, bestFd = pf, fd end
            end
        end
    end
    return best
end

-- The stop point is the platform end furthest along our travel direction,
-- so the whole train ends up berthed within the platform.
function DRIVER:PlatformStopPoint(pf)
    local a, b = pf.PlatformStart, pf.PlatformEnd
    return (self:ForwardDist(a) > self:ForwardDist(b)) and a or b
end

function DRIVER:BeginStationStop(now, pf)
    self.state = "DWELL"
    self.holdUntil = now + math.max(2, AI.CVars.dwell:GetFloat())
    self.servedPlatform = pf
    self:ApplyDrive(0, AI.HOLD_BRAKE)
    if AI.CVars.open_doors:GetInt() == 1 then self:OpenDoors(pf) end
    hook.Run("MetrostroiAI.StationStop", self, pf)
    if IsValid(self.lead) then
        self.lead:SetNW2String("AIStatus", "STATION " .. (pf.StationIndex or "?"))
    end
end

function DRIVER:BeginReverse(now)
    self.travelDir = -self.travelDir
    self.servedPlatform = nil
    self.power = 0
    self.state = "REVERSE_HOLD"
    self.holdUntil = now + 4
    self:ApplyDrive(0, AI.HOLD_BRAKE)
    if IsValid(self.lead) then self.lead:SetNW2String("AIStatus", "TERMINUS") end
end

--------------------------------------------------------------------------------
-- Doors / safety. The driver decides WHAT and WHEN (generic); the train profile
-- knows HOW (model-specific switches). Other addons can also wire the
-- "MetrostroiAI.StationStop" / "...Depart" hooks.
--------------------------------------------------------------------------------
-- Which side is the platform on, relative to travel? (geometry, not PlatformIndex)
function DRIVER:PlatformSide(pf)
    local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
    local rightDir = self.travelDir:Cross(Vector(0, 0, 1))
    return ((center - self.headFront):Dot(rightDir) > 0) and "right" or "left"
end

function DRIVER:OpenDoors(pf)
    if not self.profile then return end
    local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
    for _, w in ipairs(self.wagons) do
        if IsValid(w) then
            -- per-wagon side, so a reversed trailer still opens platform-side
            local wRight = w:GetForward():Cross(Vector(0, 0, 1))
            local side = ((center - w:GetPos()):Dot(wRight) > 0) and "right" or "left"
            self.profile.OpenDoor(w, side)
        end
    end
    self.doorsOpen = true
    if IsValid(self.lead) then
        self.lead:SetNW2String("AIStatus", "DOORS " .. string.upper(self:PlatformSide(pf)))
    end
end

function DRIVER:CloseDoors()
    if not self.doorsOpen then return end
    if self.profile then
        for _, w in ipairs(self.wagons) do self.profile.CloseDoor(w) end
    end
    self.doorsOpen = false
    hook.Run("MetrostroiAI.Depart", self)
end

-- Periodic: re-assert the safety switches a driver would hold (delegated).
function DRIVER:MaintainSafety()
    if not self.profile then return end
    for _, w in ipairs(self.wagons) do self.profile.MaintainSafety(w) end
end

-- Per tick: keep the safety/autostop valves from bleeding the brake line (delegated).
function DRIVER:SuppressSafetyVent()
    if not self.profile then return end
    for _, w in ipairs(self.wagons) do self.profile.SuppressVent(w) end
end

-- Distance (m) to a real buffer / end-of-track ahead, or nil if the track keeps
-- going. We look at the END of the current path (in our travel sense) and probe
-- a short way past it ALONG THE TRACK TANGENT: if no track is there (no junction,
-- no loop-back), it's a terminus. Because it follows the real track geometry it
-- never false-fires on curves the way a straight world-space probe did.
function DRIVER:TerminusDistance(pos)
    if not (pos and pos.path and pos.x and pos.node1 and isvector(pos.node1.dir)) then return nil end
    local path = pos.path
    local first, last = path[1], path[#path]
    if not (first and last) then return nil end
    local sgn = (self.travelDir:Dot(pos.node1.dir) < 0) and -1 or 1
    local endNode = (sgn > 0) and last or first
    if not (isvector(endNode.pos) and isvector(endNode.dir)) then return nil end

    local dist_m = (endNode.x - pos.x) * sgn               -- metres to the path end ahead
    if dist_m <= 0 or dist_m > 400 then return nil end      -- behind us / out of braking range

    local dir = endNode.dir * sgn
    for _, d in ipairs({ 4, 9, 16 }) do                     -- probe just past the end
        local p = endNode.pos + dir * (d * AI.U_PER_M)
        local res = Metrostroi.GetPositionOnTrack(p, dir:Angle())
        if res and res[1] and (res[1].distance or 1e9) < 100 then
            return nil                                      -- track continues -> not a terminus
        end
    end
    return dist_m
end

--------------------------------------------------------------------------------
-- Main per-train update
--------------------------------------------------------------------------------
function DRIVER:Think(now)
    local dt = math.max(0.001, now - (self.lastThink or now))
    self.lastThink = now

    local head = self:GetHead()
    if not IsValid(head) then return end
    self:UpdateReverser()                  -- keep reverser matched to travel direction
    self:SuppressSafetyVent()              -- stop the autostop bleeding the brake line
    local speed = self:GetSpeed()          -- km/h (absolute, from the bogeys)

    -- Hold states (dwelling at a station / pausing to reverse)
    if self.state == "DWELL" or self.state == "REVERSE_HOLD" then
        self:ApplyDrive(0, AI.HOLD_BRAKE)
        if now >= (self.holdUntil or 0) then
            if self.state == "DWELL" then self:CloseDoors() end
            self.state = "DRIVE"
            self.stuckTime, self.hasMoved = 0, false   -- grace period after a stop
        end
        return
    end

    local tp  = Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    local pos = tp and tp[1]

    -- Build the target speed. The ARS code is the AUTHORISED max speed for the
    -- block; the cruise cvar is only a fallback (no code) and an absolute ceiling.
    local cruise = math.max(0, AI.CVars.cruise:GetFloat())
    local stopTarget = self:SignalScan(cruise)        -- red-signal stop + sets arsSignalSpeed
    local target = math.min(cruise, self:ARSMaxSpeed() or cruise)
    target = self:CurveLimit(pos, target)
    target = math.min(target, stopTarget)
    target = self:TrainLimit(target, speed)

    -- Anticipatory end-of-track: start braking for a buffer well before we reach
    -- it (follows the curve; won't false-fire at junctions/loops).
    local term = self:TerminusDistance(pos)
    if term then target = math.min(target, self:StopSpeed(math.max(0, term - 3))) end

    -- Platform stop - precise. Aim a bit short of the far end so the train ends
    -- up fully inside the platform and never rolls past it (which would leave the
    -- doors off the platform). Crawl the last stretch and slam the brakes if we
    -- ever pass the aim point still moving.
    local status = "DRIVE"
    local pf = self:NextPlatform()
    if pf then
        local farFd = self:ForwardDist(self:PlatformStopPoint(pf)) / AI.U_PER_M  -- m to far end
        local aim   = farFd - PLATFORM_STOP_OFFSET
        status = "APPROACH " .. (pf.StationIndex or "?")
        if aim <= 0.3 then
            target = 0
            if speed > ARRIVE_SPEED then                  -- overrunning: emergency brake
                self:ApplyDrive(0, 6)
                if IsValid(self.lead) then
                    self.lead:SetNW2String("AIStatus", "STOPPING " .. (pf.StationIndex or "?"))
                end
                return
            end
        else
            target = math.min(target, self:StopSpeed(aim))
            if aim < 12 then target = math.min(target, 9) end   -- slow, precise final approach
        end
        if speed <= ARRIVE_SPEED and farFd <= 4 then
            self:BeginStationStop(now, pf)
            return
        end
    end

    -- End of track: once we've crept up to the buffer, stop & reverse. The
    -- anticipatory brake above has already slowed us, so this just latches it.
    if term then
        status = "TERMINUS"
        if term <= 5 and speed <= ARRIVE_SPEED then
            if AI.CVars.terminus_rev:GetInt() == 1 then self:BeginReverse(now)
            else self:ApplyDrive(0, AI.HOLD_BRAKE) end
            return
        end
    end

    -- Backstop (off-network maps / missed buffers): no progress while asking for
    -- speed means we've physically hit something.
    if speed > 5 then self.hasMoved = true end
    if self.hasMoved and not pf and not term and target > 10 and speed < 2 then
        self.stuckTime = (self.stuckTime or 0) + dt
    else
        self.stuckTime = 0
    end
    if (self.stuckTime or 0) > 3 then
        self.stuckTime, self.hasMoved = 0, false
        status = "TERMINUS"
        if AI.CVars.terminus_rev:GetInt() == 1 then self:BeginReverse(now)
        else self:ApplyDrive(0, AI.HOLD_BRAKE) end
        return
    end

    if self.holdSignal and speed <= ARRIVE_SPEED then status = "HELD AT SIGNAL" end

    -- Drive toward the target speed
    self:Drive(target, speed, dt)

    if IsValid(self.lead) then
        self.lead:SetNW2String("AIStatus",
            string.format("%s  %d/%d", status, math.Round(speed), math.Round(target)))
    end
end

-- Speed controller: convert (target,current) into power / brake.
function DRIVER:Drive(target, speed, dt)
    target = math.max(0, target)
    local power, brake = 0, 0

    if target <= 0.4 and speed <= 0.8 then
        power, brake = 0, AI.HOLD_BRAKE                 -- stopped: hold
    else
        local err = target - speed
        if err > 0.6 then
            local want = math.Clamp(err / 6, 0.08, 1)   -- ease in near the target
            self.power = math.Clamp((self.power or 0) + dt * 1.5, 0, want)
            power, brake = self.power, 0
        elseif err < -0.6 then
            self.power = 0
            brake = math.Clamp(-err / 5, 0.35, AI.SERVICE_BRAKE_MAX)
        else
            self.power = math.Clamp((self.power or 0) - dt * 1.0, 0, 0.2)
            power, brake = self.power, 0
        end
    end
    self:ApplyDrive(power, brake)
end

-- Periodic platform list refresh (cheap, every few seconds)
hook.Add("Think", "MetrostroiAI.PlatformScan", function()
    if not MetrostroiAI.Loaded then return end
    local now = CurTime()
    for _, drv in pairs(MetrostroiAI.Drivers) do
        if now >= (drv.nextPlatformScan or 0) then
            drv.nextPlatformScan = now + 5
            drv:ScanPlatforms()
            drv:MaintainSafety()
        end
    end
end)
