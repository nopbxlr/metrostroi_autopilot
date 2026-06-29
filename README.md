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
- **turn back at terminals** — a proper cab change plus the crossover maneuver to
  return on the opposite track (handles plain scissors, sawtooth pull-tracks, and
  run-out-onto-a-stub throats);
- optionally **regulate traffic** so trains stay evenly spaced around the line;
- come **alive**: the head cab lights up (headlights, panel), the whole train has
  lit saloon windows, and the reverser matches the direction of travel.

A floating `[AI]` label shows above each autopilot train with its current state
and speed.

## TL;DR

- **Make a train drive itself:** spawn one with the Metrostroi *Train Spawner*, sit
  it on the track, aim at it, and type `metrostroi_ai_add` (or `!ai`). Be an admin.
- **Restart the server** after installing/updating — GMod only loads server Lua at
  startup.
- **Regulation is on by default** (`metrostroi_ai_regulation 2`, equal headway) —
  leave it; it keeps trains evenly spaced around the line.
- **Full features (cab/saloon lights, doors) only on the 81-717 / 81-714.** Other
  models still *drive*, but their lights/doors won't work without a profile.
- **These are full-physics trains** (not lightweight legacy AI) — each costs about
  as much as a real player train, so **don't spawn too many** or you'll strain the
  server and clients.
- **Tested on the *main line only*** of `gm_metro_surfacemetro_w`,
  `gm_metro_jar_imagine_line_v4`, and `gm_metro_nekrasovskaya_line_v6`.
- **Something misbehaving?** `!ai term` (also `!ai reg` / `!ai ars`) prints a
  diagnosis to console.

## Supported trains

**Full functionality is currently guaranteed only for the 81-717 / 81-714
("Nomernoy") family** — the bundled `sv_717.lua` profile, which adds the cabin
autostart, head/saloon lights, the door circuit, the reverser and safety valves on
top of the generic driving.

**Other train models will still drive** — traction is model-agnostic (it commands
the bogeys directly), so they accelerate, brake, obey signals, stop at platforms
and turn back fine — but **anything model-specific (cab & saloon lights, doors,
reverser visuals, safety valves) will not work** until a profile exists for that
model. Adding one is self-contained: copy `lua/metrostroi_autopilot/trains/sv_717.lua`
and implement the same interface for your model. Contributions welcome (see below).

## How it works (short version)

**Traction** is done *without* fighting the electrical sim: it sets
`train.IgnoreEngine = true` and commands the bogeys directly (`MotorPower` /
`BrakeCylinderPressure`) — the same mechanism the stock train spawner uses to
couple cars. The physical map rails steer the train through curves and switches.

**Speed / signals / turn-backs** come from the live rail network:
`Metrostroi.TrainPositions` / `TrainDirections`, the governing signal's
`ARSSpeedLimit` / `Occupied`, the interlocking routes on terminus signals, platform
entities, and the track spline for curvature and the end of line.

**Lights / cabin / doors** are model-specific, so they live in *train profiles*
(`lua/metrostroi_autopilot/trains/sv_*.lua`). The bundled `sv_717.lua` profile
covers the classic **81-717 / 81-714** family. The generic driver
(`sv_driver.lua`) never touches a model-specific switch — to support another model,
drop in a new profile that registers the same interface.

## Installation

A normal addon folder: `garrysmod/addons/metrostroi_autopilot/`. Requires the
**Metrostroi** addon (and its content). **Restart the map / server after
installing or updating** — GMod loads server Lua at startup and won't hot-reload it.

## Usage

You must be an admin (single-player counts).

1. Spawn a train normally with the Metrostroi **Train Spawner** tool and sit it on
   the track. (Spawning is intentionally left to the Train Spawner — this addon
   only drives existing trains.)
2. Aim at the train and run `metrostroi_ai_add` (or just `!ai` in chat).

| Command (console) | Chat | What it does |
|---|---|---|
| `metrostroi_ai_add` | `!ai` / `!ai add` | Make the train you're **looking at** drive itself. |
| `metrostroi_ai_remove [all]` | `!ai remove [all]` | Stop AI on the aimed train, or `all`. |
| `metrostroi_ai_status` | `!ai status` | List where every train (AI + manual) is. |
| `metrostroi_ai_tp <#>` | `!ai tp <#>` | Board an AI train's forward cab. |
| `metrostroi_ai_map` | `!ai map` | Open the track-network map window. |
| `metrostroi_ai_list` | `!ai list` | List the active AI trains. |
| `metrostroi_ai_help` | `!ai help` | Print help. |

Removing AI restores normal manual control (`IgnoreEngine` is cleared), so you can
hop in and drive afterwards.

### Debugging

If a train misbehaves, these chat commands print a detailed diagnosis to console:

- `!ai term` — terminus / turn-back: what it sees ahead, the plan it would commit,
  platform stop point, nearby switches and interlocking routes.
- `!ai reg` — regulation: the line's chains, how many trains are on each, spacing.
- `!ai ars` — ARS code, governing signal, and every speed limit (which one binds).
- `!ai doors` — door state / platform side.

## Regulation

`metrostroi_ai_regulation` keeps trains from bunching up. **It defaults to `2`
(equal headway)** — the recommended setting. The levels:

