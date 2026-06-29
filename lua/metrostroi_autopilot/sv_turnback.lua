--------------------------------------------------------------------------------
-- Terminus turn-back ENGINE  (plan once, then execute deterministically)
--------------------------------------------------------------------------------
-- The old turn-back re-scored routes every tick and kept walking the train into
-- whatever crossover was nearest - straight into the depot at AK. This replaces it
-- with a PLAN-then-EXECUTE model:
--
--   1. PlanTurnback() searches the interlocking's route graph (signal -> route ->
--      NextSignal) for the crossover that lands us on the RETURN track (the opposite
--      running rail). It commits to ONE leg and never re-scores mid-maneuver.
--   2. TurnbackThink() executes a fixed state machine: LEG1 (open the route, hold its
--      switches lined, crawl through, stop when the whole train is past the points OR
--      a buffer/red blocks us) -> REVERSE -> (if not yet on the return track) re-plan
--      and run LEG2 -> done.
--
-- One reversal, single train. OpenRoute is the SOLE switch authority (it lines every
-- switch the route lists; we never raw-throw on top of it). See the saved memory
-- "metrostroi-switch-route-api" for the exact SendSignal / OpenRoute semantics.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI       = MetrostroiAI
local DRIVER   = AI.Driver
local C        = AI.C
local HALF_CAR = AI.HALF_CAR
local U_PER_M  = AI.U_PER_M
local TURNBACK_SCAN_M, TURNBACK_NEAR_U = C.TURNBACK_SCAN_M, C.TURNBACK_NEAR_U

local LEG_SETTLE = 0.6   -- seconds to let a just-opened leg's points settle before we roll in
local LEG_BUILD_MAX = 8  -- ... but never wait longer than this for the interlocking to flag our route
local THROAT_M   = 180   -- a turn-back crossover's first switch is within this of us; farther
                         -- means a junction past the local throat (e.g. a different terminus's
                         -- running-line scissors) that we should NOT divert toward instead of
                         -- the local turn-back the dispatcher uses here.

-- The mechanical reverse: flip the travel sense so the bogeys drive the other way.
-- No switch throwing here - the turn-back engine lines switches via routes only.
function DRIVER:FlipDirection(now)
    self:NoteReverse(now)                 -- remember this spot (anti-oscillation history)
    self.travelDir = -self.travelDir
    self.power = 0
    self.servedPlatform = nil
    self.arsReverseCooldown = true        -- don't let the ARS-loss brake fire on the un-coded throat
end

-- Fallback reverse for a STUB terminus with no crossover route at all: just turn the
-- train on the same track. Uses the main loop's REVERSE_HOLD state (not the engine).
function DRIVER:SimpleReverse(now)
    self:FlipDirection(now)
    self.state    = "REVERSE_HOLD"
    self.holdUntil = now + 5
    self:ApplyDrive(0, AI.HOLD_BRAKE)
    self:SetStatus("TERMINUS")
end

