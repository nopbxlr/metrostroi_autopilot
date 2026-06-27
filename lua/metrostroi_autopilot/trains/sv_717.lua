--------------------------------------------------------------------------------
-- Metrostroi Autopilot - train profile: 81-717 / 81-714 ("numbered") family
--------------------------------------------------------------------------------
-- All of the model-specific cabin/light/door/safety logic for the classic
-- 81-717 head car and 81-714 trailer. The cab autostart mirrors Metrostroi
-- Advanced's verified "TrainStart" sequence; doors drive the real 717 door
-- circuit (DoorSelect + KDL/KDP); the safety handling keeps the autostop from
-- venting the brake line on an unmanned train.
--
-- The generic driver (sv_driver.lua) calls these via self.profile.* and never
-- needs to know any of these switch names. To add another model, drop a new
-- trains/sv_*.lua that AI.RegisterProfile{}s the same interface.
--------------------------------------------------------------------------------
if not SERVER then return end
local AI = MetrostroiAI
local S = AI.SysSet   -- guarded TriggerInput(w, name, input, val)

local PROFILE = { name = "81-717 / 81-714 family" }

-- Match the classic numbered family, but NOT the newer cabs (different startup).
function PROFILE.Match(class)
    if class:find("717.9", 1, true) or class:find("7175p", 1, true) then return false end
    return (class:find("717", 1, true) or class:find("714", 1, true)) ~= nil
end

--------------------------------------------------------------------------------
-- Lights / cabin
--------------------------------------------------------------------------------
-- Electrics, saloon lights AND door-circuit power - on EVERY car. A 717/714
-- consist needs each car's electrics up or that car's doors won't open. (This is
-- what broke when only the head cab was being powered.) NOTE: deliberately does
-- NOT touch headlights (L_4), the driver brake valve or the disconnect valves -
-- those stay cab-only so we don't relight both ends or bleed the air line.
function PROFILE.PowerCar(w)
    if not IsValid(w) then return end
    timer.Simple(0.5, function()
        for _, s in ipairs({ "VMK", "V1", "KU1", "VUS" }) do S(w, s, "Set", 1) end
    end)
    timer.Simple(1.0, function()
        for _, s in ipairs({ "V2", "L_1", "L_3", "R_UNch", "R_ZS", "R_G", "R_Radio",
                             "PLights", "VU14", "KU16", "KU2" }) do S(w, s, "Set", 1) end
    end)
end

-- Full active-cab autostart - HEAD CAB ONLY. Activating both cabs lit two sets
-- of headlights and put two driver brake valves on one line (which bled air).
function PROFILE.ActivateCab(w)
    if not IsValid(w) then return end
    w.KVWrenchMode = 1
    pcall(function()
        if w.KV then w.KV:TriggerInput("Enabled", 1); w.KV:TriggerInput("ReverserSet", 1) end
    end)
    pcall(function()
        if w.Pneumatic and w.Pneumatic.DriverValvePosition ~= 2 then
            w.Pneumatic:TriggerInput("BrakeSet", 2)   -- charge the brake/air line
        end
    end)
    for _, s in ipairs({ "ALS", "ARS", "EPK", "EPV" }) do S(w, s, "Set", 0) end
    -- ARS off -> switch УАВА on so the trackside autostop doesn't trip & vent air.
    if AI.CVars.ars_onboard:GetInt() ~= 1 then S(w, "UAVA", "Set", 1) end

    timer.Simple(1.0, function()
        S(w, "L_4", "Set", 1)        -- headlights (leading/active end only)
        S(w, "GLights", "Set", 1)    -- marker lights
    end)
    timer.Simple(2.0, function()
        if AI.CVars.ars_onboard:GetInt() == 1 then
            for _, s in ipairs({ "ALS", "ARS", "EPK", "EPV" }) do S(w, s, "Set", 1) end
            S(w, "UOS", "Set", 1)
        end
    end)
    timer.Simple(3.0, function()
        for _, s in ipairs({ "DriverValveDisconnect", "DriverValveBLDisconnect",
                             "DriverValveTLDisconnect" }) do S(w, s, "Set", 1) end
        S(w, "ALSFreq", "Set", 0)
    end)
    timer.Simple(5.0, function()
        S(w, "KB", "Toggle", 1); S(w, "KVT", "Toggle", 1)
        timer.Simple(4.0, function() S(w, "KB", "Toggle", 1); S(w, "KVT", "Toggle", 1) end)
    end)
