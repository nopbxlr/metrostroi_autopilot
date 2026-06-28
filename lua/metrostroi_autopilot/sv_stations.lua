--------------------------------------------------------------------------------
-- Metrostroi Autopilot - stations, terminus / turn-back, doors. DRIVER methods
-- split out of sv_driver.lua; included AFTER it.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI
local DRIVER = AI.Driver
local C = AI.C
local PLATFORM_CLEAR_U, STATION_CORRIDOR_U = C.PLATFORM_CLEAR_U, C.STATION_CORRIDOR_U
local TURNBACK_SCAN_M, TURNBACK_NEAR_U, TURNBACK_FAR_U, TURNBACK_DIAG_M =
    C.TURNBACK_SCAN_M, C.TURNBACK_NEAR_U, C.TURNBACK_FAR_U, C.TURNBACK_DIAG_M

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
                rightDoors = m.PAStationRightDoors,
                name       = m.PAStationName,
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

-- The aim point the nose should reach. PREFER the map's authored PA station stop
-- marker (the real front-of-train berth) when one matches this station and sits
-- sensibly within the platform; otherwise EXACTLY as before - the platform end
-- furthest along travel, so the whole train berths within the platform.
function DRIVER:PlatformStopPoint(pf)
    local stop = self:PAStopFor(pf)
    if stop then return stop end
    local a, b = pf.PlatformStart, pf.PlatformEnd
    return (self:ForwardDist(a) > self:ForwardDist(b)) and a or b
end

-- The authored PA stop point for this platform's station, or nil. Sanity-gated to
-- a marker sitting within the platform (+ ~11 m margin) so a mis-tagged marker on
-- another track can never strand the train short of / past its platform.
function DRIVER:PAStopFor(pf)
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
    return best and best.pos or nil
end

function DRIVER:BeginStationStop(now, pf)
    self.state = "DWELL"
    self.holdUntil = now + math.max(2, AI.CVars.dwell:GetFloat())
    self.dwellStart = now
    self.servedPlatform = pf
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

function DRIVER:BeginReverse(now)
    self:NoteReverse(now)            -- remember this spot so we can't oscillate back to it
    self.travelDir = -self.travelDir
    self.servedPlatform = nil
    self.power = 0
    self.state = "REVERSE_HOLD"
    self.holdUntil = now + 5
    self.arsReverseCooldown = true   -- suppress ARS-loss braking until we re-acquire a code
    self:ApplyDrive(0, AI.HOLD_BRAKE)
    -- Throw the crossover so we depart on the OPPOSITE (correct) track. If we can't
    -- find one we just reverse on the same track - the safe fallback for stubs /
    -- single-track / loops with no crossover.
    self.turnbackSwitches = self:FindTurnbackSwitches()
    if self.turnbackSwitches and #self.turnbackSwitches > 0 then
        local ids = {}
        for _, sw in ipairs(self.turnbackSwitches) do
            pcall(sw.SendSignal, sw, "alt", nil, true)   -- route=true: force, like the interlocking does
            ids[#ids + 1] = sw:GetNW2String("ID", "?")
        end
        self:OpenTurnbackRoute()                          -- line + HOLD them the mapper's way
        self.nextRouteReopen = now + 1.5
        if AI.CVars.debug:GetInt() == 1 then
            AI.Msg("turnback: ", table.concat(ids, "+"), "  route: ", tostring(self.turnbackRoute))
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
    -- record the pick so !ai term can show whether we grabbed sensible switches
    self.turnbackPick = string.format("entry %s (fwd %.0fm, lat %.0fu)%s",
        entry.sw:GetNW2String("ID", "?"), entry.fd / AI.U_PER_M, entry.lat,
        partner and string.format("  +  partner %s (fwd %.0fm, lat %.0fu)",
            partner.sw:GetNW2String("ID", "?"), partner.fd / AI.U_PER_M, partner.lat)
            or "  (no far-rail partner found)")
    return out
end

-- Ask the interlocking to line the turn-back crossover the mapper's way: find the
-- signal route that throws the switches we picked to "alt" and OpenRoute it - the
-- in-code equivalent of "!sopen <route>". This is what actually HOLDS the points:
-- a raw SendSignal on an interlocked switch is reverted to main by the route
-- system (which is why the crossover never diverted us, even though we were
-- "throwing" it). Returns false (and the raw SendSignal fallback still runs) on
-- maps whose switches aren't route-controlled.
function DRIVER:OpenTurnbackRoute()
    local want, n = {}, 0
    for _, sw in ipairs(self.turnbackSwitches or {}) do
        if IsValid(sw) then
            local id = (sw:GetNW2String("ID", "") or ""):upper()
            if id ~= "" and not want[id] then want[id] = true; n = n + 1 end
        end
    end
    if n == 0 then return false end
    -- the right route is the one that throws the MOST of our switches to alt ("-")
    local bestSig, bestK, bestScore, bestName
    for _, sig in ipairs(ents.FindByClass("gmod_track_signal")) do
        if IsValid(sig) and istable(sig.Routes) then
            for k, v in pairs(sig.Routes) do
                if istable(v) and isstring(v.Switches) and v.Switches ~= "" then
                    local score = 0
                    for _, e in ipairs(string.Explode(",", v.Switches)) do
                        if e ~= "" and e:sub(-1) == "-" and want[e:sub(1, -2):upper()] then score = score + 1 end
                    end
                    if score > 0 and (not bestScore or score > bestScore) then
                        bestSig, bestK, bestScore, bestName = sig, k, score, v.RouteName
                    end
                end
            end
        end
    end
    if not bestSig then self.turnbackRoute = "no signal route lines those switches"; return false end
    pcall(bestSig.OpenRoute, bestSig, bestK)
    self.turnbackRoute = string.format("%s #%s '%s' (lines %d/%d of our switches)",
        tostring(bestSig.Name), tostring(bestK), tostring(bestName or "?"), bestScore, n)
    return true
end

-- Hold the turn-back crossover thrown until we've driven past it. Switches auto-
-- revert to "main" after ~20 s and refuse to move under an occupied segment, so
-- we re-assert every tick (which also resets their revert timer) and re-open the
-- mapper's route periodically so the interlocking keeps the points for us.
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
            pcall(sw.SendSignal, sw, "alt", nil, true)
            anyAhead = true
        end
    end
    if anyAhead then
        local now = CurTime()
        if now >= (self.nextRouteReopen or 0) then     -- keep the mapper's route lined for us
            self.nextRouteReopen = now + 1.5
            self:OpenTurnbackRoute()
        end
    else
        self.turnbackSwitches, self.turnbackRoute = nil, nil
    end
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
    if dist_m > 400 then
        self.termWhy = string.format("path end too far (%.0fm > 400)", dist_m); return nil end

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
