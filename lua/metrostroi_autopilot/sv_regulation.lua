--------------------------------------------------------------------------------
-- Metrostroi Autopilot - route model + traffic regulation
--------------------------------------------------------------------------------
-- Stitches the raw track paths into continuous ROUTES (shared with the map), and
-- runs the optional auto traffic regulation that evens out the spacing between
-- trains. metrostroi_ai_regulation: 0 off / 1 hold until next station clear /
-- 2 equalise the headway between every train on the map (AI and manual).
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI

--------------------------------------------------------------------------------
-- Route chains: join path endpoints that meet in 3D (so stacked loops don't
-- merge) and keep the straightest continuation through junctions. Cached - the
-- network is static for the life of the map.
--------------------------------------------------------------------------------
AI.Route = AI.Route or {}

function AI.BuildChains()
    local P = {}
    for id, path in pairs(Metrostroi.Paths or {}) do
        if istable(path) and #path >= 2 and tonumber(path.length) then
            local a, b = path[1], path[#path]
            if isvector(a.pos) and isvector(b.pos) and isvector(path[2].pos) and isvector(path[#path - 1].pos) then
                P[#P + 1] = {
                    id  = math.Clamp(math.floor(tonumber(path.id) or tonumber(id) or 0), 0, 65535),
                    len = path.length, pa = a.pos, pb = b.pos,
                    oa  = (a.pos - path[2].pos):GetNormalized(),
                    ob  = (b.pos - path[#path - 1].pos):GetNormalized(),
                    used = false,
                }
            end
        end
    end
    local function bestCont(pos, outDir)
        local best, bestScore, bestEnd
        for _, q in ipairs(P) do
            if not q.used then
                for _, e in ipairs({ { q.pa, q.oa, "a" }, { q.pb, q.ob, "b" } }) do
                    if pos:DistToSqr(e[1]) < 40 * 40 then
                        local score = -outDir:Dot(e[2])
                        if score > 0.25 and (not bestScore or score > bestScore) then best, bestScore, bestEnd = q, score, e[3] end
                    end
                end
            end
        end
        return best, bestEnd
    end
    table.sort(P, function(a, b) return a.len > b.len end)
    local chains, lookup = {}, {}
    for _, seed in ipairs(P) do
        if not seed.used then
            seed.used = true
            local segs = { { p = seed, flip = false } }
            local fp, fo = seed.pb, seed.ob
            while true do
                local q, qe = bestCont(fp, fo); if not q then break end
                q.used = true
                if qe == "a" then segs[#segs + 1] = { p = q, flip = false }; fp, fo = q.pb, q.ob
                else              segs[#segs + 1] = { p = q, flip = true  }; fp, fo = q.pa, q.oa end
            end
            local bp, bo = seed.pa, seed.oa
            while true do
                local q, qe = bestCont(bp, bo); if not q then break end
                q.used = true
                if qe == "b" then table.insert(segs, 1, { p = q, flip = false }); bp, bo = q.pa, q.oa
                else              table.insert(segs, 1, { p = q, flip = true  }); bp, bo = q.pb, q.ob end
            end
            local ci, off, outsegs = #chains + 1, 0, {}
            for _, s in ipairs(segs) do
                lookup[s.p.id] = { ci = ci, offset = off, len = s.p.len, flip = s.flip }
                outsegs[#outsegs + 1] = { id = s.p.id, offset = off, len = s.p.len, flip = s.flip }
                off = off + s.p.len
            end
            chains[ci] = { segs = outsegs, len = off, loop = (bp:Distance(fp) < 50) }
        end
    end
    AI.Route.chains, AI.Route.lookup = chains, lookup
    AI.Route.lineRoot = nil          -- force the line model to rebuild
    return chains, lookup
end

function AI.EnsureRoute()
    if not AI.Route.chains or #AI.Route.chains == 0 then AI.BuildChains() end   -- rebuild if empty
    return AI.Route.chains, AI.Route.lookup
end

-- (path id, local x) -> (chain index, distance along chain)
function AI.ChainPos(pid, x)
    local lk = AI.Route.lookup and AI.Route.lookup[pid]
    if not lk then return nil end
    return lk.ci, lk.offset + (lk.flip and (lk.len - x) or x)
end

--------------------------------------------------------------------------------
-- Headway regulation (level 2). Every ~1.5 s: place all trains on their chains,
-- order them, and tell each AI driver the gap to the train ahead and the even-
-- spacing target (chain length / train count). The driver holds at a platform
-- until its gap reaches the target, which converges to equal spacing for all.
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Line model: group route chains into LINES by shared station numbers (both
-- running tracks of a line share every station). A train gets one 0..2 loop
-- coordinate - 0..1 going UP the station numbers, 1..2 coming back DOWN - so
-- trains in both directions sit on one circuit and space across the whole line.
--------------------------------------------------------------------------------
function AI.BuildLines()
    AI.EnsureRoute()
    local cs = {}
    for _, pf in ipairs(ents.FindByClass("gmod_track_platform")) do
        if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
            local c = (pf.PlatformStart + pf.PlatformEnd) * 0.5
            local num = tonumber(pf.StationIndex)
            local ok, res = pcall(Metrostroi.GetPositionOnTrack, c, pf:GetAngles())
            if num and ok and res and res[1] and res[1].path then
                local ci, cd = AI.ChainPos(math.floor(tonumber(res[1].path.id) or 0), res[1].x or 0)
                if ci then cs[ci] = cs[ci] or {}; table.insert(cs[ci], { num = num, cd = cd }) end
            end
        end
    end
    local grad = {}
    for ci, sts in pairs(cs) do
        table.sort(sts, function(a, b) return a.cd < b.cd end)
        grad[ci] = (#sts >= 2 and sts[#sts].num < sts[1].num) and -1 or 1
    end
    local parent = {}
    local function find(x) while parent[x] ~= x do parent[x] = parent[parent[x]]; x = parent[x] end return x end
    for ci in pairs(cs) do parent[ci] = ci end
    local byNum = {}
    for ci, sts in pairs(cs) do
        for _, s in ipairs(sts) do
            if byNum[s.num] then local a, b = find(byNum[s.num]), find(ci); if a ~= b then parent[a] = b end
            else byNum[s.num] = ci end
        end
    end
    local range, root = {}, {}
    for ci, sts in pairs(cs) do
        local r = find(ci); root[ci] = r
        local rr = range[r] or { min = math.huge, max = -math.huge }
        for _, s in ipairs(sts) do rr.min = math.min(rr.min, s.num); rr.max = math.max(rr.max, s.num) end
        range[r] = rr
    end
    AI.Route.chainStations, AI.Route.gradient, AI.Route.lineRoot, AI.Route.lineRange = cs, grad, root, range
end

function AI.EnsureLines()
    if not AI.Route.lineRoot then AI.BuildLines() end
end

-- (chain, chain distance, motion sign) -> (line id, 0..2 loop position)
function AI.TrainLinePos(ci, cd, vsign)
    if not (AI.Route.lineRoot and AI.Route.chainStations) then return nil end
    local sts, root = AI.Route.chainStations[ci], AI.Route.lineRoot[ci]
    local r = root and AI.Route.lineRange[root]
    if not (sts and #sts >= 1 and r and r.max > r.min) then return nil end
    local num
    if #sts == 1 or cd <= sts[1].cd then num = sts[1].num
    elseif cd >= sts[#sts].cd then num = sts[#sts].num
    else
        for i = 1, #sts - 1 do
            if cd >= sts[i].cd and cd <= sts[i + 1].cd then
                local f = (cd - sts[i].cd) / math.max(1, sts[i + 1].cd - sts[i].cd)
                num = sts[i].num + f * (sts[i + 1].num - sts[i].num); break
            end
        end
    end
    if not num then return nil end
    local u  = (num - r.min) / (r.max - r.min)
    local up = ((vsign or 1) * (AI.Route.gradient[ci] or 1)) >= 0
    return root, (up and u or (2 - u)) % 2
end

--------------------------------------------------------------------------------
-- Headway regulation (level 2). ONE entry per CONSIST (its head), spaced evenly
-- around its line's 0..2 loop.
--------------------------------------------------------------------------------
AI.RegState = AI.RegState or {}   -- [wagon] = { cd, ci, vsign }

-- One representative wagon (the head) per train, AI and manual alike.
function AI.ConsistReps()
    local reps, seen = {}, {}
    for _, drv in pairs(AI.Drivers) do
        local head = IsValid(drv.head) and drv.head or drv.lead
        if IsValid(head) then
            reps[#reps + 1] = { w = head, drv = drv }
            for _, w in ipairs(drv.wagons or {}) do seen[w] = true end
        end
    end
    for w in pairs(Metrostroi.SpawnedTrains or {}) do
        if IsValid(w) and not seen[w] then
            local cars = istable(w.WagonList) and w.WagonList or { w }
            for _, c in pairs(cars) do if IsValid(c) then seen[c] = true end end
            reps[#reps + 1] = { w = w }
        end
    end
    return reps
end

function AI.UpdateRegulation(now)
    if AI.CVars.regulation:GetInt() < 2 then return end
    AI.EnsureRoute(); AI.EnsureLines()

    for _, drv in pairs(AI.Drivers) do drv.regLeaderGap, drv.regTarget = nil, nil end

    local perLine = {}
    for _, rep in ipairs(AI.ConsistReps()) do
        local tp = Metrostroi.TrainPositions and Metrostroi.TrainPositions[rep.w]
        local p = tp and tp[1]
        if p and p.path then
            local ci, cd = AI.ChainPos(math.floor(tonumber(p.path.id) or 0), p.x or 0)
            if ci then
                local st = AI.RegState[rep.w] or {}
                if st.ci == ci and st.cd then
                    local d = cd - st.cd
                    if math.abs(d) > 0.05 then st.vsign = d > 0 and 1 or -1 end
                end
                st.cd, st.ci = cd, ci; AI.RegState[rep.w] = st
                local root, lp = AI.TrainLinePos(ci, cd, st.vsign or 1)
                if root then
                    perLine[root] = perLine[root] or {}
                    table.insert(perLine[root], { lp = lp, drv = rep.drv })
                end
            end
        end
    end

    for _, items in pairs(perLine) do
        local n = #items
        if n >= 2 then
            table.sort(items, function(a, b) return a.lp < b.lp end)
            local target = 2 / n                       -- the loop coordinate spans 0..2
            for i, e in ipairs(items) do
                local leader = items[i % n + 1]
                local gap = leader.lp - e.lp; if gap <= 0 then gap = gap + 2 end
                if e.drv then e.drv.regLeaderGap, e.drv.regTarget = gap, target end
            end
        end
    end
end