end

-- Shut a cab down (non-head car, or the old head after reversing): headlights
-- off, reverser neutral, and isolate the driver brake valve so it can't fight
-- the active cab on the shared brake line.
function PROFILE.DeactivateCab(w)
    if not IsValid(w) then return end
    S(w, "L_4", "Set", 0)
    S(w, "GLights", "Set", 0)
    pcall(function() if w.KV then w.KV:TriggerInput("ReverserSet", 0) end end)
    for _, s in ipairs({ "DriverValveDisconnect", "DriverValveBLDisconnect",
                         "DriverValveTLDisconnect" }) do S(w, s, "Set", 0) end
end

-- Set the active cab's reverser to match travel (1 forward / -1 reverse / 0 neutral).
function PROFILE.Reverser(w, dir)
    if not (IsValid(w) and w.KV) then return end
    w.KVWrenchMode = 1
    pcall(function()
        w.KV:TriggerInput("Enabled", 1)
        w.KV:TriggerInput("ReverserSet", dir)   -- needs ControllerPosition == 0 (it is)
    end)
    if AI.CVars.ars_onboard:GetInt() == 1 then S(w, "UOS", "Set", 1) end
end

--------------------------------------------------------------------------------
-- Doors (real 717 circuit). side = "left" | "right".
--   DoorSelect 0=left/1=right + the side's contactor KDL/KDP -> wire 31/32 ->
--   valve VDOL/VDOP -> doors open. VUD1 drives VDZ = close.
--------------------------------------------------------------------------------
function PROFILE.OpenDoor(w, side)
    if not IsValid(w) then return end
    S(w, "VUD1", "Set", 0)                          -- release the close button
    S(w, "DoorSelect", "Set", (side == "right") and 1 or 0)
    if side == "right" then
        S(w, "KDP", "Set", 1); S(w, "KDL", "Set", 0); S(w, "VDL", "Set", 0)
    else
        S(w, "KDL", "Set", 1); S(w, "VDL", "Set", 1); S(w, "KDP", "Set", 0)
    end
end

function PROFILE.CloseDoor(w)
    if not IsValid(w) then return end
    S(w, "KDL", "Set", 0); S(w, "KDP", "Set", 0); S(w, "VDL", "Set", 0)
    S(w, "VUD1", "Set", 1)                          -- VUD1*VUD2 -> wire 16 -> VDZ = close
    timer.Simple(1.5, function() S(w, "VUD1", "Set", 0) end)
end

--------------------------------------------------------------------------------
-- Safety: keep the autostop from bleeding the brake line on an unmanned train
--------------------------------------------------------------------------------
-- Per tick: hard-clear the emergency valves. Once the autostop trips, the
-- pneumatic vents the whole brake line faster than it can recharge (and the
-- УАВА switch is pressure-interlocked), so it never recovers on its own.
function PROFILE.SuppressVent(w)
    if not IsValid(w) then return end
    local p = w.Pneumatic
    if p then
        p.EmergencyValve = false
        p.EmergencyValveEPK = false
        p.EmergencyValveDisable = false
    end
    if w.EmergencyBrakeValve and (w.EmergencyBrakeValve.Value or 0) > 0 then
        pcall(w.EmergencyBrakeValve.TriggerInput, w.EmergencyBrakeValve, "Set", 0)
    end
end

-- Periodic: re-assert the УАВА (autostop cut-out) so it can't silently re-arm.
function PROFILE.MaintainSafety(w)
    if AI.CVars.ars_onboard:GetInt() == 1 then return end
    if IsValid(w) and w.UAVA and (w.UAVA.Value or 0) == 0 then
        pcall(w.UAVA.TriggerInput, w.UAVA, "Set", 1)
    end
end

AI.RegisterProfile(PROFILE)
