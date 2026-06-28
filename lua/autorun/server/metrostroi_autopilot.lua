--------------------------------------------------------------------------------
-- Metrostroi Autopilot  -  AI "fake player" train driver for Garry's Mod
--------------------------------------------------------------------------------
-- Spawns / converts Metrostroi subway trains into autonomous AI-driven trains
-- that drive themselves around the line: obeying ARS speed codes and signals,
-- respecting track speed limits and curves, stopping at platforms with a dwell,
-- avoiding trains ahead, and reversing at terminals.
--
-- Driving is done WITHOUT the (very fragile, per-model) electrical/pneumatic
-- startup: we set train.IgnoreEngine = true and command the bogeys directly
-- (MotorPower / BrakeCylinderPressure), exactly like the game's own train
-- spawner auto-coupler. The physical map rails steer the train through curves
-- and switches, so this works on any proper Metrostroi map and any train model.
--------------------------------------------------------------------------------
if not SERVER then return end

MetrostroiAI = MetrostroiAI or {}
local AI = MetrostroiAI

AI.Drivers   = AI.Drivers   or {}   -- [leadWagon] = driver object
AI.Version   = "1.0.0"
AI.Loaded    = false

--------------------------------------------------------------------------------
-- Configuration (all live-tunable via console; FCVAR_ARCHIVE persists them)
--------------------------------------------------------------------------------
AI.CVars = {
    enabled         = CreateConVar("metrostroi_ai_enabled",        "1", FCVAR_ARCHIVE, "Master enable for the Metrostroi Autopilot control loop"),
    cruise          = CreateConVar("metrostroi_ai_cruise_speed",  "80", FCVAR_ARCHIVE, "Fallback speed in km/h for track that sends NO ARS code. Where the track does send an ARS code, that code is the max and this value is ignored (it does NOT cap ARS)."),
    dwell           = CreateConVar("metrostroi_ai_dwell",         "18", FCVAR_ARCHIVE, "How long (seconds) an AI train waits at a platform"),
    motorforce      = CreateConVar("metrostroi_ai_motorforce", "40000", FCVAR_ARCHIVE, "Per-bogey traction force"),
    brakeforce      = CreateConVar("metrostroi_ai_brakeforce", "50000", FCVAR_ARCHIVE, "Per-bogey pneumatic brake force"),
    accel           = CreateConVar("metrostroi_ai_accel",       "0.85", FCVAR_ARCHIVE, "Target acceleration m/s^2 (drives the power law)"),
    decel           = CreateConVar("metrostroi_ai_decel",        "1.1", FCVAR_ARCHIVE, "Planned service deceleration m/s^2. Higher = brakes later/harder, so the train reaches line speed between closely-spaced stations instead of crawling toward the next one. (0.7 braked ~350 m out from 80 km/h.)"),
    station_decel   = CreateConVar("metrostroi_ai_station_decel", "0.9", FCVAR_ARCHIVE, "Comfortable deceleration m/s^2 for the precise platform stop (distance-based braking). Lower = gentler/earlier braking into the platform; higher = brakes later/firmer."),
    curve_lat       = CreateConVar("metrostroi_ai_curve_lat",    "2.5", FCVAR_ARCHIVE, "Allowed lateral acceleration in curves m/s^2 (higher = faster through curves)"),
    ars_onboard     = CreateConVar("metrostroi_ai_ars",           "0", FCVAR_ARCHIVE, "Power up the train's own ARS at autostart. 0 avoids the unmanned vigilance buzzer (speed limits still come from the signals)."),
    station_stops   = CreateConVar("metrostroi_ai_station_stops",  "1", FCVAR_ARCHIVE, "1 = stop & dwell at platforms, 0 = run through"),
    terminus_rev    = CreateConVar("metrostroi_ai_terminus_reverse","1",FCVAR_ARCHIVE, "1 = reverse and continue at end of track, 0 = just hold"),
    powerup         = CreateConVar("metrostroi_ai_powerup",        "1", FCVAR_ARCHIVE, "Run the cabin autostart on engage (lights/cabin/ARS/air alive). 81-717/714 family."),
    open_doors      = CreateConVar("metrostroi_ai_open_doors",     "1", FCVAR_ARCHIVE, "Open doors at stations (needs powerup so the air/door circuit is live)"),
    obey_signals    = CreateConVar("metrostroi_ai_obey_signals",   "1", FCVAR_ARCHIVE, "1 = stop at red signals / occupied blocks"),
    open_routes     = CreateConVar("metrostroi_ai_open_routes",     "1", FCVAR_ARCHIVE, "When held at a red ROUTE signal (e.g. a terminus departure), request its route like a dispatcher. The interlocking still won't clear it into an occupied block, so it's collision-safe."),
    avoid_trains    = CreateConVar("metrostroi_ai_avoid_trains",   "1", FCVAR_ARCHIVE, "1 = brake for trains ahead even without signalling"),
    regulation      = CreateConVar("metrostroi_ai_regulation",     "0", FCVAR_ARCHIVE, "Auto traffic regulation: 0 = off; 1 = hold at a station (doors open) until the NEXT station is clear of any train; 2 = adapt dwell so every train on the map (AI + manual) ends up equally spaced (equal headway)."),
    reg_maxhold     = CreateConVar("metrostroi_ai_reg_maxhold",  "150", FCVAR_ARCHIVE, "Cap (seconds) on how long an AI train will hold at a platform for regulation, so it can never get stuck."),
    rate            = CreateConVar("metrostroi_ai_rate",          "15", FCVAR_ARCHIVE, "Control loop frequency in Hz"),
    debug           = CreateConVar("metrostroi_ai_debug",          "0", FCVAR_ARCHIVE, "Show on-screen debug info for AI trains"),
}

