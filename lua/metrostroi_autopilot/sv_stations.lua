--------------------------------------------------------------------------------
-- Metrostroi Autopilot - stations, terminus / turn-back, doors. DRIVER methods
-- split out of sv_driver.lua; included AFTER it.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI
local DRIVER = AI.Driver
local C = AI.C
local PLATFORM_CLEAR_U, STATION_CORRIDOR_U = C.PLATFORM_CLEAR_U, C.STATION_CORRIDOR_U

--------------------------------------------------------------------------------
-- Platforms
--------------------------------------------------------------------------------
-- Build a station -> authored stop point(s) map from the map's PA station markers
-- (gmod_track_pa_marker, PAType 1). Each marks where the FRONT of the train should
-- berth: rail x = marker.TrackPosition.x - PAStationCorrection (Metrostroi's own
-- formula, sv source). It also carries the terminus flag (PALastStation) and door
-- side. Only present on maps that ship PA data; we fall back to the platform end.
function AI.BuildPAStops()
    local map, gp = {}, Metrostroi.GetTrackPosition
    for _, m in ipairs(ents.FindByClass("gmod_track_pa_marker")) do
        if IsValid(m) and m.PAType == 1 and m.PAStationID and istable(m.TrackPosition) and m.TrackPosition.x then
            local tp    = m.TrackPosition
            local path  = tp.node1 and tp.node1.path
            local stopX = tp.x - (tonumber(m.PAStationCorrection) or 0)
            local wpos
            if path and gp then local ok, p = pcall(gp, path, stopX); if ok and isvector(p) then wpos = p end end
            local sid = tonumber(m.PAStationID)
            map[sid] = map[sid] or {}
            table.insert(map[sid], {
                pos        = wpos or m:GetPos(),
                isLast     = m.PALastStation and true or false,
                rightDoors = (m.PAStationRightDoors == true) or (tonumber(m.PAStationRightDoors) == 1),
                name       = m.PAStationName,
                dlStart    = tonumber(m.PADeadlockStart),   -- tail / pull-track extent past the
                dlEnd      = tonumber(m.PADeadlockEnd),     -- stop (a turn-back siding, not depot)
            })
        end
    end
    AI.PAStops = map
    return map
end

function AI.EnsurePAStops()
    if not AI.PAStops then AI.BuildPAStops() end
    return AI.PAStops
end

function DRIVER:ScanPlatforms()
    self.platforms = ents.FindByClass("gmod_track_platform")
    self.signals   = ents.FindByClass("gmod_track_signal")
    if not AI.PAStops or not next(AI.PAStops) then AI.BuildPAStops() end  -- (re)build until markers exist
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

-- Is there still an UNSERVED platform ahead of us on our own path? Used to hold off the
-- turn-back until we've actually served the terminus platform - we must not turn back at the
-- approach scissors while the terminus platform is still ahead (KS 700). This is TRACK-based
-- (same path id, greater track position in our travel direction), NOT geometric: near a throat
-- the folded/curved line swings a platform's lateral from ~240u to ~11000u, so a lateral
-- corridor (NextPlatform) loses sight of it and we'd turn back a station early.
function DRIVER:PlatformAheadOnPath()
    if not (Metrostroi.TrainPositions and Metrostroi.GetPositionOnTrack and isvector(self.travelDir)) then return false end
    local head = self:GetHead(); if not IsValid(head) then return false end
    local tp = Metrostroi.TrainPositions[head]
    local p  = tp and tp[1]
    if not (p and p.path and p.node1 and isvector(p.node1.dir)) then return false end
    local ourPathId = math.floor(tonumber(p.path.id) or 0)
    local sgn       = (self.travelDir:Dot(p.node1.dir) < 0) and -1 or 1   -- +x or -x is "ahead"
    local servedIdx = IsValid(self.servedPlatform) and self.servedPlatform.StationIndex
    for _, pf in ipairs(self.platforms or {}) do
        if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd)
           and pf.StationIndex ~= servedIdx then
            local c = (pf.PlatformStart + pf.PlatformEnd) * 0.5
            local ok, res = pcall(Metrostroi.GetPositionOnTrack, c, pf:GetAngles())
            if ok and res and res[1] and res[1].path
               and math.floor(tonumber(res[1].path.id) or 0) == ourPathId
               and ((res[1].x or 0) - (p.x or 0)) * sgn > 5 then       -- a platform still ahead on our path
                return true
            end
        end
    end
    return false
