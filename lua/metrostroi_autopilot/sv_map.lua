--------------------------------------------------------------------------------
-- Metrostroi Autopilot - track-network map networking: serve rail geometry, live
-- train positions and the stitched schematic to the client map window. Split out
-- of sv_commands.lua; loaded after sv_util.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI
local orderedDrivers, nearStation, bogeySpeed = AI.OrderedDrivers, AI.NearStation, AI.BogeySpeed

--------------------------------------------------------------------------------
-- Track-network map: serve the rail geometry (decimated XY per path) on request,
-- and the live train positions for the client map window.
--------------------------------------------------------------------------------
util.AddNetworkString("MetrostroiAI_Map")
util.AddNetworkString("MetrostroiAI_Schematic")
util.AddNetworkString("MetrostroiAI_Trains")
util.AddNetworkString("MetrostroiAI_OpenMap")

local function netPos(w)
    local tp = Metrostroi.TrainPositions and Metrostroi.TrainPositions[w]
    local p = tp and tp[1]
    if p and p.path then return math.Clamp(math.floor(tonumber(p.path.id) or 0), 0, 65535), p.x or 0 end
    return 0, 0
end

local function shortClass(w)
    return (w:GetClass():gsub("^gmod_subway_81%-", ""):gsub("^gmod_subway_", ""))
end

-- The full rich status (APPROACH/DOORS/TERMINUS/HELD AT SIGNAL/...) the driver
-- already publishes, minus the trailing "  62/80" speed/target (shown separately).
local function statusTag(lead, fallback)
    local s = lead:GetNW2String("AIStatus", "")
    s = (s:gsub("%s%s+%-?%d+/.*$", ""))
    if s == "" then return fallback or "?" end
    return s
end

local function networkPaths()
    local out, total = {}, 0
    for _, path in pairs(Metrostroi.Paths or {}) do
        if istable(path) and #path >= 2 and total < 6000 then
            local step = math.max(1, math.floor(#path / 120))   -- cap ~120 pts/path
            local pts = {}
            for i = 1, #path, step do
                local n = path[i]
                if n and isvector(n.pos) then pts[#pts + 1] = n.pos end
            end
            local last = path[#path]
            if last and isvector(last.pos) then pts[#pts + 1] = last.pos end
            if #pts >= 2 then out[#out + 1] = pts; total = total + #pts end
        end
    end
    return out
end

net.Receive("MetrostroiAI_Map", function(_, ply)
    local paths = networkPaths()
    net.Start("MetrostroiAI_Map")
    net.WriteUInt(#paths, 16)
    for _, pts in ipairs(paths) do
        net.WriteUInt(#pts, 16)
        for _, p in ipairs(pts) do net.WriteFloat(p.x) net.WriteFloat(p.y) end
    end
    net.Send(ply)
end)

net.Receive("MetrostroiAI_Trains", function(_, ply)
    local drivers = orderedDrivers()
    local aiWag, entries = {}, {}
    for i, drv in ipairs(drivers) do
        local lead = IsValid(drv.head) and drv.head or drv.lead
        if IsValid(lead) then
            for _, w in ipairs(drv.wagons or {}) do aiWag[w] = true end
            local pid, px = netPos(lead)
            local st = nearStation(lead:GetPos())
            entries[#entries + 1] = {
                p = lead:GetPos(), a = drv.travelDir or lead:GetForward(), ai = i,
                path = pid, x = px, spd = bogeySpeed(lead),
                tag = statusTag(lead, tostring(drv.state or "?")),
            }
        end
    end
    local seen = {}
    for t in pairs(Metrostroi.SpawnedTrains or {}) do
        if IsValid(t) and not seen[t] then
            local cars, n, isAI = (istable(t.WagonList) and t.WagonList or { t }), 0, false
            for _, w in pairs(cars) do if IsValid(w) then n = n + 1; seen[w] = true; if aiWag[w] then isAI = true end end end
            if not isAI then
                local pid, px = netPos(t)
                entries[#entries + 1] = {
                    p = t:GetPos(), a = t:GetForward(), ai = 0, path = pid, x = px, spd = bogeySpeed(t),
                    tag = "@" .. nearStation(t:GetPos()) .. " x" .. n,
                }
            end
        end
    end
    net.Start("MetrostroiAI_Trains")
    net.WriteUInt(#entries, 12)
    for _, e in ipairs(entries) do
        net.WriteFloat(e.p.x) net.WriteFloat(e.p.y)
        net.WriteFloat(e.a.x) net.WriteFloat(e.a.y)
        net.WriteUInt(e.ai, 8)
        net.WriteUInt(e.path, 16) net.WriteFloat(e.x)
        net.WriteInt(math.Clamp(e.spd, -300, 300), 16)
        net.WriteString(e.tag)
    end
    net.Send(ply)
end)

net.Receive("MetrostroiAI_Schematic", function(_, ply)
    local chains = AI.EnsureRoute() or {}   -- shared route stitching (sv_regulation.lua)
    local stations = {}
    for _, pf in ipairs(ents.FindByClass("gmod_track_platform")) do
        if IsValid(pf) and isvector(pf.PlatformStart) and isvector(pf.PlatformEnd) then
            local c = (pf.PlatformStart + pf.PlatformEnd) * 0.5
            local ok, res = pcall(Metrostroi.GetPositionOnTrack, c, pf:GetAngles())
            if ok and res and res[1] and res[1].path then
                stations[#stations + 1] = {
                    path = math.Clamp(math.floor(tonumber(res[1].path.id) or 0), 0, 65535),
                    x = res[1].x or 0, wx = c.x, wy = c.y, st = tostring(pf.StationIndex or "?") }
            end
        end
    end
    net.Start("MetrostroiAI_Schematic")
    net.WriteUInt(#chains, 16)
    for _, chain in ipairs(chains) do
        net.WriteUInt(#chain.segs, 16)
        for _, s in ipairs(chain.segs) do
            net.WriteUInt(s.id, 16) net.WriteFloat(s.offset) net.WriteFloat(s.len) net.WriteBool(s.flip)
        end
    end
    net.WriteUInt(#stations, 16)
    for _, s in ipairs(stations) do
        net.WriteUInt(s.path, 16) net.WriteFloat(s.x) net.WriteFloat(s.wx) net.WriteFloat(s.wy) net.WriteString(s.st)
    end
    net.Send(ply)
end)