--------------------------------------------------------------------------------
-- Physical constants derived from the Metrostroi source
--------------------------------------------------------------------------------
AI.U_PER_M    = 52.49          -- source units per metre (1/0.01905)
AI.HALF_CAR   = 480            -- units from a wagon centre to its coupler/nose
AI.HOLD_BRAKE = 2.6            -- atm, parking/holding brake pressure
AI.SERVICE_BRAKE_MAX = 4.2     -- atm, max service brake the AI will command
-- ARS transmitted code -> permitted speed (km/h). 0 = stop, nil = no restriction.
AI.ARS_SPEED  = { [0] = 0, [2] = 20, [4] = 40, [6] = 60, [7] = 70, [8] = 80 }

function AI.Msg(...)
    MsgC(Color(90, 170, 255), "[Metrostroi AI] ", color_white, ...)
    Msg("\n")
end

--------------------------------------------------------------------------------
-- Train profiles: all model-specific behaviour (cab autostart, lights, doors,
-- safety valves, reverser) lives in a profile so the driver stays generic.
--------------------------------------------------------------------------------
AI.Profiles = {}
function AI.RegisterProfile(p) AI.Profiles[#AI.Profiles + 1] = p end

-- Pick the profile for a wagon's class, or nil if the model isn't supported
-- (the train still drives via the bogeys, it just won't light up / open doors).
function AI.MatchProfile(wagon)
    if not IsValid(wagon) then return nil end
    local class = wagon:GetClass()
    for _, p in ipairs(AI.Profiles) do
        if p.Match and p.Match(class) then return p end
    end
    return nil
end

-- Guarded TriggerInput on a wagon sub-system (relay/switch) by name.
function AI.SysSet(w, name, input, val)
    if IsValid(w) and w[name] then pcall(w[name].TriggerInput, w[name], input, val) end
end

--------------------------------------------------------------------------------
-- Load the modules (server-side only). Order matters.
--------------------------------------------------------------------------------
include("metrostroi_autopilot/sv_driver.lua")
include("metrostroi_autopilot/sv_lookahead.lua")   -- DRIVER methods: ARS, signals, curves, trains ahead
include("metrostroi_autopilot/sv_stations.lua")    -- DRIVER methods: platforms, terminus, doors
include("metrostroi_autopilot/sv_regulation.lua")
include("metrostroi_autopilot/sv_commands.lua")

-- Train profiles (one per supported model/family)
include("metrostroi_autopilot/trains/sv_717.lua")

--------------------------------------------------------------------------------
-- Readiness: wait until Metrostroi's rail network API exists before we run.
--------------------------------------------------------------------------------
local function MetrostroiReady()
    return istable(Metrostroi)
       and isfunction(Metrostroi.GetARSJoint)
       and istable(Metrostroi.TrainPositions)
end

local function StartUp()
    if AI.Loaded then return end
    AI.Loaded = true
    AI.Msg("v" .. AI.Version .. " ready. Aim at a train and type ", "metrostroi_ai_add",
           " (or in chat: !ai). See ", "metrostroi_ai_help", ".")
end

timer.Create("MetrostroiAI.WaitForMetrostroi", 1, 0, function()
    if MetrostroiReady() then
        timer.Remove("MetrostroiAI.WaitForMetrostroi")
        StartUp()
    end
end)

--------------------------------------------------------------------------------
-- Master control loop: one throttled hook drives every AI train.
--------------------------------------------------------------------------------
local nextThink, nextReg = 0, 0
hook.Add("Think", "MetrostroiAI.Loop", function()
    if not AI.Loaded then return end
    if AI.CVars.enabled:GetInt() == 0 then return end

    local now = CurTime()
    if AI.UpdateRegulation and now >= nextReg then
        nextReg = now + 1.5
        pcall(AI.UpdateRegulation, now)
    end
    if now < nextThink then return end
    local hz = math.Clamp(AI.CVars.rate:GetInt(), 5, 66)
    nextThink = now + 1 / hz

    for lead, drv in pairs(AI.Drivers) do
        if not IsValid(lead) then
            AI.Drivers[lead] = nil
        else
            local ok, err = pcall(drv.Think, drv, now)
            if not ok then
                AI.Msg("driver error: ", tostring(err))
                drv:ApplyDrive(0, AI.HOLD_BRAKE)  -- fail safe: stop
            end
        end
    end
end)

-- Clean up drivers whose trains are removed.
hook.Add("EntityRemoved", "MetrostroiAI.Cleanup", function(ent)
    local drv = AI.Drivers[ent]
    if drv then drv:Disengage() end
    -- also drop drivers that lost their lead wagon to this removal
    for lead, d in pairs(AI.Drivers) do
        if d.wagons then
            for _, w in ipairs(d.wagons) do
                if w == ent then d:RefreshWagons() break end
            end
        end
    end
end)
