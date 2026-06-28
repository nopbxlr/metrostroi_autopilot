--------------------------------------------------------------------------------
-- Metrostroi Autopilot - lookahead (ARS codes, signals, curve limits, route
-- position, trains ahead). DRIVER methods split out of sv_driver.lua; this file
-- is included AFTER sv_driver so AI.Driver / AI.C already exist.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI
local DRIVER = AI.Driver
local C = AI.C
local STOP_BEFORE_SIGNAL_M, TRAIN_CORRIDOR_U, TRAIN_SAFE_GAP_U, TRAIN_SAFE_GAP_M =
    C.STOP_BEFORE_SIGNAL_M, C.TRAIN_CORRIDOR_U, C.TRAIN_SAFE_GAP_U, C.TRAIN_SAFE_GAP_M

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
    if ok and IsValid(fwd) then
        self.arsSignal = fwd
        self.arsCode   = fwd.ARSSpeedLimit
        self.arsNext   = fwd.ARSNextSpeedLimit
        self.arsSpeed  = self:DecodeARS(fwd)
    end
    -- ARS frequency tracking. On a coded line, losing the code (no governing
    -- signal at all, or one that sends no code) is a loss of frequency: the cab
    -- ARS would brake to a stop, NOT coast at cruise into whatever is ahead - and
    -- the un-coded dead-end stub past a terminus is exactly that. We only ARM
    -- this once we've genuinely seen a code, so a fully un-coded map (no ARS
    -- network) still uses the cruise fallback and drives normally. Re-acquiring a
    -- code clears the loss (and the post-reverse suppression set by BeginReverse).
    if type(self.arsSpeed) == "number" then
        self.arsEverSeen        = true
        self.arsLostAt          = nil
        self.arsReverseCooldown = nil
    elseif self.arsEverSeen and not self.arsLostAt then
        self.arsLostAt = now
    end
end

-- True when we're on a coded line but the ARS code has dropped out for long
-- enough to be a real loss of frequency (debounced past the brief gaps at block
-- joints / switches). Loss of frequency = no movement authority: the train must
-- stop, exactly like a stop signal.
function DRIVER:ARSLost(now)
    if AI.CVars.obey_signals:GetInt() == 0 then return false end
    return (self.arsEverSeen and self.arsLostAt and (now - self.arsLostAt) > 1.0) and true or false
end

