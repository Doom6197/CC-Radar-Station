# Integration ideas — FTB Skies 2: Aero

Where Radar Station could go next, given what is actually in the pack.

Since v7 the station is the right shape for all of this. **A page is one file
in `radar/modules/`** that declares its settings, claims its own hardware, runs
its own loops and builds its own settings section — see *Modules* in the README
for the descriptor. Hardware discovery matches on *capability* rather than on
peripheral type, alerts and the redstone output take providers from any module,
and the sub-pixel drawing surface and chart library are generic already.

So most of what follows is **one new file**. Nothing on this list needs the core
touched.

**A note on confidence.** Everything marked ✅ uses an API I am sure exists.
Items marked ❓ depend on a peripheral method I have not verified against this
pack's exact mod versions — check them in game with `lua` and
`peripheral.wrap(...)` before building on them.

---

## Shipped

### ⚡ Power — Energy Detector ✅ + any wrappable battery ✅

**Done in v7.** `radar/modules/power.lua` plus `radar/power.lua` and
`radar/chart.lua`: input, output and net, a buffer gauge, a rolling line chart,
a low-power alarm on the shared alert channels, and a `Buffer` redstone mode
mapping 1–15 to how full the bank is.

Worth knowing for anything similar: batteries are matched on **method name**
(`getEnergy` / `getMaxEnergy` / `getEnergyStored` / …), never on peripheral
type, so Flux Networks, Powah and the Mekanism induction matrix are all covered
without naming a single mod in code that has to run on a pack that may not have
them installed. Do the same for whatever comes next.

---

## The one to build next

### ✈️ Fleet tracking — Create: Aeronautics ❓

This is the pack's whole identity, and the station is 90% of the way there.

You start on an airship over the void and you spend the pack flying. A radar
that only knows where *players* are is missing the thing you actually want to
see: where your ships are, which one is drifting, which one is over the ore
island.

Contraptions are not peripherals and cannot be scanned from outside, so the
trick is to make each ship report itself:

- put a computer with a **wireless (or ender) modem** on each contraption
- give it a `gps.locate()` fix and `rednet.broadcast` its position, heading and
  a name on a fixed protocol, once a second
- the station listens on that protocol and plots them as a second class of
  contact — a different blip shape, its own colour band, its own tally

Everything downstream already works: `radar/modules/radar.lua` plots anything
with `dx/dz/dist/bearing`, the contacts table just gets more rows, and
`alerts:fire()` can warn you when a ship strays outside a set radius of home.

**Needs:** a GPS constellation (4 computers with wireless modems at known
coordinates). On a skyblock that is a small build, and it unlocks waypoints
below as well.

---

## High value, low effort

### 📦 Storage page — ME Bridge (AE2) / RS Bridge (Refined Storage) ✅

Both bridges are Advanced Peripherals peripherals and both are in the pack.
They expose the item list, crafting CPUs and energy.

- a **watchlist**: items with a minimum quantity, shown red when below it
- **crafting jobs** in progress, and an alert when one finishes
- ME/RS network energy and CPU usage
- reuse `radar/logbook.lua` verbatim for a stock history

The watchlist maps neatly onto the ignore-list UI that already exists: a picker
that adds names to a persisted table. The chart from the power page draws stock
levels over time with no changes at all.

### 🌙 Ritual clock — Environment Detector ✅

The station already polls the Environment Detector and knows the tick, the day,
the moon phase and the weather. It currently only draws them.

Ars Nouveau, Malum, NeoVitae and Roots all have timing that cares about night,
moon phase or weather. A module answering *"how long until night?"*, *"when is
the next full moon?"*, *"is it raining?"* is nearly free — the data is already
in `app.env.snapshot`, so this needs no `discover` and no `start` at all.

Pair it with a redstone level provider and you have an automatic ritual gate.

### 💡 Remote redstone — Redstone Integrator ✅

