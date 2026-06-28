--------------------------------------------------------------------------------
-- Metrostroi Autopilot - per-consist AI driver
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI

-- planning / scan distances (metres)
local STOP_BEFORE_SIGNAL_M = 6      -- stop this far short of a red signal
local STATION_CORRIDOR_U   = 280    -- lateral units a platform may be from us to count as "ours"
local TRAIN_CORRIDOR_U     = 120    -- lateral units to treat another train as "on our track"
local TRAIN_SAFE_GAP_U     = 700    -- keep this far behind another train (straight-corridor scan)
local TRAIN_SAFE_GAP_M     = 30     -- metres to keep behind the car in front (along-the-rails scan)
local PLATFORM_CLEAR_U     = 500    -- a served platform is "left behind" past this
local ARRIVE_SPEED         = 2.5    -- km/h, considered stopped for arrival
local ARRIVE_TOL_M         = 4.0    -- how close the nose must be to the stop point
local PLATFORM_STOP_OFFSET = 0.0    -- aim the nose exactly at the platform far end (precise berth, full use of short platforms)
local BRAKE_PER_MS2        = 1.7    -- atm of brake per m/s^2 wanted (~4.2 atm = full service ~2.5 m/s^2)
local TERMINUS_BUFFER      = 5.0    -- m to stop short of an end-of-track buffer
local TURNBACK_SCAN_M      = 400    -- m ahead to look for a turn-back crossover switch (covers approach-side crossovers, not just tail-track ones)
local TURNBACK_NEAR_U      = 260    -- lateral units: a switch this close is on OUR track (the entry switch)
local TURNBACK_FAR_U       = 600    -- ... this far out is the other track (the scissors/crossover diagonal partner)
local TURNBACK_DIAG_M      = 60     -- max longitudinal span of a crossover diagonal (entry <-> exit switch)

-- Constants shared with the lookahead / stations modules (split out of this file).
AI.C = {
    STOP_BEFORE_SIGNAL_M = STOP_BEFORE_SIGNAL_M, STATION_CORRIDOR_U = STATION_CORRIDOR_U,
    TRAIN_CORRIDOR_U = TRAIN_CORRIDOR_U, TRAIN_SAFE_GAP_U = TRAIN_SAFE_GAP_U, TRAIN_SAFE_GAP_M = TRAIN_SAFE_GAP_M,
    PLATFORM_CLEAR_U = PLATFORM_CLEAR_U, ARRIVE_SPEED = ARRIVE_SPEED, ARRIVE_TOL_M = ARRIVE_TOL_M,
    PLATFORM_STOP_OFFSET = PLATFORM_STOP_OFFSET, BRAKE_PER_MS2 = BRAKE_PER_MS2, TERMINUS_BUFFER = TERMINUS_BUFFER,
    TURNBACK_SCAN_M = TURNBACK_SCAN_M, TURNBACK_NEAR_U = TURNBACK_NEAR_U, TURNBACK_FAR_U = TURNBACK_FAR_U,
    TURNBACK_DIAG_M = TURNBACK_DIAG_M,
}

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
            self.profile.PowerCar(w)   -- electrics + doors on every car
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

