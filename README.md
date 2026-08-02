# Radar Station v6 — Basalt edition

A player radar for **CC: Tweaked + Advanced Peripherals** on **Minecraft
1.21.1**, built on the [Basalt 2.5](https://basalt.madefor.cc/2.5/) UI
framework, with a live weather and sky display driven by an Environment
Detector — plus a radar screen that flies with you, and a gallery of skies to
put behind it.

---

## What v6 adds

**Backdrops.** Twenty pictures for the weather page — floating isles through a
whole day, a sea of cloud seen from above, airships under way, stone spires in
haze. Pick one, or have them **cycle on a timer** you choose.

A backdrop is a **place** and a **sky**, and you choose those separately:

- keep the sky the picture was drawn with, and it needs **no Environment
  Detector at all** — which is what makes the weather page worth having on a
  ship;
- or set the sky to **live**, and the picture keeps its place while the hour,
  the weather and the sun all come from the detector. Your airships then fly
  through the real dusk and the real rain.

See *[Backdrops](#backdrops--a-place-and-a-sky)*. The default is unchanged: the
page draws the real sky until you tell it otherwise.

---

## What v5 adds

A **role**, under *Settings → Link*:

| Role | What it is |
|---|---|
| **STATION** | the stand-alone radar. Exactly v4, no network involved. The default. |
| **BASE** | the same radar, which also broadcasts what it sees over rednet |
| **SHIP** | a screen with no detector at all, drawing what one paired base sends it |

That exists because a **Create: Aeronautics** contraption cannot scan for
itself. See *[Flying: base and ship](#flying-base-and-ship)*. Nothing changes
for anyone who leaves the role alone.

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
  network shared with the computer.
  **Not needed in the SHIP role**, which carries no detector at all.

**Optional**

- **Environment Detector** (Advanced Peripherals) — unlocks the Weather page
- **Wireless or ender modem** — required by the BASE and SHIP roles, ignored by
  a STATION. Use an **ender** modem: no range limit, and it works across
  dimensions.
- **Advanced Monitor(s)** — any size; each monitor gets its own page
- **Speaker(s)** — every speaker on the network plays the alert
- Any redstone contraption on a side of the computer

---

## Install

On the computer in game:

```
wget run https://raw.githubusercontent.com/Doom6197/cc-radar-station/main/install.lua
```

That pulls down all 23 files and offers to install Basalt 2.5 for you. Then:

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
memory first and only writes once all 23 files have arrived, so a dropped
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

## Flying: base and ship

### Why a radar on a ship cannot scan

Create: Aeronautics assembles a structure into a **contraption**. While it is
assembled, its blocks live in a proxy level rather than in the world, so
anything that asks a question about a real block position gets nothing back.
The computer keeps running, `peripheral.getNames()` still lists the detector,
and `getPlayersInRange()` returns an **empty list** the whole time you are
flying. Dock the ship and it works again.

`getPlayerPos(name)` is different: it looks up an **entity by name**, not a
position in the world. A Player Detector bolted to the ground can therefore
read the pilot accurately wherever they have got to — including three thousand
blocks up, aboard a ship.

So the detecting is done on the ground and the picture is flown:

```
   ground                                    in the air
   ┌────────────────────┐                    ┌────────────────────┐
   │ BASE               │   contacts, your   │ SHIP               │
   │ Player Detector    │   position, yaw    │ ender modem        │
   │ ender modem        │ ─────────────────► │ monitor            │
   │ SELF mode          │      rednet        │ no detector, no GPS│
   └────────────────────┘                    └────────────────────┘
```

Because the base runs in **SELF** mode — centred on you rather than on a fixed
point — every distance and bearing it computes is already relative to the
pilot, which is what a scope on the ship wants. Nothing is recalculated for
being airborne.

### Setting it up

**On the ground station**

1. *Settings → Link → Role* → **BASE**.
2. Give it a name under *Station name* — this is what ships see. It defaults to
   `Base <computer id>`.
3. Set *Tracking → Mode* to **SELF** and your *Username*, so the scope is
   centred on you. (BASE works in FIXED mode too; it just watches the base
   coordinates instead, which is rarely what you want while flying.)
4. Attach a wireless or ender modem. The *Modem* row shows which one it opened.

**On the ship**

1. Put a computer, an **ender modem** and a monitor on the contraption. No
   Player Detector and no GPS constellation are needed.
2. *Settings → Link → Role* → **SHIP**.
3. Press **Scan for base stations**. The ship listens for a few seconds,
   collects every base that announced itself, and offers them in a picker.
4. Pick yours. The status page then reads `SHIP - linked to <name>`.

The ship accepts traffic **only** from the computer id it was paired with, so
several base/ship pairs can share one world without seeing each other's
contacts. Pairing is a one-way choice: the base never needs to know who is
listening, and announces itself whether or not anyone is.

Every page then works exactly as it does on the ground — the radar scope, the
contacts table, the log and the alerts all read the same `app.contacts` a local
sweep would have produced. The pilot's yaw is relayed too, so unlocking the
orientation (`L`) gives the ship a proper heading-up scope.

### Weather on the ship

*Settings → Link → Relay weather*, on the **base**, also sends the environment
readings. A paired ship then draws the full weather page — sky, biome scenery,
clock, moon phase, light levels — from what the base's Environment Detector
reads, and stops asking its own. It is off by default: it is extra traffic, and
not everyone flying wants it.

Only the raw readings travel. The sky, palette and scenery are rebuilt on the
ship from the same code that builds them on the base, so the page is identical
without a single pixel crossing the network.

### When the link drops

If nothing arrives from the paired base for roughly two of its sweep intervals,
the ship treats the link as lost. It **clears the scope** and says so — a
stale picture drawn as though it were live is worse than an empty one. The
message appears where a detector fault already does: across the contacts page,
along the bottom of the radar, and on the `Link` row of the status page.

| What you see | What it means |
|---|---|
| `Waiting for <name>` | paired, but that base has not spoken yet |
| `Link lost - nothing from <name>` | it has gone quiet, or you have flown out of a wireless modem's range |
| `No base station paired` | pick one with *Scan for base stations* |
| `No modem - the ship link needs one` | attach a wireless or ender modem and press *Modem* to rescan |

### Notes

- **STATION is untouched and is still the default.** It opens no modem, sends
  nothing, and needs no network to exist. A v4 install upgrades straight into
  it with nothing new turned on.
- A **BASE is a fully working radar in its own right** — it keeps its own
  screens, alerts, log and redstone whether or not a ship is ever paired to it.
- **The ship carries no position source.** Everything it draws, including "you
  are at X, Y, Z" on the status page, is the pilot's position as read by the
  base. That is the ship's position *while the pilot is aboard it* — if you
  leave the ship flying on autopilot and walk away, the status page follows
  **you**, not the ship. There is deliberately no GPS fallback.
- **Ender modems** are the right choice: unlimited range, and not
  dimension-limited. A plain wireless modem is fine within its range, and the
  link simply goes stale beyond it.
- Only positions travel. Distance, bearing, altitude band and colour are
  rebuilt at the far end by the same code that computes them locally, so there
  is one implementation of that maths rather than two that can drift apart.

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

## Backdrops — a place and a sky

Everything above is driven by what the Environment Detector reports. On a pack
where every dimension is floating islands and you live on an airship, that is
often either wrong or missing entirely: **a contraption is not made of world
blocks**, so a detector riding on one has nothing to report at all, and the
weather page sits empty.

A **backdrop** is a scene chosen by hand instead. It has two halves, and you
pick them separately:

| | |
|---|---|
| the **place** | which ground gets drawn — the archipelago, a cloud sea, airships, spires |
| the **sky** | the hour, the weather and where the sun is: either baked into the picture, or taken live from the detector |

Twenty pictures ship with v6:

![Twenty backdrops: floating isles at dawn, noon, sunset and by moonlight, in storm and snow; a cloud sea at dawn, day, dusk and night; airships in fair weather, at sunset, by moonlight, in rain and in a storm; stone spires by day, dusk and night; the Nether lava sea; and the End](preview/backdrops.png)

| | |
|---|---|
| **Isles** | the archipelago in parallax, waterfalls off the undersides, right round a day and through storm and snow |
| **Cloud sea** | a deck of billowing cloud with peaks breaking through it, from above |
| **Airships** | an envelope, fins and a slung gondola, under way over islands, in five kinds of weather |
| **Spires** | stone towers standing in haze |
| **Other dimensions** | the Nether's lava sea, and an End island in the void |

Set it under **Settings → Backdrop**:

| | |
|---|---|
| **Picture** | `Live` draws the real sky (the default), `Cycle` walks a set on a timer, or name one and it stays |
| **Sky** | `From the picture` — the hour and weather it was drawn with — or `Live` |
| **Change every** | 10 seconds to 30 minutes |
| **In the cycle** | which pictures are in the rotation — tick them off one at a time, exactly like a monitor's page rotation |

Plus **Show the next picture now**, to step the cycle by hand.

### Keeping the picture, following the weather

Set **Sky** to `Live` and the picture keeps only its **place**. The hour, the
weather, the sun's position on its arc, the moon's phase and the dimension all
come from the detector, and the ground is lit to match:

![One airship picture under twelve live skies: sunrise, noon, sunset, a moonlit night, rain, a lightning strike, snow over a taiga and clear sky over a desert, then the isles at night and in a storm, a cloud sea at dusk and spires at sunrise](preview/backdrops-live.png)

That is the same code path the live weather page takes with its scenery forced,
so nothing about the lighting is special-cased for backdrops.

Two things follow from *where you actually are* rather than from the picture:

- **whether it can rain at all**, and **whether that falls as snow**. An
  airship is not a climate — so it snows over a taiga, rains over plains, and
  stays clear over a desert while it rains elsewhere.
- **the dimension.** In the Nether you get the Nether sky.

*Over the Lava Sea* and *The Far End* are places rather than hours, so they are
always drawn as authored, live sky or not.

**With no detector there is no live sky to follow**, so the picture quietly
falls back to the hour it was drawn with rather than to nothing. A ship set to
a live sky therefore still shows something the moment it leaves the ground.

Under a live sky the **cycle walks places rather than pictures**. The six
island presets differ only in the hour they were drawn at, and the hour is now
coming from the detector — so cycling them would show the same picture six
times running. The rotation collapses to one entry per place instead.

### What a backdrop does and does not replace

Only the **picture**. The readout beneath it, the badge in the header and the
status page all carry on reporting what the detector actually says — so a
sunset backdrop over a real thunderstorm still shows `STORM` in the header and
`SKY Thunderstorm` in the readout. Nothing on screen lies about the weather
because you chose a nicer sky.

The big clock is the real time, so a backdrop with no detector behind it simply
has no clock on it.

Even with the sky set to `From the picture`, the **moon phase** on a night
backdrop is the real one whenever there is a detector to ask.

**Settings → Environment → Scenery** only applies while the picture is `Live`,
and greys out when a backdrop is up — the backdrop brings its own ground.

Backdrops cost **no extra palette slots**. They are built from the same ten-tone
sky-plus-ground palettes as everything else, so they are exactly as cheap to
draw as the live sky.

---

## Seeing it without launching Minecraft

`preview/` holds rendered sheets of every scene, every backdrop, every moon
phase and the radar scope. They are not screenshots of a mock-up:
`preview/render-preview.lua`
compiles the real pixel grid into teletext cells exactly as the game will, then
expands each cell back into its two surviving colours — so what you see is what
the monitor shows.

```
lua preview/render-preview.lua . preview     # needs a desktop Lua 5.x
lua preview/smoke-test.lua .                 # 62 checks, no Minecraft needed
```

`smoke-test.lua` stubs CC:Tweaked and Basalt, then drives every page at seven
screen sizes across five scenarios (contacts, empty, detector fault, no
Environment Detector, muted) and presses every button on the settings page. It
also paints **every biome** at six sizes in every weather and every hour, and
reads the pixel grid back afterwards to prove no terrain painter leaves a hole
in the ground — `blitTo` silently substitutes a palette entry for an unpainted
sub-pixel, so a gap would otherwise only show up in game.

rednet is stubbed as a loopback, so the whole base/ship link is exercised too:
a base broadcasting after a sweep, a ship rebuilding that sweep and comparing
it **field for field** against the one the base drew, the pairing picker,
traffic from an unpaired sender being refused, a silent base being called lost,
and the weather relay producing an identical snapshot with no detector present.

Every backdrop gets the same sub-pixel treatment as every biome, at six sizes
and four animation frames, plus checks that the cycle honours its interval and
its skip set, that an open-air scene draws **no horizon** under it, and — by
reading back the text the page actually wrote — that the backdrop replaces the
artwork while the readout underneath carries on reporting the real sky.

---

## Notes

**Rotation** turns the *picture* only, so a monitor can hang on any wall with
"up" matching the way you face. Distances and the N/NE/E labels stay true
compass bearings. See *Orientation* above for following your heading instead.

**FIXED vs SELF** — `getPlayersInRange()` is always centred on the Player
Detector *block*. FIXED changes only what distances are measured *from*. For a
stationary station, put the detector at the base and point the base coordinates
at it, so the two agree.

**Aboard a contraption nothing block-based answers.** `getPlayersInRange()` and
the Environment Detector's calls both need a real world position, and a
Create: Aeronautics ship is not in the world while it is assembled. That is
what the BASE and SHIP roles are for — see *Flying: base and ship* above — and
why *Backdrops* exist for the weather page, which has nothing to draw from a
detector that cannot answer.

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
  link.lua             base <-> ship over rednet: pairing, relay, staleness
  environment.lua      Environment Detector -> snapshot + scene description
  biomes.lua           biome id -> ground profile, and its colours by mood
  backdrops.lua        hand-picked scenes for the weather page, and the cycle
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

Views never touch a peripheral. They read `app` and subscribe to six events —
`scan`, `env`, `anim`, `heading`, `config` and `backdrop` — which keeps
rendering independent of how often the hardware is polled. It is also why the
SHIP role
needed no view changes at all: `radar/link.lua` fills the same tables and fires
the same events from the network that `radar/scan.lua` fills them from a
detector, and nothing downstream can tell which it is looking at.