| Value | Behaviour |
|---|---|
| `0` | Off — trains run independently (they'll bunch). |
| `1` | **Hold at a station (doors open) until the NEXT station ahead is clear of any train.** Stops bunching/rear-ending. A good minimum. |
| `2` | **Equal headway** *(default)* — adapt each train's dwell so all trains (AI *and* manual) end up evenly spaced around the line. Best for a "living line". |

Lower it if you prefer (e.g. `1`, or `0` to disable):

```
metrostroi_ai_regulation 1
```

`metrostroi_ai_reg_maxhold` (default 150 s) caps how long a train will ever hold
for regulation, so it can never get permanently stuck.

## Tuning (console variables)

All persist (`FCVAR_ARCHIVE`) and are live-tunable.

| ConVar | Default | Meaning |
|---|---|---|
| `metrostroi_ai_enabled` | `1` | Master on/off for the control loop. |
| `metrostroi_ai_regulation` | `2` | Traffic regulation — see above. Defaults to `2` (equal headway). |
| `metrostroi_ai_reg_maxhold` | `150` | Cap (s) on a regulation hold. |
| `metrostroi_ai_cruise_speed` | `80` | Fallback speed (km/h) where the track sends **no** ARS code. Does **not** cap a coded section. |
| `metrostroi_ai_dwell` | `18` | Seconds stopped at a platform. |
| `metrostroi_ai_station_stops` | `1` | Stop & dwell at platforms (`0` = run through). |
| `metrostroi_ai_terminus_reverse` | `1` | Turn back at the end of the line. |
| `metrostroi_ai_turnback_speed` | `25` | Max speed (km/h) while threading a terminus crossover. |
| `metrostroi_ai_obey_signals` | `1` | Stop at red signals / occupied blocks. |
| `metrostroi_ai_open_routes` | `1` | Request a route (like a dispatcher) when held at a red route signal. Still collision-safe — the interlocking won't clear into an occupied block. |
| `metrostroi_ai_avoid_trains` | `1` | Brake for trains ahead even without signalling. |
| `metrostroi_ai_open_doors` | `1` | Open doors at stations (needs `powerup`). |
| `metrostroi_ai_powerup` | `1` | Run the cabin autostart on engage (lights/cab/air alive). Needs a train profile. |
| `metrostroi_ai_ars` | `0` | Power up the train's *own* ARS. `0` avoids the unmanned vigilance buzzer (limits still come from signals). |
| `metrostroi_ai_decel` | `1.1` | Planned service braking (m/s²) — higher = brakes later/harder. |
| `metrostroi_ai_station_decel` | `0.9` | Braking for the precise platform stop (m/s²) — lower = gentler/earlier. |
| `metrostroi_ai_accel` | `0.85` | Acceleration target (m/s²). |
| `metrostroi_ai_curve_lat` | `2.5` | Allowed lateral accel in curves (m/s²) — higher = faster through curves. |
| `metrostroi_ai_motorforce` | `40000` | Per-bogey traction force. |
| `metrostroi_ai_brakeforce` | `50000` | Per-bogey brake force. |
| `metrostroi_ai_rate` | `15` | Control-loop frequency (Hz). |
| `metrostroi_ai_debug` | `0` | On-screen debug overlay for AI trains. |

## Tested maps

Driving, signals, platform stops, regulation and **terminus turn-backs** have been
worked through end-to-end on the **main line** of each of:

| Map | Workshop ID |
|---|---|
| `gm_metro_surfacemetro_w` | 1676720559 |
| `gm_metro_jar_imagine_line_v4` | 1371670909 |
| `gm_metro_nekrasovskaya_line_v6` | 2091799900 |

> **Only the main running line of each map is tested.** Branches, depot/yard
> tracks, secondary lines and unusual junctions are not — the autopilot may not
> turn back or route correctly there. Other Metrostroi maps should generally work
> (it reads the live network, not hardcoded per-map data) but are unverified.

## Performance

These are **full Metrostroi trains with complete physics** — real spawned consists,
driven directly — **not** the lightweight/simplified legacy AI ("phantom") trains
Metrostroi provides itself. Each autopilot train therefore costs about as much as a
real player-driven train (physics, networking, rendering on every client), so
**running several can put significant strain on both the server and connected
clients.** Keep the number of simultaneous AI trains modest for your hardware and
keep an eye on the server tickrate / client FPS.

## Notes / limitations

- **Maps:** needs a proper Metrostroi map with physical rails and (for signal /
  ARS / turn-back obedience) a compiled track network. Without a network it still
  drives, cruises, avoids trains and reverses at the ends — it just can't read
  signals or plan crossovers.
- **Doors** are *best effort*. The pneumatic door line needs a powered air system,
  which an unpowered (`IgnoreEngine`) train doesn't have, so doors may not
  physically open. The train still stops and dwells.
- **Spawning** is not handled here — use the Metrostroi *Train Spawner*, then
  `metrostroi_ai_add`.

## Contributing

Contributions are very welcome — most useful right now:

- **Train profiles** for models other than the 81-717 (copy `trains/sv_717.lua` as
  the template and implement the same interface — that's all that's needed to give
  a model working lights/doors/cab).
- **Map & line testing** beyond the main lines listed above — branches, secondary
  lines, depots, unusual terminus throats. If something misbehaves, a `!ai term`
  (or `!ai reg` / `!ai ars`) dump at the spot is the single most useful thing to
  include.

Open an issue / PR with what you tried, the map, and the relevant console output.

## For other addon authors

```lua
hook.Add("MetrostroiAI.StationStop", "MyDoors", function(driver, platform)
    -- driver.wagons, driver.head, platform.PlatformIndex (door side) ...
end)
hook.Add("MetrostroiAI.Depart", "MyDoors", function(driver) end)

local ok, driver = MetrostroiAI.Engage(someTrainEntity)   -- programmatic
```