end

-- The aim point the nose should reach. PREFER the map's authored PA station stop
-- marker (the real front-of-train berth) when one matches this station and sits
-- sensibly within the platform; otherwise EXACTLY as before - the platform end
-- furthest along travel, so the whole train berths within the platform.
function DRIVER:PlatformStopPoint(pf)
    local a, b   = pf.PlatformStart, pf.PlatformEnd
    local fa, fb = self:ForwardDist(a), self:ForwardDist(b)
    local far    = (fa > fb) and a or b               -- platform end furthest along travel (deep berth)
    local stop   = self:PAStopFor(pf)
    if stop then
        -- Use the authored PA berth only when it's a sensible FRONT-of-train stop: in the
        -- FORWARD half of the platform. A station's two faces share a StationIndex, so the
        -- nearest-matched marker can be the OPPOSITE direction's berth, pinned to OUR near
        -- end - berthing there leaves the train hanging out the entrance (706 from 705). In
        -- that case berth at the far end so the whole train sits inside the platform.
        if self:ForwardDist(stop) >= (fa + fb) * 0.5 then return stop end
    end
    return far
end

-- The best-matching PA station record for this platform (stop pos / terminus flag
-- / door side), or nil. Sanity-gated to a marker sitting within the platform (+
-- ~11 m margin) so a mis-tagged marker on another track can't mislead us.
function DRIVER:PAInfoFor(pf)
    if not (IsValid(pf) and pf.StationIndex and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd)) then return nil end
    local map  = AI.EnsurePAStops and AI.EnsurePAStops()
    local list = map and map[pf.StationIndex]
    if not list then return nil end
    local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
    local maxOff = pf.PlatformStart:Distance(pf.PlatformEnd) * 0.5 + 600   -- within platform + ~11 m (units)
    local best, bestD
    for _, s in ipairs(list) do
        if isvector(s.pos) then
            local d = s.pos:Distance(center)
            if d < maxOff and (not bestD or d < bestD) then best, bestD = s, d end
        end
    end
    return best
end

function DRIVER:PAStopFor(pf)
    local r = self:PAInfoFor(pf)
    return r and r.pos or nil
end

function DRIVER:BeginStationStop(now, pf)
    self.state = "DWELL"
    self.holdUntil = now + math.max(2, AI.CVars.dwell:GetFloat())
    self.dwellStart = now
    self.servedPlatform = pf
    local info = self:PAInfoFor(pf)
    self.servedIsTerminus = info and info.isLast or false   -- map flags this as the last station
    -- A deadlock (tail / pull track past the platform) means the crossover is UP
    -- the throat, not at the platform - so we must NOT reverse here; run on into the
    -- tail and turn back there instead.
    self.servedDeadlock = info and (info.dlStart ~= nil or info.dlEnd ~= nil) or false
    -- At a terminus, lock in the OPPOSITE running track now (while we're still berthed on
    -- our arrival track) - that's the line we continue on after turning back. The route
    -- picker prefers a route landing on THIS chain, so it can't pick a stub (e.g. 551) that
    -- merely happens to be reachable from the throat.
    self.returnChainCi = self.servedIsTerminus and self:OppositeRunningChain(self:CurrentChain()) or nil
    self:ApplyDrive(0, AI.HOLD_BRAKE)
    if AI.CVars.open_doors:GetInt() == 1 then self:OpenDoors(pf) end
    hook.Run("MetrostroiAI.StationStop", self, pf)
    if IsValid(self.lead) then
        self:SetStatus("STATION " .. (pf.StationIndex or "?"))
    end
end

-- Is any OTHER train standing within a platform's length of it? (used by level-1
-- regulation - we won't leave a station until the next one is clear).
function DRIVER:StationOccupied(pf)
    if not (IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd)) then return false end
    local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
    local range  = pf.PlatformStart:Distance(pf.PlatformEnd) * 0.5 + 6 * AI.U_PER_M
    local mine = {}
    for _, w in ipairs(self.wagons) do mine[w] = true end
    for w in pairs(Metrostroi.SpawnedTrains or {}) do
        if IsValid(w) and not mine[w] and w:GetPos():Distance(center) < range then return true end
    end
    return false
