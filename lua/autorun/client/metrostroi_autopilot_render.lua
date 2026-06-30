--------------------------------------------------------------------------------
-- Metrostroi Autopilot - client render optimisation for AI trains.
--------------------------------------------------------------------------------
-- A Metrostroi train's client cost is, in order: projected-texture headlights
-- (ProjectedTexture - very expensive, and Source caps how many exist, so AI trains
-- starve the player's own train of them), the deep interior ClientProps (salon
-- shell, seats, handrails, cab panel - many models, none visible from outside a
-- train you don't ride), and render-to-texture shadows. We only touch AI trains
-- (AIControlled), never the player's, so player trains keep full fidelity.
--
-- The interior cut is by WHAT the prop is, not by distance: keep the exterior, the
-- DOORS and the body panels at every distance; always drop the deep interior + cab.
--------------------------------------------------------------------------------
if not CLIENT then return end

local cv_on       = CreateClientConVar("metrostroi_ai_lite_render", "1", true, false,
    "Render AI autopilot trains cheaper (strip deep interior, drop projected headlights + shadows). 0 = full fidelity.")
local cv_interior = CreateClientConVar("metrostroi_ai_strip_interior", "1", true, false,
    "Cull AI trains' deep interior (salon/seats/handrails) at distance. Doors/body/exterior always stay; cab always hidden.")
local cv_mult     = CreateClientConVar("metrostroi_ai_interior_mult", "1.0", true, false,
    "AI interior draw distance as a MULTIPLE of Metrostroi's normal (metrostroi_renderdistance x the prop's own hide). 1 = same as player trains; lower = cull sooner for FPS.")
local C_RenderDistance = GetConVar("metrostroi_renderdistance")
local cv_nolights = CreateClientConVar("metrostroi_ai_no_projlights", "1", true, false,
    "Drop the expensive projected-texture headlights + dynamic lights on AI trains (keeps the cheap glow sprites, so they still look lit).")
local cv_noshadow = CreateClientConVar("metrostroi_ai_no_shadows", "1", true, false,
    "Disable render-to-texture shadows on AI trains.")

-- On AI trains keep exterior props (nohide), the doors, and body panels; drop the
-- deep interior + cab. Doors and body are matched by model path so the train still
-- has working doors and a complete shell.
local function aiShouldDraw(self, v)
    if not v then return false end
    if cv_on:GetInt() == 0 then return self:_aiOrigShouldDraw(v) end
    if v.nohide then return true end                                  -- exterior: masks, headlight & red-light models
    local m = v.model or ""
    if m:find("door", 1, true) or m:find("body", 1, true) then return true end   -- doors + body panels: ALWAYS
    if v.hideseat then return false end                              -- cab props (pult/ars/valves): always hidden
    if cv_interior:GetInt() == 0 then return self:_aiOrigShouldDraw(v) end
    -- deep interior (salon/seats/handrails/cabine/lamps/signs): Metrostroi's normal
    -- distance (renderdistance x the prop's hide) scaled by our multiplier
    local rd = (C_RenderDistance and C_RenderDistance:GetFloat()) or 1024
    local r  = rd * (v.hide or 1) * cv_mult:GetFloat()
    local d  = LocalPlayer():GetPos():DistToSqr(self:LocalToWorld(v.pos or vector_origin))
    return d <= r * r
end

-- Drop the projected-texture headlights + dynamic lights (expensive); keep glow
-- sprites (cheap). Also tears down any already-live one.
local function aiSetLightPower(self, index, power, brightness)
    local ld = self.Lights and self.Lights[index]
    local expensive = ld and (ld[1] == "headlight" or ld[1] == "dynamiclight")
    if expensive and cv_on:GetInt() == 1 and cv_nolights:GetInt() == 1 then
        if self.GlowingLights and IsValid(self.GlowingLights[index]) then
            self.GlowingLights[index]:Remove()
            self.GlowingLights[index] = nil
        end
        return
    end
    return self:_aiOrigSetLightPower(index, power, brightness)
end

local function applyOpt(train)
    if train._aiOptDone then return end
    train._aiOptDone = true

    train._aiOrigShouldDraw    = train.ShouldDrawClientEnt
    train.ShouldDrawClientEnt  = aiShouldDraw
    train._aiOrigSetLightPower = train.SetLightPower
    train.SetLightPower        = aiSetLightPower

    if cv_noshadow:GetInt() == 1 then train:DrawShadow(false) end

    if cv_nolights:GetInt() == 1 and istable(train.GlowingLights) then
        for i, l in pairs(train.GlowingLights) do
            local ld = train.Lights and train.Lights[i]
            if IsValid(l) and ld and (ld[1] == "headlight" or ld[1] == "dynamiclight") then
                l:Remove(); train.GlowingLights[i] = nil
            end
        end
    end
end

timer.Create("MetrostroiAI.RenderOpt", 2, 0, function()
    if cv_on:GetInt() == 0 then return end
    for _, e in ipairs(ents.GetAll()) do
        if IsValid(e) and not e._aiOptDone and e.GetNW2Bool and e:GetNW2Bool("AIControlled", false)
           and e.ShouldDrawClientEnt and e.SetLightPower then
            applyOpt(e)
        end
    end
end)
