# Radar Station v4 — Basalt edition

A stationary player radar for **CC: Tweaked + Advanced Peripherals** on
**Minecraft 1.21.1**, rebuilt on the [Basalt 2.5](https://basalt.madefor.cc/2.5/)
UI framework, with a live weather and sky display driven by an Environment
Detector.

---

## What changed from v3

| | v3 | v4 |
|---|---|---|
| UI | hand-rolled `term.write` and blocking modal menus | Basalt 2.5 elements, tabbed pages, non-blocking |
| Graphics | one blip per character cell | 2×3 sub-pixel drawing — round range rings, real sweep |
| Weather | — | live procedural sky from the Environment Detector |
| Scenery | — | terrain and flora drawn from the biome you are standing in |
| Orientation | a fixed bearing at the top | that, or unlocked so the scope turns with you |
| Monitors | one style each, redraw loop | one Basalt root each; right-click to change page, or cycle on a timer |
| Settings | nested modal menus that froze scanning | a scrolling settings page; scanning never stops |
| Layout | fixed | every page adapts from a 15-cell pocket screen to a 5×5 monitor |

Scanning, alerts, ranges, rotation, the ignore list, the log and the redstone
modes all behave as they did in v3. **Your v3 settings, log and ignore list are
imported automatically on first run** — as are the older `pocket_radar.*` files.

---

## Hardware

**Required**

- Advanced Computer (advanced, for colour)
- **Player Detector** (Advanced Peripherals) — adjacent, or on a wired modem
  network shared with the computer

**Optional**

- **Environment Detector** (Advanced Peripherals) — unlocks the Weather page
- **Advanced Monitor(s)** — any size; each monitor gets its own page
- **Speaker(s)** — every speaker on the network plays the alert
- Any redstone contraption on a side of the computer

---

## Install

On the computer in game:

```
wget run https://raw.githubusercontent.com/Doom6197/cc-radar-station/main/install.lua
```

That pulls down all 20 files and offers to install Basalt 2.5 for you. Then:

```
radar
```

or pass your base coordinates straight in:

```
radar 120 64 -340
```

### Installer options

| | |
|---|---|
| `--startup` | also write a `startup.lua` so it launches on boot |
| `--dir <path>` | install somewhere other than the current directory |
| `--no-basalt` | skip the Basalt check |
| `<owner>/<repo>` | install from a fork |
| `<branch>` | install from a branch other than `main` |

```
wget run <url> --startup
wget run <url> dev --dir /apps
```

Run the same command again any time to update — it downloads everything into
memory first and only writes once all 20 files have arrived, so a dropped
connection leaves the computer exactly as it was.

### Installing by hand

Copy `radar.lua` and the whole `radar/` folder next to `basalt.lua`:

```
/basalt.lua
/radar.lua
/radar/…
```

Basalt itself: `wget run https://basalt.madefor.cc/2.5/install.lua minified`

---

## Pages

| Key | Page | What it shows |
|---|---|---|
| `1` | **Status** | Everything at a glance: base, your position, ranges, alerts, sound, redstone, hardware, environment, contacts, recent log |
| `2` | **Radar** | Polar scope with range rings, a rotating sweep, and colour-coded blips |
| `3` | **Contacts** | Table of every contact — distance, bearing, altitude, band, position, health |
| `4` | **Weather** | Live sky and biome scenery, big clock, day number, moon phase, light levels |
| `5` | **Log** | Detection history, plus a visitor tally on wide screens |
| `6` | **Settings** | Everything configurable, on one scrolling page |

Monitors can show any page except Settings.

### Driving a monitor

Monitors have no keyboard, so the screen is the control:

- **Right-click a monitor** (a *use*, which arrives as a touch) to move it to
  the next page. Turn this off with **Settings → Displays → Tap to change**.
- Monitors big enough for a tab strip can still be pressed on a tab to jump
  straight to that page.
- **Auto-cycle** walks a monitor through its pages on a timer. Set it per
  monitor under **Settings → Displays**: turn it on, pick an interval from 5
  seconds to 5 minutes, and choose which pages are in the rotation. Right-
  clicking gives you a fresh interval to read the page you picked, so you are
  never yanked off it mid-glance.

The page a monitor cycles to is deliberately not saved — on restart every
monitor returns to the page you chose for it.

---

## Keyboard

```
1..6       jump to a page
Left/Right previous / next page
Up/Down    scan range up / down
R          rotate the picture 45 degrees
L          lock / unlock the scope orientation
T          toggle FIXED / SELF tracking
A          mute or unmute alerts
P          test the alert sound
N          ignore the nearest contact
B          set the base to your current position
C          clear the log
Q          quit
```

Mouse clicks and monitor taps work everywhere.

---

## Orientation: locked or unlocked

**Locked** (the default) keeps a bearing of your choosing at the top of the
scope — the right thing for a monitor bolted to a wall, where "up" should match
the way you are facing when you look at it.

**Unlocked** turns the whole picture with you. The station reads your yaw and
puts whatever you are looking at at the top, marking it with a lubber line, and
the bottom-right readout switches to `HDG 227`. Press `L`, or use
**Settings → Orientation → Scope**.

This needs your **username** set, because the yaw comes from reading your own
player position. With no username the scope says `HDG --` and falls back to the
locked bearing rather than pretending to have a fix.

Three knobs under **Settings → Orientation**:

| | |
|---|---|
| **Heading steps** | Smooth free rotation, or snap to 5° / 15° / 45° / 90°. Snapping to 45° gives a stable eight-point compass that does not shimmer while you look around. |
| **Heading rate** | How often the yaw is re-read — 0.25 to 2 seconds. This is one detector call, and the loop idles entirely while the scope is locked. |
| **Ease turns** | Slide into a turn instead of jumping to it. Needs animation on. |

Bearings, distances and the N/NE/E labels stay true compass values throughout.
Only the picture turns.

---

## The weather page

The sky is **generated from the live snapshot**, not chosen from a set of stock
pictures. As the Minecraft day runs:

- the sun climbs its arc from the eastern horizon and sets in the west, and the
  moon takes over after dusk, drawn at its **real phase** (all eight of them);
- the palette moves through **dawn → day → dusk → night**, each with its own
  ten-colour scheme;
- **rain** slants, **snow** drifts and sways, **thunderstorms** wash the sky
  white behind a forked bolt;
- clouds drift in parallax layers — low and sparse in fair weather, filling the
  sky when it is overcast;
- snow instead of rain in cold biomes, and dry biomes correctly show clear skies
  while it rains elsewhere.

Everything is drawn with the teletext block characters, giving 2×3 sub-pixels
per character cell. Because a CC glyph is 6×9 screen pixels, those sub-pixels
are square — so circles are round without any aspect-ratio fudging.

![Sky scenes: sunrise, morning, noon, sunset, moonlit night, rain, thunderstorm, snow and the Nether](preview/sky-scenes.png)

All eight moon phases, drawn from `getMoonId()`:

![Full, waning gibbous, last quarter, waning crescent, new, waxing crescent, first quarter, waxing gibbous](preview/moon-phases.png)

And the scope:

![Radar scope with range rings, sweep and colour-coded contacts](preview/radar-scope.png)

### Biome scenery

The ground under the sky comes from the biome the Environment Detector reports.
A profile picks three things independently — a **terrain silhouette**, a kind of
**plant** to grow on it, and three **colours** — so thirty-odd biomes are
covered without thirty-odd bespoke pictures:

| | |
|---|---|
| Terrain | rolling hills, flat plains, sand dunes, jagged peaks, stepped mesa plateaus, open water, a shoreline with surf, swamp pools, cave interiors, and floating islands over open sky |
| Flora | conifers, broadleaf, birch, acacia, cactus, bamboo, giant mushrooms, palms, ice spikes, bare dead trees, hanging glow vines, nether fungi, end crystals |

![Thirty biome scenes: plains, meadow, forest, birch, dark forest, taiga, cherry grove, jungle, bamboo, mushroom fields, savanna, desert, badlands, volcanic, mountains, snowy peaks and taiga, snowy plains, ice spikes, swamp, mangrove, river, beach, ocean, frozen ocean, lush caves, dripstone, deep dark, caves and floating islands](preview/biomes.png)

The colours are written once, as they look at midday, and everything else is
derived: dawn and dusk warm them, night drains them, rain and storms grey them
out, and settling snow whitens the ground whatever it started as.

![The same forest at dawn, noon, dusk, night, in rain and in a storm, then snowy taiga by day and night, then floating islands](preview/biome-moods.png)

The other dimensions vary too — the Nether's crimson, warped, soul sand and
basalt biomes each draw differently over the lava:

![Nether wastes, crimson forest, warped forest, soul sand valley, basalt deltas, and the End](preview/biomes-dimensions.png)

**Modded biomes** are matched on name, most specific first, so
`somemod:frozen_highlands` still lands on snowy peaks. Anything unrecognised
falls back to plains rather than to nothing. If your pack reports a biome the
station reads wrongly — or reports a dull one for a world that is really open
sky — force the scenery under **Settings → Environment → Scenery**. Both the
weather readout and the status page show which ground is actually being drawn,
and say `(forced)` when you have overridden it.

**Palette budget.** A biome only ever replaces the three ground slots (land,
its shadow, one accent) of the ten-tone scene palette. Everything above them
belongs to the sky. Changing biome therefore costs no extra palette slots at
all, which is what keeps the weather page inside the sixteen the hardware has.

### Seeing it without launching Minecraft

`preview/` holds rendered sheets of every scene, every moon phase and the radar
scope. They are not screenshots of a mock-up: `preview/render-preview.lua`
compiles the real pixel grid into teletext cells exactly as the game will, then
expands each cell back into its two surviving colours — so what you see is what
the monitor shows.

```
lua preview/render-preview.lua . preview     # needs a desktop Lua 5.x
lua preview/smoke-test.lua .                 # 40 checks, no Minecraft needed
```

`smoke-test.lua` stubs CC:Tweaked and Basalt, then drives every page at seven
screen sizes across five scenarios (contacts, empty, detector fault, no
Environment Detector, muted) and presses every button on the settings page. It
also paints **every biome** at six sizes in every weather and every hour, and
reads the pixel grid back afterwards to prove no terrain painter leaves a hole
in the ground — `blitTo` silently substitutes a palette entry for an unpainted
sub-pixel, so a gap would otherwise only show up in game.

---

## Notes

**Rotation** turns the *picture* only, so a monitor can hang on any wall with
"up" matching the way you face. Distances and the N/NE/E labels stay true
compass bearings. See *Orientation* above for following your heading instead.

**FIXED vs SELF** — `getPlayersInRange()` is always centred on the Player
Detector *block*. FIXED changes only what distances are measured *from*. For a
stationary station, put the detector at the base and point the base coordinates
at it, so the two agree.

**MAX range** is capped by the server's `playerDetMaxRange` in
`advancedperipherals-server.toml`. Set it to `-1` for no limit.

**`getPlayerPos` may be disabled** by the server's `playerSpy` config option,
and some servers add random error to positions at long range. The radar reports
whatever it is given.

**Colours.** Basalt maps custom RGB colours onto the 16 hardware palette slots
per terminal, per frame. The station budgets nine chrome colours and ten scene
colours, of which only three change with the biome. On a *non-advanced*
computer or monitor there is no palette control at all, and every colour falls
back to the nearest of the sixteen defaults — everything still renders, just
flatter.

---

## Layout

```
radar.lua              entry point: paths, preflight checks, shutdown
radar/
  app.lua              shared state, background loops, actions
  ui.lua               Basalt roots, header, tab strip, page router, keys
  config.lua           settings schema, defaults, v3 import, persistence
  hardware.lua         peripheral discovery by capability
  scan.lua             Player Detector -> contact list
  environment.lua      Environment Detector -> snapshot + scene description
  biomes.lua           biome id -> ground profile, and its colours by mood
  alerts.lua           sound, redstone and flash
  logbook.lua          detection history and visitor stats
  theme.lua            colour palettes (chrome + sky + derived ground)
  pixel.lua            2x3 sub-pixel drawing surface
  glyphs.lua           3x5 bitmap font for the big clock
  sky.lua              procedural sky, weather, terrain and flora painter
  util.lua             maths, bearings, headings, formatting
  views/
    status.lua  radar.lua  contacts.lua  weather.lua  log.lua  settings.lua
install.lua            in-game installer
manifest.txt           the file list it downloads
IDEAS.md               where this could go next in FTB Skies 2: Aero
preview/               desktop-only: rendered sheets and the tools that make them
```

Only `radar.lua` and `radar/` end up on the computer. `manifest.txt` is
generated from disk — if you add a module, add its path there too, or the
installer will not fetch it. `preview/install-test.lua` checks for exactly that.

```
lua preview/install-test.lua .    # 13 checks against a mocked CC + HTTP
```

Views never touch a peripheral. They read `app` and subscribe to five events —
`scan`, `env`, `anim`, `heading` and `config` — which keeps rendering
independent of how often the hardware is polled.