end

-- Traffic regulation: should we keep holding at the platform (doors open)?
--   1 = wait until the next station ahead is clear of any train.
--   2 = wait until our gap to the train ahead reaches the even-spacing target
--       (set by AI.UpdateRegulation), evening out the headway across all trains.
function DRIVER:RegulationHold(now)
    local reg = AI.CVars.regulation:GetInt()
    if reg == 0 then return false end
    if now - (self.dwellStart or now) > AI.CVars.reg_maxhold:GetFloat() then return false end  -- safety cap
    if reg == 1 then
        local nx = self:NextPlatform()
        return (nx and self:StationOccupied(nx)) and true or false
    elseif reg == 2 then
        local g, t = self.regLeaderGap, self.regTarget
        if not (g and t) then return false end
        return g < t * 0.93                       -- still bunched behind the leader
    end
    return false
end

-- Remember where/when we last turned back so the terminus / end-of-track / stuck
-- logic can't bounce the train straight back to a spot it just reversed at - the
-- dead-end <-> failed-crossover oscillation. Keep the few most recent points.
function DRIVER:NoteReverse(now)
    local head = self:GetHead()
    if not IsValid(head) then return end
    self.reverseHistory = self.reverseHistory or {}
    table.insert(self.reverseHistory, 1, { pos = head:GetPos(), t = now })
    self.reverseHistory[5] = nil
end

-- True if we already reversed within the last 2 minutes within ~150 m of here: a
-- new reverse now would just be oscillating, not serving a fresh terminus.
function DRIVER:RecentlyReversedNear(now)
    local head = self:GetHead()
    if not (IsValid(head) and self.reverseHistory) then return false end
    local p = head:GetPos()
    for _, h in ipairs(self.reverseHistory) do
        if (now - h.t) < 120 and p:Distance(h.pos) < 150 * AI.U_PER_M then return true end
    end
    return false
end

-- The chain our train's head is currently on.
function DRIVER:CurrentChain()
    if not (AI.ChainPos and Metrostroi.TrainPositions) then return nil end
    local head = self:GetHead(); if not IsValid(head) then return nil end
    local tp = Metrostroi.TrainPositions[head]
    local p  = tp and tp[1]
    if p and p.path then return AI.ChainPos(math.floor(tonumber(p.path.id) or 0), p.x or 0) end
end

-- The opposite RUNNING track of chain C - the return track after a turn-back. The two
-- running tracks of a line are exactly the chains that carry this line's platform faces
-- (each station has one face on each direction). So: resolve every platform face to a
-- chain, group by station, and for every station that has a face on C, tally the OTHER
-- chain at that station. The most-tallied chain is the opposite running track. A throat
-- or stabling spur (e.g. 551) carries no platform face, so it can never be picked - which
-- is the whole bug we kept hitting (turn-backs diverting off the line onto a stub).
function DRIVER:OppositeRunningChain(C)
    if not (C and AI.ChainPos and Metrostroi.GetPositionOnTrack) then return nil end
    local byStation = {}
    for _, pf in ipairs(self.platforms or {}) do
        if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
            local c = (pf.PlatformStart + pf.PlatformEnd) * 0.5
            local ok, res = pcall(Metrostroi.GetPositionOnTrack, c, pf:GetAngles())
            if ok and res and res[1] and res[1].path then
                local ci = AI.ChainPos(math.floor(tonumber(res[1].path.id) or 0), res[1].x or 0)
                if ci then
                    local si = pf.StationIndex
                    byStation[si] = byStation[si] or {}
                    byStation[si][ci] = true
                end
            end
        end
    end
    local tally = {}
    for _, chains in pairs(byStation) do
        if chains[C] then
            for ci in pairs(chains) do
                if ci ~= C then tally[ci] = (tally[ci] or 0) + 1 end
            end
        end
    end
    local best, bestN = nil, 0
    for ci, n in pairs(tally) do if n > bestN then best, bestN = ci, n end end
    return best
