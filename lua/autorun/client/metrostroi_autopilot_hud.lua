--------------------------------------------------------------------------------
-- Metrostroi Autopilot - client marker / HUD
--------------------------------------------------------------------------------
-- Floats a small "[AI] status" label above EVERY car of an autopilot train (the
-- status is networked on every car, so it reads the same from whichever car you
-- look at), plus a corner detail panel for the car you're riding in / nearest to
-- so you can read the full status - including the debug ARS line - from the cab.
-- Toggle with metrostroi_ai_show 0/1.
--------------------------------------------------------------------------------
if not CLIENT then return end

local show = CreateClientConVar("metrostroi_ai_show", "1", true, false,
    "Show floating labels + a detail panel for Metrostroi Autopilot (AI) trains")

local aiTrains = {}
local function refresh()
    aiTrains = {}
    for _, e in ipairs(ents.GetAll()) do
        if IsValid(e) and e.GetNW2Bool and e:GetNW2Bool("AIControlled", false) then
            aiTrains[#aiTrains + 1] = e
        end
    end
end
timer.Create("MetrostroiAI.HUDRefresh", 1, 0, refresh)
refresh()

surface.CreateFont("MetrostroiAITag",   { font = "Roboto",      size = 19, weight = 700, antialias = true })
surface.CreateFont("MetrostroiAISub",   { font = "Roboto",      size = 15, weight = 500, antialias = true })
surface.CreateFont("MetrostroiAIPanel", { font = "Roboto Mono", size = 16, weight = 500, antialias = true })

-- Floating "[AI] status" labels above every AI car.
hook.Add("HUDPaint", "MetrostroiAI.HUD", function()
    if show:GetInt() == 0 then return end
    local eye = EyePos()
    for _, e in ipairs(aiTrains) do
        if IsValid(e) then
            local pos = e:GetPos() + Vector(0, 0, 140)
            if eye:DistToSqr(pos) < (5000 * 5000) then
                local s = pos:ToScreen()
                if s.visible then
                    local status = e:GetNW2String("AIStatus", "AI")
                    draw.SimpleTextOutlined("[AI]", "MetrostroiAITag", s.x, s.y,
                        Color(120, 200, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
                    draw.SimpleTextOutlined(status, "MetrostroiAISub", s.x, s.y + 2,
                        Color(235, 235, 235), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black)
                end
            end
        end
    end
end)

-- Corner detail panel for the AI car you're riding in / standing nearest, so the
-- full status (incl. the debug ARS/limit line) is readable from inside any car.
hook.Add("HUDPaint", "MetrostroiAI.Panel", function()
    if show:GetInt() == 0 then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local origin = ply:GetPos()
    local near, nd
    for _, e in ipairs(aiTrains) do
        if IsValid(e) then
            local d = e:GetPos():DistToSqr(origin)
            if d < (1400 * 1400) and (not nd or d < nd) then nd, near = d, e end
        end
    end
    if not IsValid(near) then return end

    local status = near:GetNW2String("AIStatus", "AI")
    local cls = near:GetClass():gsub("^gmod_subway_", "")
    local title = "[AI]  " .. cls

    surface.SetFont("MetrostroiAIPanel")
    local tw = math.max((surface.GetTextSize(title)), (surface.GetTextSize(status)))
    local pad = 10
    local x, y = 18, math.floor(ScrH() * 0.42)
    local w, h = tw + pad * 2, 50
    draw.RoundedBox(6, x, y, w, h, Color(12, 18, 28, 205))
    draw.RoundedBox(6, x, y, 4, h, Color(120, 200, 255, 230))
    draw.SimpleText(title,  "MetrostroiAIPanel", x + pad, y + pad,      Color(120, 200, 255))
    draw.SimpleText(status, "MetrostroiAIPanel", x + pad, y + pad + 22, Color(235, 235, 235))
end)