--------------------------------------------------------------------------------
-- PLANNING
--------------------------------------------------------------------------------
-- Find the turn-back crossover that takes us toward the RETURN track. Returns a leg
-- { sig, k, name, switches, landCh, divertFd } or nil, and fills self.tbPlanStr for
-- the !ai term diagnostic. We require the route to divert OUR rail at a switch AHEAD
-- (so it physically grabs us), anchor to the LOCAL throat (so an unrelated far junction
-- that merely touches the line-long return rail can't be picked), and then prefer the
-- route that LANDS ON the return chain over one that lands on a tail/siding.
function DRIVER:PlanTurnback()
    local head = self:GetHead()
    if not (IsValid(head) and AI.ChainPos and Metrostroi.GetSwitchByName) then return nil end
    local tp  = Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    local pos = tp and tp[1]
    if not (pos and pos.path) then return nil end
    local ourCh    = AI.ChainPos(math.floor(tonumber(pos.path.id) or 0), pos.x or 0)
    local returnCh = self:ReturnTrackChain()
    local ref      = head:GetPos()
    local dir      = isvector(self.travelDir) and self.travelDir or head:GetForward()

    -- If the return track resolves to OUR OWN chain, ReturnTrackChain couldn't find the
    -- opposite running track (e.g. no dwell-recorded face yet and the geometric fallback
    -- landed on us). Every "cross to the return" route is then degenerate - it crosses back
    -- onto our own track and derails. Don't attempt a crossover: leave it to the plain
    -- reverse-on-the-spot fallback. (Also the correct behaviour for a true single-track stub.)
    if returnCh and ourCh and returnCh == ourCh then
        self.tbPlanStr = "return track == our track - no crossover (reverse on the spot)"
        return nil
    end

    -- signal name -> chain it sits on
    local byName = {}
    for _, sg in ipairs(ents.FindByClass("gmod_track_signal")) do
        if IsValid(sg) and sg.Name then byName[sg.Name] = sg end
    end
    local function chainOf(nm)
        local sg = byName[nm or ""]
        if not IsValid(sg) then return nil end
        local t = sg.TrackPosition
        if not (istable(t) and t.path) then return nil end
        return (AI.ChainPos(math.floor(tonumber(t.path.id) or 0), t.x or 0))
    end

    -- candidate legs: every route that diverts our rail at a switch ahead of us
    local maxFd = (TURNBACK_SCAN_M + 50) * U_PER_M
    local cands = {}
    for _, sig in ipairs(ents.FindByClass("gmod_track_signal")) do
        if IsValid(sig) and istable(sig.Routes) and sig:GetPos():Distance(ref) < maxFd then
            for k, v in pairs(sig.Routes) do
                if istable(v) and isstring(v.Switches) and v.Switches:find("%-") then
                    local maxfd, divertFd
                    for _, e in ipairs(string.Explode(",", v.Switches)) do
                        if e ~= "" then
                            local s = Metrostroi.GetSwitchByName(e:sub(1, -2))
                            if IsValid(s) then
                                local rel = s:GetPos() - ref
                                local fd  = rel:Dot(dir)
                                local lat = (rel - dir * fd):Length()
                                if not maxfd or fd > maxfd then maxfd = fd end
                                if e:sub(-1) == "-" and fd > -HALF_CAR and lat < TURNBACK_NEAR_U then
                                    local a = math.abs(fd)
                                    if not divertFd or a < divertFd then divertFd = a end
                                end
                            end
                        end
                    end
                    -- The route's SIGNAL must govern OUR track. A route written on a signal
                    -- on another chain (RCAK7 on ch4 while we're on ch1) only sets the throat
                    -- switches for THAT track's move; our train follows the half-set points
                    -- into the wrong place. (Once we reverse onto ch4, RCAK7 *is* on our
                    -- chain and becomes the correct leg-2.)
                    -- The signal must be one we're APPROACHING (ahead of us, facing our way).
                    -- Two signals govern the same scissors from opposite ends - e.g. KS30
                    -- (faces arrivals, north of the throat) and KSB (faces the reversed train);
                    -- only the one we're rolling toward is OURS. A signal behind us governs the
                    -- other direction.
                    local sigFd = self:ForwardDist(sig:GetPos()) / U_PER_M
                    if divertFd and maxfd and maxfd > -HALF_CAR and chainOf(sig.Name) == ourCh
                       and sigFd > -HALF_CAR / U_PER_M then
                        cands[#cands + 1] = { sig = sig, k = k, name = v.RouteName,
                                              switches = v.Switches, divertFd = divertFd, sigFd = sigFd,
                                              nextSig = v.NextSignal, landCh = chainOf(v.NextSignal) }
                    end
                end
            end
        end
    end

    -- FOLLOW the route graph (signal -> route -> NextSignal -> ...) to see whether a route
    -- eventually reaches the return chain, and in how many hops. The crucial bit: a route's
    -- OWN NextSignal is not where the train ends up - the leg-2 route 'AK3-1' has NextSignal
    -- AKFIX1 (still ch4), yet the rail past it leads on to the return. So we must chase the
    -- chain, not read the immediate landing chain. Cached per start signal.
    local hopCache = {}
    local function hopsToReturn(startNx)
        if not returnCh then return nil end
        if hopCache[startNx] ~= nil then return hopCache[startNx] or nil end
        local q, qi, seen = { { startNx, 0 } }, 1, {}
        while qi <= #q do
            local nx, h = q[qi][1], q[qi][2]; qi = qi + 1
            if isstring(nx) and nx ~= "" and nx ~= "*" and not seen[nx] and h <= 8 then
                seen[nx] = true
                if chainOf(nx) == returnCh then hopCache[startNx] = h; return h end
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

    -- Two routes with the SAME switch list are the SAME physical move - BUT ONLY when
    -- entered from the SAME track. AK1 'AK3-1' and RCAK7 #2 are both "AK5+,AK3+,AK1-" on
    -- ch4: one's NextSignal is a dead-end (AKFIX1 -> *), the other's chains to the return
    -- (AKG -> ch2), so the move reaches the return from ch4. The IDENTICAL set as AK2
    -- 'AK4-1' on ch3, though, just loops back into the depot. So judge "does this move reach
    -- the return?" by (ENTRY-CHAIN, switch SET) - if any route throwing this set, entered
    -- from this chain, chains to the return, the set does. (Same for NAMED, so we prefer the
    -- dispatcher's move over an unnamed twin that picks a derailing diagonal.)
    local function switchKey(sw)
        local t = string.Explode(",", sw or "")
        table.sort(t)
        return table.concat(t, ",")
    end
    local function keyOf(ch, sw) return tostring(ch) .. "|" .. switchKey(sw) end
    local setReaches, setNamed = {}, {}
    for _, sg in ipairs(ents.FindByClass("gmod_track_signal")) do
        if IsValid(sg) and istable(sg.Routes) then
            local sc = chainOf(sg.Name)                  -- the track this route is entered FROM
            if sc then
                for _, r in pairs(sg.Routes) do
                    if istable(r) and isstring(r.Switches) and r.Switches:find("%-") then
                        local key = keyOf(sc, r.Switches)
                        if hopsToReturn(r.NextSignal) ~= nil then setReaches[key] = true end
                        if r.RouteName ~= nil and r.RouteName ~= "" then setNamed[key] = true end
                    end
                end
            end
        end
    end
    local function reachesReturn(ch, sw) return setReaches[keyOf(ch, sw)] == true end

    -- Does a tail chain T reach the RETURN track in ONE more leg (after we reverse onto it)?
    -- A route ENTERED FROM T whose switch set reaches the return. Tells the AK sawtooth's ch4
    -- tail (AK1 'AK3-1' -> ch2) from the ch3 depot, where the look-alike set just loops back.
    local tailCache = {}
    local function tailReachesReturn(T)
        if not (T and returnCh) then return false end
        if tailCache[T] ~= nil then return tailCache[T] end
        tailCache[T] = false
        for _, sg in ipairs(ents.FindByClass("gmod_track_signal")) do
            if IsValid(sg) and istable(sg.Routes) and chainOf(sg.Name) == T then
                for _, r in pairs(sg.Routes) do
                    if istable(r) and isstring(r.Switches) and r.Switches:find("%-")
                       and reachesReturn(T, r.Switches) then tailCache[T] = true; break end
                end
            end
            if tailCache[T] then break end
        end
        return tailCache[T]
    end

    -- Rank by HOW the leg reaches the return track:
    --   DIRECT (3)  its rail chains all the way to the return (SV1R1; AK leg-2 'AK3-1')
    --   VIA-TAIL(2) lands on a tail from which one more leg reaches the return (AK leg-1
    --               'AK2-3': cross to ch4, reverse, then 'AK3-1' -> ch2)
    --   tail (1)    some other real track (best-effort); stub (0) a dead end '-> *'
    -- Then prefer a NAMED route (one a dispatcher would "!sopen") - the mapper's intended
    -- move, which picks the diagonal that actually works; an unnamed twin (RCAK7) often
    -- crosses on the other diagonal and derails. Then fewest hops, then nearest entry.
    local best, bestScore
    for _, c in ipairs(cands) do
        if c.divertFd <= THROAT_M * U_PER_M then
            local direct  = reachesReturn(ourCh, c.switches)        -- by (entry chain, switch SET)
            local real    = c.landCh ~= nil and c.landCh ~= ourCh
            local viaTail = (not direct) and real and tailReachesReturn(c.landCh) or false
            local kind    = direct and 3 or (viaTail and 2 or (real and 1 or 0))
            -- "named" = this MOVE (switch set) entered from OUR chain is a route a dispatcher
            -- would !sopen, even if THIS signal's copy is unnamed. So 'AK3-1' (named on ch4)
            -- is preferred over the unnamed RCAK7 #3 twin (its named copy 'AK4-1' lives on
            -- ch3, a different entry, so it does NOT lend its name to the ch4 move).
            local named   = setNamed[keyOf(ourCh, c.switches)] == true
            local h       = hopsToReturn(c.nextSig)                 -- display / tie-break only
            local thisNamed = c.name ~= nil and c.name ~= "" and 1 or 0  -- show the named copy
            -- Then prefer the route on the signal we're APPROACHING (nearest ahead) - the one
            -- governing OUR move. Two signals govern a scissors from opposite ends (KS30 vs KSB,
            -- AK1 vs RCAK7); only the near one is ours. This sits under kind/named so it just
            -- breaks ties among otherwise-equal routes; then fewer hops, then nearest switch.
            local score = kind * 1e7 + (named and 1e5 or 0)
                          - math.max(0, c.sigFd or 0) * 1e2
                          - (h or 0) * 1e1
                          - (c.divertFd / U_PER_M) * 1e-1
                          + thisNamed * 1e-2
            if not bestScore or score > bestScore then best, bestScore, c.kind, c.hops = c, score, kind, h end
        end
    end
    if not best then self.tbPlanStr = "no turn-back crossover on our track ahead"; return nil end
    local kindStr = ({ [3] = "DIRECT", [2] = "via-tail", [1] = "tail", [0] = "stub" })[best.kind or 0]
    self.tbPlanStr = string.format("%s #%s '%s' sw=%s -> %s (%s%s) @%dm",
        tostring(best.sig.Name), tostring(best.k), tostring(best.name or "?"), tostring(best.switches),
        best.landCh and ("ch" .. best.landCh) or "stub", kindStr,
        best.hops and (", " .. best.hops .. "hop->return") or "",
        math.Round(best.divertFd / U_PER_M))
    -- Only COMMIT a leg that actually reaches the return track - DIRECT (lands on it) or
    -- VIA-TAIL (a tail one leg short of it). A bare stub/dead-tail (kind < 2) is never the
    -- maneuver: holding for a better position (the scissors entry still ahead) beats
    -- diverting onto a dead pull-track and oscillating on it (the SV2005 trap).
    if (best.kind or 0) < 2 then
        self.tbPlanStr = self.tbPlanStr .. "  [not committed: no through route]"
        return nil
    end
    return best
end

--------------------------------------------------------------------------------
-- EXECUTION helpers
--------------------------------------------------------------------------------
-- Open a leg's route, exactly as "!sopen <route>" does: OpenRoute lines the route's OWN
-- switch list (its complete set for that move) and nothing else. We do NOT manually toggle
-- any switch - the route is authoritative; a manual "set the rest to main" would force a
-- switch the train needs to DIVERGE at to straight, which is the wrong-side derail. Stale
-- switches from a previous leg are cleared by CloseLeg (CloseRoute) at the transition.
function DRIVER:OpenLeg(leg)
    if IsValid(leg.sig) and leg.sig.OpenRoute then pcall(leg.sig.OpenRoute, leg.sig, leg.k) end
    leg.swList, leg.nextReopen = {}, 0
    leg.openedAt, leg.ready = CurTime(), false   -- gate: don't roll in until lined, settled & clear
    for _, e in ipairs(string.Explode(",", leg.switches or "")) do
        if e ~= "" then
            local s = Metrostroi.GetSwitchByName and Metrostroi.GetSwitchByName(e:sub(1, -2))
            if IsValid(s) then leg.swList[#leg.swList + 1] = { sw = s, alt = (e:sub(-1) == "-") } end
        end
    end
end

-- Are every leg switch physically in the position the route commands? (AlternateTrack ==
-- the route's +/-). OpenRoute sets these at once, but confirm before we commit to rolling.
function DRIVER:LegSwitchesSet(leg)
    if not istable(leg.swList) then return true end
    for _, it in ipairs(leg.swList) do
        if IsValid(it.sw) and (it.sw.AlternateTrack and true or false) ~= it.alt then return false end
    end
    return true
end

-- Has the interlocking actually BUILT our route yet? OpenRoute throws the switches at once,
-- but the signal's own logic takes ~1 s to match those switches and make OUR route the active
-- one (self.Route). Until then the route is still "building" and the signal ahead is red - we
-- must not roll in. self.Route is the index the signal recognises as set; leg.k is ours.
function DRIVER:LegRouteBuilt(leg)
    local s = leg.sig
    if not IsValid(s) then return true end
    return s.Route == leg.k
end

-- Is the route's OWN signal holding us at stop? The interlocking drops a signal to stop for
-- an occupied/conflicting block ahead - the authoritative "do not proceed". We read the same
-- flags the driver's SignalStop uses, MINUS ARSSpeedLimit (a turn-back throat is often un-
-- coded, so code 0 there means "no ARS", not "red"). Occupied/Close/KGU are explicit stops.
function DRIVER:LegSignalAtStop(leg)
    local s = leg.sig
    if not IsValid(s) then return false end
    return (s.Occupied == true) or (s.Close == true) or (s.KGU == true)
end

-- Is another train standing on/near the crossover we're about to take? (any wagon that
-- isn't ours within ~30 m of a leg switch). Don't line/cross a throat onto another train.
function DRIVER:ThroatOccupied(leg)
    if not (istable(leg.swList) and istable(Metrostroi.TrainPositions)) then return false end
    local mine = {}
    for _, w in ipairs(self.wagons or {}) do mine[w] = true end
    for wag in pairs(Metrostroi.TrainPositions) do
        if IsValid(wag) and not mine[wag] then
            local wp = wag:GetPos()
            for _, it in ipairs(leg.swList) do
                if IsValid(it.sw) and wp:Distance(it.sw:GetPos()) < 30 * U_PER_M then return true end
            end
        end
    end
    return false
end

-- Close a leg's route (CloseRoute sends all its switches back to main), so the next leg
-- starts from a clean throat - the dispatcher's same-signal close, applied across legs.
function DRIVER:CloseLeg(leg)
    if leg and IsValid(leg.sig) and leg.sig.CloseRoute then pcall(leg.sig.CloseRoute, leg.sig, leg.k) end
end

-- Keep the leg lined while we thread it: re-assert each ALT switch still ahead of the
-- tail (refreshing its 20 s auto-revert timer) and re-open the route periodically.
function DRIVER:HoldLeg(leg, now)
    if not (istable(self.wagons) and isvector(self.travelDir) and istable(leg.swList)) then return end
    local tail = math.huge
    for _, w in ipairs(self.wagons) do if IsValid(w) then tail = math.min(tail, w:GetPos():Dot(self.travelDir)) end end
    local anyAhead = false
    for _, it in ipairs(leg.swList) do
        if IsValid(it.sw) and (it.sw:GetPos():Dot(self.travelDir) - tail) >= -HALF_CAR then
            if it.alt then pcall(it.sw.SendSignal, it.sw, "alt", nil, true) end
            anyAhead = true
        end
    end
    if anyAhead and now >= (leg.nextReopen or 0) then
        leg.nextReopen = now + 1.5
        if IsValid(leg.sig) and leg.sig.OpenRoute then pcall(leg.sig.OpenRoute, leg.sig, leg.k) end
    end
end

-- Has the WHOLE train cleared every switch the leg throws (with a 2-car margin)?
function DRIVER:LegSwitchesCleared(leg)
    if not (istable(self.wagons) and isvector(self.travelDir) and istable(leg.swList)) then return false end
    if #leg.swList == 0 then return true end
    local tail = math.huge
    for _, w in ipairs(self.wagons) do if IsValid(w) then tail = math.min(tail, w:GetPos():Dot(self.travelDir)) end end
    for _, it in ipairs(leg.swList) do
        if IsValid(it.sw) and (it.sw:GetPos():Dot(self.travelDir) - tail) >= -HALF_CAR * 2 then return false end
    end
    return true
end

-- Begin the maneuver. Returns true if it took control.
function DRIVER:StartTurnback(now)
    -- Lock the return track NOW, while we're still on our arrival running track (the
    -- opposite running track of the line). If a dwell already locked it, keep that; only
    -- compute here for a no-dwell turn-back (rail ends ahead with no terminus platform).
    if not self.returnChainCi then self.returnChainCi = self:OppositeRunningChain(self:CurrentChain()) end
    local leg = self:PlanTurnback()
    if leg then
        self.tb = { phase = "LEG1", leg = leg }
        self.servedIsTerminus = nil
        self:OpenLeg(leg)
        self:SetStatus("TURNBACK: " .. tostring(self.tbPlanStr))
        return true
    end
    -- No crossover within reach AHEAD, and we just served a terminus. Reverse in place ONLY if
    -- the rail END is right here (within a throat length): then the scissors is BEHIND the
    -- platform (we crossed it on the way IN, the KS case) or it's a plain stub, and the REVERSE
    -- re-plan finds the scissors ahead and crosses it - avoiding the over-run "pull-track dance".
    -- But if the rail RUNS ON well past us, the scissors is a long way ahead (SV/100: ~470 m out,
    -- past the platform); do NOT reverse here - return false and keep DRIVING, and PlanTurnback
    -- picks the scissors up once we're within a throat length of it.
    local tp  = Metrostroi.TrainPositions and Metrostroi.TrainPositions[self:GetHead()]
    local pos = tp and tp[1]
    if self.servedIsTerminus and not self:RecentlyReversedNear(now)
       and pos and self:TerminusDistance(pos, THROAT_M) then
        self.servedIsTerminus = nil
        self:FlipDirection(now)
        self.tb = { phase = "REVERSE", holdUntil = now + 5 }
        self:SetStatus("TURNBACK: reverse at platform (scissors behind)")
        return true
    end
    return false
end

--------------------------------------------------------------------------------
-- The state machine (owns the train completely while self.tb is set)
--------------------------------------------------------------------------------
function DRIVER:TurnbackThink(now, dt, speed)
    local tb    = self.tb
    local crawl = AI.CVars.turnback_speed and AI.CVars.turnback_speed:GetFloat() or 25

    -- Hold after a reverse, then either finish (we're on the return track) or run leg 2.
    if tb.phase == "REVERSE" then
        self:ApplyDrive(0, AI.HOLD_BRAKE)
        self:SetStatus("TURNBACK reverse")
        if now >= (tb.holdUntil or 0) then
            if self:OnReturnTrack() then
                self:CloseLeg(tb.leg)                           -- straighten the crossover so we run OUT on the return track, not get diverted back across it
                self.tb = nil; self.returnChainCi = nil         -- direct crossover: done
            else
                local leg = self:PlanTurnback()                 -- re-plan the come-back leg
                if leg then
                    self:CloseLeg(tb.leg)                        -- clear leg-1's switches first
                    tb.leg = leg; tb.phase = "LEG2"; self:OpenLeg(leg)
                else self:CloseLeg(tb.leg); self.tb = nil; self.returnChainCi = nil end  -- no leg 2: straighten & stop cleanly
            end
        end
        return
    end

    -- LEG1 / LEG2 : drive the crossover.
    local leg = tb.leg
    self:HoldLeg(leg, now)

    -- SAFEGUARD before rolling into a leg: keep the train stopped until the route is fully
    -- lined (every point in its commanded position), has had a moment to SETTLE, and the
    -- crossover ahead is clear of any other train. One-time per leg (once moving we don't
    -- re-check, or our own train on the points would read as "occupied").
    if not leg.ready then
        local heldFor     = now - (leg.openedAt or 0)
        local switchesSet = self:LegSwitchesSet(leg)
        local stopSig     = self:LegSignalAtStop(leg)             -- interlocking says: do not proceed
        local blocked     = stopSig or self:ThroatOccupied(leg)   -- + a physical wagon on the points
        local built       = self:LegRouteBuilt(leg)               -- interlocking made OUR route active
        -- Normal: route built + points set + settle elapsed + nothing blocking. Fallback: if
        -- the interlocking never flags our route (a self.Route quirk) but the points ARE set
        -- and nothing blocks, go after LEG_BUILD_MAX so we can't hang forever.
        if not blocked and switchesSet
           and ((heldFor >= LEG_SETTLE and built) or heldFor >= LEG_BUILD_MAX) then
            leg.ready = true
        else
            self:ApplyDrive(0, AI.HOLD_BRAKE)
            self:SetStatus("TURNBACK " .. tb.phase .. (blocked
                and (stopSig and " (signal at stop - waiting)" or " (throat occupied - waiting)")
                or ((built and switchesSet) and " (settling)" or " (building route)")))
            return
        end
    end

    -- LEG2 complete: once the whole train is CLEAR of the come-back crossover we're on the
    -- return path heading out, so hand back to normal driving (it accelerates and stops at
    -- stations). Do NOT wait for OnReturnTrack - the return line spans several chains and the
    -- platform's chain can be far ahead, which left us crawling past every station in LEG2.
    if tb.phase == "LEG2" and self:LegSwitchesCleared(leg) then
        self:CloseLeg(leg)                                       -- straighten the throat behind us
        self.tb = nil; self.returnChainCi = nil; self:SetStatus("TURNBACK done"); return
    end

    -- LEG1 fully across the points -> reverse. Leg 1 lands us on the pull track (or, at a
    -- plain scissors, on the return track facing the buffer); either way we reverse, then
    -- either finish (REVERSE sees OnReturnTrack) or run leg 2. We do NOT reverse after
    -- LEG2: that is the come-back leg, so once across it we are already heading the right
    -- way and just crawl on until we reach the return track (the LEG2-complete check above)
    -- - reversing there would send us straight back toward the pull track.
    if tb.phase == "LEG1" and self:LegSwitchesCleared(leg) then
        self:FlipDirection(now)
        tb.phase, tb.holdUntil = "REVERSE", now + 5
        self:ApplyDrive(0, AI.HOLD_BRAKE); self:SetStatus("TURNBACK reverse"); return
    end

    -- Obey a real red ONLY on the come-back leg (LEG2), where we're rejoining the live line
    -- and a stop means an occupied block AHEAD. On LEG1 we run INTO the terminus throat to
    -- reverse, so the dead-end reds ahead of us are expected and must NOT freeze us partway
    -- across the crossover (the leg-start gate already proved our route was clear to enter,
    -- and we reverse the moment we clear the points - we never reach those reds).
    -- "Red" = no movement authority: a stop CODE (0), or - on an un-coded throat with no code
    -- to read - a governing signal flagged at stop. A valid GO code (e.g. 40) IS the
    -- interlocking's authority (it won't code us into an occupied block), so we must NOT
    -- freeze on a mere Occupied flag while we hold a code - that stopped us dead at a coded
    -- terminus-side signal our nose had already passed.
    if tb.phase == "LEG2" then
        local rs  = self.arsSignal
        local red = (self.arsSpeed == 0)
                 or (self.arsSpeed == nil and IsValid(rs) and (rs.Occupied or rs.Close or rs.KGU))
        if red and IsValid(rs) and self:ForwardDist(rs:GetPos()) > HALF_CAR then
            self:ApplyDrive(0, AI.HOLD_BRAKE)
            self:SetStatus("TURNBACK LEG2 (held at red signal ahead)")
            return
        end
    end

    -- CRAWL: LEG1 forward to clear the points (it reverses above once across), LEG2 forward
    -- to the return line (the LEG2-complete check finishes us when OnReturnTrack). We do NOT
    -- consult the end-of-track probe here: it false-fires on the sharp S-curve through a
    -- crossover and would bounce us back mid-throat. A committed leg always reaches the
    -- return or clears onto a tail we reverse off above, so no buffer stop is needed. Drive
    -- brakes us down to the crawl speed on the run-in, so the bogeys take the frogs slowly.
    self:Drive(crawl, speed, dt)
    self:SetStatus(string.format("TURNBACK %s %d/%d", tb.phase, math.Round(speed), math.Round(crawl)))
end