-- Follow the rail FORWARD from the nose (re-projecting onto the nearest track
-- each step, so it tracks through curves) and return the distance in metres to
-- where the drivable track ends within `maxScan`, or nil if it keeps going. This
-- is purely geometric - no ARS - so it's the authority on a real dead end: a
-- transient or mid-line ARS dropout where the rail still runs ahead reads as
-- "continues" here and so can never trigger a stop or a turn-back. Conservative:
-- any uncertainty (no API / lost the rail sideways) returns nil = "continues".
function DRIVER:TrackEndAhead(maxScan)
    if not (Metrostroi.GetPositionOnTrack and Metrostroi.GetTrackPosition) then return nil end
    local head = self:GetHead()
    local tp   = IsValid(head) and Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    local pos  = tp and tp[1]
    if not (pos and pos.path and pos.x and pos.node1 and isvector(pos.node1.dir)
            and isvector(self.travelDir)) then return nil end
    -- Start at the nose, but RAIL-LEVEL: take the network track position a half-car
    -- ahead of the head centre (the wagon's own GetPos sits ABOVE the rail, which
    -- is why scanning from it read as instantly off-track). Then walk the rail
    -- forward, re-projecting each step onto the nearest track so it follows curves
    -- AND crosses path-segment boundaries (the dead end was a short segment past
    -- the current path's end, which the path-end probe never reached).
    local sgn   = (self.travelDir:Dot(pos.node1.dir) < 0) and -1 or 1
    local rp, rd = Metrostroi.GetTrackPosition(pos.path, pos.x + sgn * (AI.HALF_CAR / AI.U_PER_M))
    if not (isvector(rp) and isvector(rd)) then return nil end
    local dir = Vector(rd); dir:Normalize(); dir = dir * sgn
    local prev, gone, step = rp, 0, 8                         -- 8 m probe steps
    while gone < maxScan do
        local probe = prev + dir * (step * AI.U_PER_M)
        local ok, res = pcall(Metrostroi.GetPositionOnTrack, probe, dir:Angle())
        local r = ok and res and res[1]
        if not (r and isvector(r.pos) and (r.distance or 1e9) < 250) then
            return gone                                       -- no rail ahead -> end of track
        end
        local nd = r.pos - prev
        if nd:Length() > 1 then nd:Normalize(); if nd:Dot(dir) > 0 then dir = nd end end  -- steer along the rail
        prev = r.pos
        gone = gone + step
    end
    return nil                                                -- rail continues past the scan
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
    self.sigStopM = nil
    if AI.CVars.obey_signals:GetInt() == 0 then return limit end
    local sig = self.arsSignal
    if not IsValid(sig) then return limit end
    -- STOP if the ARS code our cab actually RECEIVES is 0 (the authoritative test -
    -- the raw ARSSpeedLimit field can differ for occupied/override blocks), or the
    -- signal is otherwise red / its block occupied / closed.
    if not ((self.arsSpeed == 0) or (sig.ARSSpeedLimit == 0) or sig.Occupied or sig.Close or sig.KGU) then
        return limit
    end
    self.holdSignal = true
    -- distance to it: along the route when we can (so a red just around a curve
    -- isn't read as "behind us"), else straight-line; if neither gives a sensible
    -- positive distance, brake anyway - never roll through a stop.
    local fd_m
    local tpos = sig.TrackPosition
    if self.chainCi and istable(tpos) and tpos.path then
        local sci, scd = AI.ChainPos(math.floor(tonumber(tpos.path.id) or 0), tpos.x or 0)
        if sci == self.chainCi and scd then
            local d = ((self.chainDir or 1) > 0) and (scd - self.chainCd) or (self.chainCd - scd)
            if d > 0 then fd_m = d end
        end
    end
    if not fd_m then
        local w = self:ForwardDist(sig:GetPos()) / AI.U_PER_M
        if w > 0 then fd_m = w end
    end
    self.sigStopM = fd_m and math.max(0, fd_m - STOP_BEFORE_SIGNAL_M) or 0   -- m to stop at it
    return math.min(limit, self:StopSpeed(self.sigStopM))
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
-- Track our position + travel direction along the stitched route, so we can look
-- for the train/signal ahead ALONG THE RAILS instead of through a straight
-- corridor that misses whatever is just around a curve.
function DRIVER:UpdateRoutePos(pos)
    self.chainCi, self.chainCd = nil, nil
    if not (pos and pos.path and AI.ChainPos) then return end
    local ci, cd = AI.ChainPos(math.floor(tonumber(pos.path.id) or 0), pos.x or 0)
    if not ci then return end
    if self.rpCi == ci and self.rpCd then
        local d = cd - self.rpCd
        if math.abs(d) > 0.02 then self.chainDir = d > 0 and 1 or -1 end
    end
    self.rpCi, self.rpCd = ci, cd
    self.chainCi, self.chainCd, self.chainDir = ci, cd, self.chainDir
end

-- Metres to the nearest OTHER car ahead of us on our route chain (the closest
-- such car is the rear of the train in front), or nil. Follows the rails.
function DRIVER:RouteTrainAhead()
    local ci, cd, dir = self.chainCi, self.chainCd, self.chainDir
    if not (ci and cd and dir) then return nil end
    local mine = {}
    for _, w in ipairs(self.wagons) do mine[w] = true end
    local nearest
    for w in pairs(Metrostroi.TrainPositions or {}) do
        if IsValid(w) and not mine[w] then
            local wp = Metrostroi.TrainPositions[w][1]
            if wp and wp.path then
                local wci, wcd = AI.ChainPos(math.floor(tonumber(wp.path.id) or 0), wp.x or 0)
                if wci == ci and wcd then
                    local ahead = (dir > 0) and (wcd - cd) or (cd - wcd)
                    if ahead > 0.5 and (not nearest or ahead < nearest) then nearest = ahead end
                end
            end
        end
    end
    return nearest
end

function DRIVER:TrainLimit(limit, speed)
    self.trainStopM = nil
    if AI.CVars.avoid_trains:GetInt() == 0 then return limit end
    if not Metrostroi.TrainPositions then return limit end
    local lim = limit

    -- 1) along-the-track scan: brakes for the train in front even around curves/loops
    local routeAhead = self:RouteTrainAhead()
    if routeAhead then
        local m = math.max(0, routeAhead - TRAIN_SAFE_GAP_M)
        self.trainStopM = m
        lim = math.min(lim, self:StopSpeed(m))
    end

    -- 2) straight-corridor scan as a backup (catches trains across a chain gap)
    local mine = {}
    for _, w in ipairs(self.wagons) do mine[w] = true end
    local a = math.max(0.1, AI.CVars.decel:GetFloat())
    local range = math.max(8 * AI.U_PER_M, ((speed / 3.6) ^ 2 / (2 * a)) * AI.U_PER_M + 12 * AI.U_PER_M)
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
        local m = math.max(0, (nearest - TRAIN_SAFE_GAP_U) / AI.U_PER_M)
        self.trainStopM = math.min(self.trainStopM or math.huge, m)
        lim = math.min(lim, self:StopSpeed(m))
    end
    return lim
end