end

-- The route chain of the RETURN track at the terminus we're at - the opposite running
-- track we continue on after turning back. Locked into returnChainCi at the start of the
-- maneuver (while we're still on our ARRIVAL running track); recomputing it after we cross
-- would point back at the track we just left and ping-pong. Falls back to a live compute
-- from the current chain when nothing is locked yet (e.g. engaged already in the throat).
function DRIVER:ReturnTrackChain()
    if self.returnChainCi then return self.returnChainCi end
    return self:OppositeRunningChain(self:CurrentChain())
end

-- Are we already on the return track's chain? (Once we've crossed over we must
-- stop re-lining crossovers, or we could divert ourselves back off it.)
function DRIVER:OnReturnTrack()
    local rc = self:ReturnTrackChain()
    if not (rc and AI.ChainPos) then return false end
    local head = self:GetHead()
    local tp = IsValid(head) and Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    local p = tp and tp[1]
    if not (p and p.path) then return false end
    local ci = AI.ChainPos(math.floor(tonumber(p.path.id) or 0), p.x or 0)
    return ci == rc
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
    -- Decide the platform side ONCE, in the head's frame, and command that SAME
    -- side on every car. The door commands feed train-wide wires 31 (left) / 32
    -- (right); a per-car side meant cars facing opposite ways drove BOTH wires hot,
    -- and VDOL+VDOP energised together is the CLOSE command - so the doors locked
    -- shut and never opened. One side -> one wire -> they open.
    local hRight = h:GetForward():Cross(Vector(0, 0, 1))
    local side
    local info = self:PAInfoFor(pf)
    if info then
        -- PREFER the map's authored side. PAStationRightDoors is the train's RIGHT
        -- in the travel frame (sv: rightDoors -> "DP"/right, else "DL"/left); map
        -- it into the head's frame so it survives a reversed cab.
        local tRight = (isvector(self.travelDir) and self.travelDir or h:GetForward()):Cross(Vector(0, 0, 1))
        local phys   = info.rightDoors and tRight or (tRight * -1)
        side = (phys:Dot(hRight) > 0) and "right" or "left"
    else
        -- geometric fallback (unchanged): whichever side the platform is on
        local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
        side = ((center - h:GetPos()):Dot(hRight) > 0) and "right" or "left"
    end
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
function DRIVER:TerminusDistance(pos, maxDist)
    maxDist = maxDist or 400
    -- self.termWhy records WHICH branch decided the outcome, so !ai term can show
    -- why a real dead end was (or wasn't) seen instead of us having to guess.
    if not (pos and pos.path and pos.x and pos.node1 and isvector(pos.node1.dir)) then
        self.termWhy = "no network pos / node1.dir"; return nil end
    local path = pos.path
    local first, last = path[1], path[#path]
    if not (first and last) then self.termWhy = "path has no end nodes"; return nil end
    local sgn = (self.travelDir:Dot(pos.node1.dir) < 0) and -1 or 1
    local endNode = (sgn > 0) and last or first
    if not (isvector(endNode.pos) and isvector(endNode.dir)) then
        self.termWhy = "end node missing pos/dir"; return nil end

    local dist_m = (endNode.x - pos.x) * sgn               -- metres to the path end ahead
    if dist_m <= 0 then
        self.termWhy = string.format("path end behind us (%.0fm, sgn=%d)", dist_m, sgn); return nil end
    if dist_m > maxDist then
        self.termWhy = string.format("path end too far (%.0fm > %.0f)", dist_m, maxDist); return nil end

    local dir = endNode.dir * sgn
    for _, d in ipairs({ 4, 9, 16 }) do                     -- probe just past the end
        local p = endNode.pos + dir * (d * AI.U_PER_M)
        local res = Metrostroi.GetPositionOnTrack(p, dir:Angle())
        local rd = res and res[1] and res[1].distance
        if rd and rd < 100 then
            self.termWhy = string.format("track continues past end (probe %dm -> %.0fu; end %.0fm ahead)", d, rd, dist_m)
            return nil                                      -- track continues -> not a terminus
        end
    end
    self.termWhy = string.format("TERMINUS %.0fm ahead", dist_m)
    return dist_m
end
