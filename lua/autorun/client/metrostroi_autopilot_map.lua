--------------------------------------------------------------------------------
-- Metrostroi Autopilot - track-network map window
--------------------------------------------------------------------------------
-- Two views (toggle button):
--   * Schematic - the network UNROLLED. Path segments are stitched into continuous
--     routes (following connectivity, keeping the straight line through junctions),
--     so each running track is one long horizontal lane and crossovers/sidings are
--     their own short lanes. Stations & trains sit at their distance along the lane.
--     Ignores real geometry, so a map folded into stacked loops reads flat.
--   * Geographic - literal top-down XY.
-- Drag = pan, wheel = zoom. Each train carries a small info card. Click an AI
-- train to board it. Open: console metrostroi_ai_map, or "!ai map".
--------------------------------------------------------------------------------
if not CLIENT then return end

local geo, geoBounds = {}, nil
local sch = { pathLookup = {}, chainLen = {}, stations = {} }   -- pathLookup[id]={ci,offset,len,flip}
local trains = {}
local frame

surface.CreateFont("MetroMap",  { font = "Roboto", size = 15, weight = 600, antialias = true })
surface.CreateFont("MetroMapS", { font = "Roboto", size = 12, weight = 500, antialias = true })

local function recomputeGeoBounds()
    local a, b, c, d
    local function acc(x, y)
        a = math.min(a or x, x); c = math.max(c or x, x)
        b = math.min(b or y, y); d = math.max(d or y, y)
    end
    for _, pts in ipairs(geo) do for _, p in ipairs(pts) do acc(p[1], p[2]) end end
    for _, s in ipairs(sch.stations) do acc(s.wx, s.wy) end
    geoBounds = a and { a, b, c, d } or nil
end

net.Receive("MetrostroiAI_Map", function()
    geo = {}
    for i = 1, net.ReadUInt(16) do
        local n, pts = net.ReadUInt(16), {}
        for j = 1, n do pts[j] = { net.ReadFloat(), net.ReadFloat() } end
        geo[i] = pts
    end
    recomputeGeoBounds()
end)

net.Receive("MetrostroiAI_Schematic", function()
    sch = { pathLookup = {}, chainLen = {}, stations = {} }
    for ci = 1, net.ReadUInt(16) do
        local maxEnd = 0
        for s = 1, net.ReadUInt(16) do
            local id, offset, len, flip = net.ReadUInt(16), net.ReadFloat(), net.ReadFloat(), net.ReadBool()
            sch.pathLookup[id] = { ci = ci, offset = offset, len = len, flip = flip }
            maxEnd = math.max(maxEnd, offset + len)
        end
        sch.chainLen[ci] = maxEnd
    end
    for i = 1, net.ReadUInt(16) do
        sch.stations[#sch.stations + 1] = { path = net.ReadUInt(16), x = net.ReadFloat(),
            wx = net.ReadFloat(), wy = net.ReadFloat(), st = net.ReadString() }
    end
    recomputeGeoBounds()
end)

net.Receive("MetrostroiAI_Trains", function()
    trains = {}
    for i = 1, net.ReadUInt(12) do
        trains[i] = { wx = net.ReadFloat(), wy = net.ReadFloat(), hx = net.ReadFloat(), hy = net.ReadFloat(),
            ai = net.ReadUInt(8), path = net.ReadUInt(16), x = net.ReadFloat(),
            spd = net.ReadInt(16), tag = net.ReadString() }
    end
end)

local AICOL, MANCOL = Color(90, 180, 255), Color(255, 170, 70)

-- (path, local x) -> (chain index, distance along chain)
local function chainPos(path, x)
    local lk = sch.pathLookup[path]
    if not lk then return nil end
    return lk.ci, lk.offset + (lk.flip and (lk.len - x) or x)
end

