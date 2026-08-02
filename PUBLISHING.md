# Publishing

How this repository gets from a folder on disk to a `wget run` line in game.

The repository is **<https://github.com/Doom6197/CC-Radar-Station>**, and it has
to stay **public**: `raw.githubusercontent.com` only serves files without
authentication for public repositories, and a private one would force the
in-game installer to carry a GitHub token in plaintext on a computer anyone
could read it off.

---

## Installing in game

```
wget run https://raw.githubusercontent.com/Doom6197/CC-Radar-Station/main/install.lua
```

The installer adds a cache-busting query string to every request, so an update
lands immediately instead of waiting out `raw.githubusercontent.com`'s
five-minute cache. Running it again overwrites the old install.

**From a fork**, pass the repository as an argument too — the installer has the
default baked in for the files it fetches afterwards:

```
wget run https://raw.githubusercontent.com/YOURNAME/CC-Radar-Station/main/install.lua YOURNAME/CC-Radar-Station
```

To avoid typing that every time, edit `DEFAULT_REPO` near the top of
`install.lua` and push that one file.

---

## Before you push

Both suites run on a desktop Lua 5.x with no Minecraft and no network:

```
lua preview/smoke-test.lua .        # 139 checks
lua preview/install-test.lua .      # 16 checks
```

`install-test.lua` runs the real `install.lua` against a mocked CC: Tweaked,
serving this repository off disk — so a manifest that has drifted from what is
actually here fails there rather than in game.

**If you added a module or any other file, add its path to `manifest.txt`.**
The installer downloads exactly what that file lists; anything missing from it
simply never reaches the computer, and a page that does not exist is a
confusing thing to debug in game. `install-test.lua` checks the manifest three
ways: every listed path exists, every built-in module named in
`radar/modules.lua` is listed, and every module file on disk is listed.

---

## Pushing

```
git add -A
git commit -m "..."
git push
```

Or use **Add file → Upload files** on the repository page and drag the changed
files in; GitHub replaces same-named files and its uploader walks subfolders, so
`radar/modules/weather.lua` keeps its path.

The default branch is `main`, which is what the installer expects. Installing
from another branch:

```
wget run <url> dev
```

---

## Preview images

`preview/*.png` are rendered from the real drawing code, not screenshotted:

```
lua preview/render-preview.lua . preview
```

`render-preview.lua` compiles the pixel grid into teletext cells exactly as the
game will, then expands each cell back into the two colours that survived, and
writes a PNG with its own CRC32, Adler32 and deflate encoder. There is no
conversion step and no image library involved.

The images render on the repository page, so the README shows what the station
looks like without anyone installing it. Regenerate them whenever the drawing
code changes — but only commit the ones that actually differ, since every sheet
is rewritten on each run.

---

## Repository settings worth having

- **Description** — "Player radar, weather display and power monitor for
  CC: Tweaked + Advanced Peripherals (MC 1.21.1). Modular pages."
- **Topics** — `computercraft`, `cc-tweaked`, `minecraft`, `lua`, `basalt`,
  `advanced-peripherals`
- **Licence** — *Add file → Create new file*, name it `LICENSE`, and GitHub
  offers a template picker. MIT matches Basalt's own licence.
