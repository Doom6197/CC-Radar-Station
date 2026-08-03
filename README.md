# Radar Station

A player radar, weather display and power monitor for **CC: Tweaked +
Advanced Peripherals** on **Minecraft 1.21.1**, built on the
[Basalt 2.5](https://basalt.madefor.cc/2.5/) UI framework.

Every page is a **module** — one file in `radar/modules/` that owns its page,
its settings, its hardware and its background polling. Drop a file into that
folder and the station has a new page. Nothing else needs editing.

It runs in three places, and asks which on first boot: the **main base** with
the detectors and monitors, a **pocket computer** in your hand, or an
**airship** in the air. The main base does all the scanning and feeds the rest
over rednet — along with energy readings collected from any number of
**power clients** dotted around your build.

![Radar scope with range rings, sweep and colour-coded contacts](preview/radar-scope.png)

---

## Contents

- [Install](#install)
- [Hardware](#hardware)
- [Profiles](#profiles) — base, pocket, airship
- [Pages](#pages)
- [Settings](#settings) — the index, and why it is two levels
- [Modules](#modules) — the plugin system, and how to write one
- [Flight](#flight) — speed, climb and course from the pilot's position, and the autopilot
- [Power](#power) — and the power clients that feed it
- [Weather and backdrops](#weather-and-backdrops)
- [Orientation](#orientation-locked-or-unlocked)
- [The network: main base, mobiles and power clients](#the-network-main-base-mobiles-and-power-clients)
- [Alerts and the alert log](#alerts-and-the-alert-log) — and the unread marker
- [Keyboard and monitors](#keyboard-and-monitors)
- [Project layout](#project-layout)
- [Development](#development)
- [Version history](#version-history)

---

## Install

On the computer in game:

```
wget run https://raw.githubusercontent.com/Doom6197/CC-Radar-Station/main/install.lua
```

That pulls down all 32 files and offers to install Basalt 2.5 for you. Then:

```
radar
```

or pass your base coordinates straight in:

```
radar 120 64 -340
```

On first boot it asks what the computer is bolted to and what your username
is. Both are ordinary settings afterwards.

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
memory first and only writes once every file has arrived, so a dropped
connection leaves the computer exactly as it was. **Settings from every earlier
version are imported automatically**, and an upgrade never sees the first-boot
questions: what is already on disk is your answer to them.

### Installing by hand

Copy `radar.lua` and the whole `radar/` folder next to `basalt.lua`:

```
/basalt.lua
/radar.lua
/radar/…
```

Basalt itself: `wget run https://basalt.madefor.cc/2.5/install.lua minified`

---

## Hardware

**Required**

- Advanced Computer (advanced, for colour)
- **Player Detector** (Advanced Peripherals) — adjacent, or on a wired modem
  network shared with the computer.
  **Not needed by a MOBILE**, which carries no detector at all.

**Optional — each unlocks a module**

| Peripheral | Unlocks |
|---|---|
| **Environment Detector** | the Weather page: live sky, biome scenery, moon phase, light levels |
| **Energy Detector**, inline in a cable | the Power page: transfer rate, and a settable limit |
| Any wrappable battery — induction matrix, energy cell, flux point | stored and capacity on the Power page |
| **Wireless or ender modem** | the MAIN BASE and MOBILE roles, and power clients. Use an **ender** modem: no range limit, works across dimensions |
| **Advanced Monitor(s)** | any size; each monitor gets its own page |
| **Speaker(s)** | every speaker on the network plays the alert |
| **Redstone Relay** (CC: Tweaked) | the flight page's [autopilot](#autopilot): two sides driving the left and right thruster groups |
| Any redstone contraption on a side of the computer | the redstone output |

Peripherals are matched on **what they can do**, not on their type name, so a
Player Detector works whether it is bolted to the computer, built into a pocket
computer, or somewhere on a wired modem network — and a battery from a mod this
was never tested against is recognised as long as it answers something like
`getEnergy()` and `getMaxEnergy()`.

---

## Profiles

The same station runs in three very different places, and each wants different
defaults rather than different code. On first boot it asks which:

| Profile | What it sets up |
|---|---|
| **MAIN BASE** | the master. A fixed, chunk-loaded installation: monitors get their own pages, the scope holds a fixed bearing, every module on, and it feeds everything else over the network. |
| **POCKET** | carried in hand. Sweeps and polls slow down, the animation stops, the scope turns with you in 45° steps, the Power page is off. |
| **AIRSHIP / VEHICLE** | aboard something that moves. The scope follows the pilot's heading and eases into turns. |

The choice is **offered, not guessed**. Hardware is a poor proxy for intent: a
pocket computer is unmistakable, but a main base and a vehicle carry
identical peripherals and differ only in what they are attached to.

The **role** is not part of the profile: it follows from whether there is a
modem. With one, the base profile becomes the **MAIN BASE** and the other two
become **MOBILE**; without one, all three are **STANDALONE**.

A profile is applied **once**. It is not a mode the rest of the program keeps
checking — afterwards every setting it touched is an ordinary setting you can
change like any other, and **every one of them has its own row in Settings**:
tracking mode, the scope, heading steps, heading rate, eased turns, animation,
sweep rate, screen flash and the banner. Reapply or switch under
**Settings → Station → This station**; doing so overwrites the settings it covers, which is the
point of it.

---

## Settings

The settings page is an **index of eight groups**, each showing its own current
state — so it is a report on the station as much as it is a menu. Pressing one
fills the page with that group.

```
 SETTINGS   v8.8                                    |  SETTINGS   v8.8
 -------------------------------------------------  |  ---------------------
 STATION       MAIN BASE "Hangar"                   |  STATION
 TRACKING      FIXED   120, 64, -340                |  MAIN BASE
 SCANNING      10k   every 1s   1 ignored           |  TRACKING
 SCOPE         locked - 45 deg, NE up               |  FIXED 120, -340
 ALERTS        ON   sound, flash, banner, redstone  |  SCANNING
 DISPLAYS      terminal: status   1 monitor         |  10k   1s
 PAGES         9 of 9 on                            |  SCOPE
 KEYBOARD      shortcuts and monitor taps           |  locked
                                                    |  ALERTS
 Quit Radar Station                                 |  ON   4 channels
```

| Group | What is in it |
|---|---|
| **Station** | version, profile, role, modem, station name, pairing, broadcasting |
| **Tracking** | your username, FIXED/SELF, the base coordinates, follow base |
| **Scanning** | range, sweep rate, other worlds, the ignore list |
| **Scope** | locked or unlocked, bearing up, heading steps and rate, eased turns, animation |
| **Alerts** | master, alert range, flash, banner, chime, the sound, the redstone line |
| **Displays** | this page's layout and hints, the terminal page, every monitor |
| **Pages** | which modules are on — and each module's own settings, one press further |
| **Keyboard** | the shortcut list and what a monitor tap does |

### Why it is two levels

It used to be one scrolling page. By v8.4 that was 17 sections, 85 controls and
99 notes: **231 rows — fourteen screenfuls on a terminal and twenty-one on a
pocket computer.** Worse than the length was the filing. A module's ON/OFF
switch sat about a hundred rows above the settings it governed; `Alert within`
lived under SCANNING while the alerts lived under ALERTS; and two sections were
both called some variety of "alerts".

Now the index is 12 rows and **thirteen of the eighteen screens fit without
scrolling at all**. The longest, ALERTS, is 28 rows. Nothing was removed.

**PAGES is the spine of the module system.** Each module is one row, and
pressing it opens a screen holding its switch *and* its settings — so
`Power ON` and the power thresholds are finally in the same place. A module
that is switched off keeps its screen, so there is somewhere to turn it back
on from.

### Hints

The 99 explanatory notes are **off by default** and switched on under
**Settings → Displays → Hints**. Anything that stops a mistake being made — the
warning that applying a profile overwrites your settings, the keyboard list —
is shown either way, so turning hints off cannot cost you a warning.

### On a small screen

A pocket computer is 26 cells across, which is not enough for a label column
and a value column side by side. Below 34 cells the page **stacks**: each label
gets its own line with the value full-width underneath, notes wrap instead of
being clipped, the three coordinate boxes sit on one line rather than running
off the edge, and each group's index summary switches to a shorter form.

That is automatic, and **Settings → Displays → Layout** overrides it either way
— `Stacked` on a wide screen, `Side by side` on a narrow one.

---

## Pages

| Key | Page | What it shows |
|---|---|---|
| `1` | **Status** | Everything at a glance: profile, base, your position, ranges, alerts, sound, redstone, power, hardware, environment, contacts, recent alerts |
| `2` | **Radar** | Polar scope with range rings, a rotating sweep, and colour-coded blips |
| `3` | **Flight** | Speed, climb rate, heading, course, altitude and the way home |
| `4` | **Contacts** | Table of every contact — distance, bearing, altitude, band, position, health |
| `5` | **Weather** | Live sky and biome scenery, big clock, day number, moon phase, light levels |
| `6` | **Power** | Supply, demand and net, a buffer gauge, and a rolling graph |
| `7` | **Alerts** | Arrivals and alarms, newest first, plus a visitor tally on wide screens |
| `8` | **Settings** | An index of eight groups, each opening onto one screen — see [Settings](#settings) |

The number keys follow the tab strip rather than a fixed table, so switching a
module off does not leave a hole in the numbering. Monitors can show any page
except Settings — a monitor has no keyboard, and that page is mostly typing.

### On a 1×1 monitor

A 1×1 advanced monitor at text scale 0.5 is **fifteen cells across and ten
down**, and there is no room for a tab strip — so nine rows of content. Below
twenty cells wide every page stops being a smaller version of the big one and
draws a **different, shorter thing**: no heading of its own (the header carries
the page name instead), no separator rule, short labels, and only what is worth
a glance.

| Page | What a 1×1 gets |
|---|---|
| **Status** | link, contacts, speed, altitude, power, time, alerts — the things that change on their own. The range, tracking mode and bearing-up are settings, and settings do not surprise you |
| **Flight** | all eight instruments; it is designed for this size first |
| **Contacts** | names and distances, hard against both edges |
| **Weather** | six rows of sky, then clock, conditions, biome — and the buffer percentage hard right, when there is a power reading to have |
| **Power** | percentage, gauge, net rate, and the rest given to the graph |
| **Alerts** | clock and what happened, nine entries deep |

```
      SYS        ! 2        FLT          2        WX      11:12  *
      LINK    Hangar        SPD       15.2        Clear
      CONTACT      2        VS        +3.0        Snowy Taiga 30%
      UNREAD       1        HDG     210 SW
      SPD       15.2        CRS     067 NE
      ALT       3204        ALT       3204
      PWR        30%        HOME      142m
      TIME     11:12        BRG         SW
      ALERTS      on        ETA         9s
```

The `!` in the header is the unread-alert marker, and it is on **every** screen
until the alerts are dismissed — see [Alerts](#alerts-and-the-alert-log).

---

## Modules

A module is **one file** in `radar/modules/` that returns one descriptor table.
It owns a page, whatever settings that page needs, whatever hardware it wants
to claim, and whatever background work keeps it fed.

Every page ships as a module, including the ones that were built in before v7,
so there is one mechanism rather than a core set plus an add-on set that drift
apart. Switch them on and off under **Settings → Modules**; turning one off
removes its page, its tab, its settings section *and* its polling, so a pocket
computer is not paying for a Power page it has nothing to wire to.

### Writing one

```lua
-- radar/modules/mything.lua
local theme = require("radar.theme")

return {
  id = "mything",
  title = "MY THING",
  short = "MYT",
  order = 55,                       -- position in the tab strip
  summary = "one line, shown in the module picker",

  defaults = { myThingRate = 5 },   -- merged into the settings file
  sanitise = function(cfg)          -- forced back into range on load
    cfg.myThingRate = math.max(1, math.min(60, cfg.myThingRate))
  end,

  discover = function(kit)          -- claim peripherals off kit.peripherals
    for _, entry in ipairs(kit.peripherals) do
      if type(entry.dev.getWhatever) == "function" then kit.myThing = entry.dev end
    end
  end,

  attach = function(app) app.myThing = { readings = {} } end,

  start = function(app)             -- background loops, as Basalt schedules
    require("basalt").schedule(function()
      while app.running do
        sleep(app.cfg.myThingRate)
        app:emit("mything")
      end
    end)
  end,
  events = { "mything" },           -- redraw the page when this fires

  settings = function(ctx)          -- your own settings section
    ctx.heading("MY THING")
    ctx.row("Rate", function() return ctx.app.cfg.myThingRate .. "s" end, function()
      ctx.app.cfg.myThingRate = ctx.app.cfg.myThingRate + 1
      ctx.app:saveConfig()
    end)
  end,

  build = function(container, app, root)   -- the page itself
    local canvas = container:addCanvas({
      x = 1, y = 1,
      width = function(s) return s.parent.width end,
      height = function(s) return s.parent.height end,
      background = theme.bg,
    })
    canvas.draw = function(self, buf)
      buf:fill(1, 1, self.width, self.height, " ", theme.text, theme.bg)
      buf:blit(2, 1, "hello", theme.accent, theme.bg)
    end
    return { refresh = function() canvas:markRenderDirty() end }
  end,
}
```

Everything except `id` is optional. A module with no `build` is a **service**
rather than a page: it can claim hardware, add settings and run loops without
ever appearing in the tab strip. A module whose id matches a shipped one
**replaces** it, which is how a pack overrides a built-in page.

| Field | |
|---|---|
| `id` | unique; the page id, the settings key, the file name |
| `title` / `short` | tab labels, wide and narrow |
| `order` | position in the tab strip; built-ins leave gaps of 10 |
| `core` | cannot be switched off (Status and Settings) |
| `monitor` | may be shown on a monitor; `false` = terminal only |
| `defaults` / `sanitise` | settings keys, and how to repair them |
| `discover` / `attach` | claim hardware; hang state off `app` |
| `start` / `events` | background loops, and what redraws the page |
| `settings` | its own section of the settings page |
| `build` | the page |
| `keys` | extra keyboard shortcuts |

Views never touch a peripheral. They read `app` and subscribe to events —
`scan`, `env`, `anim`, `heading`, `config`, `backdrop`, `modules`, plus
whatever a module emits — which keeps rendering independent of how often the
hardware is polled. It is also why the MOBILE role needed no view changes at
all: `radar/link.lua` fills the same tables and fires the same events from the
network that `radar/scan.lua` fills them from a detector, and nothing
downstream can tell which it is looking at.

**Add a module, add its path to `manifest.txt`**, or the installer will not
fetch it and the page will silently not exist. `preview/install-test.lua`
checks for exactly that.

---

## Flight

An instrument panel worked out from one thing: **where the pilot is, sampled
over time**. Every sweep already produces a position — read locally, or relayed
by the main base — so differentiating that against the clock gives ground
speed, climb rate and course over ground for nothing. No extra peripheral, no
extra server calls, and a full panel on a computer carrying only a modem.

| | |
|---|---|
| `SPD` | ground speed, blocks per second |
| `VS` | vertical speed — climb positive, descent negative |
| `HDG` | **heading**: the way you are looking, as `210 SW` |
| `CRS` | **course**: the way you are actually going, the same way |
| `DFT` | the angle between them, on screens with room for it |
| `ALT` | altitude |
| `HOME` `BRG` `ETA` | distance, compass bearing and time to the destination |

Showing both `HDG` and `CRS` is the point of it: on an airship being pushed
sideways they differ, and the gap is the drift. Both carry their compass point,
because reading a heading off a number takes a moment and off `SW` it does not.

### Where you are going

**Settings → Flight → Destination** picks one of three, and the row is
relabelled to match:

| | |
|---|---|
| `HOME` | the base coordinates under *Tracking* |
| a **contact** | anyone on the contact list, chosen by name. Re-read on every draw, so the panel **follows them as they move** — and says `lost` rather than quietly falling back to home if they leave the sweep |
| `WPT` | coordinates you type in |

On a MOBILE the base coordinates **come from the main base itself** — see
below — so `HOME` points at somewhere real without anything being kept in step
by hand.

There are two ways in that need no keyboard at all, which is what a monitor on
an airship has:

- **Press a name on the CONTACTS page** and they become the destination. It is
  a list you are already reading, so choosing a chase target is a matter of
  recognising the name rather than typing it into a picker.
- **Press the destination on the FLIGHT page** and it swaps between `HOME` and
  the waypoint — those two only. A contact was chosen deliberately off the
  contact list, so it drops straight back to `HOME` rather than being one more
  stop in the cycle. On a screen with room the button is on the bottom row as
  `[ HOME ]` or `[ WPT ]`; on a 1×1 the destination row itself is the button.
- **`[ MARK ]` drops the waypoint where you are standing** and flies to it.
  That is the confirmation as well as the action: a monitor has no banner to
  tell you it worked, so the panel changing to `WPT` in front of you is how you
  know. It is **not** on a 1×1 — eight cells of button is half that screen —
  and needs about thirty cells of width before it appears.

Typed-in coordinates are still under **Settings → Flight → Waypoint XYZ**;
`[ MARK ]` is the version that works on a monitor, which has no keyboard.

A press that does either of those does **not** also move a monitor to the next
page: the page gets first refusal on a tap, and only what it does not claim
falls through to *Tap to change*.

### Autopilot

With a **CC:Tweaked Redstone Relay** attached, the flight page grows an `A/P`
row that flies the ship to whatever the destination is — `HOME`, a tracked
contact, or a waypoint.

Two of the relay's sides carry the thruster groups — one left, one right,
usually through a redstone link at each. The thrusters take a **signal
strength of 0 to 15**, and that is what the autopilot writes.

It is the relay rather than the computer's own sides on purpose: the computer
has **one** redstone output and the alert system already owns it
(*Settings → Alerts → Redstone output*). Two subsystems driving one line would
be a fault you could not see from either page.

```
   FLT           2      FLT           2      FLT           2
   A/P       find       A/P       -180       A/P         +0
   SPD        0.0       SPD       12.0       SPD       12.0
   VS         0.0       VS         0.0       VS         0.0
   HDG     225 SW       HDG     225 SW       HDG     225 SW
   CRS        ---       CRS      090 E       CRS      270 W
   ALT         70       ALT         70       ALT         70
   HOME      600m       HOME      660m       HOME      540m
   BRG          W       BRG          W       BRG          W
   ETA         --       ETA        55s       ETA        45s

  L 0.60 R 0.60        L 0.00 R 0.84        L 0.60 R 0.60
  finding course       turning around       on course
```

**The `A/P` row is drawn first and is a button.** Press it to engage or
disengage. That is deliberate: nine rows is exactly what this panel fills, and
on a 1×1 monitor — no keyboard, no settings page — that row is the only switch
there is, so it must never be the one that gets clipped.

Note `HDG 225 SW` in all three columns above. The pilot is facing south-west
throughout while the ship flies west. That is the point:

#### It steers by where the ship has been, not where you are looking

The control law is **never given a heading**. It takes a `CRS` — the course
made good, derived from the ship's own position changing over time — and
nothing else. A computer can read which way the *pilot* is facing, and on a
vessel that is not which way the *ship* is going; someone turning to look over
the rail would otherwise steer the boat.

The cost is that a stationary ship has no course at all, so engaging opens with
a **probe**: both sides equally, straight ahead, until it is moving fast enough
for a course to exist. Then it steers. If nothing moves after eight seconds of
that, the thrusters are not wired to the inputs it was given and it says so
rather than pushing forever.

#### Steering

**More thrust on the left swings the nose to the right**, so the error — the
signed angle from the course being made to the bearing wanted — is added to the
left and taken off the right. If it turns the wrong way, the sides are the
wrong way round; there is a *Swap left and right* button for exactly that.

The control law works in a dimensionless `0..1` throttle and only becomes a
redstone level on the way out, so the quantising happens in one place. Anything
above zero comes out as **at least 1**: rounding a real command down to *off*
would make a thruster meant to be idling indistinguishable from one that has
been cut, and only one of those is a decision.

Sixteen levels is all redstone has, so a correction finer than about 7% of
cruise cannot be expressed. That is what the 5° deadband is for anyway.

Three softeners matter, because a position fix arrives about once a second:

| | |
|---|---|
| **deadband** | errors under 5° are not chased — a fix a second apart cannot resolve them and steering for them just twitches the ship |
| **turn brake** | up to 60% of cruise is given up at full deflection, because a vessel at full ahead in the wrong direction is going the wrong way faster |
| **slew limit** | outputs walk to their new values rather than slamming, which a heavy contraption cannot follow anyway |

**Cutting the throttle is never slewed.** Everything that stops the autopilot
is a reason to stop now.

#### It gives up loudly

| Phase | Shown | What happened |
|---|---|---|
| `probe` | `find` | moving off to find which way it points |
| `steer` | `+12` | flying, showing the course error in degrees |
| `arrived` | `there` | inside the arrive radius; thrusters off, **still engaged**, so a moving contact can pull it going again |
| `stalled` | `STALL` | pushed for eight seconds with no movement — check the inputs |
| `nofix` | `no fix` | the position feed stopped: link lost, base unloaded, username stopped resolving |
| `lost` | `lost` | the contact being chased left the sweep |
| `toofar` | `far` | the destination is beyond the shut-off range |

The last four **cut the thrusters, disengage, and go in the alert log** — so
they put the `!` marker on every screen and ring whatever channels are on.

#### Settings

Under **Settings → Pages → Flight → Autopilot**:

| | |
|---|---|
| **Relay** | which peripheral, matched on the methods it answers to rather than its type name |
| **Left / Right thrusters** | which side of the relay each group is wired to |
| **Swap left and right** | for when they are backwards |
| **Cruise** | throttle in level flight |
| **Turn response** | how hard it corrects — `Sharp` on a heavy ship will hunt |
| **Arrive within** | how close is close enough |
| **Ease off within** | where it starts throttling back so it stops rather than sailing past |
| **Shut off beyond** | 250 / 500 / **1000** / 2500 / 5000 blocks, or no limit |
| **Test left / right thrusters** | a one-second pulse on one side at cruise level, to check the wiring without engaging |

**Shut off beyond** is checked on **every pass**, not only when engaging: a
contact who logs back in on the far side of the world moves the destination,
not the ship.

#### What it will not do

- **No altitude control.** It holds whatever height you are at.
- **No obstacle avoidance** of any kind.
- **Engagement is never persisted.** A chunk reload or a reboot mid-flight
  comes back with the thrusters off. "Was flying somewhere" is not a thing that
  should survive a restart with nobody present.
- **Quitting the station cuts the thrusters**, before anything else is torn
  down. A ship still under power with nothing left running to steer it is the
  one outcome worth writing code to prevent.

### What it cannot know

- **It is the pilot's position, not the ship's.** Walking the deck reads as a
  couple of blocks a second; step off entirely and the panel follows *you*.
  That caveat has always applied to the status page — it is just more visible
  on a page about motion.
- **There is no pitch or roll.** `getPlayerPos` gives a yaw and nothing else.
- **The sample rate is the sweep interval**, so a reading is an average over
  the last few seconds rather than an instant. Speeds are smoothed for exactly
  that reason: computed raw from two fixes a second apart they jitter far too
  much to read while flying.
- A teleport, a portal or a chunk reload **throws the history away** rather
  than reporting several thousand blocks a second.

It needs your **username** set, since that is what a position is read against.
On by default for the POCKET and AIRSHIP profiles, off for the MAIN BASE — a
station that never moves would show a page of zeroes.

---

## Power

An Advanced Peripherals **Energy Detector** sits inline in a cable and reports
a transfer rate, so one on the main bus is a live FE/t readout for nothing.
What it cannot tell you is how much is **banked** — so anything directly
wrappable that reports stored and capacity is read too, and the page shows both.

![Six power graphs: a healthy base, a furnace array switching on, a buffer under the alarm threshold, a reactor charging back up, an idle grid, and rate-only with no battery](preview/power-graph.png)

| | |
|---|---|
| **Rates** | supply, demand and the net, summed from every meter |
| **Buffer** | a sub-pixel gauge with the alarm threshold marked on it, plus stored / capacity |
| **Graph** | a rolling 1–15 minute line chart of supply and demand, with the buffer as a filled backdrop behind them |
| **Footer** | time to empty or full at the current rate, and how many devices are being read |

Each device is told whether it measures **supply** or **demand** under
*Settings → Power → Devices*; a meter with no role assigned counts as supply,
because one detector on the main bus is usually measuring what is coming in.
An Energy Detector's **transfer limit** can be set from the same picker — the
one thing here that changes the world rather than reporting on it, so it never
happens on a poll.

**With no meter anywhere**, the change in stored energy *is* the net rate. It
is coarser — it cannot separate supply from demand, only the balance — but it
is the difference between a useful page and an empty one on a base whose only
energy peripheral is its battery.

### The alarm, and the redstone

A buffer falling below the threshold fires the **ordinary alert channels**: the
same sound, screen flash and redstone pulse a contact arriving does, on
whichever of them you have switched on. It fires **once per crossing**, with
hysteresis, so a buffer sitting exactly on the line does not chatter.

**Settings → Redstone Output → Mode → Buffer** maps strength 1–15 to how full
the bank is, exactly as *Analog* maps 1–15 to how close a contact is. That
drives a fuel gate or starts a backup generator off the one output line the
computer has. An unreadable buffer holds the last level rather than dropping —
a fuel gate that opens the moment a chunk unloads is worse than one that does
not move.

### Power clients

A **power client** is a computer wired to energy hardware somewhere that is not
the main base — a reactor room, a battery bank, a furnace hall. It reads its
meters and batteries and broadcasts the readings; the main base merges every
client with its own hardware, graphs the total, and relays it to the mobiles.

```
powerclient                     -- named after the computer id
powerclient "Reactor room"      -- or give it a name the base will show
```

Install one with `--client`, which sets it to launch on boot and skips Basalt —
a client is a sensor, not a screen:

```
wget run https://raw.githubusercontent.com/Doom6197/CC-Radar-Station/main/install.lua --client
```

It needs a modem and at least one Energy Detector or battery. **No** Player
Detector, no monitor, no Basalt. It draws a plain status readout so you can see
at a glance that it is being heard.

| Key | |
|---|---|
| `R` | **rename it** — this is the name the main base shows against its readings |
| `B` | point it at a different main base |
| `Q` | stop |

Both are remembered in `powerclient.cfg` next to the program, so they are set
once. A name on the command line is a deliberate rename and sticks too.

### Which base a client reports to

On a shared server there may be several unrelated main bases, each with their
own clients. A client that shouted its readings to the whole world would put
everybody's power into everybody's graph — so on first run it **listens for
main bases announcing themselves, asks which one is yours**, and from then on
addresses that computer directly. Nobody else receives it.

The payload also carries the id of the base it was meant for, so a base ignores
readings that were never meant for it even if it does hear them. *Any main base
(broadcast)* is offered as well, for a single-player world where there is
nothing to collide with.

Run as many as you like. They are merged by computer id, so:

- a client that stops reporting **drops out on its own** after about fifteen
  seconds — a reactor whose chunk has unloaded stops being counted as supply
  rather than being reported as power that is not being generated;
- two clients with a peripheral of the same name do not collide, because a
  device's role is stored against the computer that reported it;
- **only raw readings travel.** Which meter counts as supply and which as demand
  is decided on the main base, under *Settings → Power → Devices*, so it is one
  decision in one place rather than one per client.

The main base needs the **MAIN BASE** role for this: the modem has to be open,
and a STANDALONE station deliberately never opens one.

### Which mods work, and what units they answer in

Matching is on **method name**, never on peripheral type, so nothing here
depends on a mod being installed. A block answering `getEnergy()` and
`getMaxEnergy()` is a battery whatever it came from — which covers the
Mekanism induction matrix, Powah cells and Flux Networks points among others,
including spellings this was never tested against.

Mods do not agree on what the number *means*. Most quote Forge Energy;
**Mekanism quotes Joules**, and its API keeps doing so whatever the client is
set to display. A Basic Energy Cube holding 1.6 MFE answers `getMaxEnergy()`
with `4000000`, because Mekanism uses **2.5 J to the FE** — so reading it as FE
overstates it by exactly two and a half times.

Every device is therefore read raw and scaled per device on the way into the
totals, so one grid can mix a Mekanism matrix with an Energy Detector and still
add up. The unit is guessed from the methods the peripheral offers — a
Forge-style `getEnergyCapacity()` means Forge Energy; Mekanism-only calls mean
Joules — and it is **shown against the device** under
*Settings → Power → Devices*, where you can correct it. Guessing wrong by 2.5×
is exactly the kind of error that looks plausible until you check it, so it is
never silent.

*Settings → Power → Units* is a separate thing: the **label** printed after the
numbers, for whichever of FE / RF / J / E you recognise.

---

## Weather and backdrops

The sky is **generated from the live snapshot**, not chosen from stock
pictures. As the Minecraft day runs:

- the sun climbs its arc and sets in the west, and the moon takes over after
  dusk, drawn at its **real phase** (all eight);
- the palette moves through **dawn → day → dusk → night**;
- **rain** slants, **snow** drifts, **thunderstorms** wash the sky white behind
  a forked bolt;
- clouds drift in parallax layers;
- snow instead of rain in cold biomes, and dry biomes correctly show clear
  skies while it rains elsewhere.

![Sky scenes: sunrise, morning, noon, sunset, moonlit night, rain, thunderstorm, snow and the Nether](preview/sky-scenes.png)

All eight moon phases, drawn from `getMoonId()`:

![Full, waning gibbous, last quarter, waning crescent, new, waxing crescent, first quarter, waxing gibbous](preview/moon-phases.png)

### Biome scenery

The ground under the sky comes from the biome the Environment Detector reports.
A profile picks three things independently — a **terrain silhouette**, a kind of
**plant**, and three **colours** — so thirty-odd biomes are covered without
thirty-odd bespoke pictures.

![Thirty biome scenes](preview/biomes.png)

The colours are written once, as they look at midday, and everything else is
derived: dawn and dusk warm them, night drains them, rain and storms grey them
out, and settling snow whitens the ground whatever it started as.

![The same forest at dawn, noon, dusk, night, in rain and in a storm, then snowy taiga by day and night, then floating islands](preview/biome-moods.png)

![Nether wastes, crimson forest, warped forest, soul sand valley, basalt deltas, and the End](preview/biomes-dimensions.png)

**Modded biomes** are matched on name, most specific first, so
`somemod:frozen_highlands` still lands on snowy peaks. Anything unrecognised
falls back to plains rather than to nothing. If your pack reports a biome the
station reads wrongly, force the scenery under
**Settings → Environment → Scenery**.

### Backdrops — a place and a sky

On a pack where every dimension is floating islands and you live on an airship,
the live sky is often wrong or missing entirely: **a contraption is not made of
world blocks**, so a detector riding on one has nothing to report.

A **backdrop** is a scene chosen by hand instead. It has two halves, picked
separately:

| | |
|---|---|
| the **place** | which ground gets drawn — the archipelago, a cloud sea, airships, spires |
| the **sky** | the hour, weather and sun: either baked into the picture, or taken live from the detector |

![Twenty backdrops](preview/backdrops.png)

Set it under **Settings → Backdrop**: `Live` draws the real sky (the default),
`Cycle` walks a set on a timer from 10 seconds to 30 minutes, or name one and
it stays.

Set **Sky** to `Live` and the picture keeps only its **place** — the hour, the
weather, the sun's position, the moon's phase and the dimension all come from
the detector, and the ground is lit to match:

![One airship picture under twelve live skies](preview/backdrops-live.png)

Two things follow from *where you actually are* rather than from the picture:
**whether it can rain at all** and **whether that falls as snow** (an airship is
not a climate — so it snows over a taiga and stays clear over a desert), and
**the dimension**.

**A backdrop replaces only the picture.** The readout beneath it, the badge in
the header and the status page all carry on reporting what the detector
actually says, so a sunset backdrop over a real thunderstorm still shows
`STORM`. Nothing on screen lies about the weather because you chose a nicer sky.

With no detector there is no live sky to follow, so the picture quietly falls
back to the hour it was drawn with — which is what keeps this working on a ship.

---

## Orientation: locked or unlocked

**Locked** (the default) keeps a bearing of your choosing at the top of the
scope — the right thing for a monitor bolted to a wall.

**Unlocked** turns the whole picture with you. The station reads your yaw, puts
whatever you are looking at at the top, marks it with a lubber line, and the
readout switches to `HDG 227`. Press `L`, or use
**Settings → Orientation → Scope**.

This needs your **username**, because the yaw comes from reading your own
player position. With no username the scope says `HDG --` and falls back to the
locked bearing rather than pretending to have a fix.

| | |
|---|---|
| **Heading steps** | smooth free rotation, or snap to 5° / 15° / 45° / 90°. Snapping to 45° gives a stable eight-point compass that does not shimmer while you look around. |
| **Heading rate** | how often the yaw is re-read — 0.25 to 2 seconds. One detector call, and the loop idles entirely while the scope is locked. |
| **Ease turns** | slide into a turn instead of jumping. Needs animation on. |

Bearings, distances and the N/NE/E labels stay true compass values throughout.
Only the picture turns.

---

## The network: main base, mobiles and power clients

Three kinds of computer, one modem network:

| Role | What it is |
|---|---|
| **MAIN BASE** | the master. It holds the Player Detector, the Environment Detector and the monitors, does all the scanning, and feeds everything else. Keep it **chunk loaded**, or it goes quiet the moment you walk away. |
| **MOBILE** | a pocket computer or a vehicle: a modem and a screen, drawing what the main base sends it. No detector, no GPS. |
| **STANDALONE** | one computer, no network. The fallback when there is no modem; it opens nothing and sends nothing. |

Plus **power clients** — see [below](#power-clients) — which are not radar
installs at all, just computers reporting what their energy hardware reads.

```
   power clients                 MAIN BASE                    mobiles
  ┌───────────────┐           ┌──────────────────┐        ┌──────────────────┐
  │ Energy Detect │  readings │ Player Detector  │ sweep  │ pocket computer  │
  │ batteries     │ ────────► │ Environment Det. │ ─────► │ airship          │
  │ modem         │           │ monitors, modem  │ power  │ modem, no sensors│
  └───────────────┘           │ CHUNK LOADED     │ weather└──────────────────┘
       (many)                 └──────────────────┘
```

### Why a mobile cannot scan for itself

Create: Aeronautics assembles a structure into a **contraption**. While it is
assembled its blocks live in a proxy level rather than in the world, so anything
that asks a question about a real block position gets nothing back. The computer
keeps running, `peripheral.getNames()` still lists the detector, and
`getPlayersInRange()` returns an **empty list** the whole time you are flying. A
pocket computer has the same problem for a simpler reason: there is nowhere to
bolt a detector to it.

`getPlayerPos(name)` is different: it looks up an **entity by name**. A Player
Detector on the ground can therefore read you wherever you have got to —
including three thousand blocks up, aboard a ship.

So the detecting is done on the ground and the picture is sent. Because the main
base runs in **SELF** mode — centred on you rather than on a fixed point — every
distance and bearing it computes is already relative to you. Nothing is
recalculated for being airborne.

### Setting it up

**On the main base**

1. Pick the **MAIN BASE** profile on first boot, or *Settings → Link → Role* →
   **MAIN BASE**.
2. Give it a name under *Station name* — this is what mobiles see.
3. Set *Tracking → Mode* to **SELF** and your *Username*.
4. Attach a wireless or ender modem, and chunk-load the computer.

**On each mobile**

1. A computer, an **ender modem** and a screen. Pick the **POCKET** or
   **AIRSHIP / VEHICLE** profile on first boot and it takes the MOBILE role.
2. Press **Scan for base stations**, and pick yours.

A mobile accepts traffic **only** from the computer id it was paired with, so
several crews can share one world. The main base never needs to know who is
listening, and announces itself whether or not anyone is.

### What travels

| | |
|---|---|
| **Contacts** | always. Only positions — distance, bearing, altitude band and colour are rebuilt at the far end by the same code that computes them locally. |
| **Where the base is** | always. A mobile has no other way of knowing, and was otherwise left with whatever was in its own settings file — `0, 64, 0` on a fresh install, which points *home* at the world origin. It lands in the ordinary base coordinates, so the status page and the flight page need no special case. Turn it off with *Settings → Tracking → Follow base*. |
| **Weather** | *Settings → Link → Relay weather*. Only the raw detector readings; the sky, palette and scenery are rebuilt on the mobile from the same code, so the page is identical without a pixel crossing the network. Off by default. |
| **Power** | *Settings → Pages → Power → Relay power*. The merged totals from the main base and every power client. On by default. |
| **Who the base is watching** | always. It is the one player who is *not* in the contact list, and a mobile needs to know that in order to find its own pilot. |

### Every station measures for itself

Nothing derived travels — the wire carries raw positions and each station works
out its own distances, bearings and bands from them with the same code a local
sweep uses. That is what makes **Tracking → Mode a mobile's own choice** rather
than the base's:

| Mobile's mode | It measures from |
|---|---|
| **FIXED** | its own base coordinates — which *Follow base* keeps in step with the main base |
| **SELF** | **you**, wherever the main base happens to be |

`SELF` needs a **username the main base can see**, since your position is read
by the base's detector, not by the mobile. If it cannot find you the mobile
says so and **draws nothing** — being quietly measured from the wrong place is
the failure this replaced.

Two crews can share one base: it watches its owner and relays everybody's
position, and each pocket computer picks its own pilot out of that.

### When the link drops

If nothing arrives for roughly two of the main base's sweep intervals, a mobile
treats the link as lost. It **clears the scope** and says so — a stale picture
drawn as though it were live is worse than an empty one.

| What you see | What it means |
|---|---|
| `Waiting for <name>` | paired, but that base has not spoken yet |
| `Link lost - nothing from <name>` | it has gone quiet, or you have flown out of range |
| `No main base paired` | pick one with *Scan for base stations* |
| `No modem - a MOBILE needs one` | attach a modem and press *Modem* to rescan |

### Notes

- **STANDALONE opens no modem and sends nothing.** A computer with no interest
  in the network never touches it. That is also why collecting power clients
  means being a MAIN BASE rather than a standalone with a flag set.
- A **MAIN BASE is a fully working radar in its own right** — its own screens,
  alerts, alert log and redstone, whether or not anything is ever paired to it.
- **A mobile's tracking mode is its own.** The main base sends positions, not
  distances, so `SELF` on a pocket computer measures from the pilot even while
  the base it is paired to is measuring from a fixed point kilometres away.
- **A mobile carries no position source.** Everything it draws is *your*
  position as read by the main base. Leave a ship on autopilot and walk away and
  the status page follows **you**, not the ship. There is deliberately no GPS
  fallback.

---

## Alerts and the alert log

The **ALERTS** page is the record of everything the station has had to tell
you, newest first. Two kinds of entry go in it:

| Kind | Written when |
|---|---|
| **arrival** | a contact appears that was not on the previous sweep |
| **alarm** | a module raises one — at present, the power buffer crossing the low threshold |

Both also appear in **RECENT** on the status page, which is the other place
anyone looks to find out what happened while they were away. Before v8.4 the
page was called LOG and took arrivals only, so a buffer that emptied overnight
left no trace anywhere.

### The unread marker

Every entry is **unread** until it has been looked at, and while anything is
unread every screen carries a `!` in its header — the radar, the weather, a
monitor on the far wall, all of them. That is the whole point of it: the marker
has to be visible from whatever you happened to be looking at.

It goes **first** in the header, so truncating a narrow header can never be
what takes it off.

**Opening the ALERTS page on the terminal dismisses them.** A monitor showing
the page does not — a monitor walking its rotation would otherwise clear the
marker with nobody in the room. *Settings → Alert log → Dismiss unread alerts*
does it explicitly, and `C` clears the whole log.

Unread state is stored on the entry rather than as a running total, so a
restart cannot lose track of which ones had been seen.

### The chime

An arrival **outside the alert range** is logged but does not set the alarm
off, and without a sound the first anyone knows of it is the next time they
happen to look at a screen. So anything that goes unread **without** ringing
the alarm gets one note, once, at half volume — *Settings → Alerts → Unread
chime*.

It never doubles up: if the alarm fired for that same event, the chime does
not. A muted station is silent either way — muting silences the alarm, it does
not mean the entry is not written down.

---

## Keyboard and monitors

```
1..9       jump to a page, in tab-strip order
Left/Right previous / next page
Up/Down    scan range up / down
R          rotate the picture 45 degrees
L          lock / unlock the scope orientation
T          toggle FIXED / SELF tracking
A          mute or unmute alerts
P          test the alert sound
N          ignore the nearest contact
B          set the base to your current position
C          clear the alert log
Q          quit
```

Monitors have no keyboard, so the screen is the control:

- **Right-click a monitor** (a *use*, which arrives as a `monitor_touch`) to
  move it to the next page. Turn this off under
  **Settings → Displays → Tap to change**.
- **A page gets first refusal on a tap.** Pressing a name on CONTACTS makes
  them the flight destination; pressing the destination on FLIGHT swaps
  between `HOME` and the waypoint, and `[ MARK ]` drops the waypoint where you
  are. None of those also move the monitor along. Everything else falls
  through to the page change above.
- Monitors big enough for a tab strip can be pressed on a tab to jump straight
  to that page.
- **Auto-cycle** walks a monitor through its pages on a timer — per monitor,
  5 seconds to 5 minutes, with a chosen set of pages. Right-clicking gives you a
  fresh interval so you are never yanked off a page mid-glance.

The page a monitor cycles to is deliberately not saved: on restart every monitor
returns to the page you chose for it.

---

## Project layout

```
radar.lua              entry point: paths, preflight checks, first boot, shutdown
radar/
  modules.lua          THE REGISTRY: what a module is, and how one gets found
  modules/
    status.lua         the dashboard                            (core)
    radar.lua          the polar scope
    contacts.lua       the contact table
    weather.lua        live sky, scenery, and the backdrop cycle
    power.lua          rates, buffer and the rolling graph
    alerts.lua         arrivals and alarms, and the unread marker
    settings.lua       the settings index and its groups              (core)

  app.lua              shared state, background loops, actions
  ui.lua               Basalt roots, header, tab strip, page router, keys
  config.lua           settings schema, defaults, migration, persistence
  profiles.lua         base / pocket / vehicle, and what each sets up
  setup.lua            the first-boot chooser
  hardware.lua         peripheral discovery by capability

  scan.lua             Player Detector -> contact list
  link.lua             the network: pairing, relay, staleness, module protocols
  environment.lua      Environment Detector -> snapshot + scene description
  power.lua            energy peripherals -> rates, buffer, history, alarms
  autopilot.lua        the autopilot's control law: differential thrust
  biomes.lua           biome id -> ground profile, and its colours by mood
  backdrops.lua        hand-picked scenes for the weather page, and the cycle
  alerts.lua           sound, redstone and flash; the shared alarm channels
  logbook.lua          detection history and visitor stats

  theme.lua            colour palettes (chrome + sky + derived ground)
  pixel.lua            2x3 sub-pixel drawing surface
  chart.lua            line charts and gauges on that surface
  glyphs.lua           3x5 bitmap font for the big clock
  sky.lua              procedural sky, weather, terrain and flora painter
  util.lua             maths, bearings, headings, formatting

powerclient.lua        the power client: reads energy hardware, reports it
install.lua            in-game installer
manifest.txt           the file list it downloads
IDEAS.md               where this could go next
preview/               desktop-only: rendered sheets and the tools that make them
```

Only `radar.lua` and `radar/` end up on the computer.

---

## Development

Everything runs on a desktop Lua 5.x, with no Minecraft and no network:

```
lua preview/smoke-test.lua .        # 139 checks
lua preview/install-test.lua .      # 16 checks
lua preview/render-preview.lua . preview
```

**`smoke-test.lua`** stubs CC: Tweaked and Basalt, then drives every page at
seven screen sizes across five scenarios and presses every button on the
settings page. It paints **every biome** and **every backdrop** at six sizes in
every weather and every hour, and reads the pixel grid back afterwards to prove
no painter leaves a hole in the ground — `blitTo` silently substitutes a palette
entry for an unpainted sub-pixel, so a gap would otherwise only show up in game.

rednet is stubbed as a loopback, so the whole network is exercised: a main base
broadcasting after a sweep, a mobile rebuilding that sweep and comparing it
**field for field** against the one the base drew, pairing, refusing an unpaired
sender, a silent base being called lost, and the weather relay.

`powerclient.lua` is run as a real program against the same mocks, and what it
puts on the wire is fed straight into the main base's handler -- so the client
and the base cannot drift apart on the payload format without failing here.

The module system is tested by **registering a synthetic module before the app
is built** — so it goes through the whole machine exactly as a dropped-in file
does: its defaults reach the settings file, its `discover()` claims hardware,
its page joins the tab strip and is drawn at every size, its settings section is
built and pressed, and switching it off takes all of that away again.

**`render-preview.lua`** compiles the real pixel grid into teletext cells
exactly as the game will, then expands each cell back into its two surviving
colours — so the sheets in `preview/` are what the monitor shows, not a mock-up.
It writes PNGs directly, with its own CRC32, Adler32 and deflate encoder, so it
depends on nothing but the drawing code it exists to exercise.

### Colours

Basalt maps custom RGB colours onto the 16 hardware palette slots per terminal,
per frame. The station budgets nine chrome colours and ten scene colours, of
which only three change with the biome. Check that before adding colours to a
page. On a *non-advanced* computer or monitor there is no palette control at
all and every colour falls back to the nearest of the sixteen defaults —
everything still renders, just flatter.

### Gotchas

- **`getPlayersInRange()` is always centred on the Player Detector block.**
  FIXED changes only what distances are measured *from*, so put the detector at
  the base and point the base coordinates at it.
- **MAX range** is capped by the server's `playerDetMaxRange` in
  `advancedperipherals-server.toml`. Set it to `-1` for no limit.
- **`getPlayerPos` may be disabled** by the server's `playerSpy` option, and
  some servers add random error at long range. The radar reports what it is
  given.
- **Aboard a contraption nothing block-based answers.** That is what the MAIN
  BASE and MOBILE roles are for, and why backdrops exist.

---

## Version history

**v8.8 - the autopilot drives a redstone relay.** The contraption controller
is gone. The thruster groups are now two sides of a **CC:Tweaked Redstone
Relay**, carrying a signal strength of **0 to 15** -- not the computer's own
sides, which the alert output already owns.

**v8.7 - autopilot.** The flight page flies the ship to its destination on
**differential thrust**: left and right thruster groups, steered by the
**course made good** and never by which way the pilot is facing. Engaging opens with a probe,
because a stationary ship has no course to steer by. An `A/P` row on the 1x1
flight screen is the switch. A **shut-off range**, a stall detector, a stale-fix
watchdog and a shutdown hook all cut the thrusters and say why in the alert log.
No altitude control, no obstacle avoidance, and engagement is never persisted.

**v8.6 - a mobile measures for itself.** A MOBILE used the centre the main
base had worked out from ITS settings, whatever the mobile's own tracking mode
said -- so a pocket computer or airship set to **SELF** reported everyone's
distance **from the base**, and somebody standing next to you read as six
kilometres away. Every station now decides its own centre from the raw
positions on the wire: `SELF` measures from the pilot, `FIXED` from that
station's own base coordinates. A mobile also finds **its own** pilot rather
than the base operator's, takes their heading, and leaves them out of its own
contact list. `SELF` with nobody to find says so and draws nothing.

**v8.5 - the settings page, reorganised.** One scrolling page of 17 sections,
85 controls and 99 notes -- 231 rows, fourteen screenfuls -- became an **index
of eight groups**, each opening onto one screen and each showing its current
state on the index. Thirteen of the eighteen screens now fit without scrolling.
A module's ON/OFF switch and its settings are **on the same screen** instead of
a hundred rows apart; `Alert within` moved from SCANNING to ALERTS where it
belongs; and the notes are **off by default**, with warnings shown either way.
Nothing was removed.

**v8.4.** LOG became **ALERTS** and now takes alarms as well as arrivals, so a
power buffer that emptied overnight leaves a trace instead of vanishing. Unread
entries put a `!` in **every screen's header** until they are dismissed, and
anything that goes unread without ringing the alarm gets **one chime**. Pages
take presses: a name on CONTACTS becomes the flight destination, the
destination on FLIGHT **swaps between `HOME` and the waypoint**, and `[ MARK ]`
drops the waypoint where you are standing. The weather page carries the base's
**buffer percentage**.

**v8.3.** A mobile now takes its **base coordinates from the main base** it is
paired with, instead of being left pointing *home* at `0, 64, 0`. The flight
page can be aimed at **home, any contact, or a typed-in waypoint** — a contact
target follows them as they move. `HDG` and `CRS` carry their compass point.

**v8.2.** A **Flight** page — speed, climb, heading, course, altitude and the
way home, all derived from the pilot's position as it changes, so it needs no
peripheral at all. And every page redrawn for a **1×1 monitor**: below twenty
cells they drop their headings, shorten their labels and show only what is
worth a glance, instead of truncating the full layout into `AIRS` and `trac`.

**v8.1.** Mekanism reports **Joules**, not FE — a Basic Energy Cube holding
1.6 MFE answers `getMaxEnergy()` with 4,000,000 — so every device is now read
raw and scaled per device, with the unit guessed from the methods it offers and
shown where you can correct it. Power clients **pair with one main base** and
address it directly, so several crews on a server no longer pool their readings.
A client can be renamed with `R` and repointed with `B`, and remembers both.

**v8 — networked edition.** Roles renamed to what they are actually used for:
**MAIN BASE** (the chunk-loaded master that holds the detectors), **MOBILE**
(pocket computers and vehicles) and **STANDALONE**. A new `powerclient`
program, so any number of computers can report energy readings the main base
merges, graphs and relays onward. Right-clicking a monitor to change its page
works again. The settings page shows the version, and stacks readably on a
pocket screen.

**v7 — modular edition.** Every page is a module in `radar/modules/`, with its
own settings, hardware and loops; drop a file in and it is a page. Device
**profiles** (base / pocket / airship), chosen on first boot. A **Power** page:
rates, buffer, rolling graph, low-power alarm on the shared alert channels, and
a `Buffer` redstone mode. `radar/chart.lua` for sub-pixel line charts. The
preview renderer writes PNGs directly.

**v6 — backdrops.** Twenty hand-drawn scenes for the weather page, as a
**place** plus a **sky** chosen separately, with a timed cycle. Keep the place
and set the sky to live, and the airships fly through the real dusk and the real
rain.

**v5 — base and ship.** The first **role** under *Settings → Link*, so a ground
station could relay its sweep over rednet to a screen aboard a Create:
Aeronautics contraption that cannot scan for itself. Renamed in v8.

**v4 — Basalt edition.** Rebuilt on Basalt 2.5: tabbed pages, non-blocking
settings, 2×3 sub-pixel drawing for round range rings and a real sweep, the live
procedural weather page, biome scenery, unlockable orientation, and per-monitor
pages with a timed rotation.

Scanning, alerts, ranges, rotation, the ignore list, the alert log and the redstone
modes have behaved the same way throughout.
