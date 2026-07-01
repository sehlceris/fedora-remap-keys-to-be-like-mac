# fedora-remap-keys-to-be-like-mac

macOS-style key remapping for Fedora (GNOME on Wayland), powered by
[keyd](https://github.com/rvaiya/keyd). Works with both **laptop** keyboards
(e.g. ThinkPad) and **standard desktop** keyboards — pick your bottom-row
layout with `--layout` (see [Keyboard layout](#keyboard-layout)).

The key directly left of the spacebar (where macOS Cmd sits) becomes a **Cmd**
layer. Which physical key that is depends on your keyboard's bottom row, so the
installer supports two layouts (see [Keyboard layout](#keyboard-layout) below):

- **`thinkpad`** (default): the ThinkPad bottom row is `Fn Ctrl Win Alt Space`,
  so physical **Alt** sits left of space. Alt becomes the Cmd layer and the
  **Win** key takes over as Alt so nothing is lost (a true swap).
- **`standard`**: a standard US desktop row is `Ctrl Alt Super Space Alt Fn`,
  so physical **Super** sits left of space. Super becomes the Cmd layer; **Alt**
  is already in the Option position (just like a Mac), so it is left untouched —
  no swap needed.

## What you get

| Chord (Cmd = key next to space) | Action |
|---|---|
| Cmd+C / Cmd+V / Cmd+X | copy / paste / cut |
| Cmd+A | select all |
| Cmd+Z | undo (Cmd+Shift+Z = redo) |
| Cmd+W | close tab (sends Ctrl+W) |
| Cmd+R | reload |
| Cmd+T / Cmd+N / Cmd+L | new tab / new window / address bar (Shift composes: Cmd+Shift+T reopens a tab) |
| Cmd+S / Cmd+F / Cmd+P / Cmd+O | save / find / print / open |
| Cmd+Q | close window (sends Alt+F4) |
| Cmd+Tab | app switcher |
| Cmd tap | GNOME overview (still sends Super) |
| Win key (`thinkpad` layout) | acts as Alt (Alt+F4-style accelerators, menus) |

Commented-out extras (Cmd+Q, Cmd+Space, line/word jumps) live at the bottom of
the generated config — uncomment to taste.

### The Ctrl guarantee

**Physical Ctrl is never remapped.** Plain Ctrl+C keeps sending SIGINT in
every terminal (real, VS Code integrated, web terminals). The scripts contain
a grep guard that aborts if a generated config would ever bind
`control`/`leftcontrol`/`rightcontrol` as a mapping source, and the install
verification re-checks the installed file.

## Install

```bash
./install-mac-keys.sh                       # prompts for layout (interactive)
./install-mac-keys.sh --layout standard     # standard US desktop layout
./install-mac-keys.sh --dry-run             # preview without changing anything
```

Run without `--layout` on a terminal and the installer asks which layout to
use. When piped (e.g. `curl … | bash`) it can't prompt, so it defaults to
`thinkpad`.

- Installs keyd from the [`alternateved/keyd` COPR](https://copr.fedorainfracloud.org/coprs/alternateved/keyd/)
  (falls back to building from source if COPR fails); requires keyd >= 2.2.
- Confirms the real config path via `man keyd` (`.conf` vs `.cfg` differs
  across keyd versions) and writes a sentinel-marked config, backing up any
  pre-existing one.
- Enables/starts the `keyd` service and adds you to the `keyd` group
  (re-login needed for `keyd monitor`; the mappings themselves work
  immediately).
- Records everything it changed in `/var/lib/mac-keys-script/state`.
- Idempotent — safe to re-run; re-runs converge with no duplication.

## Keyboard layout

Pick the layout that matches your keyboard's bottom row with `--layout`, or
omit it to be prompted interactively (defaults to `thinkpad` when piped):

```bash
./install-mac-keys.sh --layout thinkpad   # default
./install-mac-keys.sh --layout standard
```

| Layout | Bottom row | Key left of space | What becomes the Cmd layer |
|---|---|---|---|
| `thinkpad` (default) | `Fn Ctrl Win Alt Space` | Alt | Alt → Cmd layer, and Win → Alt (a swap) |
| `standard` | `Ctrl Alt Super Space Alt Fn` | Super | Super → Cmd layer (Alt is already Option — no swap) |

Only the `[main]` block differs between layouts. Each layout's `[main]` block
lives in [`layouts/`](layouts/) (`layouts/thinkpad.conf`,
`layouts/standard.conf`); the installer splices the chosen one into the shared
[`mac-keys.conf`](mac-keys.conf) body to produce `/etc/keyd/default.conf`. An
unknown `--layout` value aborts before anything is touched.

## Customizing key combinations

The shared mappings live in [`mac-keys.conf`](mac-keys.conf) — a plain keyd
config with a placeholder marker where the layout's `[main]` block is spliced
in. To add, change, or remove a chord, edit the `[cmd:M]` layer and re-run the
installer (it validates, installs, and hot-reloads keyd):

```ini
b = C-b        # example: Cmd+B → Ctrl+B (bold)
```

```bash
./install-mac-keys.sh
```

Pre-written extras (Cmd+Space, line jumps, Option-key word jumps) are at the
bottom of the file, commented out. Edit the repo copy, not
`/etc/keyd/default.conf` — the installer overwrites the installed copy.

## Uninstall

```bash
./uninstall-mac-keys.sh          # revert mappings only; keyd stays installed
./uninstall-mac-keys.sh --purge  # full teardown: remove keyd + COPR repo too
```

The default run restores your previous config (if one was backed up), reloads
keyd, and removes only what the installer added — it only ever deletes a
config carrying the script's sentinel marker. Running it when nothing is
installed exits 0 cleanly. Both scripts support `--dry-run`.

## Gotchas

- **Chords are global, not per-app.** Without keyd's GNOME Shell extension
  there is no per-application scoping, so every Cmd chord sends its Ctrl
  chord everywhere — most visibly in terminals:
  - Cmd+C sends Ctrl+C = **SIGINT**, not copy. Use the terminal's native
    Ctrl+Shift+C / Ctrl+Shift+V.
  - Cmd+S sends Ctrl+S = **freezes terminal output** (Ctrl+Q unfreezes).
  - Cmd+W sends Ctrl+W = delete-word in shells.
- **The remap is system-wide at the input-device level** — it applies on
  the lock screen, GDM login, and virtual consoles too, and to any
  keyboard you plug in (`[ids] *`), where the Alt/Win swap may not match
  an external keyboard's physical layout.
- **Bare Cmd tap still sends Super**, so tapping the Cmd key opens the
  GNOME overview. Holding it for chords does not.
- **Super+L (GNOME screen lock) is unreachable.** Cmd+L is claimed by the
  address-bar mapping (`l = C-l`) and the Win key acts as Alt, so no key
  emits Super+L. Lock via `loginctl lock-session`, remove the `l = C-l`
  line, or rebind GNOME's lock shortcut. Other unmapped Super chords pass
  through fine — only keys claimed in the `[cmd:M]` layer shadow their
  Super shortcut.
- **Cmd+Q closes the focused window** (Alt+F4), it does not quit the whole
  app like macOS.
- **Hand-edits to `/etc/keyd/default.conf` are overwritten** by the next
  installer run (the sentinel on line 1 marks it as managed) — edit
  `mac-keys.conf` in the repo instead.
- **`keyd monitor` needs the keyd group**, which only takes effect after
  logging out and back in. The mappings themselves work immediately.
- **If something goes wrong**, `sudo systemctl stop keyd` instantly returns
  the keyboard to stock behavior; `./uninstall-mac-keys.sh` reverts the
  config cleanly.

## Tested on

Fedora 44, GNOME on Wayland, keyd 2.6.0. Developed on a ThinkPad X1 Carbon
(`thinkpad` layout); the `standard` layout targets standard US desktop
keyboards.
