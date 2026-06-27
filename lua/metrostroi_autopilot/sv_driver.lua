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
local PLATFORM_STOP_OFFSET = 0.0    -- aim the nose exactly at the platform far end (precise berth, full use of short platforms)
local BRAKE_PER_MS2        = 1.7    -- atm of brake per m/s^2 wanted (~4.2 atm = full service ~2.5 m/s^2)
local TERMINUS_BUFFER      = 5.0    -- m to stop short of an end-of-track buffer
local TURNBACK_SCAN_M      = 400    -- m ahead to look for a turn-back crossover switch (covers approach-side crossovers, not just tail-track ones)
local TURNBACK_NEAR_U      = 260    -- lateral units: a switch this close is on OUR track (the entry switch)
local TURNBACK_FAR_U       = 600    -- ... this far out is the other track (the scissors/crossover diagonal partner)
local TURNBACK_DIAG_M      = 60     -- max longitudinal span of a crossover diagonal (entry <-> exit switch)

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
-- Lookahead: speed limits and stop points
--------------------------------------------------------------------------------
-- Find the GOVERNING ARS signal for our current track circuit (the one whose
-- code the train's ARS receiver would read) and cache it + its code. This is
-- exactly what the stock ALS coil does: Metrostroi.GetARSJoint(), throttled to
-- ~2 Hz, with a real boolean direction. Safe (the game does this for every train
-- every second) and gives the true per-section code - the old geometric "nearest
-- signal facing us" guess kept latching onto one code-6 signal => a constant 60.
function DRIVER:UpdateARS(pos, dir, now)
    if now < (self.arsNextScan or 0) then return end
    self.arsNextScan = now + 0.5
    self.arsSignal, self.arsSpeed, self.arsCode, self.arsNext = nil, nil, nil, nil
    if AI.CVars.obey_signals:GetInt() == 0 then return end
    if not (pos and pos.node1 and type(dir) == "boolean" and Metrostroi.GetARSJoint) then return end
    local ok, fwd = pcall(Metrostroi.GetARSJoint, pos.node1, pos.x, dir, self.head)
    if not (ok and IsValid(fwd)) then return end
    self.arsSignal = fwd
    self.arsCode   = fwd.ARSSpeedLimit
    self.arsNext   = fwd.ARSNextSpeedLimit
    self.arsSpeed  = self:DecodeARS(fwd)
end

-- Decode a governing signal to the km/h the cab ARS would show, exactly like the
-- stock ALS coil: GetARS(8/7/6/4/0) -> 80/70/60/40/stop. This factors in the
-- NEXT signal's code / the 1-5 vs 2-6 decoder, which the raw ARSSpeedLimit field
-- does not - reading the raw code is why a 70 section came out as 60.
function DRIVER:DecodeARS(sig)
    if not (IsValid(sig) and sig.GetARS) then return nil end
    local tbl = IsValid(self.head) and self.head.SubwayTrain and self.head.SubwayTrain.ALS
    local f15 = (not tbl) or (not tbl.TwoToSix)
    local okc, nocode = pcall(sig.GetARS, sig, 1, self.head)
    if okc and nocode then return nil end                  -- no valid code here
    for _, cs in ipairs({ { 8, 80 }, { 7, 70 }, { 6, 60 }, { 4, 40 }, { 0, 0 } }) do
        local ok2, r = pcall(sig.GetARS, sig, cs[1], f15)
        if ok2 and r then return cs[2] end
    end
    return nil
end

-- Brake to a stop if the governing signal is red / its block is occupied.
function DRIVER:SignalStop(limit)
    self.holdSignal = nil
    if AI.CVars.obey_signals:GetInt() == 0 then return limit end
    local sig = self.arsSignal
    if not IsValid(sig) then return limit end
    if not ((sig.ARSSpeedLimit == 0) or sig.Occupied or sig.Close or sig.KGU) then return limit end
    local fd = self:ForwardDist(sig:GetPos())
    if fd <= 0 then return limit end
    self.holdSignal = true
    local s_m = math.max(0, fd / AI.U_PER_M - STOP_BEFORE_SIGNAL_M)
    return math.min(limit, self:StopSpeed(s_m))
end

-- A dispatcher would grant the route at a red ROUTE signal we're held at (e.g. a
-- terminus departure). OpenRoute opens it and lines its switches - but the
-- interlocking still won't show green into an occupied block, so this is
-- collision-safe: an occupancy red just stays red and we keep waiting. (It also
-- lines the turn-back crossover the mapper's way when the route owns those points.)
function DRIVER:TryOpenSignal(now, speed)
    if AI.CVars.obey_signals:GetInt() == 0 or AI.CVars.open_routes:GetInt() ~= 1 then return end
    if not self.holdSignal or speed > 8 then return end          -- only when actually held & crawling
    if (self.nextSigOpen or 0) > now then return end
    self.nextSigOpen = now + 2
    local sig = self.arsSignal
    if not (IsValid(sig) and istable(sig.Routes)) then return end
    if sig.Close then sig.Close = false end                      -- a manually-closed signal
    -- grant ONE route: the one the signal already favours if it's openable, else
    -- the first manual/emergency route (a plain auto block signal has neither and
    -- is left alone - it's red for occupancy, which we must respect)
    local k = (sig.Route and sig.Routes[sig.Route]
               and (sig.Routes[sig.Route].Manual or sig.Routes[sig.Route].Emer)) and sig.Route or nil
    if not k then
        for i, r in ipairs(sig.Routes) do
            if r.Manual or r.Emer then k = i break end
        end
    end
    if k then
        pcall(sig.OpenRoute, sig, k)
        if AI.CVars.debug:GetInt() == 1 then
            AI.Msg("signal '", tostring(sig.Name), "' held -> requested route ", k)
        end
    end
end

-- The ARS-authorised max speed (km/h) for the current section, or nil when there
-- is no ARS code here (then the cruise cvar applies). The stop code (0) returns
-- nil too - SignalStop handles the actual braking distance to the red signal.
function DRIVER:ARSMaxSpeed()
    if AI.CVars.obey_signals:GetInt() == 0 then return nil end
    local s = self.arsSpeed
    if s == nil or s == 0 then return nil end   -- 0 (stop) is handled by SignalStop
    return s
end

-- Max comfortable speed (km/h) for the curvature over `base` metres centred on x
-- along `path`; nil if effectively straight or the sample runs off the path end.
-- pos.x / node.x are in Metrostroi METRES, so we advance by plain metres.
local function curveVmaxAt(path, x, base, lat)
    local gp = Metrostroi.GetTrackPosition
    if not gp then return nil end
    local _, d1 = gp(path, x - base * 0.5)
    local _, d2 = gp(path, x + base * 0.5)
    if not (isvector(d1) and isvector(d2)) then return nil end
    d1:Normalize(); d2:Normalize()
    local turn = math.acos(math.Clamp(d1:Dot(d2), -1, 1))   -- bend across `base` m
    if turn < 0.02 then return nil end                       -- near-straight: no limit
    local R = base / turn                                    -- curve radius (m)
    return math.sqrt(math.max(0.3, lat) * R) * 3.6
end

-- Curve speed limit that accounts for the WHOLE TRAIN. We sample the curvature at
-- every car's own track position and take the tightest, so the head clearing a
-- curve can't let us power up while the rear cars are still in it (which was
-- nearly throwing them off). Each wagon reports its own path, so this also covers
-- curves that straddle a track-segment / switch boundary. A nose look-ahead is
-- added on top so we still slow BEFORE the front reaches a curve.
function DRIVER:CurveLimit(pos, limit)
    if not (pos and pos.path and pos.x) then return limit end
    local lat   = AI.CVars.curve_lat:GetFloat()
    local worst = limit

    -- under every car (covers the full train length)
    for _, w in ipairs(self.wagons) do
        local tp = Metrostroi.TrainPositions and Metrostroi.TrainPositions[w]
        local wp = tp and tp[1]
        if wp and wp.path and wp.x then
            local v = curveVmaxAt(wp.path, wp.x, 16, lat)
            if v then worst = math.min(worst, math.max(25, v)) end
        end
    end

    -- look-ahead beyond the nose (on the head's path)
    local sgn = (isvector(pos.node1 and pos.node1.dir)
                 and self.travelDir:Dot(pos.node1.dir) < 0) and -1 or 1
    local noseM = AI.HALF_CAR / AI.U_PER_M
    for _, ahead in ipairs({ 10, 24, 40 }) do
        local v = curveVmaxAt(pos.path, pos.x + sgn * (noseM + ahead), 24, lat)
        if v then worst = math.min(worst, math.max(25, v)) end
    end

    return worst
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
    local served    = self.servedPlatform
    local servedIdx = IsValid(served) and served.StationIndex
    local best, bestFd
    for _, pf in ipairs(self.platforms or {}) do
        if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
            local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
            local fd = self:ForwardDist(self:PlatformStopPoint(pf))   -- distance to far end
            -- A station has TWO platform faces (separate entities, same StationIndex).
            -- Treat BOTH faces of the station we just served as served, or we re-
            -- acquire the opposite face and stop again - at a terminus that left us
            -- ping-ponging between the two faces and never reversing.
            local sameStation = (pf == served) or (servedIdx and pf.StationIndex == servedIdx)
            if sameStation then
                -- clear once OUR served face is clearly behind us
                if pf == served and fd < -PLATFORM_CLEAR_U then self.servedPlatform = nil end
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
        self:SetStatus("STATION " .. (pf.StationIndex or "?"))
    end
end

function DRIVER:BeginReverse(now)
    self.travelDir = -self.travelDir
    self.servedPlatform = nil
    self.power = 0
    self.state = "REVERSE_HOLD"
    self.holdUntil = now + 5
    self:ApplyDrive(0, AI.HOLD_BRAKE)
    -- Throw the crossover so we depart on the OPPOSITE (correct) track. If we can't
    -- find one we just reverse on the same track - the safe fallback for stubs /
    -- single-track / loops with no crossover.
    self.turnbackSwitches = self:FindTurnbackSwitches()
    if self.turnbackSwitches and #self.turnbackSwitches > 0 then
        local ids = {}
        for _, sw in ipairs(self.turnbackSwitches) do
            pcall(sw.SendSignal, sw, "alt", nil)
            ids[#ids + 1] = sw:GetNW2String("ID", "?")
        end
        if AI.CVars.debug:GetInt() == 1 then
            AI.Msg("turnback: throwing crossover ", table.concat(ids, "+"))
        end
    end
    self:SetStatus("TERMINUS")
end

-- Find the crossover switch(es) to throw so the reversing train departs on the
-- opposite track. Scan gmod_track_switch ahead (in the already-flipped travel
-- sense). The ENTRY is the nearest switch on our track - we must divert there
-- first. For a scissors / double crossover we also need its diagonal PARTNER on
-- the far track (a switch at a different longitudinal position, ~track-gap out),
-- or the diagonal won't complete. Returns a list (entry [+ partner]); empty ->
-- same-track reverse (safe fallback for stubs / single track / loops).
function DRIVER:FindTurnbackSwitches()
    if not (self.travelDir and self.wagons) then return {} end
    -- reference = the foremost point of the train in the NEW travel direction
    local ref, best = nil, -math.huge
    for _, w in ipairs(self.wagons) do
        if IsValid(w) then
            local d = w:GetPos():Dot(self.travelDir)
            if d > best then best, ref = d, w:GetPos() end
        end
    end
    if not ref then return {} end

    local list, maxFd = {}, TURNBACK_SCAN_M * AI.U_PER_M
    for _, sw in ipairs(ents.FindByClass("gmod_track_switch")) do
        if IsValid(sw) then
            local rel = sw:GetPos() - ref
            local fd  = rel:Dot(self.travelDir)
            local lat = (rel - self.travelDir * fd):Length()
            if fd > 0 and fd < maxFd then
                list[#list + 1] = { sw = sw, fd = fd, lat = lat }
            end
        end
    end
    if #list == 0 then return {} end
    table.sort(list, function(a, b) return a.fd < b.fd end)

    -- entry: nearest switch on our own track
    local entry
    for _, s in ipairs(list) do
        if s.lat < TURNBACK_NEAR_U then entry = s break end
    end
    if not entry then return {} end

    local out = { entry.sw }
    -- partner: the diagonal's far-track end, at a *different* longitudinal spot
    local partner
    for _, s in ipairs(list) do
        local dl = math.abs(s.fd - entry.fd) / AI.U_PER_M
        if s.lat >= TURNBACK_NEAR_U and s.lat < TURNBACK_FAR_U and dl > 8 and dl < TURNBACK_DIAG_M then
            if not partner or math.abs(s.fd - entry.fd) < math.abs(partner.fd - entry.fd) then partner = s end
        end
    end
    if partner then out[#out + 1] = partner.sw end
    return out
end

-- Hold the turn-back crossover thrown until we've driven past it. Switches auto-
-- revert to "main" after ~20 s and refuse to move under an occupied segment, so
-- we re-assert every tick (which also resets their revert timer).
function DRIVER:MaintainTurnback()
    local list = self.turnbackSwitches
    if not (list and #list > 0) then self.turnbackSwitches = nil return end
    -- Re-assert each thrown switch until the whole train (tail included) is past
    -- it, so its rails can't snap back under us mid-crossing (the switch's own
    -- occupancy-inhibit also guards this). Release the set once all are behind us.
    local tailAlong = math.huge
    for _, w in ipairs(self.wagons) do
        if IsValid(w) then tailAlong = math.min(tailAlong, w:GetPos():Dot(self.travelDir)) end
    end
    local anyAhead = false
    for _, sw in ipairs(list) do
        if IsValid(sw) and (sw:GetPos():Dot(self.travelDir) - tailAlong) >= -AI.HALF_CAR then
            pcall(sw.SendSignal, sw, "alt", nil)
            anyAhead = true
        end
    end
    if not anyAhead then self.turnbackSwitches = nil end
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
    local h = self.head
    if not IsValid(h) then return end
    local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
    -- Decide the platform side ONCE, in the head's frame, and command that SAME
    -- side on every car. The door commands feed train-wide wires 31 (left) / 32
    -- (right); a per-car side meant cars facing opposite ways drove BOTH wires hot,
    -- and VDOL+VDOP energised together is the CLOSE command - so the doors locked
    -- shut and never opened. One side -> one wire -> they open.
    local hRight = h:GetForward():Cross(Vector(0, 0, 1))
    local side = ((center - h:GetPos()):Dot(hRight) > 0) and "right" or "left"
    for _, w in ipairs(self.wagons) do
        if IsValid(w) then self.profile.OpenDoor(w, side) end
    end
    self.doorsOpen = true
    self:SetStatus("DOORS " .. string.upper(side))
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
    self:MaintainTurnback()                -- hold the turn-back crossover until we're past it
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
    local dir = Metrostroi.TrainDirections and Metrostroi.TrainDirections[head]
    self:UpdateARS(pos, dir, now)                      -- refresh the governing ARS signal

    -- Build the target speed from every limit. The ARS code IS the AUTHORISED max
    -- wherever the track sends one; cruise is ONLY the fallback for un-coded track
    -- - it must NEVER cap an ARS block (a cruise of 60 was dragging ARS-70 sections
    -- down to 60: that was the "60 instead of 70" all along). Each limit is computed
    -- standalone so the debug can show which one is actually binding.
    local cruise    = math.max(0, AI.CVars.cruise:GetFloat())
    local arsMax    = self:ARSMaxSpeed()
    local base      = arsMax or cruise
    local curveLim  = self:CurveLimit(pos, 9999)
    local signalLim = self:SignalStop(9999)
    local trainLim  = self:TrainLimit(9999, speed)
    local term      = self:TerminusDistance(pos)
    local termLim   = term and self:StopSpeed(math.max(0, term - 3)) or 9999
    local target = math.min(base, curveLim, signalLim, trainLim, termLim)
    self.dbg = { cruise = cruise, ars = arsMax, curve = curveLim, signal = signalLim,
                 train = trainLim, term = termLim, target = target }
    self:TryOpenSignal(now, speed)             -- request a route if held at a red route signal

    -- Platform stop - DISTANCE-BASED braking. Each tick we work out the
    -- deceleration needed to bring the nose to rest on the aim point (a couple of
    -- metres short of the far end) and command exactly that brake. Re-solving it
    -- live makes it self-correcting: the train settles onto a smooth braking curve
    -- and stops on the mark, with no speed-error lag riding over it, no last-moment
    -- slam, and no overrun (the old proportional law caused all three).
    local status = "DRIVE"
    local pf = self:NextPlatform()
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
            if AI.CVars.terminus_rev:GetInt() == 1 then self:BeginReverse(now)
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
        self.stuckTime, self.hasMoved = 0, false
        status = "TERMINUS"
        if AI.CVars.terminus_rev:GetInt() == 1 then self:BeginReverse(now)
        else self:ApplyDrive(0, AI.HOLD_BRAKE) end
        return
    end

    if self.holdSignal and speed <= ARRIVE_SPEED then status = "HELD AT SIGNAL" end

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
