--------------------------------------------------------------------------------
-- Metrostroi Autopilot - diagnostic dump commands (ARS code / door circuit /
-- terminus & turn-back / regulation). Split out of sv_commands.lua; loaded
-- after sv_util.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI
local tell, resolveTrain, resolveDriver = AI.Tell, AI.ResolveTrain, AI.ResolveDriver

-- Print exactly what ARS code the governing signal is sending for the nearest /
-- aimed AI train, so we can see why a section reads slower than expected.
function AI.CmdArsDebug(ply)
    local drv
    local t = resolveTrain(ply)
    if IsValid(t) and t.GetNW2Entity then
        local p = t:GetNW2Entity("TrainEntity"); if IsValid(p) then t = p end
    end
    for lead, d in pairs(AI.Drivers) do
        if lead == t then drv = d break end
        for _, w in ipairs(d.wagons or {}) do if w == t then drv = d break end end
        if drv then break end
    end
    if not drv and IsValid(ply) then
        local bd
        for _, d in pairs(AI.Drivers) do
            if IsValid(d.head) then
                local dd = d.head:GetPos():DistToSqr(ply:GetPos())
                if not bd or dd < bd then bd, drv = dd, d end
            end
        end
    end
    if not drv then return tell(ply, "no AI train found - aim at one or stand near it.") end

    local function line(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[AI ARS] " .. s .. "\n") end
        tell(ply, s)
    end

    local head = drv.head
    local tp  = Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    local pos = tp and tp[1]
    local dir = Metrostroi.TrainDirections and Metrostroi.TrainDirections[head]
    line(string.format("dir=%s path=%s x=%s speed=%d", tostring(dir),
        pos and pos.path and tostring(pos.path.id) or "?",
        pos and string.format("%.1f", pos.x) or "?", math.Round(drv:GetSpeed())))
    if not (pos and pos.node1 and type(dir) == "boolean") then
        return line("no valid network position (off-network map?)")
    end
    local ok, fwd = pcall(Metrostroi.GetARSJoint, pos.node1, pos.x, dir, head)
    if not ok or not IsValid(fwd) then return line("GetARSJoint -> no signal: " .. tostring(fwd)) end
    if not fwd.GetARS then return line("signal '" .. tostring(fwd.Name) .. "' has no GetARS") end
    local tbl = head.SubwayTrain and head.SubwayTrain.ALS
    local f15 = (not tbl) or (not tbl.TwoToSix)
    line(string.format("signal '%s'  ARSSpeedLimit=%s  Next=%s  TwoToSix=%s",
        tostring(fwd.Name), tostring(fwd.ARSSpeedLimit), tostring(fwd.ARSNextSpeedLimit), tostring(fwd.TwoToSix)))
    line(string.format("f15=%s  GetARS 8=%s 7=%s 6=%s 4=%s 0=%s", tostring(f15),
        tostring(fwd:GetARS(8, f15)), tostring(fwd:GetARS(7, f15)), tostring(fwd:GetARS(6, f15)),
        tostring(fwd:GetARS(4, f15)), tostring(fwd:GetARS(0, f15))))
    line("decoded -> " .. tostring(drv:DecodeARS(fwd)) .. " km/h")
    local function f(v) if not v or v >= 9000 then return "-" end return tostring(math.Round(v)) end
    local d = drv.dbg
    if d then
        line(string.format("LIMITS km/h: cruise=%s ars=%s curve=%s signal=%s train=%s term=%s plat=%s  => target=%s",
            f(d.cruise), f(d.ars), f(d.curve), f(d.signal), f(d.train), f(d.term), f(d.platform), f(d.target)))
    end
end

-- Dump the live door-circuit state per car so we can see exactly which
-- precondition is unmet. The door opens only if BOTH (a) the electrical command
-- reaches the valve: VDOL/VDOP == 1 (needs wire10 * A21 * reverser-engaged for
-- D1 power, then DoorSelect + KDL/VDL + A31), AND (b) air: DoorLinePressure > 3.5.
function AI.CmdDoorDebug(ply)
    local drv
    local t = resolveTrain(ply)
    if IsValid(t) and t.GetNW2Entity then
        local p = t:GetNW2Entity("TrainEntity"); if IsValid(p) then t = p end
    end
    for lead, d in pairs(AI.Drivers) do
        if lead == t then drv = d break end
        for _, w in ipairs(d.wagons or {}) do if w == t then drv = d break end end
        if drv then break end
    end
    if not drv and IsValid(ply) then
        local bd
        for _, d in pairs(AI.Drivers) do
            if IsValid(d.head) then
                local dd = d.head:GetPos():DistToSqr(ply:GetPos())
                if not bd or dd < bd then bd, drv = dd, d end
            end
        end
    end
    if not drv then return tell(ply, "no AI train found - aim at one or stand near it.") end

    local function line(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[AI DOORS] " .. s .. "\n") end
        tell(ply, s)
    end
    local function val(w, sys, field)
        if not IsValid(w) or not w[sys] then return "-" end
        local ok, v = pcall(function() return w[sys][field or "Value"] end)
        if not ok or v == nil then return "?" end
        if type(v) == "number" then return string.format("%.2f", v) end
        return tostring(v)
    end
    local function wire(w, n)
        if IsValid(w) and w.ReadTrainWire then
            local ok, v = pcall(w.ReadTrainWire, w, n)
            if ok then return string.format("%.1f", v) end
        end
        return "?"
    end
    local function door(w, key)
        if IsValid(w) and w.GetPackedBool then
            local ok, v = pcall(w.GetPackedBool, w, key)
            if ok then return tostring(v) end
        end
        return "?"
    end

    line("=== door circuit (open needs VDOL/VDOP=1 AND DoorLinePress>3.5) ===")
    for i, w in ipairs(drv.wagons or {}) do
        if i > 4 then break end
        local tag = (w == drv.head) and "HEAD" or ("car" .. i)
        line(string.format("%s %s  wire10=%s A21=%s rev=%s D-D1=%s  | DSel=%s KDL=%s VDL=%s VUD1=%s A31=%s",
            tag, w:GetClass(), wire(w, 10), val(w, "A21"), val(w, "KV", "ReverserPosition"),
            val(w, "KV", "D-D1"), val(w, "DoorSelect"), val(w, "KDL"), val(w, "VDL"),
            val(w, "VUD1"), val(w, "A31")))
        line(string.format("     VDOL=%s VDOP=%s  DoorLinePress=%s  physDoorL=%s physDoorR=%s",
            val(w, "VDOL"), val(w, "VDOP"), val(w, "Pneumatic", "DoorLinePressure"),
            door(w, "DoorL"), door(w, "DoorR")))
    end
end

-- Terminus / turn-back diagnostic: distance to the buffer ahead, which crossover
-- switch the turn-back would throw, and the switches near the train (id, forward
-- dist in m, lateral in units, current alt state) so we can verify the pick.
function AI.CmdTermDebug(ply)
    local drv = resolveDriver(ply)
    if not drv then return tell(ply, "no AI train found - aim at one or stand near it.") end
    local function line(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[AI TERM] " .. s .. "\n") end
        tell(ply, s)
    end
    local head = drv.head
    if not IsValid(head) then return line("driver has no head wagon") end
    local tp  = Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
    local pos = tp and tp[1]
    local term = pos and drv:TerminusDistance(pos)
    local thrown = "-"
    if drv.turnbackSwitches and #drv.turnbackSwitches > 0 then
        local ids = {}
        for _, sw in ipairs(drv.turnbackSwitches) do
            if IsValid(sw) then ids[#ids + 1] = sw:GetNW2String("ID", "?") end
        end
        thrown = table.concat(ids, "+")
    end
    line(string.format("state=%s  term=%s  turnback=%s",
        tostring(drv.state),
        term and (string.format("%.0f m to buffer", term)) or "none (track continues / loop)",
        thrown))
    line("  terminus probe (path end): " .. tostring(drv.termWhy))
    drv:TrackEndAhead(200)
    line("  end-of-track scan: " .. tostring(drv.trackEndWhy))
    if drv.turnbackPick then line("  turnback pick: " .. drv.turnbackPick) end
    if drv.turnbackRoute then line("  turnback route: " .. drv.turnbackRoute) end
    if drv.turnbackSwitches and #drv.turnbackSwitches > 0 then
        local st = {}
        for _, sw in ipairs(drv.turnbackSwitches) do
            if IsValid(sw) then st[#st + 1] = sw:GetNW2String("ID", "?") .. (sw.AlternateTrack and "=ALT" or "=main") end
        end
        line("  turnback switches held: " .. table.concat(st, "  "))
    end
    line("  recently reversed near here: " .. tostring(drv:RecentlyReversedNear(CurTime())))
    -- What platform (if any) the driver is currently locked onto - the prime
    -- suspect for getting stuck at a terminus is the OPPOSITE-track face being
    -- re-acquired (small farFd, lateral ~= track gap) so the platform block keeps
    -- returning before the terminus reverse can run.
    local pf = drv:NextPlatform()
    if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
        local farFd  = drv:ForwardDist(drv:PlatformStopPoint(pf)) / AI.U_PER_M
        local center = (pf.PlatformStart + pf.PlatformEnd) * 0.5
        line(string.format("nextPlatform: station %s  farFd=%+.0fm  lateral=%.0fu  stop=%s",
            tostring(pf.StationIndex or "?"), farFd, drv:LateralDist(center),
            drv:PAStopFor(pf) and "PA marker" or "platform end"))
        local pa = drv:PAInfoFor(pf)
        if pa then line(string.format("  PA marker: terminus=%s  doors=%s  name=%s",
            tostring(pa.isLast), pa.rightDoors and "RIGHT" or "LEFT", tostring(pa.name or "?"))) end
    else
        line("nextPlatform: none")
    end
    line(string.format("servedPlatform=%s  doorsOpen=%s",
        IsValid(drv.servedPlatform) and tostring(drv.servedPlatform.StationIndex or "?") or "-",
        tostring(drv.doorsOpen)))
    -- ARS frequency: if we've seen a code and then lost it, that's a stop (and,
    -- at the end of coded track, a turn-back) - this is what catches a dead-end
    -- stub the geometric terminus probe misses.
    line(string.format("ARS: code=%s everSeen=%s lostFor=%s -> LOST=%s  revCooldown=%s",
        tostring(drv.arsSpeed), tostring(drv.arsEverSeen or false),
        drv.arsLostAt and string.format("%.1fs", CurTime() - drv.arsLostAt) or "-",
        tostring(drv:ARSLost(CurTime())), tostring(drv.arsReverseCooldown or false)))
    -- Scan BOTH ways along travel: +fwd = toward the buffer ahead, -fwd = behind us
    -- toward the line (where an approach-side crossover lives).
    local ref = head:GetPos()
    local dir = drv.travelDir or head:GetForward()
    local n = 0
    for _, sw in ipairs(ents.FindByClass("gmod_track_switch")) do
        if IsValid(sw) then
            local rel = sw:GetPos() - ref
            local fd  = rel:Dot(dir)
            local lat = (rel - dir * fd):Length()
            if math.abs(fd) < 450 * AI.U_PER_M and lat < 1000 then
                n = n + 1
                line(string.format("  switch %s  fwd=%+.0fm  lat=%.0fu  alt=%s",
                    tostring(sw:GetNW2String("ID", "?")), fd / AI.U_PER_M, lat, tostring(sw.AlternateTrack)))
                if n >= 10 then break end
            end
        end
    end
    if n == 0 then line("  no switches within ~450 m either direction (single-track / stub terminus?)") end

    -- Terminus routing: the diverting routes on nearby signals and where each leads
    -- (a LINE track = a proper track-change back onto the line; off-line = toward a
    -- depot / yard). This is how we tell the turn-back route from the depot trap.
    line("--- nearby diverting routes (LINE = back onto the line, off-line = depot/yard) ---")
    local rc = drv.ReturnTrackChain and drv:ReturnTrackChain()
    local oc
    do
        local tp2 = Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
        local p2  = tp2 and tp2[1]
        if p2 and p2.path and AI.ChainPos then oc = AI.ChainPos(math.floor(tonumber(p2.path.id) or 0), p2.x or 0) end
    end
    line(string.format("  return-track chain=%s  our chain=%s  (<<RETURN = route lands on the return track)",
        tostring(rc), tostring(oc)))
    local byName = {}
    for _, sg in ipairs(ents.FindByClass("gmod_track_signal")) do
        if IsValid(sg) and sg.Name then byName[sg.Name] = sg end
    end
    local rdir = isvector(drv.travelDir) and drv.travelDir or head:GetForward()
    local shown = 0
    for _, sg in ipairs(ents.FindByClass("gmod_track_signal")) do
        if IsValid(sg) and istable(sg.Routes) and sg:GetPos():Distance(ref) < 3500 then
            for _, r in ipairs(sg.Routes) do
                local sw = r.Switches
                if isstring(sw) and sw:find("%-") and shown < 16 then
                    -- farthest thrown switch's forward distance: the crossover the
                    -- selector treats as "ahead" only if this is > about -9 m
                    local swfd
                    for _, e in ipairs(string.Explode(",", sw)) do
                        if e ~= "" then
                            local s = Metrostroi.GetSwitchByName and Metrostroi.GetSwitchByName(e:sub(1, -2))
                            if IsValid(s) then
                                local fd = (s:GetPos() - ref):Dot(rdir) / AI.U_PER_M
                                if not swfd or fd > swfd then swfd = fd end
                            end
                        end
                    end
                    local fdtag = swfd and string.format(" pts%+.0fm", swfd) or " pts?"
                    local nx  = r.NextSignal or ""
                    local cls, dDepot = "?", ""
                    local nsig = byName[nx]
                    if IsValid(nsig) then
                        local tp = nsig.TrackPosition
                        if istable(tp) and tp.path and AI.IsLinePath then
                            cls = AI.IsLinePath(math.floor(tonumber(tp.path.id) or 0)) and "LINE" or "off-line"
                        end
                        dDepot = string.format("  next@%dm", math.floor(nsig:GetPos():Distance(ref) / AI.U_PER_M))
                    end
                    local dci
                    if IsValid(nsig) and istable(nsig.TrackPosition) and nsig.TrackPosition.path and AI.ChainPos then
                        dci = AI.ChainPos(math.floor(tonumber(nsig.TrackPosition.path.id) or 0), nsig.TrackPosition.x or 0)
                    end
                    local mark = (dci and rc and dci == rc) and "  <<RETURN" or ""
                    local sigch
                    if istable(sg.TrackPosition) and sg.TrackPosition.path and AI.ChainPos then
                        sigch = AI.ChainPos(math.floor(tonumber(sg.TrackPosition.path.id) or 0), sg.TrackPosition.x or 0)
                    end
                    local ourMark = (sigch and oc and sigch == oc) and " {OURtrack}" or ""
                    shown = shown + 1
                    line(string.format("  %s(ch%s) '%s'  sw=%s  -> %s [%s] dch=%s%s%s%s%s",
                        tostring(sg.Name), tostring(sigch), tostring(r.RouteName or ""), sw, nx, cls,
                        tostring(dci), fdtag, dDepot, mark, ourMark))
                end
            end
        end
    end
    if shown == 0 then line("  (no diverting routes within ~67 m)") end
end

-- Why isn't regulation working? Shows the route chains, how many trains landed on
-- each, and the aimed train's leader gap / spacing target.
function AI.CmdRegDebug(ply)
    local function line(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[AI REG] " .. s .. "\n") end
        tell(ply, s)
    end
    line("regulation=" .. AI.CVars.regulation:GetInt() .. "  maxhold=" .. AI.CVars.reg_maxhold:GetInt())
    local chains = AI.EnsureRoute and AI.EnsureRoute()
    line("route chains: " .. (chains and tostring(#chains) or "NIL (route build failed)"))
    if AI.EnsureLines then AI.EnsureLines() end
    if AI.ConsistReps then
        local perLine, total = {}, 0
        for _, rep in ipairs(AI.ConsistReps()) do
            total = total + 1
            local tp = Metrostroi.TrainPositions and Metrostroi.TrainPositions[rep.w]
            local p = tp and tp[1]
            if p and p.path then
                local ci, cd = AI.ChainPos(math.floor(tonumber(p.path.id) or 0), p.x or 0)
                if ci then
                    local rs = AI.RegState and AI.RegState[rep.w]
                    local root = AI.TrainLinePos(ci, cd, rs and rs.vsign or 1)
                    if root then perLine[root] = (perLine[root] or 0) + 1 end
                end
            end
        end
        line("consists (trains): " .. total)
        local shown = 0
        for root, n in pairs(perLine) do
            shown = shown + 1
            if shown <= 8 then line(string.format("  line %s: %d train(s)", tostring(root), n)) end
        end
    end
    local drv = resolveDriver(ply)
    if drv then
        local head = IsValid(drv.head) and drv.head or drv.lead
        local tp = IsValid(head) and Metrostroi.TrainPositions and Metrostroi.TrainPositions[head]
        local p = tp and tp[1]
        local ci, cd
        if p and p.path then ci, cd = AI.ChainPos(math.floor(tonumber(p.path.id) or 0), p.x or 0) end
        local rs = IsValid(head) and AI.RegState and AI.RegState[head]
        local root, lp = ci and AI.TrainLinePos(ci, cd, rs and rs.vsign or 1)
        line(string.format("aimed: state=%s chain=%s line=%s linePos=%s | leaderGap=%s target=%s",
            tostring(drv.state), tostring(ci), tostring(root),
            lp and string.format("%.3f", lp) or "?",
            drv.regLeaderGap and string.format("%.3f", drv.regLeaderGap) or "nil",
            drv.regTarget and string.format("%.3f", drv.regTarget) or "nil"))
    end
end

--------------------------------------------------------------------------------
-- Register diagnostic console commands
--------------------------------------------------------------------------------
concommand.Add("metrostroi_ai_arsdebug",  function(ply) AI.CmdArsDebug(ply) end)
concommand.Add("metrostroi_ai_doordebug", function(ply) AI.CmdDoorDebug(ply) end)
concommand.Add("metrostroi_ai_termdebug", function(ply) AI.CmdTermDebug(ply) end)
concommand.Add("metrostroi_ai_regdebug",  function(ply) AI.CmdRegDebug(ply) end)