Right now redstone output is limited to the six sides of the computer itself.
A **Redstone Integrator** is placed anywhere on the wired network and driven
over it, so the station could:

- light an approach path when a ship comes within range of home
- open a hangar door on arrival
- run a beacon that says "someone who is not you just landed"

A side becomes a `{ peripheral, side }` pair in `radar/alerts.lua`, plus a
picker in settings.

---

## Bigger, but a good fit

### 🪨 Ore scope — Geo Scanner ✅ + Geores ❓

The **Geo Scanner** returns every block in a radius as a list with relative
coordinates. That is a point cloud, and the station already has a polar plot
that draws point clouds.

A `SCAN` module could render a top-down ore map, coloured by ore type, with the
same range rings and the same rotation logic as the radar.

**Watch out:** Geo Scanner has an energy cost and a cooldown, and a large radius
returns a *lot* of entries. Give it a slow `start` loop — every 15 seconds, not
every sweep — and a hard cap on how many blocks get plotted.

### 🥽 Heads-up display — AR Controller ❓

The **AR Controller** draws to the player's screen. The contact list, the
bearing to home and a compass strip as an overlay while you fly is the single
most useful thing on this list for actually playing the pack, because it does
not require you to be standing at a monitor.

The drawing is a different API from Basalt canvases, so this is a **service**
module — one with `start` and no `build` — rather than a page. It consumes
exactly the same `app.contacts`.

### 🧭 Waypoints ✅

Once a GPS constellation exists (see fleet tracking), a persisted list of named
points — home island, the ore island, a boss arena, wherever a **Tempad** goes —
can be drawn on the scope as a distinct marker, with bearing and distance in the
contacts table.

On a skyblock where every destination is a separate island in the void, this
turns the radar from a security tool into a navigation instrument. A module's
`defaults` and `sanitise` hooks persist the list with no changes to
`radar/config.lua`.

### 🎒 Operator panel — Inventory Manager ✅

The **Inventory Manager** reads the bound player's inventory and armour. A strip
showing armour durability, with a warning before a piece breaks, is worth having
before a **Cataclysm** or **Apothic** boss fight.

### 💬 Chat control — Chat Box ✅

The **Chat Box** both sends messages and receives them, so the station can:

- announce contacts and alerts in chat, instead of only on the terminal
- take commands: `$radar range 500`, `$radar status`, `$radar mute`

The command handlers already exist as methods on `app` (`setRangeIndex`,
`toggleAlerts`, `clearLog`, `toggleModule`, `setProfile`) — this is a parser and
an event loop in a service module, not new logic.

---

## Smaller wins

| Idea | Mod / peripheral | Notes |
|---|---|---|
| Show each contact's dimension instead of hiding it | none needed | `cfg.dimFilter` already knows; make it a three-way filter with a per-dimension tally |
| Machine-health panel | Create stress, PneumaticCraft, Modern Industrialization ❓ | Block Reader on key machines; warn on stalled. The power page's chart draws stress over time unchanged |
| Factory alarm on the existing speaker | none needed | `alerts:fire(reason)` is already generic; point it at a non-player trigger |
| Boss-arena proximity warning | Soaring Structures, Cataclysm | Waypoints plus the existing alert-range check; no new peripheral |
| A profile for a turtle or a mining rig | none needed | `radar/profiles.lua` is a list; a fourth entry is a few lines |

---

## What is deliberately not here

**Mob and boss detection.** The Player Detector detects players, and that is
all. I have not found an Advanced Peripherals device that enumerates arbitrary
mobs, so a "hostile radar" would need a peripheral this pack may not ship.
Worth checking before anyone plans around it — and if one does exist, the
contacts pipeline is already generic enough to take it.

**Anything requiring a server-side config change.** `getPlayerPos` can be
disabled by `playerSpy`, and `playerDetMaxRange` caps MAX range. Ideas above
stay inside what a default install permits.
