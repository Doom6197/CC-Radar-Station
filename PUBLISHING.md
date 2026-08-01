# Publishing this to GitHub

One-time setup so `wget` works in game. Nothing here needs git installed.

---

## 1. Create the repository

Go to **<https://github.com/new>** and set:

| Field | Value |
|---|---|
| Repository name | `cc-radar-station` |
| Visibility | **Public** — required, see below |
| Initialize with README | **leave unticked** — this folder already has one |

Click **Create repository**.

> **Why public?** `raw.githubusercontent.com` only serves files without
> authentication for public repositories. A private repo would force the in-game
> installer to carry a GitHub token in plaintext on the computer, where anyone
> with access to that computer could read it.

---

## 2. Upload the files

On the empty repository page, click **uploading an existing file**, then drag
in **the entire contents** of

```
C:\Users\JeffD\Documents\AI\MineCraft ComputerCraft\Basalt
```

Select everything inside the folder — `radar.lua`, `install.lua`,
`manifest.txt`, `README.md`, `PUBLISHING.md`, and the `radar` and `preview`
folders. GitHub's uploader walks subfolders, so `radar/views/weather.lua` keeps
its path.

Scroll down, leave the commit message as-is, and click **Commit changes**.

### Check it worked

The repository root should list exactly this:

```
preview/     radar/     README.md     PUBLISHING.md
install.lua  manifest.txt   radar.lua
```

Open `radar/views/` in the browser and confirm the six view files are there. If
`radar/` came out flat, or the `views` folder is missing, the drag picked up
files rather than folders — delete and re-upload by dragging the folders
themselves.

---

## 3. Check the branch name

GitHub names the default branch `main` for new repositories, which is what the
installer expects. Confirm it at the top-left of the file list. If it says
`master`, either rename it (**Settings → Branches → the pencil icon**) or pass
the branch when installing:

```
wget run <url> master
```

---

## 4. Install in game

```
wget run https://raw.githubusercontent.com/JeffDoom/cc-radar-station/main/install.lua
```

**If your GitHub username is not `JeffDoom`**, substitute it in that URL and
also pass it as an argument, because the installer has the default baked in for
the files it fetches afterwards:

```
wget run https://raw.githubusercontent.com/YOURNAME/cc-radar-station/main/install.lua YOURNAME/cc-radar-station
```

To avoid typing that every time, edit the `DEFAULT_REPO` line near the top of
`install.lua` (line 27) to your own `owner/repo` and re-upload that one file.

---

## Updating later

Edit files locally, then on the repository page use **Add file → Upload files**
and drag the changed ones in — GitHub replaces same-named files. In game, run
the same `wget run` command again; it overwrites the old install.

The installer adds a cache-busting query string to every request, so an update
lands immediately instead of waiting out `raw.githubusercontent.com`'s
five-minute cache.

**If you add a new module**, add its path to `manifest.txt` as well, or the
installer will not download it. `preview/install-test.lua` checks the manifest
against the files on disk.

---

## Optional polish

- **Description** — "Player radar with a live weather display for CC: Tweaked +
  Advanced Peripherals (MC 1.21.1)"
- **Topics** — `computercraft`, `cc-tweaked`, `minecraft`, `lua`, `basalt`,
  `advanced-peripherals`
- **Licence** — *Add file → Create new file*, name it `LICENSE`, and GitHub
  offers a template picker. MIT matches Basalt's own licence.
- The images in `preview/` render on the repository page, so the README shows
  what the weather display looks like without anyone installing it.
