-- Metrostroi Autopilot - shared loader.
-- Make sure the client-side marker/HUD is sent to players even on dedicated
-- servers that mount this addon as a plain folder.
if SERVER then
    AddCSLuaFile("autorun/client/metrostroi_autopilot_hud.lua")
end
