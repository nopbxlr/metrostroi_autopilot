--------------------------------------------------------------------------------
-- Metrostroi Autopilot - client marker / HUD
--------------------------------------------------------------------------------
-- Floats a small "AI" label with status above every autopilot train so you can
-- see your "fake players" at a glance. Toggle with metrostroi_ai_show 0/1.
--------------------------------------------------------------------------------
if not CLIENT then return end

local show = CreateClientConVar("metrostroi_ai_show", "1", true, false,
    "Show floating labels above Metrostroi Autopilot (AI) trains")

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

surface.CreateFont("MetrostroiAITag", { font = "Roboto", size = 19, weight = 700, antialias = true })
surface.CreateFont("MetrostroiAISub", { font = "Roboto", size = 15, weight = 500, antialias = true })

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
