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
    -- At a terminus, remember the chain of the OPPOSITE running track (this station's
    -- other platform face) - the line we actually continue on after turning back. The
    -- route picker prefers a route landing on THIS chain so it can't pick a reversing
    -- stub that merely happens to share a line chain.
    self.returnChainCi = nil
    if self.servedIsTerminus and AI.ChainPos and Metrostroi.GetPositionOnTrack then
        for _, op in ipairs(self.platforms or {}) do
            if IsValid(op) and op ~= pf and op.StationIndex == pf.StationIndex
               and isvector(op.PlatformStart) and isvector(op.PlatformEnd) then
                local c = (op.PlatformStart + op.PlatformEnd) * 0.5
                local ok, res = pcall(Metrostroi.GetPositionOnTrack, c, op:GetAngles())
                if ok and res and res[1] and res[1].path then
                    local ci = AI.ChainPos(math.floor(tonumber(res[1].path.id) or 0), res[1].x or 0)
                    if ci then self.returnChainCi = ci; break end
                end
            end
        end
    end
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
-- The route chain of the RETURN track at the terminus we're at - the opposite
-- running track we continue on after turning back. Prefer the value recorded when
-- we dwelled (returnChainCi); else derive it geometrically so it works even when a
-- train is engaged already in the throat: the nearest station's OTHER platform
-- face is the return track (we're laterally on our own arrival track, so the other
-- face is the one we did NOT arrive on).
function DRIVER:ReturnTrackChain()
    if self.returnChainCi then return self.returnChainCi end
    if not (AI.ChainPos and Metrostroi.GetPositionOnTrack) then return nil end
    local head = self:GetHead(); if not IsValid(head) then return nil end
    local hp = head:GetPos()
    local mine, md
    for _, pf in ipairs(self.platforms or {}) do
        if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
            local d = ((pf.PlatformStart + pf.PlatformEnd) * 0.5):Distance(hp)
            if not md or d < md then mine, md = pf, d end
        end
    end
    if not mine then return nil end
    for _, pf in ipairs(self.platforms or {}) do
        if IsValid(pf) and pf ~= mine and pf.StationIndex == mine.StationIndex
           and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
            local c = (pf.PlatformStart + pf.PlatformEnd) * 0.5
            local ok, res = pcall(Metrostroi.GetPositionOnTrack, c, pf:GetAngles())
            if ok and res and res[1] and res[1].path then
                return (AI.ChainPos(math.floor(tonumber(res[1].path.id) or 0), res[1].x or 0))
            end
        end
    end
    return nil
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

function DRIVER:OpenTurnbackRoute()
    local head = self:GetHead()
    if not IsValid(head) then return false end
    local ref = head:GetPos()
    local returnCi = self:ReturnTrackChain()
    -- switches we think the crossover physically uses (geometric pick), for tie-break
    local want = {}
    for _, sw in ipairs(self.turnbackSwitches or {}) do
        if IsValid(sw) then
            local id = (sw:GetNW2String("ID", "") or ""):upper()
            if id ~= "" then want[id] = true end
        end
    end
    local byName = {}
    for _, sg in ipairs(ents.FindByClass("gmod_track_signal")) do
        if IsValid(sg) and sg.Name then byName[sg.Name] = sg end
    end
    -- The chain a signal sits on (by name).
    local function chainOf(nm)
        local sg = byName[nm or ""]
        if not IsValid(sg) then return nil end
        local tp = sg.TrackPosition
        if not (istable(tp) and tp.path) then return nil end
        return (AI.ChainPos(math.floor(tonumber(tp.path.id) or 0), tp.x or 0))
    end
    -- Fewest ROUTE-HOPS from a signal until the path lands on the RETURN track. A real
    -- terminus throat has no single crossover from our track to the return track - the
    -- turn-back threads several signals (our chain -> throat sidings -> ... -> return
    -- chain) - so we follow the route graph, not just the immediate destination. A
    -- reversing stub or a depot spur never reaches the return chain, so it scores 0.
    local hopCache = {}
    local function hopsToReturn(startNx)
        if not returnCi then return nil end
        if hopCache[startNx] ~= nil then return hopCache[startNx] or nil end
        local q, qi, seen = { { startNx, 0 } }, 1, {}
        while qi <= #q do
            local nx, h = q[qi][1], q[qi][2]; qi = qi + 1
            if isstring(nx) and nx ~= "" and nx ~= "*" and not seen[nx] and h <= 8 then
                seen[nx] = true
                if chainOf(nx) == returnCi then hopCache[startNx] = h; return h end
                local sg = byName[nx]
                if IsValid(sg) and istable(sg.Routes) then
                    for _, r in ipairs(sg.Routes) do
                        if isstring(r.NextSignal) then q[#q + 1] = { r.NextSignal, h + 1 } end
                    end
                end
            end
        end
        hopCache[startNx] = false
        return nil
    end
    -- Pick the route whose path reaches the RETURN track in the FEWEST hops; ties by
    -- how many of our geometric switches it throws. Falls back to a line-track / most-
    -- switches pick when nothing reaches the return track (no return chain / no PA).
    local maxFd = (TURNBACK_SCAN_M + 50) * AI.U_PER_M
    local best, bestK, bestScore, bestName, bestTag
    for _, sig in ipairs(ents.FindByClass("gmod_track_signal")) do
        if IsValid(sig) and istable(sig.Routes) and sig:GetPos():Distance(ref) < maxFd then
            for k, v in pairs(sig.Routes) do
                if istable(v) and isstring(v.Switches) and v.Switches:find("%-") then
                    local overlap = 0
                    for _, e in ipairs(string.Explode(",", v.Switches)) do
                        if e ~= "" and e:sub(-1) == "-" and want[e:sub(1, -2):upper()] then overlap = overlap + 1 end
                    end
                    local h    = hopsToReturn(v.NextSignal)
                    local dci  = chainOf(v.NextSignal)
                    local line = dci and AI.Route and AI.Route.chainStations
                                 and AI.Route.chainStations[dci] and #AI.Route.chainStations[dci] > 0 or false
                    local score = (h ~= nil and (1000 - h * 10) or 0) + (line and 30 or 0) + overlap
                    if score > 0 and (not bestScore or score > bestScore) then
                        best, bestK, bestScore, bestName = sig, k, score, v.RouteName
                        bestTag = (h ~= nil) and string.format("-> RETURN in %d hop(s)", h)
                                  or (line and "-> line (not return track)" or "geometric")
                    end
                end
            end
        end
    end
    if not best then self.turnbackRoute = "no diverting route nearby"; return false end
    pcall(best.OpenRoute, best, bestK)
    -- Adopt ONLY the route's alt ("-") switches so MaintainTurnback re-asserts the
    -- right set; the "+" (main) switches are handled by re-opening the route, and
    -- forcing them to alt would break the path.
    local list = {}
    for _, e in ipairs(string.Explode(",", best.Routes[bestK].Switches)) do
        if e ~= "" and e:sub(-1) == "-" then
            local s = Metrostroi.GetSwitchByName and Metrostroi.GetSwitchByName(e:sub(1, -2))
            if IsValid(s) then list[#list + 1] = s end
        end
    end
    if #list > 0 then self.turnbackSwitches = list end
    self.turnbackRoute = string.format("%s #%s '%s' [%s]",
        tostring(best.Name), tostring(bestK), tostring(bestName or "?"), tostring(bestTag))
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
        self.turnbackSwitches = nil   -- keep turnbackRoute so !ai term still shows what we lined
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