-- Publish the AI status string to EVERY car (not just the lead) so the floating
-- label and the detail HUD are readable from whichever car you're riding in.
-- NW2String is delta-compressed, so re-setting the same value costs no traffic.
function DRIVER:SetStatus(s)
    self.status = s
    for _, w in ipairs(self.wagons or {}) do
        if IsValid(w) then w:SetNW2String("AIStatus", s) end
    end
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
-- Main per-train update
--------------------------------------------------------------------------------
function DRIVER:Think(now)
    local dt = math.max(0.001, now - (self.lastThink or now))
    self.lastThink = now

    local head = self:GetHead()
    if not IsValid(head) then return end
    self:UpdateReverser()                  -- keep reverser matched to travel direction
    self:SuppressSafetyVent()              -- stop the autostop bleeding the brake line
    self:MaintainTurnback()                -- hold the turn-back crossover until we're past it
    local speed = self:GetSpeed()          -- km/h (absolute, from the bogeys)

    -- Hold states (dwelling at a station / pausing to reverse)
    if self.state == "DWELL" or self.state == "REVERSE_HOLD" then
        self:ApplyDrive(0, AI.HOLD_BRAKE)
        if now >= (self.holdUntil or 0) then
            if self.state == "DWELL" and self:RegulationHold(now) then
                self:SetStatus("REGULATING " .. (IsValid(self.servedPlatform) and (self.servedPlatform.StationIndex or "") or ""))
                return                                 -- keep doors open, hold for regulation
            end
            if self.state == "DWELL" then
                self:CloseDoors()
                -- Terminus station (the map's PA marker flags it) with the crossover
                -- AT the platform (no tail track): turn back right here. If there's a
                -- deadlock tail track, the crossover is up the throat - so we DON'T
                -- reverse here; we run on into the tail and turn back there instead.
                if self.servedIsTerminus and not self.servedDeadlock
                   and AI.CVars.terminus_rev:GetInt() == 1
                   and not self:RecentlyReversedNear(now) then
                    self.servedIsTerminus = nil
                    self:BeginReverse(now)
                    return
                end
            end
            self.state = "DRIVE"
            self.stuckTime, self.hasMoved = 0, false   -- grace period after a stop
        end
        return
    end

    local tp  = Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    local pos = tp and tp[1]
    local dir = Metrostroi.TrainDirections and Metrostroi.TrainDirections[head]
    self:UpdateARS(pos, dir, now)                      -- refresh the governing ARS signal
    self:UpdateRoutePos(pos)                           -- track position along the route (for ahead-checks)

    -- Build the target speed from every limit. The ARS code IS the AUTHORISED max
    -- wherever the track sends one; cruise is ONLY the fallback for un-coded track
    -- - it must NEVER cap an ARS block (a cruise of 60 was dragging ARS-70 sections
    -- down to 60: that was the "60 instead of 70" all along). Each limit is computed
    -- standalone so the debug can show which one is actually binding.
    local cruise    = math.max(0, AI.CVars.cruise:GetFloat())
    local arsMax    = self:ARSMaxSpeed()
    -- No ARS code: if the line IS coded and the code just dropped out (an un-coded
    -- throat / dead-end stub past a terminus), crawl at 7 km/h - un-coded track is
    -- unsignalled, so feel your way rather than barrel into it. A map with NO ARS at
    -- all (we never saw a code) isn't crippled: it keeps the normal cruise fallback.
    local base      = arsMax or (self.arsEverSeen and math.min(cruise, 7) or cruise)
    local curveLim  = self:CurveLimit(pos, 9999)
    local signalLim = self:SignalStop(9999)
    local trainLim  = self:TrainLimit(9999, speed)
    local term      = self:TerminusDistance(pos)
    local termLim   = term and self:StopSpeed(math.max(0, term - 3)) or 9999
    local target = math.min(base, curveLim, signalLim, trainLim, termLim)
    self.dbg = { cruise = cruise, ars = arsMax, curve = curveLim, signal = signalLim,
                 train = trainLim, term = termLim, target = target }
    self:TryOpenSignal(now, speed)             -- request a route if held at a red route signal

    local status = "DRIVE"
    local pf = self:NextPlatform()
    local platAim = pf and (self:ForwardDist(self:PlatformStopPoint(pf)) / AI.U_PER_M - PLATFORM_STOP_OFFSET)

    -- Approaching a terminus with nothing to serve: line the turn-back crossover
    -- EARLY, while we're still well short of the points - so they're clear of the
    -- train and can actually throw, and we divert across the scissors instead of
    -- arriving on top of switches that then refuse. Fires as soon as a buffer is in
    -- range (coded track or throat); OnReturnTrack stops it once we've crossed over.
    if AI.CVars.terminus_rev:GetInt() == 1 and not pf and not self.arsReverseCooldown
       and not self:RecentlyReversedNear(now) and now >= (self.nextApproachRoute or 0) then
        if self:TrackEndAhead(240) and not self:OnReturnTrack() then
            self.nextApproachRoute = now + 1.0
            self:OpenTurnbackRoute()
        end
    end

    -- HARD STOP for a red signal / train ahead, using the same precise distance
    -- braking so a stop is actually held at instead of rolled through. Only takes
    -- PRIORITY over the platform when the obstacle is genuinely BEFORE it - a red
    -- AT the platform exit must let us berth (doors) first, then hold the departure.
    local obstacleM = math.min(self.sigStopM or math.huge, self.trainStopM or math.huge)
    if obstacleM < math.huge and (not platAim or obstacleM < platAim - 5) then
        if obstacleM <= 0.6 then
            self:ApplyDrive(0, speed > ARRIVE_SPEED and 6 or AI.HOLD_BRAKE)
            self:SetStatus(self.holdSignal and "HELD AT SIGNAL" or "HELD (train ahead)")
            return
        end
        local vms  = speed / 3.6
        local need = (vms * vms) / (2 * obstacleM)
        if need >= math.max(0.2, AI.CVars.station_decel:GetFloat()) then
            -- 40% margin + full service authority: always pull up short of the
            -- stop, never overrun it (safety beats comfort at a red).
            self:ApplyDrive(0, math.Clamp(need * BRAKE_PER_MS2 * 1.4, 1.0, 6))
            self:SetStatus(self.holdSignal and "STOPPING (signal)" or "STOPPING (train)")
            return
        end
        target = math.min(target, self:StopSpeed(obstacleM))
    end

    -- END OF TRACK (geometry-authoritative, ARS-corroborated). Losing the ARS code
    -- with no platform to serve is only the CUE to look; the geometric forward rail
    -- scan is the AUTHORITY. We follow the actual rail ahead and act ONLY if it
    -- genuinely ends within braking range - then a precise feed-forward stop short
    -- of the buffer, and a turn-back through the crossover behind us. If the rail
    -- still runs ahead (a transient or mid-line ARS dropout), we do nothing, so a
    -- blip can never brake or reverse the train. The cooldown (cleared on re-
    -- acquiring a code, set by BeginReverse) lets the reversed train drive back off
    -- the un-coded stub instead of instantly re-detecting the end behind it.
    if self:ARSLost(now) and not pf and not self.arsReverseCooldown then
        local endM = self:TrackEndAhead(200)
        if endM then
            local aim = endM - TERMINUS_BUFFER
            if speed <= ARRIVE_SPEED and aim <= 1.2 then
                if AI.CVars.terminus_rev:GetInt() == 1 and not self:RecentlyReversedNear(now) then
                    self:BeginReverse(now)
                else
                    self:ApplyDrive(0, AI.HOLD_BRAKE); self:SetStatus("TERMINUS (rail ends)")
                end
                return
            end
            local vms  = speed / 3.6
            local need = (aim > 0.05) and (vms * vms) / (2 * aim) or 99
            self:ApplyDrive(0, math.Clamp(need * BRAKE_PER_MS2 * 1.3, 0.6, 6))
            self:SetStatus(string.format("RAIL ENDS %dm", math.Round(endM)))
            return
        end
        -- ARS lost but the rail clearly continues: a blip / un-coded gap, not a dead
        -- end. Don't stop - fall through and keep driving (cruise governs).
    end

    -- Platform stop - DISTANCE-BASED braking. Each tick we work out the
    -- deceleration needed to bring the nose to rest on the aim point (a couple of
    -- metres short of the far end) and command exactly that brake. Re-solving it
    -- live makes it self-correcting: the train settles onto a smooth braking curve
    -- and stops on the mark, with no speed-error lag riding over it, no last-moment
    -- slam, and no overrun (the old proportional law caused all three).
    if pf then
        local farFd = self:ForwardDist(self:PlatformStopPoint(pf)) / AI.U_PER_M  -- m, nose -> far end
        local aim   = farFd - PLATFORM_STOP_OFFSET                               -- m, nose -> stop point
        local sdec  = math.max(0.2, AI.CVars.station_decel:GetFloat())
        status = "APPROACH " .. (pf.StationIndex or "?")
        self.dbg.platform = self:StopSpeed(math.max(0, aim))

        if speed <= ARRIVE_SPEED and aim <= 1.5 then
            self:BeginStationStop(now, pf)                  -- berthed on the mark
            return
        end
        if aim <= 0.4 then
            -- on/over the mark and still rolling: ease it to a halt (gentle, it's slow)
            self:ApplyDrive(0, speed > ARRIVE_SPEED and 4 or AI.HOLD_BRAKE)
            if IsValid(self.lead) then
                self:SetStatus("STOPPING " .. (pf.StationIndex or "?"))
            end
            return
        end
        local vms       = speed / 3.6
        local needDecel = (aim > 0.05) and (vms * vms) / (2 * aim) or 99
        if needDecel >= sdec then
            -- close enough that we must brake: command the deceleration we need
            self:ApplyDrive(0, math.Clamp(needDecel * BRAKE_PER_MS2, 0.4, 5))
            self:SetStatus(status)
            return
        end
        target = math.min(target, self:StopSpeed(aim))      -- still far: just cap cruise speed
    end

    -- End of track: pull into the tail track and stop precisely short of the
    -- buffer (same distance-based feedforward as the platform stop, so we never
    -- nose into the wall), then turn the train back.
    if term then
        status = "TERMINUS"
        local aim  = term - TERMINUS_BUFFER
        local sdec = math.max(0.2, AI.CVars.station_decel:GetFloat())
        if speed <= ARRIVE_SPEED and aim <= 1.2 then
            if AI.CVars.terminus_rev:GetInt() == 1 and not self:RecentlyReversedNear(now) then self:BeginReverse(now)
            else self:ApplyDrive(0, AI.HOLD_BRAKE) end
            return
        end
        if aim <= 0.4 then
            self:ApplyDrive(0, speed > ARRIVE_SPEED and 4 or AI.HOLD_BRAKE)
            self:SetStatus("TERMINUS")
            return
        end
        local vms  = speed / 3.6
        local need = (aim > 0.05) and (vms * vms) / (2 * aim) or 99
        if need >= sdec then
            self:ApplyDrive(0, math.Clamp(need * BRAKE_PER_MS2, 0.4, 5))
            self:SetStatus("TERMINUS")
            return
        end
        target = math.min(target, self:StopSpeed(aim))
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
        if AI.CVars.terminus_rev:GetInt() == 1 and not self:RecentlyReversedNear(now) then
            self.stuckTime, self.hasMoved = 0, false
            status = "TERMINUS"
            self:BeginReverse(now)
            return
        end
        -- Stuck again right after a turn-back nearby: that's the dead-end <-> failed-
        -- crossover oscillation, not a fresh terminus. Hold instead of bouncing back.
        self.stuckTime = 0
        self:ApplyDrive(0, AI.HOLD_BRAKE)
        self:SetStatus("STUCK (held; turned back nearby)")
        return
    end

    if self.holdSignal and speed <= ARRIVE_SPEED then status = "HELD AT SIGNAL" end

    -- Crawl through the turn-back points. A scissors taken at line speed derails the
    -- bogeys on the diverging frogs (the switches are set right, but we were charging
    -- through at 40), so cap the speed while a turn-back route is committed / held.
    if self.turnbackRouteRef or (self.turnbackSwitches and #self.turnbackSwitches > 0) then
        target = math.min(target, AI.CVars.turnback_speed and AI.CVars.turnback_speed:GetFloat() or 12)
        if status == "DRIVE" then status = "TURNBACK" end
    end

    -- Drive toward the target speed
    self:Drive(target, speed, dt)

    local s = string.format("%s  %d/%d", status, math.Round(speed), math.Round(target))
    if AI.CVars.debug:GetInt() == 1 then
        s = s .. string.format("  ARS[code %s, next %s]=%s  sig:%s",
            tostring(self.arsCode), tostring(self.arsNext), tostring(self.arsSpeed),
            IsValid(self.arsSignal) and tostring(self.arsSignal.Name) or "-")
    end
    self:SetStatus(s)
end

-- Smoothed longitudinal acceleration (m/s^2) from the lead bogey, used to keep
-- tractive effort comfortable instead of slamming to full power.
function DRIVER:Accel()
    local h = self.head
    local b = IsValid(h) and ((IsValid(h.FrontBogey) and h.FrontBogey) or h.RearBogey)
    local a = (IsValid(b) and b.Acceleration) or 0
    self.accelSmooth = (self.accelSmooth or 0) * 0.6 + a * 0.4
    return self.accelSmooth
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
            -- Close the loop on ACCELERATION: trim power to pull away at the
            -- comfortable rate set by metrostroi_ai_accel (m/s^2) rather than
            -- dumping full tractive effort. Ease off fast if we're over the target,
            -- build up gently if under; `want` still eases us in near the speed.
            local aTgt = math.max(0.2, AI.CVars.accel:GetFloat())
            local want = math.Clamp(err / 6, 0.08, 1)
            local adj  = (self:Accel() > aTgt) and (-dt * 1.5) or (dt * 0.6)
            self.power = math.Clamp((self.power or 0) + adj, 0, want)
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
