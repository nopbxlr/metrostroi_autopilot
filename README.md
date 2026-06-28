# Metrostroi Autopilot — AI "fake player" trains

Drives Metrostroi subway trains around the map by themselves, so your line feels
alive even when you're the only real player. AI trains:

- accelerate, cruise and brake on their own;
- **obey ARS speed codes and signals** (stop at red / occupied blocks, slow for
  restrictive aspects);
- respect **track curves and a configurable line speed limit**;
- **stop precisely at platforms**, wait (dwell), open the doors on the platform
  side, then carry on;
- **avoid trains ahead** (so they queue instead of colliding);
- **brake for and reverse at the end of the track**, doing a proper cab change;
- come **alive**: the head cab lights up (headlights, panel), the whole train has
  lit saloon windows, and the reverser matches the direction of travel.

A floating `[AI]` label shows above each autopilot train with its current state
and speed.

## How it works (short version)

**Traction** is done *without* fighting the electrical sim: it sets
`train.IgnoreEngine = true` and commands the bogeys directly (`MotorPower` /
`BrakeCylinderPressure`) — the same mechanism the stock train spawner uses to
couple cars. The physical map rails steer the train through curves and switches.

**Speed** comes from the live rail network: `Metrostroi.TrainPositions` /
`TrainDirections`, the governing signal's `ARSSpeedLimit` / `Occupied`, platform
entities, and the track spline for curvature and the end of line.

**Lights / cabin / doors** are model‑specific, so they live in *train profiles*
(`lua/metrostroi_autopilot/trains/sv_*.lua`). The bundled `sv_717.lua` profile
covers the classic **81‑717 / 81‑714** family: it runs the verified cabin
autostart (only on the active head cab), drives the real door circuit, and keeps
the autostop from venting the brake line on an unmanned train. The generic
driver (`sv_driver.lua`) never touches a model‑specific switch — to support
another model, drop in a new profile that registers the same interface.

## Installation

This is a normal addon folder:
`garrysmod/addons/metrostroi_autopilot/`. Requires the **Metrostroi** addon
(and its content) to be installed. Restart the map / server after installing.

## Usage

You must be an admin (single‑player counts).

| Command | What it does |
|---|---|
| `metrostroi_ai_add` | Make the train you're **looking at** drive itself. |
| `metrostroi_ai_remove [all]` | Stop AI on the aimed train, or `all` of them. |
| `metrostroi_ai_status` | List where every train (AI + manual) is. |
| `metrostroi_ai_tp <#>` | Board an AI train's forward cab. |
| `metrostroi_ai_map` | Open the track-network map window. |
| `metrostroi_ai_list` | List the active AI trains. |
| `metrostroi_ai_help` | Print help. |

In chat: `!ai`, `!ai status`, `!ai tp 2`, `!ai map`, `!ai remove`, `!ai remove all`, `!ai list`.

**Quickest start:** spawn a train normally with the Metrostroi *Train Spawner*
tool, sit it on the track, aim at it and type `metrostroi_ai_add`. (Spawning is
intentionally left to the Train Spawner — this addon only drives existing trains.)

## Tuning (console variables)

| ConVar | Default | Meaning |
|---|---|---|
| `metrostroi_ai_enabled` | 1 | Master on/off for the control loop. |
| `metrostroi_ai_cruise_speed` | 80 | Fallback/ceiling speed (km/h). ARS code is the real max where present; this is used where the track sends no code, and as an absolute cap. |
| `metrostroi_ai_dwell` | 18 | Seconds stopped at a platform. |
| `metrostroi_ai_decel` | 0.7 | Planned braking deceleration (m/s²) — lower = earlier, gentler stops. |
| `metrostroi_ai_accel` | 0.85 | Acceleration target (m/s²) — affects how hard it powers up. |
| `metrostroi_ai_curve_lat` | 1.8 | Allowed lateral accel in curves (m/s²); higher = faster through curves. |
| `metrostroi_ai_motorforce` | 40000 | Per‑bogey traction force. |
| `metrostroi_ai_brakeforce` | 50000 | Per‑bogey brake force. |
| `metrostroi_ai_obey_signals` | 1 | Stop at red signals / occupied blocks. |
| `metrostroi_ai_station_stops` | 1 | Stop & dwell at platforms (0 = run through). |
| `metrostroi_ai_terminus_reverse` | 1 | Reverse and continue at the end of the track. |
| `metrostroi_ai_avoid_trains` | 1 | Brake for trains ahead even without signalling. |
| `metrostroi_ai_powerup` | 1 | Run the cabin autostart on engage (lights/cab/air alive). Needs a train profile. |
| `metrostroi_ai_open_doors` | 1 | Open doors at stations. |
| `metrostroi_ai_ars` | 0 | Power up the train's *own* ARS. 0 avoids the unmanned vigilance buzzer (speed limits still come from the signals). |
| `metrostroi_ai_rate` | 15 | Control loop frequency (Hz). |
| `metrostroi_ai_show` | 1 | (client) Show the floating `[AI]` labels. |

## Notes / limitations

- **Maps:** needs a proper Metrostroi map with physical rails and (for signal /
  ARS obedience) a compiled track network. Without a network it still drives,
  cruises, avoids trains and reverses at the ends — it just can't read signals.
- **Doors** are *best effort*. The pneumatic door line normally needs a powered
  air system, which an unpowered (IgnoreEngine) train doesn't have, so doors may
  not physically open. The train still stops and dwells. Hooks
  `MetrostroiAI.StationStop(driver, platform)` and `MetrostroiAI.Depart(driver)`
  are provided so you can wire up doors/announcements yourself.
- **Spawning** is intentionally not handled here — spawn (and couple) trains with
  the Metrostroi *Train Spawner* tool, then `metrostroi_ai_add` to drive them.
- Removing AI (`metrostroi_ai_remove`) restores normal manual control
  (`IgnoreEngine` is cleared), so you can hop in and drive afterwards.

## For other addon authors

```lua
hook.Add("MetrostroiAI.StationStop", "MyDoors", function(driver, platform)
    -- driver.wagons, driver.head, platform.PlatformIndex (door side) ...
end)
hook.Add("MetrostroiAI.Depart", "MyDoors", function(driver) end)

local ok, driver = MetrostroiAI.Engage(someTrainEntity)   -- programmatic
```