local function openMap()
    if IsValid(frame) then frame:MakePopup() return end
    net.Start("MetrostroiAI_Map") net.SendToServer()
    net.Start("MetrostroiAI_Schematic") net.SendToServer()

    frame = vgui.Create("DFrame")
    frame:SetSize(math.min(1280, ScrW() - 60), math.min(820, ScrH() - 60))
    frame:Center()
    frame:SetTitle("Metrostroi AI  -  Track Map")
    frame:SetSizable(true)
    frame:SetMinWidth(600) frame:SetMinHeight(400)
    frame:MakePopup()

    local mode = "schematic"
    local zoom, panx, pany = 1, 0, 0
    local dragging, resizing, lmx, lmy

    local top = vgui.Create("DPanel", frame); top:Dock(TOP); top:SetTall(30); top.Paint = function() end
    local btn = vgui.Create("DButton", top); btn:Dock(LEFT); btn:SetWide(200)
    btn:SetText("View: Schematic  (click to flip)")
    btn.DoClick = function()
        mode = (mode == "schematic") and "geographic" or "schematic"
        zoom, panx, pany = 1, 0, 0
        btn:SetText("View: " .. (mode == "schematic" and "Schematic" or "Geographic") .. "  (click to flip)")
    end
    local reset = vgui.Create("DButton", top); reset:Dock(LEFT); reset:SetWide(90)
    reset:SetText("Reset view"); reset.DoClick = function() zoom, panx, pany = 1, 0, 0 end

    local canvas = vgui.Create("DPanel", frame); canvas:Dock(FILL)

    local function paintSchematic(w, h)
        if not next(sch.chainLen) then
            draw.SimpleText("loading schematic...", "MetroMap", w / 2, h / 2,
                Color(170, 170, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return
        end
        -- per-chain station lists + which chains carry a train
        local cs, hasTrain = {}, {}
        for _, s in ipairs(sch.stations) do
            local ci, d = chainPos(s.path, s.x)
            if ci then cs[ci] = cs[ci] or {}; cs[ci][#cs[ci] + 1] = { num = tonumber(s.st) or 0, d = d, st = s.st } end
        end
        for _, t in ipairs(trains) do local ci = chainPos(t.path, t.x); if ci then hasTrain[ci] = true end end
        -- flip a chain when its station numbers run high->low, so the opposite-
        -- direction track aligns with its pair (both read low->high left to right)
        local flip = {}
        for ci, sts in pairs(cs) do
            if #sts >= 2 then
                local lo, hi = sts[1], sts[1]
                for _, s in ipairs(sts) do if s.d < lo.d then lo = s end if s.d > hi.d then hi = s end end
                if lo.num > hi.num then flip[ci] = true end
            end
        end
        local function adist(ci, d) return flip[ci] and (sch.chainLen[ci] - d) or d end
        -- lanes that actually have a station or a train (drop empty connector stubs)
        local order = {}
        for ci, len in pairs(sch.chainLen) do
            if cs[ci] or hasTrain[ci] then order[#order + 1] = { ci = ci, len = len } end
        end
        if #order == 0 then
            draw.SimpleText("no stations or trains on the network", "MetroMap", w / 2, h / 2,
                Color(170, 170, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return
        end
        table.sort(order, function(p, q) return p.len > q.len end)
        local maxLen = 1
        for _, o in ipairs(order) do maxLen = math.max(maxLen, o.len) end
        local x0, spacing = 50, math.max(22, 36 * zoom)
        local xscale = (math.max(120, w - x0 - 40) / maxLen) * zoom
        local laneY = {}
        for i, o in ipairs(order) do laneY[o.ci] = 44 + pany + (i - 1) * spacing end
        local function sx(d) return x0 + panx + d * xscale end

        surface.SetFont("MetroMapS")
        for i, o in ipairs(order) do
            local y = laneY[o.ci]
            if y > 16 and y < h - 6 then
                surface.SetDrawColor(58, 78, 108) surface.DrawLine(sx(0), y, sx(o.len), y)
                draw.SimpleText(tostring(i), "MetroMapS", sx(0) - 8, y, Color(140, 150, 170),
                    TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
            end
        end
        for ci, sts in pairs(cs) do
            local y = laneY[ci]
            if y and y > 16 and y < h - 6 then
                for _, s in ipairs(sts) do
                    local x = sx(adist(ci, s.d))
                    surface.SetDrawColor(205, 205, 215) surface.DrawLine(x, y - 6, x, y + 6)
                    draw.SimpleText(s.st, "MetroMapS", x, y - 8, Color(215, 215, 225),
                        TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
                end
            end
        end
        for _, t in ipairs(trains) do
            t._sx, t._sy = nil, nil
            local ci, d = chainPos(t.path, t.x)
            local y = ci and laneY[ci]
            if y and y > 16 and y < h - 6 then
                t._sx, t._sy = sx(adist(ci, d)), y
                draw.RoundedBox(0, t._sx - 4, t._sy - 4, 8, 8, t.ai > 0 and AICOL or MANCOL)
            end
        end
    end

    local function paintGeographic(w, h)
        if not geoBounds then
            draw.SimpleText("loading network...", "MetroMap", w / 2, h / 2,
                Color(170, 170, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return
        end
        local bw = math.max(1, geoBounds[3] - geoBounds[1])
        local bh = math.max(1, geoBounds[4] - geoBounds[2])
        local fit = math.min((w - 40) / bw, (h - 40) / bh) * zoom
        local cx, cy = (geoBounds[1] + geoBounds[3]) / 2, (geoBounds[2] + geoBounds[4]) / 2
        local function w2s(wx, wy) return w / 2 + panx + (wx - cx) * fit, h / 2 + pany - (wy - cy) * fit end

        surface.SetDrawColor(58, 78, 108)
        for _, pts in ipairs(geo) do
            for i = 1, #pts - 1 do
                local x1, y1 = w2s(pts[i][1], pts[i][2])
                local x2, y2 = w2s(pts[i + 1][1], pts[i + 1][2])
                surface.DrawLine(x1, y1, x2, y2)
            end
        end
        surface.SetFont("MetroMapS")
        for _, s in ipairs(sch.stations) do
            local x, y = w2s(s.wx, s.wy)
            surface.SetDrawColor(205, 205, 215) surface.DrawRect(x - 2, y - 2, 4, 4)
            draw.SimpleText(s.st, "MetroMapS", x + 4, y - 6, Color(200, 200, 210), TEXT_ALIGN_LEFT)
        end
        local pp = LocalPlayer():GetPos()
        local gx, gy = w2s(pp.x, pp.y)
        draw.RoundedBox(0, gx - 3, gy - 3, 6, 6, Color(90, 255, 130))
        for _, t in ipairs(trains) do
            local x, y = w2s(t.wx, t.wy)
            t._sx, t._sy = x, y
            local col = t.ai > 0 and AICOL or MANCOL
            local hn = math.sqrt(t.hx * t.hx + t.hy * t.hy)
            if hn > 0.01 then
                surface.SetDrawColor(col.r, col.g, col.b)
                surface.DrawLine(x, y, x + (t.hx / hn) * 11, y - (t.hy / hn) * 11)
            end
            draw.RoundedBox(0, x - 4, y - 4, 8, 8, col)
        end
    end

    -- small info card that rides with each train
    local function drawCard(t)
        local col = t.ai > 0 and AICOL or MANCOL
        local title = t.ai > 0 and ("#" .. t.ai) or "M"
        local txt = title .. "  " .. t.spd .. " km/h"
        surface.SetFont("MetroMapS")
        local w1 = surface.GetTextSize(txt)
        local w2 = surface.GetTextSize(t.tag)
        local cw = math.max(w1, w2) + 10
        local cx, cy = t._sx + 8, t._sy - 30
        draw.RoundedBox(3, cx, cy, cw, 30, Color(10, 14, 22, 225))
        draw.RoundedBox(3, cx, cy, 3, 30, col)
        draw.SimpleText(txt,   "MetroMapS", cx + 6, cy + 3,  col, TEXT_ALIGN_LEFT)
        draw.SimpleText(t.tag, "MetroMapS", cx + 6, cy + 16, Color(210, 210, 220), TEXT_ALIGN_LEFT)
    end

    canvas.Paint = function(self, w, h)
        surface.SetDrawColor(16, 20, 28) surface.DrawRect(0, 0, w, h)
        if mode == "schematic" then paintSchematic(w, h) else paintGeographic(w, h) end
        for _, t in ipairs(trains) do if t._sx then drawCard(t) end end
        draw.SimpleText(#trains .. " trains   (blue=AI, orange=manual; click AI to board)",
            "MetroMapS", 10, h - 16, Color(170, 170, 180), TEXT_ALIGN_LEFT)
    end

    canvas.OnCursorMoved = function(self, mx, my)
        local w, h = self:GetSize()
        if mx > w - 16 and my > h - 16 then self:SetCursor("sizenwse")
        elseif mx > w - 16 then self:SetCursor("sizewe")
        elseif my > h - 16 then self:SetCursor("sizens")
        else self:SetCursor("arrow") end
    end
    canvas.OnMousePressed = function(self, key)
        if key ~= MOUSE_LEFT then return end
        local mx, my = self:CursorPos()
        local w, h = self:GetSize()
        if mx > w - 16 or my > h - 16 then            -- grab an edge -> resize the frame
            resizing = { fw = frame:GetWide(), fh = frame:GetTall(), gx = gui.MouseX(), gy = gui.MouseY(),
                         ew = mx > w - 16, eh = my > h - 16 }
            return
        end
        for _, t in ipairs(trains) do
            if t.ai > 0 and t._sx and math.abs(mx - t._sx) < 9 and math.abs(my - t._sy) < 9 then
                RunConsoleCommand("metrostroi_ai_tp", tostring(t.ai))
                if IsValid(frame) then frame:Close() end
                return
            end
        end
        dragging, lmx, lmy = true, mx, my
    end
    canvas.OnMouseReleased = function() dragging, resizing = false, nil end
    canvas.Think = function(self)
        if resizing then
            frame:SetSize(
                resizing.ew and math.max(600, resizing.fw + (gui.MouseX() - resizing.gx)) or frame:GetWide(),
                resizing.eh and math.max(400, resizing.fh + (gui.MouseY() - resizing.gy)) or frame:GetTall())
        elseif dragging then
            local mx, my = self:CursorPos()
            panx, pany = panx + (mx - lmx), pany + (my - lmy)
            lmx, lmy = mx, my
        end
    end
    canvas.OnMouseWheeled = function(self, d)
        zoom = math.Clamp(zoom * (d > 0 and 1.15 or 0.87), 0.2, 60)
        return true
    end

    timer.Create("MetrostroiAI_MapPoll", 0.5, 0, function()
        if not IsValid(frame) then timer.Remove("MetrostroiAI_MapPoll") return end
        net.Start("MetrostroiAI_Trains") net.SendToServer()
    end)
    net.Start("MetrostroiAI_Trains") net.SendToServer()
    frame.OnClose = function() timer.Remove("MetrostroiAI_MapPoll") end
end

concommand.Add("metrostroi_ai_map", openMap)
net.Receive("MetrostroiAI_OpenMap", openMap)
